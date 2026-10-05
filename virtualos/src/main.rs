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

//! CloudStack orchestrator extension for virtualOS on macOS.
//!
//! virtualOS (https://github.com/yep/virtualOS) runs macOS guests on Apple
//! silicon through Apple's Virtualization framework. It has no command line
//! interface, so this program manages its VM bundles directly and starts a VM
//! by launching a separate virtualOS process with the autostartVMBundlePath
//! user default set as a launch argument. Stopping a VM terminates that
//! process.
//!
//! The management server reaches the Mac over SSH (or runs locally when the
//! management server itself runs on the Mac). Instances are created by
//! cloning an existing virtualOS VM bundle, which is a copy-on-write copy on
//! APFS, after which the clone gets a new machine identifier and the CPU
//! count, memory and MAC address of the CloudStack instance. The bundle is
//! named after the CloudStack instance's internal name.
//!
//! Details (host details override extension details):
//!   url                   Mac hostname/IP, or "localhost" to run locally
//!   username              SSH user owning the virtualOS VMs (logged in to the GUI)
//!   password              optional, SSH password (requires sshpass on the
//!                         management server; key authentication is preferred)
//!   ssh_key               optional, private key path on the management server
//!   ssh_port              optional, defaults to 22
//!   verify_host_key       optional, "true" (default) or "false"
//!   app_path              optional, defaults to /Applications/virtualOS.app,
//!                         falling back to a Spotlight lookup of the app bundle
//!   vm_directory          optional, directory holding the VM bundles; must be
//!                         the "VM files" directory configured in virtualOS,
//!                         defaults to its sandbox container's Documents folder
//!   template_name         optional, default VM bundle to clone (without .bundle)
//!   network_mode          optional, nat|bridged; when set it is applied to the
//!                         instance, otherwise the template's mode is kept
//!   bridge_interface      optional, macOS interface for bridged mode, e.g. en0
//!   wait_timeout          optional, seconds to wait for state changes (120)
//!
//! Instance/template details:
//!   template_name         VM bundle to clone, overrides the host/extension value

use serde_json::{json, Map, Value};
use std::collections::BTreeMap;
use std::fs;
use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

const DEFAULT_APP_PATH: &str = "/Applications/virtualOS.app";
const VIRTUALOS_BUNDLE_ID: &str = "com.github.yep.ios.virtualOS";
const VIRTUALOS_LOG_SUBSYSTEM: &str = "com.github.virtualOS";
const AUTOSTART_ARGUMENT: &str = "-autostartVMBundlePath";
const LOCAL_HOSTS: [&str; 3] = ["localhost", "127.0.0.1", "::1"];
const DHCP_LEASES: &str = "/var/db/dhcpd_leases";
const REQUIRED_BUNDLE_FILES: [&str; 3] = ["HardwareModel", "AuxiliaryStorage", "Parameters.txt"];
const START_CHECK_DELAY: Duration = Duration::from_secs(5);

type Result<T> = std::result::Result<T, String>;

fn default_vm_directory() -> String {
    format!("~/Library/Containers/{VIRTUALOS_BUNDLE_ID}/Data/Documents")
}

fn network_type(mode: &str) -> Option<&'static str> {
    match mode {
        "nat" => Some("NAT"),
        "bridged" => Some("Bridge"),
        _ => None,
    }
}

fn success_message(message: &str) -> Value {
    json!({"status": "success", "message": message})
}

/// Lower case, zero padded form of a MAC address; macOS drops leading zeros in its DHCP leases.
fn normalize_mac(mac: &str) -> String {
    mac.split(':')
        .map(|octet| match u8::from_str_radix(octet.trim(), 16) {
            Ok(value) => format!("{value:02x}"),
            Err(_) => octet.trim().to_lowercase(),
        })
        .collect::<Vec<_>>()
        .join(":")
}

