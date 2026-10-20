// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

//! CloudStack orchestrator extension for Parallels Desktop on macOS.
//!
//! The management server reaches the Mac over SSH (or runs locally when the
//! management server itself runs on the Mac) and drives Parallels Desktop
//! through its command line tool `prlctl`, which requires the Pro or Business
//! edition of Parallels Desktop.
//!
//! Instances are created by cloning an existing Parallels virtual machine or
//! template, after which CPU count, memory and NIC MAC addresses are set from
//! the CloudStack instance. The Parallels virtual machine is named after the
//! CloudStack instance's internal name.
//!
//! See README.txt for the supported details and custom actions.

use serde_json::{json, Map, Value};
use std::collections::BTreeMap;
use std::io::Read;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const DEFAULT_PRLCTL_PATHS: [&str; 2] = [
    "/usr/local/bin/prlctl",
    "/Applications/Parallels Desktop.app/Contents/MacOS/prlctl",
];
const PARALLELS_BUNDLE_ID: &str = "com.parallels.desktop.console";
const NETWORK_MODES: [&str; 3] = ["shared", "bridged", "host-only"];
const LOCAL_HOSTS: [&str; 3] = ["localhost", "127.0.0.1", "::1"];

const POWER_ON_STATES: [&str; 7] = [
    "running",
    "starting",
    "paused",
    "pausing",
    "continuing",
    "resuming",
    "resetting",
];
const POWER_OFF_STATES: [&str; 2] = ["stopped", "suspended"];

type Result<T> = std::result::Result<T, String>;

#[derive(Debug)]
struct Config {
    url: String,
    username: String,
    password: String,
    ssh_key: String,
    ssh_port: String,
    verify_host_key: bool,
    prlctl: String,
    linked_clone: bool,
    network_mode: String,
    bridge_interface: String,
    headless: bool,
    wait_timeout: u64,
    template_name: String,
    local: bool,
    vmname: String,
    cpus: Option<String>,
    memory: Option<u64>,
    macs: Vec<String>,
    snapshot_name: String,
}

/// Renders a JSON scalar as a detail value; empty strings and null count as unset.
fn value_str(value: Option<&Value>) -> Option<String> {
    match value? {
        Value::String(s) if !s.is_empty() => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        Value::Bool(b) => Some(b.to_string()),
        _ => None,
    }
}

fn object(value: Option<&Value>) -> Option<&Map<String, Value>> {
    value.and_then(Value::as_object)
}

impl Config {
    fn parse(json_data: &Value) -> Result<Config> {
        let empty = Map::new();
        let external = object(json_data.get("externaldetails")).unwrap_or(&empty);
        let extension = object(external.get("extension")).unwrap_or(&empty);
        let host = object(external.get("host")).unwrap_or(&empty);
        let vm = object(external.get("virtualmachine")).unwrap_or(&empty);

        let detail = |name: &str, default: &str| -> String {
            value_str(host.get(name))
                .or_else(|| value_str(extension.get(name)))
                .unwrap_or_else(|| default.to_string())
        };
        let flag = |name: &str, default: &str| detail(name, default).to_lowercase() == "true";

        let wait_timeout = detail("wait_timeout", "120");
        let mut config = Config {
            url: detail("url", ""),
            username: detail("username", ""),
            password: detail("password", ""),
            ssh_key: detail("ssh_key", ""),
            ssh_port: detail("ssh_port", "22"),
            verify_host_key: flag("verify_host_key", "true"),
            prlctl: detail("prlctl_path", ""),
            linked_clone: flag("linked_clone", "false"),
            network_mode: detail("network_mode", "").to_lowercase(),
            bridge_interface: detail("bridge_interface", ""),
            headless: flag("headless", "false"),
            wait_timeout: wait_timeout
                .parse()
                .map_err(|_| format!("Error parsing JSON: invalid wait_timeout '{wait_timeout}'"))?,
            template_name: value_str(vm.get("template_name")).unwrap_or_else(|| detail("template_name", "")),
            local: false,
            vmname: String::new(),
            cpus: None,
            memory: None,
            macs: Vec::new(),
            snapshot_name: String::new(),
        };
        if config.url.is_empty() {
            return Err("Missing required field in JSON: url".into());
        }
        if !config.network_mode.is_empty() && !NETWORK_MODES.contains(&config.network_mode.as_str()) {
            return Err(format!(
                "Invalid network_mode '{}', expected one of {}",
                config.network_mode,
                NETWORK_MODES.join(", ")
            ));
        }
        if config.network_mode == "bridged" && config.bridge_interface.is_empty() {
            return Err("Missing required field in JSON: bridge_interface (required for bridged network_mode)".into());
        }
        config.local = LOCAL_HOSTS.contains(&config.url.to_lowercase().as_str()) && config.username.is_empty();
        if !config.local && config.username.is_empty() {
            return Err("Missing required field in JSON: username".into());
        }

        let vm_details = object(json_data.get("cloudstack.vm.details")).unwrap_or(&empty);
        config.vmname = value_str(vm_details.get("name")).unwrap_or_default();
        config.cpus = value_str(vm_details.get("cpus"));
        config.memory = match value_str(vm_details.get("minRam")) {
            Some(m) => Some(
                m.parse()
                    .map_err(|_| format!("Error parsing JSON: invalid minRam '{m}'"))?,
            ),
            None => None,
        };
        let mut nics: Vec<&Value> = vm_details
            .get("nics")
            .and_then(Value::as_array)
            .map(|n| n.iter().collect())
            .unwrap_or_default();
        nics.sort_by_key(|n| n.get("deviceId").and_then(Value::as_i64).unwrap_or(0));
        config.macs = nics.iter().filter_map(|n| value_str(n.get("mac"))).collect();

        let parameters = object(json_data.get("parameters")).unwrap_or(&empty);
        config.snapshot_name = value_str(parameters.get("snapshot_name"))
            .unwrap_or_default()
            .trim()
            .to_string();
        Ok(config)
    }
}

/// Quotes an argument for a POSIX shell, like Python's shlex.quote.
fn shell_quote(arg: &str) -> String {
    if arg.is_empty() {
        return "''".into();
    }
    if arg
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || "@%+=:,./-_".contains(c))
    {
        return arg.into();
    }
    format!("'{}'", arg.replace('\'', "'\"'\"'"))
}

fn power_state(state: Option<&str>) -> &'static str {
    match state {
        Some(s) if POWER_ON_STATES.contains(&s) => "poweron",
        Some(s) if POWER_OFF_STATES.contains(&s) => "poweroff",
        _ => "unknown",
    }
}

/// Network adapters (net0, net1, ...) of a `prlctl list --info --json` Hardware section, in order.
fn net_devices(hardware: &Map<String, Value>) -> Vec<String> {
    let mut devices: Vec<(u32, String)> = hardware
        .keys()
        .filter_map(|d| {
            d.strip_prefix("net")
                .and_then(|n| n.parse().ok())
                .map(|n| (n, d.clone()))
        })
        .collect();
    devices.sort();
    devices.into_iter().map(|(_, d)| d).collect()
}

fn parse_ip_addresses(output: &str) -> Vec<String> {
    output
        .replace(',', " ")
        .split_whitespace()
        .filter(|a| *a != "-")
        .map(String::from)
        .collect()
}

fn success(message: &str) -> Value {
    json!({"status": "success", "message": message})
}

struct ParallelsManager {
    data: Config,
}

impl ParallelsManager {
    fn ssh_command(&self, remote_argv: &[String]) -> Vec<String> {
        let d = &self.data;
        let mut cmd: Vec<String> = vec![
            "ssh".into(),
            "-o".into(),
            "ConnectTimeout=15".into(),
            "-o".into(),
            format!("StrictHostKeyChecking={}", if d.verify_host_key { "yes" } else { "no" }),
            "-p".into(),
            d.ssh_port.clone(),
        ];
        if !d.verify_host_key {
            cmd.extend(["-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR"].map(String::from));
        }
        if !d.ssh_key.is_empty() {
            cmd.extend(["-i".into(), d.ssh_key.clone()]);
        }
        if !d.password.is_empty() {
            cmd.splice(0..0, ["sshpass", "-e"].map(String::from));
            cmd.extend(["-o", "BatchMode=no"].map(String::from));
        } else {
            cmd.extend(["-o", "BatchMode=yes"].map(String::from));
        }
        let remote: Vec<String> = remote_argv.iter().map(|a| shell_quote(a)).collect();
        cmd.extend([format!("{}@{}", d.username, d.url), "--".into(), remote.join(" ")]);
        cmd
    }