/// Quote an argument for a POSIX shell, like Python's shlex.quote.
fn shell_quote(arg: &str) -> String {
    let safe = |c: char| c.is_ascii_alphanumeric() || "@%+=:,./_-".contains(c);
    if !arg.is_empty() && arg.chars().all(safe) {
        arg.to_string()
    } else {
        format!("'{}'", arg.replace('\'', "'\"'\"'"))
    }
}

/// VZMacMachineIdentifier.dataRepresentation: a binary plist holding {"ECID": <integer>}.
fn machine_identifier(ecid: u64) -> Vec<u8> {
    let mut plist = b"bplist00".to_vec();
    // object 0 at offset 8: dict with one entry, key object 1, value object 2
    plist.extend_from_slice(&[0xd1, 0x01, 0x02]);
    // object 1 at offset 11: ASCII string of length 4
    plist.push(0x54);
    plist.extend_from_slice(b"ECID");
    // object 2 at offset 16: 8 byte integer
    plist.push(0x13);
    plist.extend_from_slice(&ecid.to_be_bytes());
    let offset_table = plist.len() as u64;
    plist.extend_from_slice(&[8, 11, 16]);
    // trailer: 6 unused bytes, offset size, object reference size, object count, top object, offset table offset
    plist.extend_from_slice(&[0; 6]);
    plist.extend_from_slice(&[1, 1]);
    plist.extend_from_slice(&3u64.to_be_bytes());
    plist.extend_from_slice(&0u64.to_be_bytes());
    plist.extend_from_slice(&offset_table.to_be_bytes());
    plist
}

fn random_ecid() -> Result<u64> {
    let mut bytes = [0u8; 8];
    fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut bytes))
        .map_err(|e| format!("Failed to read random data: {e}"))?;
    Ok(u64::from_be_bytes(bytes) >> 1)
}

/// IP addresses leased to the given (normalized) MAC address in a macOS dhcpd_leases file.
fn leased_addresses(leases: &str, mac: &str) -> Vec<String> {
    let mut addresses = Vec::new();
    for block in leases.split('{').skip(1) {
        let block = block.split('}').next().unwrap_or("");
        let fields: BTreeMap<&str, &str> = block
            .lines()
            .filter_map(|line| line.trim().split_once('='))
            .collect();
        let hw_address = fields.get("hw_address").map(|a| a.rsplit(',').next().unwrap_or("")).unwrap_or("");
        if let Some(ip) = fields.get("ip_address") {
            if !hw_address.is_empty() && normalize_mac(hw_address) == mac {
                addresses.push(ip.to_string());
            }
        }
    }
    addresses
}

/// Text of a JSON value that may be a string or a number.
fn value_text(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Null) | None => String::new(),
        Some(other) => other.to_string(),
    }
}

fn value_u64(value: Option<&Value>) -> Option<u64> {
    match value {
        Some(Value::Number(n)) => n.as_u64(),
        Some(Value::String(s)) => s.trim().parse().ok(),
        _ => None,
    }
}

struct Config {
    url: String,
    username: String,
    password: String,
    ssh_key: String,
    ssh_port: String,
    verify_host_key: bool,
    app_path: String,
    vm_directory: String,
    network_mode: String,
    bridge_interface: String,
    wait_timeout: u64,
    template_name: String,
    local: bool,
    vmname: String,
    cpus: Option<u64>,
    memory: Option<u64>,
    macs: Vec<String>,
}

impl Config {
    fn parse(json_data: &Value) -> Result<Config> {
        let empty = Map::new();
        let section = |value: Option<&Value>| value.and_then(Value::as_object).unwrap_or(&empty).clone();
        let external = section(json_data.get("externaldetails"));
        let extension = section(external.get("extension"));
        let host = section(external.get("host"));
        let vm = section(external.get("virtualmachine"));

        let detail = |name: &str, default: &str| {
            [host.get(name), extension.get(name)]
                .into_iter()
                .map(value_text)
                .find(|v| !v.is_empty())
                .unwrap_or_else(|| default.to_string())
        };
        let flag = |name: &str, default: &str| detail(name, default).to_lowercase() == "true";

        let url = detail("url", "");
        let username = detail("username", "");
        if url.is_empty() {
            return Err("Missing required field in JSON: url".into());
        }
        let network_mode = detail("network_mode", "").to_lowercase();
        if !network_mode.is_empty() && network_type(&network_mode).is_none() {
            return Err(format!("Invalid network_mode '{network_mode}', expected one of nat, bridged"));
        }
        let local = LOCAL_HOSTS.contains(&url.to_lowercase().as_str()) && username.is_empty();
        if !local && username.is_empty() {
            return Err("Missing required field in JSON: username".into());
        }
        let wait_timeout = detail("wait_timeout", "120")
            .trim()
            .parse()
            .map_err(|_| "Error parsing JSON: invalid wait_timeout".to_string())?;
        let template_name = Some(value_text(vm.get("template_name")))
            .filter(|t| !t.is_empty())
            .unwrap_or_else(|| detail("template_name", ""));

        let vm_details = section(json_data.get("cloudstack.vm.details"));
        let mut nics: Vec<&Value> = vm_details.get("nics").and_then(Value::as_array).map(|n| n.iter().collect()).unwrap_or_default();
        nics.sort_by_key(|nic| nic.get("deviceId").and_then(Value::as_i64).unwrap_or(0));
        let macs = nics
            .iter()
            .map(|nic| value_text(nic.get("mac")))
            .filter(|mac| !mac.is_empty())
            .collect();

        Ok(Config {
            url,
            username,
            password: detail("password", ""),
            ssh_key: detail("ssh_key", ""),
            ssh_port: detail("ssh_port", "22"),
            verify_host_key: flag("verify_host_key", "true"),
            app_path: detail("app_path", ""),
            vm_directory: detail("vm_directory", &default_vm_directory()).trim_end_matches('/').to_string(),
            network_mode,
            bridge_interface: detail("bridge_interface", ""),
            wait_timeout,
            template_name,
            local,
            vmname: value_text(vm_details.get("name")),
            cpus: value_u64(vm_details.get("cpus")),
            memory: value_u64(vm_details.get("minRam")),
            macs,
        })
    }
}

struct VirtualOSManager {
    config: Config,
}

impl VirtualOSManager {
    fn ssh_command(&self, remote_argv: &[String]) -> Vec<String> {
        let c = &self.config;
        let mut cmd: Vec<String> = vec![
            "ssh".into(),
            "-o".into(), "ConnectTimeout=15".into(),
            "-o".into(), format!("StrictHostKeyChecking={}", if c.verify_host_key { "yes" } else { "no" }),
            "-p".into(), c.ssh_port.clone(),
        ];
        if !c.verify_host_key {
            cmd.extend(["-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR"].map(String::from));
        }
        if !c.ssh_key.is_empty() {
            cmd.extend(["-i".to_string(), c.ssh_key.clone()]);
        }
        if !c.password.is_empty() {
            cmd.splice(0..0, ["sshpass".to_string(), "-e".to_string()]);
            cmd.extend(["-o", "BatchMode=no"].map(String::from));
        } else {
            cmd.extend(["-o", "BatchMode=yes"].map(String::from));
        }
        cmd.push(format!("{}@{}", c.username, c.url));
        cmd.push("--".into());
        cmd.push(remote_argv.iter().map(|a| shell_quote(a)).collect::<Vec<_>>().join(" "));
        cmd
    }