    fn run(&self, argv: &[String]) -> Result<String> {
        let cmd = if self.data.local {
            argv.to_vec()
        } else {
            self.ssh_command(argv)
        };
        let mut command = Command::new(&cmd[0]);
        command
            .args(&cmd[1..])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if !self.data.local && !self.data.password.is_empty() {
            command.env("SSHPASS", &self.data.password);
        }
        let mut child = command.spawn().map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => format!("Command not found: {}", cmd[0]),
            _ => format!("Failed to run {}: {e}", cmd[0]),
        })?;

        let read_all = |mut pipe: Box<dyn Read + Send>| {
            thread::spawn(move || {
                let mut s = String::new();
                let _ = pipe.read_to_string(&mut s);
                s
            })
        };
        let stdout = read_all(Box::new(child.stdout.take().expect("piped stdout")));
        let stderr = read_all(Box::new(child.stderr.take().expect("piped stderr")));

        let deadline = Instant::now() + Duration::from_secs(self.data.wait_timeout + 30);
        let status = loop {
            if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
                break status;
            }
            if Instant::now() > deadline {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("Timed out running: {}", argv.join(" ")));
            }
            thread::sleep(Duration::from_millis(50));
        };
        let stdout = stdout.join().unwrap_or_default();
        let stderr = stderr.join().unwrap_or_default();
        if !status.success() {
            let message = if stderr.trim().is_empty() {
                stdout.trim()
            } else {
                stderr.trim()
            };
            return Err(if message.is_empty() {
                format!("'{}' exited with {}", argv.join(" "), status.code().unwrap_or(-1))
            } else {
                message.to_string()
            });
        }
        Ok(stdout)
    }

    fn resolve_prlctl(&self) -> Result<String> {
        let candidates: Vec<String> = DEFAULT_PRLCTL_PATHS.iter().map(|p| shell_quote(p)).collect();
        let script = format!(
            "for p in {}; do [ -x \"$p\" ] && echo \"$p\" && exit 0; done; \
             p=\"$(mdfind \"kMDItemCFBundleIdentifier == '{PARALLELS_BUNDLE_ID}'\" | head -n 1)/Contents/MacOS/prlctl\"; \
             [ -x \"$p\" ] && echo \"$p\"",
            candidates.join(" ")
        );
        let path = self
            .run(&["sh".into(), "-c".into(), script])
            .map(|p| p.trim().to_string())
            .unwrap_or_default();
        if path.is_empty() {
            return Err("Parallels Desktop not found on the host, set the prlctl_path detail".into());
        }
        Ok(path)
    }

    fn prlctl(&mut self, args: &[&str]) -> Result<String> {
        if self.data.prlctl.is_empty() {
            self.data.prlctl = self.resolve_prlctl()?;
        }
        let mut argv = vec![self.data.prlctl.clone()];
        argv.extend(args.iter().map(|a| a.to_string()));
        self.run(&argv)
    }

    fn prlctl_json(&mut self, args: &[&str]) -> Result<Value> {
        let output = self.prlctl(args)?;
        let output = output.trim();
        if output.is_empty() {
            return Ok(Value::Null);
        }
        serde_json::from_str(output).map_err(|_| format!("Failed to parse prlctl output: {output}"))
    }

    fn list_vms(&mut self, templates: bool) -> Result<BTreeMap<String, String>> {
        let mut args = vec!["list", "--all", "--json"];
        if templates {
            args.push("--template");
        }
        let vms = self.prlctl_json(&args)?;
        Ok(vms
            .as_array()
            .map(|vms| {
                vms.iter()
                    .filter_map(|vm| {
                        let name = value_str(vm.get("name"))?;
                        Some((name, value_str(vm.get("status")).unwrap_or_default().to_lowercase()))
                    })
                    .collect()
            })
            .unwrap_or_default())
    }

    fn vm_state(&mut self, name: &str) -> Result<Option<String>> {
        Ok(self.list_vms(false)?.remove(name))
    }

    fn vm_info(&mut self, name: &str) -> Result<Value> {
        let info = self.prlctl_json(&["list", "--info", "--json", name])?;
        Ok(match info {
            Value::Array(mut items) if !items.is_empty() => items.swap_remove(0),
            Value::Object(_) => info,
            _ => json!({}),
        })
    }

    fn wait_for_state(&mut self, states: &[&str], name: &str) -> Result<String> {
        let deadline = Instant::now() + Duration::from_secs(self.data.wait_timeout);
        loop {
            let state = self.vm_state(name)?;
            if let Some(s) = state.as_deref().filter(|s| states.contains(s)) {
                return Ok(s.to_string());
            }
            if Instant::now() > deadline {
                return Err(format!(
                    "Timed out waiting for {name} to reach {}, current state: {}",
                    states.join("/"),
                    state.as_deref().unwrap_or("None")
                ));
            }
            thread::sleep(Duration::from_secs(2));
        }
    }

    fn require_vmname(&self) -> Result<String> {
        if self.data.vmname.is_empty() {
            return Err("Missing required field in JSON: cloudstack.vm.details.name".into());
        }
        Ok(self.data.vmname.clone())
    }

    fn require_snapshot_name(&self) -> Result<String> {
        if self.data.snapshot_name.is_empty() {
            return Err("Missing required field in JSON: snapshot_name".into());
        }
        Ok(self.data.snapshot_name.clone())
    }

    fn stop_vm(&mut self, name: &str) -> Result<()> {
        match self.vm_state(name)?.as_deref() {
            None | Some("stopped") => Ok(()),
            Some("suspended") => self.prlctl(&["stop", name, "--drop-state"]).map(|_| ()),
            Some(_) => {
                let graceful = self
                    .prlctl(&["stop", name])
                    .and_then(|_| self.wait_for_state(&["stopped"], name));
                if graceful.is_err() {
                    self.prlctl(&["stop", name, "--kill"])?;
                    self.wait_for_state(&["stopped"], name)?;
                }
                Ok(())
            }
        }
    }

    fn configure_nics(&mut self, vm_name: &str) -> Result<()> {
        let info = self.vm_info(vm_name)?;
        let existing = info
            .get("Hardware")
            .and_then(Value::as_object)
            .map(net_devices)
            .unwrap_or_default();
        let mode = self.data.network_mode.clone();
        let mut mode_args: Vec<String> = Vec::new();
        if !mode.is_empty() {
            mode_args.extend(["--type".into(), mode.clone()]);
            if mode == "bridged" {
                mode_args.extend(["--iface".into(), self.data.bridge_interface.clone()]);
            }
        }
        let macs = self.data.macs.clone();
        for (i, mac) in macs.iter().enumerate() {
            let mac = mac.replace(':', "").to_uppercase();
            let mut args: Vec<String> = vec!["set".into(), vm_name.into()];
            match existing.get(i) {
                Some(device) => {
                    args.extend(["--device-set".into(), device.clone(), "--mac".into(), mac]);
                    args.extend(mode_args.iter().cloned());
                }
                None => {
                    args.extend(["--device-add".into(), "net".into(), "--mac".into(), mac]);
                    if mode_args.is_empty() {
                        args.extend(["--type".into(), "shared".into()]);
                    } else {
                        args.extend(mode_args.iter().cloned());
                    }
                }
            }
            let args: Vec<&str> = args.iter().map(String::as_str).collect();
            self.prlctl(&args)?;
        }
        for device in existing.iter().skip(macs.len()) {
            self.prlctl(&["set", vm_name, "--device-del", device])?;
        }
        Ok(())
    }

    fn create(&mut self) -> Result<Value> {
        let vm_name = self.require_vmname()?;
        let template = self.data.template_name.clone();
        if template.is_empty() {
            return Err("Missing required field in JSON: template_name".into());
        }
        let (Some(cpus), Some(memory)) = (self.data.cpus.clone(), self.data.memory) else {
            return Err("Missing CPU or memory in cloudstack.vm.details".into());
        };

        let vms = self.list_vms(true)?;
        if !vms.contains_key(&template) {
            return Err(format!("Template VM '{template}' not found in Parallels Desktop"));
        }
        if vms.contains_key(&vm_name) {
            return Err(format!("A Parallels VM named '{vm_name}' already exists"));
        }

        let mut clone_args = vec!["clone", template.as_str(), "--name", vm_name.as_str()];
        if self.data.linked_clone {
            clone_args.push("--linked");
        }
        self.prlctl(&clone_args)?;

        let result = (|| {
            let memory_mib = (memory / (1024 * 1024)).to_string();
            let mut set_args = vec![
                "set",
                vm_name.as_str(),
                "--cpus",
                cpus.as_str(),
                "--memsize",
                memory_mib.as_str(),
            ];
            if self.data.headless {
                set_args.extend(["--startup-view", "headless"]);
            }
            self.prlctl(&set_args)?;
            self.configure_nics(&vm_name)?;
            self.prlctl(&["start", &vm_name])
        })();
        if let Err(e) = result {
            let _ = self.stop_vm(&vm_name).and_then(|_| self.prlctl(&["delete", &vm_name]));
            return Err(e);
        }
        Ok(success("Instance created"))
    }

    fn start(&mut self) -> Result<Value> {
        let name = self.require_vmname()?;
        self.prlctl(&["start", &name])?;
        Ok(success("Instance started"))
    }

    fn stop(&mut self) -> Result<Value> {
        let name = self.require_vmname()?;
        self.stop_vm(&name)?;
        Ok(success("Instance stopped"))
    }

    fn reboot(&mut self) -> Result<Value> {
        let name = self.require_vmname()?;
        self.prlctl(&["restart", &name])?;
        Ok(success("Instance rebooted"))
    }

    fn delete(&mut self) -> Result<Value> {
        let name = self.require_vmname()?;
        if self.vm_state(&name)?.is_some() {
            self.stop_vm(&name)?;
            self.prlctl(&["delete", &name])?;
        }
        Ok(success("Instance deleted"))
    }

    fn status(&mut self) -> Result<Value> {
        let name = self.require_vmname()?;
        let state = self.vm_state(&name)?;
        Ok(json!({"status": "success", "power_state": power_state(state.as_deref())}))
    }

    fn statuses(&mut self) -> Result<Value> {
        let states: Map<String, Value> = self
            .list_vms(false)?
            .into_iter()
            .map(|(name, state)| (name, Value::from(power_state(Some(&state)))))
            .collect();
        Ok(json!({"status": "success", "power_state": states}))
    }

    fn get_console(&mut self) -> Result<Value> {
        Err("Operation not supported".into())
    }

    fn suspend(&mut self) -> Result<Value> {
        let name = self.require_vmname()?;
        self.prlctl(&["pause", &name])?;
        Ok(success("Instance suspended"))
    }

    fn resume(&mut self) -> Result<Value> {
        let name = self.require_vmname()?;
        self.prlctl(&["resume", &name])?;
        Ok(success("Instance resumed"))
    }

    fn get_ip_addresses(&mut self) -> Result<Value> {
        let name = self.require_vmname()?;
        let output = self.prlctl(&["list", "--full", "--no-header", "--output", "ip", &name])?;
        Ok(json!({"status": "success", "printmessage": "true", "message": parse_ip_addresses(&output)}))
    }

    /// Snapshots keyed by snapshot ID.
    fn snapshots(&mut self, name: &str) -> Result<Vec<(String, Value)>> {
        Ok(match self.prlctl_json(&["snapshot-list", name, "--json"])? {
            Value::Object(map) => map.into_iter().collect(),
            Value::Array(items) => items
                .into_iter()
                .map(|s| (value_str(s.get("id")).unwrap_or_default(), s))
                .collect(),
            _ => Vec::new(),
        })
    }

    fn snapshot_id(&mut self, name: &str, snapshot_name: &str) -> Result<String> {
        let matches: Vec<String> = self
            .snapshots(name)?
            .into_iter()
            .filter(|(_, s)| s.get("name").and_then(Value::as_str) == Some(snapshot_name))
            .map(|(id, _)| id)
            .collect();
        match matches.as_slice() {
            [] => Err(format!("Snapshot '{snapshot_name}' not found")),
            [id] => Ok(id.clone()),
            _ => Err(format!("Multiple snapshots named '{snapshot_name}' found")),
        }
    }

    fn list_snapshots(&mut self) -> Result<Value> {
        let name = self.require_vmname()?;
        let snapshots: Vec<Value> = self
            .snapshots(&name)?
            .into_iter()
            .map(|(_, s)| {
                json!({
                    "Name": value_str(s.get("name")).unwrap_or_default(),
                    "CreationTime": value_str(s.get("date")).unwrap_or_default(),
                    "Current": s.get("current").and_then(Value::as_bool).unwrap_or(false),
                })
            })
            .collect();
        Ok(json!({"status": "success", "printmessage": "true", "message": snapshots}))
    }

    fn create_snapshot(&mut self) -> Result<Value> {
        let name = self.require_vmname()?;
        let snapshot = self.require_snapshot_name()?;
        self.prlctl(&["snapshot", &name, "--name", &snapshot])?;
        Ok(success(&format!("Snapshot '{snapshot}' created")))
    }

    fn restore_snapshot(&mut self) -> Result<Value> {
        let name = self.require_vmname()?;
        let snapshot = self.require_snapshot_name()?;
        let id = self.snapshot_id(&name, &snapshot)?;
        self.prlctl(&["snapshot-switch", &name, "--id", &id])?;
        Ok(success(&format!("Snapshot '{snapshot}' restored")))
    }

    fn delete_snapshot(&mut self) -> Result<Value> {
        let name = self.require_vmname()?;
        let snapshot = self.require_snapshot_name()?;
        let id = self.snapshot_id(&name, &snapshot)?;
        self.prlctl(&["snapshot-delete", &name, "--id", &id])?;
        Ok(success(&format!("Snapshot '{snapshot}' deleted")))
    }
}