    fn run_with_input(&self, argv: &[String], stdin: Option<&[u8]>) -> Result<String> {
        let cmd = if self.config.local { argv.to_vec() } else { self.ssh_command(argv) };
        let mut command = Command::new(&cmd[0]);
        command
            .args(&cmd[1..])
            .stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if !self.config.local && !self.config.password.is_empty() {
            command.env("SSHPASS", &self.config.password);
        }
        let mut child = command.spawn().map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => format!("Command not found: {}", cmd[0]),
            _ => format!("Failed to run {}: {e}", cmd[0]),
        })?;
        if let (Some(input), Some(mut pipe)) = (stdin, child.stdin.take()) {
            let input = input.to_vec();
            thread::spawn(move || pipe.write_all(&input));
        }
        let pid = child.id();
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || sender.send(child.wait_with_output()));
        let timeout = Duration::from_secs(self.config.wait_timeout + 30);
        let output = match receiver.recv_timeout(timeout) {
            Ok(output) => output.map_err(|e| format!("Failed to run {}: {e}", cmd[0]))?,
            Err(_) => {
                let _ = Command::new("kill").args(["-KILL", &pid.to_string()]).status();
                return Err(format!("Timed out running: {}", argv.join(" ")));
            }
        };
        let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let message = if stderr.trim().is_empty() { stdout.trim() } else { stderr.trim() };
            return Err(if message.is_empty() {
                format!("'{}' exited with {}", argv.join(" "), output.status.code().unwrap_or(-1))
            } else {
                message.to_string()
            });
        }
        Ok(stdout)
    }

    fn run(&self, argv: &[&str]) -> Result<String> {
        self.run_with_input(&argv.iter().map(|a| a.to_string()).collect::<Vec<_>>(), None)
    }

    fn sh_with_input(&self, script: &str, args: &[&str], stdin: Option<&[u8]>) -> Result<String> {
        let mut argv = vec!["sh".to_string(), "-c".into(), script.into(), "sh".into()];
        argv.extend(args.iter().map(|a| a.to_string()));
        self.run_with_input(&argv, stdin)
    }

    fn sh(&self, script: &str, args: &[&str]) -> Result<String> {
        self.sh_with_input(script, args, None)
    }

    fn vm_directory(&mut self) -> Result<String> {
        let directory = &self.config.vm_directory;
        if directory == "~" || directory.starts_with("~/") {
            let home = self.sh("printf %s \"$HOME\"", &[])?.trim().to_string();
            self.config.vm_directory = format!("{home}{}", &self.config.vm_directory[1..]);
        }
        Ok(self.config.vm_directory.clone())
    }

    fn bundle_path(&mut self, name: Option<&str>) -> Result<String> {
        let name = name.map(String::from).unwrap_or_else(|| self.config.vmname.clone());
        Ok(format!("{}/{name}.bundle", self.vm_directory()?))
    }

    fn app_path(&mut self) -> Result<String> {
        if self.config.app_path.is_empty() {
            let script = format!(
                "[ -d \"$1\" ] && echo \"$1\" && exit 0; mdfind \"kMDItemCFBundleIdentifier == '{VIRTUALOS_BUNDLE_ID}'\" | head -n 1"
            );
            let path = self.sh(&script, &[DEFAULT_APP_PATH]).map(|p| p.trim().to_string()).unwrap_or_default();
            if path.is_empty() {
                return Err("virtualOS not found on the host, set the app_path detail".into());
            }
            self.config.app_path = path;
        }
        Ok(self.config.app_path.clone())
    }

    fn list_bundles(&mut self) -> Result<Vec<String>> {
        let script = "cd \"$1\" 2>/dev/null || exit 0; for b in *.bundle; do [ -d \"$b\" ] && echo \"${b%.bundle}\"; done; exit 0";
        let directory = self.vm_directory()?;
        Ok(self.sh(script, &[&directory])?.lines().filter(|l| !l.is_empty()).map(String::from).collect())
    }

    fn bundle_not_found(&mut self) -> Result<String> {
        let directory = self.vm_directory()?;
        Ok(format!("VM bundle '{}' not found in {directory}", self.config.vmname))
    }

    fn bundle_exists(&mut self) -> Result<bool> {
        let name = self.config.vmname.clone();
        Ok(self.list_bundles()?.contains(&name))
    }

    /// Map bundle path to the pids of the virtualOS processes autostarting it.
    fn running_vms(&self) -> Result<BTreeMap<String, Vec<String>>> {
        let executable = "/Contents/MacOS/virtualOS ";
        let marker = format!(" {AUTOSTART_ARGUMENT} ");
        let mut running: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for line in self.run(&["ps", "-axww", "-o", "pid=,command="])?.lines() {
            let (pid, command) = line.trim().split_once(' ').unwrap_or((line.trim(), ""));
            if command.contains(executable) {
                if let Some((_, bundle)) = command.split_once(&marker) {
                    running.entry(bundle.trim().to_string()).or_default().push(pid.to_string());
                }
            }
        }
        Ok(running)
    }

    fn vm_pids(&mut self, name: Option<&str>) -> Result<Vec<String>> {
        let bundle = self.bundle_path(name)?;
        Ok(self.running_vms()?.remove(&bundle).unwrap_or_default())
    }

    fn require_vmname(&self) -> Result<()> {
        let name = &self.config.vmname;
        if name.is_empty() {
            return Err("Missing required field in JSON: cloudstack.vm.details.name".into());
        }
        if name.contains('/') || name.starts_with('.') {
            return Err(format!("Invalid instance name '{name}'"));
        }
        Ok(())
    }

    fn read_parameters(&self, bundle: &str) -> Result<Map<String, Value>> {
        let output = self.run(&["cat", &format!("{bundle}/Parameters.txt")])?;
        match serde_json::from_str(&output) {
            Ok(Value::Object(parameters)) => Ok(parameters),
            _ => Err(format!("Failed to parse {bundle}/Parameters.txt")),
        }
    }

    fn write_file(&self, path: &str, content: &[u8]) -> Result<()> {
        self.sh_with_input("cat > \"$1\"", &[path], Some(content)).map(|_| ())
    }

    fn write_machine_identifier(&self, bundle: &str) -> Result<()> {
        self.write_file(&format!("{bundle}/MachineIdentifier"), &machine_identifier(random_ecid()?))
    }

    /// virtualOS matches the bridge by its display name, e.g. "Wi-Fi (en0)".
    fn bridge_description(&self) -> Result<String> {
        let interface = &self.config.bridge_interface;
        if interface.is_empty() || interface.contains('(') {
            return Ok(interface.clone());
        }
        let mut port: Option<&str> = None;
        let output = self.run(&["networksetup", "-listallhardwareports"])?;
        for line in output.lines() {
            if let Some(name) = line.strip_prefix("Hardware Port: ") {
                port = Some(name.trim());
            } else if let (Some(device), Some(port)) = (line.strip_prefix("Device: "), port) {
                if device.trim() == interface {
                    return Ok(format!("{port} ({interface})"));
                }
            }
        }
        Ok(interface.clone())
    }

    fn configure(&self, bundle: &str) -> Result<()> {
        let mut parameters = self.read_parameters(bundle)?;
        let cpus = self.config.cpus.unwrap_or(1);
        let memory_gb = self.config.memory.unwrap_or(0).div_ceil(1024 * 1024 * 1024).max(1);
        let current = |parameters: &Map<String, Value>, key: &str, default: u64| value_u64(parameters.get(key)).unwrap_or(default);
        let cpu_max = current(&parameters, "cpuCountMax", cpus).max(cpus);
        let cpu_min = current(&parameters, "cpuCountMin", cpus).min(cpus);
        let memory_max = current(&parameters, "memorySizeInGBMax", memory_gb).max(memory_gb);
        let memory_min = current(&parameters, "memorySizeInGBMin", memory_gb).min(memory_gb);
        parameters.insert("cpuCount".into(), json!(cpus));
        parameters.insert("cpuCountMax".into(), json!(cpu_max));
        parameters.insert("cpuCountMin".into(), json!(cpu_min));
        parameters.insert("memorySizeInGB".into(), json!(memory_gb));
        parameters.insert("memorySizeInGBMax".into(), json!(memory_max));
        parameters.insert("memorySizeInGBMin".into(), json!(memory_min));
        parameters.insert("installFinished".into(), json!(true));
        if let Some(mac) = self.config.macs.first() {
            parameters.insert("macAddress".into(), json!(normalize_mac(mac)));
        }
        if let Some(network) = network_type(&self.config.network_mode) {
            parameters.insert("networkType".into(), json!(network));
            if self.config.network_mode == "bridged" {
                parameters.insert("networkBridge".into(), json!(self.bridge_description()?));
            }
        }
        let content = serde_json::to_string_pretty(&parameters).map_err(|e| e.to_string())?;
        self.write_file(&format!("{bundle}/Parameters.txt"), content.as_bytes())
    }

    fn start_errors(&self, pid: &str) -> Result<Vec<String>> {
        let predicate = format!("subsystem == \"{VIRTUALOS_LOG_SUBSYSTEM}\" AND processID == {pid}");
        let output = self.run(&["/usr/bin/log", "show", "--last", "2m", "--style", "compact", "--predicate", &predicate])?;
        let mut errors: Vec<String> = Vec::new();
        for line in output.lines().filter(|l| l.contains("] Error")) {
            let error = line.rsplit_once("] ").map(|(_, e)| e.to_string()).unwrap_or_default();
            if !errors.contains(&error) {
                errors.push(error);
            }
        }
        Ok(errors)
    }

    fn start_vm(&mut self) -> Result<()> {
        if !self.vm_pids(None)?.is_empty() {
            return Ok(());
        }
        let bundle = self.bundle_path(None)?;
        let app = self.app_path()?;
        self.run(&["open", "-n", "-g", "-a", &app, "--args", AUTOSTART_ARGUMENT, &bundle])?;
        let vmname = self.config.vmname.clone();
        let deadline = Instant::now() + Duration::from_secs(self.config.wait_timeout);
        while self.vm_pids(None)?.is_empty() {
            if Instant::now() > deadline {
                return Err(format!("Timed out waiting for virtualOS to start {vmname}"));
            }
            thread::sleep(Duration::from_secs(1));
        }
        thread::sleep(START_CHECK_DELAY);
        let pids = self.vm_pids(None)?;
        let Some(pid) = pids.first() else {
            return Err(format!("virtualOS exited while starting {vmname}"));
        };
        let errors = self.start_errors(pid).unwrap_or_default();
        if !errors.is_empty() {
            self.stop_vm(None)?;
            return Err(format!("virtualOS failed to start {vmname}: {}", errors.join("; ")));
        }
        Ok(())
    }

    fn kill(&self, signal: &str, pids: &[String]) -> Result<()> {
        let mut argv = vec!["kill", signal];
        argv.extend(pids.iter().map(String::as_str));
        self.run(&argv).map(|_| ())
    }

    fn stop_vm(&mut self, name: Option<&str>) -> Result<()> {
        let pids = self.vm_pids(name)?;
        if pids.is_empty() {
            return Ok(());
        }
        self.kill("-TERM", &pids)?;
        let deadline = Instant::now() + Duration::from_secs(self.config.wait_timeout);
        loop {
            let pids = self.vm_pids(name)?;
            if pids.is_empty() {
                break;
            }
            if Instant::now() > deadline {
                self.kill("-KILL", &pids)?;
                thread::sleep(Duration::from_secs(2));
                break;
            }
            thread::sleep(Duration::from_secs(1));
        }
        if !self.vm_pids(name)?.is_empty() {
            return Err(format!("Failed to stop {}", name.unwrap_or(&self.config.vmname)));
        }
        Ok(())
    }

    fn remove_bundle(&mut self) -> Result<()> {
        let bundle = self.bundle_path(None)?;
        if self.config.vmname.is_empty() || !bundle.ends_with(".bundle") {
            return Err(format!("Refusing to remove '{bundle}'"));
        }
        self.run(&["rm", "-rf", &bundle]).map(|_| ())
    }

    fn create(&mut self) -> Result<Value> {
        self.require_vmname()?;
        let vm_name = self.config.vmname.clone();
        let template = self.config.template_name.clone();
        if template.is_empty() {
            return Err("Missing required field in JSON: template_name".into());
        }
        if self.config.cpus.is_none() || self.config.memory.is_none() {
            return Err("Missing CPU or memory in cloudstack.vm.details".into());
        }
        if self.config.macs.len() > 1 {
            return Err("virtualOS supports a single network interface per VM".into());
        }

        let bundles = self.list_bundles()?;
        if !bundles.contains(&template) {
            return Err(format!("Template VM bundle '{template}' not found in {}", self.vm_directory()?));
        }
        if bundles.contains(&vm_name) {
            return Err(format!("A virtualOS VM named '{vm_name}' already exists"));
        }
        let template_bundle = self.bundle_path(Some(&template))?;
        let mut args = vec![template_bundle.as_str()];
        args.extend(REQUIRED_BUNDLE_FILES);
        let missing = self.sh("cd \"$1\" && shift && for f; do [ -e \"$f\" ] || echo \"$f\"; done; exit 0", &args)?;
        let missing: Vec<&str> = missing.split_whitespace().collect();
        if !missing.is_empty() {
            return Err(format!("Template VM bundle '{template}' is incomplete, missing: {}", missing.join(", ")));
        }
        if !self.vm_pids(Some(&template))?.is_empty() {
            return Err(format!("Template VM '{template}' is running, stop it before cloning"));
        }

        let bundle = self.bundle_path(None)?;
        // -c clones the files on APFS, plain copy elsewhere
        self.sh("cp -cR \"$1\" \"$2\" 2>/dev/null || { rm -rf \"$2\"; cp -R \"$1\" \"$2\"; }", &[&template_bundle, &bundle])?;
        let result = self
            .write_machine_identifier(&bundle)
            .and_then(|_| self.configure(&bundle))
            .and_then(|_| self.start_vm());
        if let Err(e) = result {
            let _ = self.stop_vm(None).and_then(|_| self.remove_bundle());
            return Err(e);
        }
        Ok(success_message("Instance created"))
    }

    fn start(&mut self) -> Result<Value> {
        self.require_vmname()?;
        if !self.bundle_exists()? {
            return Err(self.bundle_not_found()?);
        }
        self.start_vm()?;
        Ok(success_message("Instance started"))
    }

    fn stop(&mut self) -> Result<Value> {
        self.require_vmname()?;
        self.stop_vm(None)?;
        Ok(success_message("Instance stopped"))
    }

    fn reboot(&mut self) -> Result<Value> {
        self.require_vmname()?;
        self.stop_vm(None)?;
        self.start_vm()?;
        Ok(success_message("Instance rebooted"))
    }

    fn delete(&mut self) -> Result<Value> {
        self.require_vmname()?;
        self.stop_vm(None)?;
        if self.bundle_exists()? {
            self.remove_bundle()?;
        }
        Ok(success_message("Instance deleted"))
    }

    fn power_state(&mut self, name: &str, running: &BTreeMap<String, Vec<String>>) -> Result<&'static str> {
        let bundle = self.bundle_path(Some(name))?;
        Ok(if running.contains_key(&bundle) { "poweron" } else { "poweroff" })
    }

    fn status(&mut self) -> Result<Value> {
        self.require_vmname()?;
        if !self.bundle_exists()? {
            return Ok(json!({"status": "success", "power_state": "unknown"}));
        }
        let running = self.running_vms()?;
        let name = self.config.vmname.clone();
        Ok(json!({"status": "success", "power_state": self.power_state(&name, &running)?}))
    }

    fn statuses(&mut self) -> Result<Value> {
        let running = self.running_vms()?;
        let mut power_state = Map::new();
        for name in self.list_bundles()? {
            let state = self.power_state(&name, &running)?;
            power_state.insert(name, json!(state));
        }
        Ok(json!({"status": "success", "power_state": power_state}))
    }

    fn get_ip_addresses(&mut self) -> Result<Value> {
        self.require_vmname()?;
        if !self.bundle_exists()? {
            return Err(self.bundle_not_found()?);
        }
        let bundle = self.bundle_path(None)?;
        let mac = normalize_mac(&value_text(self.read_parameters(&bundle)?.get("macAddress")));
        let leases = self.sh("[ -r \"$1\" ] && cat \"$1\"; exit 0", &[DHCP_LEASES])?;
        Ok(json!({"status": "success", "printmessage": "true", "message": leased_addresses(&leases, &mac)}))
    }
}

fn execute(operation: &str, json_file_path: &str) -> Result<Value> {
    let content = fs::read_to_string(json_file_path).map_err(|e| match e.kind() {
        std::io::ErrorKind::NotFound => format!("JSON file not found: {json_file_path}"),
        _ => format!("Failed to read {json_file_path}: {e}"),
    })?;
    let json_data: Value = serde_json::from_str(&content).map_err(|_| "Invalid JSON in file".to_string())?;
    let mut manager = VirtualOSManager { config: Config::parse(&json_data)? };

    match operation {
        "create" => manager.create(),
        "start" => manager.start(),
        "stop" => manager.stop(),
        "reboot" => manager.reboot(),
        "delete" => manager.delete(),
        "status" => manager.status(),
        "statuses" => manager.statuses(),
        "getconsole" => Err("Operation not supported".into()),
        "getipaddresses" => manager.get_ip_addresses(),
        _ => Err("Invalid action".into()),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let result = if args.len() < 3 {
        Err("Usage: virtualos <operation> '<json-file-path>'".to_string())
    } else {
        execute(&args[1].to_lowercase(), &args[2])
    };
    match result {
        Ok(data) => println!("{data}"),
        Err(message) => {
            println!("{}", json!({"status": "error", "error": message}));
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_macs() {
        assert_eq!(normalize_mac("2:0:A:7b:0:5"), "02:00:0a:7b:00:05");
        assert_eq!(normalize_mac("02:00:0a:7b:00:05"), "02:00:0a:7b:00:05");
    }

    #[test]
    fn quotes_shell_arguments() {
        assert_eq!(shell_quote("/Users/me/x.bundle"), "/Users/me/x.bundle");
        assert_eq!(shell_quote(""), "''");
        assert_eq!(shell_quote("a b"), "'a b'");
        assert_eq!(shell_quote("it's"), "'it'\"'\"'s'");
    }

    #[test]
    fn builds_machine_identifier_plist() {
        let plist = machine_identifier(0x0123_4567_89ab_cdef);
        assert_eq!(&plist[..8], b"bplist00");
        assert_eq!(&plist[17..25], &0x0123_4567_89ab_cdefu64.to_be_bytes());
        assert_eq!(plist.len(), 28 + 32);
    }

    #[test]
    fn finds_leased_addresses() {
        let leases = "{\n\tname=mac\n\tip_address=192.168.64.7\n\thw_address=1,2:0:a:7b:0:5\n\tlease=0x6a0\n}\n\
                      {\n\tname=other\n\tip_address=192.168.64.8\n\thw_address=1,aa:bb:cc:dd:ee:ff\n}\n";
        assert_eq!(leased_addresses(leases, "02:00:0a:7b:00:05"), vec!["192.168.64.7"]);
        assert!(leased_addresses(leases, "02:00:0a:7b:00:06").is_empty());
    }

    #[test]
    fn parses_details() {
        let data = json!({
            "externaldetails": {"extension": {"url": "localhost", "network_mode": "NAT"},
                                "host": {"ssh_port": 2222}, "virtualmachine": {"template_name": "tpl"}},
            "cloudstack.vm.details": {"name": "i-2-10-VM", "cpus": 2, "minRam": 4294967296u64,
                                      "nics": [{"deviceId": 1, "mac": "b"}, {"deviceId": 0, "mac": "a"}]}
        });
        let config = Config::parse(&data).unwrap();
        assert!(config.local);
        assert_eq!(config.ssh_port, "2222");
        assert_eq!(config.network_mode, "nat");
        assert_eq!(config.template_name, "tpl");
        assert_eq!(config.macs, vec!["a", "b"]);
        assert_eq!(config.memory, Some(4294967296));
        assert!(Config::parse(&json!({"externaldetails": {"extension": {"url": "mac"}}})).is_err());
    }
}