fn load_config(path: &str) -> Result<Config> {
    let content = std::fs::read_to_string(path).map_err(|e| match e.kind() {
        std::io::ErrorKind::NotFound => format!("JSON file not found: {path}"),
        _ => format!("Failed to read JSON file {path}: {e}"),
    })?;
    let json_data: Value = serde_json::from_str(&content).map_err(|_| "Invalid JSON in file".to_string())?;
    Config::parse(&json_data)
}

fn execute(args: &[String]) -> Result<Value> {
    if args.len() < 3 {
        return Err("Usage: parallels <operation> '<json-file-path>'".into());
    }
    let operation = args[1].to_lowercase();
    let mut manager = ParallelsManager {
        data: load_config(&args[2])?,
    };

    match operation.as_str() {
        "create" => manager.create(),
        "start" => manager.start(),
        "stop" => manager.stop(),
        "reboot" => manager.reboot(),
        "delete" => manager.delete(),
        "status" => manager.status(),
        "statuses" => manager.statuses(),
        "getconsole" => manager.get_console(),
        "suspend" => manager.suspend(),
        "resume" => manager.resume(),
        "getipaddresses" => manager.get_ip_addresses(),
        "listsnapshots" => manager.list_snapshots(),
        "createsnapshot" => manager.create_snapshot(),
        "restoresnapshot" => manager.restore_snapshot(),
        "deletesnapshot" => manager.delete_snapshot(),
        _ => Err("Invalid action".into()),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match execute(&args) {
        Ok(data) => println!("{data}"),
        Err(error) => {
            println!("{}", json!({"status": "error", "error": error}));
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn payload(extension: Value) -> Value {
        json!({
            "externaldetails": {"extension": extension, "host": {"ssh_port": 2222}, "virtualmachine": {}},
            "cloudstack.vm.details": {
                "name": "i-2-10-VM", "cpus": 2, "minRam": 2147483648u64,
                "nics": [{"deviceId": 1, "mac": "02:00:00:00:00:02"}, {"deviceId": 0, "mac": "02:00:00:00:00:01"}]
            },
            "parameters": {"snapshot_name": " s1 "}
        })
    }

    #[test]
    fn parses_local_payload() {
        let c = Config::parse(&payload(json!({"url": "localhost", "template_name": "tmpl"}))).unwrap();
        assert!(c.local);
        assert_eq!(c.ssh_port, "2222");
        assert_eq!(c.vmname, "i-2-10-VM");
        assert_eq!(c.cpus.as_deref(), Some("2"));
        assert_eq!(c.memory, Some(2147483648));
        assert_eq!(c.macs, vec!["02:00:00:00:00:01", "02:00:00:00:00:02"]);
        assert_eq!(c.template_name, "tmpl");
        assert_eq!(c.snapshot_name, "s1");
        assert!(c.verify_host_key);
        assert_eq!(c.wait_timeout, 120);
    }

    #[test]
    fn rejects_invalid_payloads() {
        assert!(Config::parse(&payload(json!({}))).unwrap_err().contains("url"));
        assert!(Config::parse(&payload(json!({"url": "mac.example"})))
            .unwrap_err()
            .contains("username"));
        let mode = json!({"url": "localhost", "network_mode": "nat"});
        assert!(Config::parse(&payload(mode))
            .unwrap_err()
            .contains("Invalid network_mode"));
        let bridged = json!({"url": "localhost", "network_mode": "Bridged"});
        assert!(Config::parse(&payload(bridged))
            .unwrap_err()
            .contains("bridge_interface"));
    }

    #[test]
    fn quotes_like_shlex() {
        assert_eq!(shell_quote(""), "''");
        assert_eq!(shell_quote("i-2-10-VM"), "i-2-10-VM");
        assert_eq!(shell_quote("Parallels Desktop.app"), "'Parallels Desktop.app'");
        assert_eq!(shell_quote("it's"), "'it'\"'\"'s'");
    }

    #[test]
    fn maps_power_states() {
        assert_eq!(power_state(Some("running")), "poweron");
        assert_eq!(power_state(Some("paused")), "poweron");
        assert_eq!(power_state(Some("suspended")), "poweroff");
        assert_eq!(power_state(Some("invalid")), "unknown");
        assert_eq!(power_state(None), "unknown");
    }

    #[test]
    fn orders_net_devices() {
        let hardware = json!({"net10": {}, "cpu": {}, "net2": {}, "hdd0": {}, "netx": {}, "net0": {}});
        assert_eq!(
            net_devices(hardware.as_object().unwrap()),
            vec!["net0", "net2", "net10"]
        );
    }

    #[test]
    fn parses_ip_addresses() {
        assert_eq!(
            parse_ip_addresses("10.211.55.3, fdb2::1\n"),
            vec!["10.211.55.3", "fdb2::1"]
        );
        assert!(parse_ip_addresses("-\n").is_empty());
    }

    #[test]
    fn builds_ssh_command() {
        let mut ext = json!({"url": "mac.example", "username": "dev", "verify_host_key": "false"});
        let c = Config::parse(&payload(ext.take())).unwrap();
        let cmd = ParallelsManager { data: c }.ssh_command(&["prlctl".into(), "list".into(), "my vm".into()]);
        assert_eq!(cmd[0], "ssh");
        assert!(cmd.contains(&"BatchMode=yes".to_string()));
        assert!(cmd.contains(&"UserKnownHostsFile=/dev/null".to_string()));
        assert_eq!(
            cmd[cmd.len() - 2..],
            ["--".to_string(), "prlctl list 'my vm'".to_string()]
        );
    }
}
