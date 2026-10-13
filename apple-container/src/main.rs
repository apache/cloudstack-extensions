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

//! CloudStack orchestrator extension for Apple container on macOS.
//!
//! Apple container (https://github.com/apple/container) runs each Linux
//! container from an OCI image in its own lightweight virtual machine on Apple
//! silicon, through Apple's Virtualization framework. This program drives its
//! `container` command line tool: every CloudStack instance is one container,
//! named after the instance's internal name and labelled as managed by
//! CloudStack, created from the OCI image configured on the template.
//!
//! The management server reaches the Mac over SSH (or runs locally when the
//! management server itself runs on the Mac). Each NIC of the instance is
//! attached to a container network with the CloudStack MAC address. A NIC on
//! a network of the vmnet network extension carries a broadcast URI such as
//! vs://cs-net-42?mode=nat; it is attached to the container network of that
//! name, which is created on first use and deleted with its last container.
//! Other NICs use the networks of the network detail.
//!
//! Details (host details override extension details):
//!   url                   Mac hostname/IP, or "localhost" to run locally
//!   username              SSH user running the container system service
//!   password              optional, SSH password (requires sshpass on the
//!                         management server; key authentication is preferred)
//!   ssh_key               optional, private key path on the management server
//!   ssh_port              optional, defaults to 22
//!   verify_host_key       optional, "true" (default) or "false"
//!   container_path        optional, defaults to /usr/local/bin/container
//!   network               optional, comma separated container networks, one
//!                         per NIC in device order, the last one repeating for
//!                         further NICs; defaults to "default". Not used for
//!                         NICs on vmnet extension networks
//!   wait_timeout          optional, seconds a stop waits before the container
//!                         is killed and to wait for other commands (60)
//!   pull_timeout          optional, seconds to wait for an image pull (900)
//!   start_service         optional, "true" (default) starts the container
//!                         system service when it is not running
//!
//! Template, service offering or instance details (instance wins), which may
//! also be set on the host or extension as defaults:
//!   image                 OCI image reference, e.g. docker.io/library/alpine:3.22
//!   command               optional, command line replacing the image's default
//!                         arguments, split on whitespace, e.g. "sleep infinity"
//!   platform              optional, image platform, e.g. linux/amd64
//!   init                  optional, "true" runs an init process that reaps
//!                         zombies and forwards signals
//!   rosetta               optional, "true" enables Rosetta for amd64 images

use serde_json::{json, Map, Value};
use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

const DEFAULT_CONTAINER_PATH: &str = "/usr/local/bin/container";
const DEFAULT_NETWORK: &str = "default";
const MANAGED_LABEL: &str = "org.apache.cloudstack.managed";
const LOCAL_HOSTS: [&str; 3] = ["localhost", "127.0.0.1", "::1"];
const DEFAULT_LOG_LINES: u64 = 100;
/// Broadcast URI scheme of the networks named by the vmnet network extension.
const VMNET_SCHEME: &str = "vs://";
/// Hint the container tool prints when its system service is not running.
const SERVICE_DOWN_HINT: &str = "container system start";
const OPERATIONS: [&str; 10] = [
    "create", "start", "stop", "reboot", "delete", "status", "statuses", "getconsole", "getipaddresses", "getlogs",
];

type Result<T> = std::result::Result<T, String>;

fn success_message(message: &str) -> Value {
    json!({"status": "success", "message": message})
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

/// Memory argument for `container create`, in whole MiB as container has 1 MiB granularity.
fn memory_argument(bytes: u64) -> String {
    format!("{}M", bytes.div_ceil(1024 * 1024).max(1))
}

/// A container network named by the vmnet network extension.
#[derive(Clone, Debug, PartialEq)]
struct VmnetNetwork {
    name: String,
    internal: bool,
}

/// The vmnet network of a NIC broadcast URI like vs://cs-net-42?mode=internal,
/// or None for NICs on other networks.
fn vmnet_network(broadcast_uri: &str) -> Result<Option<VmnetNetwork>> {
    let Some(rest) = broadcast_uri.strip_prefix(VMNET_SCHEME) else {
        return Ok(None);
    };
    let (name, query) = rest.split_once('?').unwrap_or((rest, ""));
    if name.is_empty() || !name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-') {
        return Err(format!("Invalid vmnet network name in broadcast URI '{broadcast_uri}'"));
    }
    let mode = query.split('&').find_map(|p| p.strip_prefix("mode=")).unwrap_or("nat");
    let internal = match mode {
        "nat" => false,
        "internal" => true,
        _ => return Err(format!("Invalid vmnet network mode in broadcast URI '{broadcast_uri}'")),
    };
    Ok(Some(VmnetNetwork { name: name.to_string(), internal }))
}

struct Nic {
    mac: String,
    vmnet: Option<VmnetNetwork>,
}

/// The container network for each NIC, the last configured network repeating for further NICs.
fn nic_networks(networks: &[String], nic_count: usize) -> Vec<String> {
    let last = networks.last().cloned().unwrap_or_else(|| DEFAULT_NETWORK.to_string());
    (0..nic_count.max(1)).map(|i| networks.get(i).cloned().unwrap_or_else(|| last.clone())).collect()
}

/// Runtime state of a container snapshot. `container list --format json` nests
/// it in status.state, the ContainerSnapshot type serializes a bare status.
fn container_state(snapshot: &Value) -> String {
    match snapshot.get("status") {
        Some(Value::Object(status)) => value_text(status.get("state")),
        other => value_text(other),
    }
}

fn container_networks(snapshot: &Value) -> Vec<Value> {
    snapshot
        .get("networks")
        .or_else(|| snapshot.get("status").and_then(|s| s.get("networks")))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
}

/// Names of the networks a container is attached to, running or not; only
/// running containers report their network status.
fn network_names(snapshot: &Value) -> Vec<String> {
    let configured = snapshot
        .get("configuration")
        .and_then(|c| c.get("networks"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut names: Vec<String> = Vec::new();
    for network in configured.iter().chain(container_networks(snapshot).iter()) {
        let name = value_text(network.get("network"));
        if !name.is_empty() && !names.contains(&name) {
            names.push(name);
        }
    }
    names
}

fn container_id(snapshot: &Value) -> String {
    value_text(snapshot.get("configuration").and_then(|c| c.get("id")))
}

/// Whether a container or network carries the CloudStack label.
fn is_managed(snapshot: &Value) -> bool {
    snapshot
        .get("configuration")
        .and_then(|c| c.get("labels"))
        .and_then(|l| l.get(MANAGED_LABEL))
        .map(|v| value_text(Some(v)) == "true")
        .unwrap_or(false)
}

fn power_state(state: &str) -> &'static str {
    match state {
        "running" | "stopping" => "poweron",
        "stopped" => "poweroff",
        _ => "unknown",
    }
}

/// IPv4 and IPv6 addresses of a container, without their prefix lengths.
fn ip_addresses(snapshot: &Value) -> Vec<String> {
    let mut addresses = Vec::new();
    for network in container_networks(snapshot) {
        for key in ["ipv4Address", "address", "ipv6Address"] {
            let address = value_text(network.get(key));
            let address = address.split('/').next().unwrap_or("");
            if !address.is_empty() && !addresses.iter().any(|a| a == address) {
                addresses.push(address.to_string());
            }
        }
    }
    addresses
}

struct Config {
    url: String,
    username: String,
    password: String,
    ssh_key: String,
    ssh_port: String,
    verify_host_key: bool,
    local: bool,
    container_path: String,
    networks: Vec<String>,
    wait_timeout: u64,
    pull_timeout: u64,
    start_service: bool,
    image: String,
    command: Vec<String>,
    platform: String,
    init: bool,
    rosetta: bool,
    vmname: String,
    cpus: Option<u64>,
    memory: Option<u64>,
    nics: Vec<Nic>,
    parameters: Map<String, Value>,
}

impl Config {
    fn parse(json_data: &Value) -> Result<Config> {
        let empty = Map::new();
        let section = |value: Option<&Value>| value.and_then(Value::as_object).unwrap_or(&empty).clone();
        let external = section(json_data.get("externaldetails"));
        let extension = section(external.get("extension"));
        let host = section(external.get("host"));
        let vm = section(external.get("virtualmachine"));

        let first = |sections: &[&Map<String, Value>], name: &str, default: &str| {
            sections
                .iter()
                .map(|s| value_text(s.get(name)))
                .find(|v| !v.is_empty())
                .unwrap_or_else(|| default.to_string())
        };
        let detail = |name: &str, default: &str| first(&[&host, &extension], name, default);
        let vm_detail = |name: &str, default: &str| first(&[&vm, &host, &extension], name, default);
        let number = |name: &str, default: &str| -> Result<u64> {
            detail(name, default).trim().parse().map_err(|_| format!("Error parsing JSON: invalid {name}"))
        };

        let url = detail("url", "");
        let username = detail("username", "");
        if url.is_empty() {
            return Err("Missing required field in JSON: url".into());
        }
        let local = LOCAL_HOSTS.contains(&url.to_lowercase().as_str()) && username.is_empty();
        if !local && username.is_empty() {
            return Err("Missing required field in JSON: username".into());
        }
        let networks = detail("network", DEFAULT_NETWORK)
            .split(',')
            .map(|n| n.trim().to_string())
            .filter(|n| !n.is_empty())
            .collect();

        let vm_details = section(json_data.get("cloudstack.vm.details"));
        let mut nics: Vec<&Value> = vm_details.get("nics").and_then(Value::as_array).map(|n| n.iter().collect()).unwrap_or_default();
        nics.sort_by_key(|nic| nic.get("deviceId").and_then(Value::as_i64).unwrap_or(0));
        let nics = nics
            .iter()
            .map(|nic| {
                Ok(Nic {
                    mac: value_text(nic.get("mac")),
                    vmnet: vmnet_network(&value_text(nic.get("broadcastUri")))?,
                })
            })
            .collect::<Result<Vec<_>>>()?;

        Ok(Config {
            url,
            username,
            password: detail("password", ""),
            ssh_key: detail("ssh_key", ""),
            ssh_port: detail("ssh_port", "22"),
            verify_host_key: detail("verify_host_key", "true").to_lowercase() == "true",
            local,
            container_path: detail("container_path", DEFAULT_CONTAINER_PATH),
            networks,
            wait_timeout: number("wait_timeout", "60")?,
            pull_timeout: number("pull_timeout", "900")?,
            start_service: detail("start_service", "true").to_lowercase() == "true",
            image: vm_detail("image", ""),
            command: vm_detail("command", "").split_whitespace().map(String::from).collect(),
            platform: vm_detail("platform", ""),
            init: vm_detail("init", "false").to_lowercase() == "true",
            rosetta: vm_detail("rosetta", "false").to_lowercase() == "true",
            vmname: value_text(vm_details.get("name")),
            cpus: value_u64(vm_details.get("cpus")),
            memory: value_u64(vm_details.get("minRam")),
            nics,
            parameters: section(json_data.get("parameters")),
        })
    }
}

struct ContainerManager {
    config: Config,
}

impl ContainerManager {
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

    fn run_with_timeout(&self, argv: &[String], timeout: Duration) -> Result<String> {
        let cmd = if self.config.local { argv.to_vec() } else { self.ssh_command(argv) };
        let mut command = Command::new(&cmd[0]);
        command.args(&cmd[1..]).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
        if !self.config.local && !self.config.password.is_empty() {
            command.env("SSHPASS", &self.config.password);
        }
        let child = command.spawn().map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => format!("Command not found: {}", cmd[0]),
            _ => format!("Failed to run {}: {e}", cmd[0]),
        })?;
        let pid = child.id();
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || sender.send(child.wait_with_output()));
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

    /// Run the container tool with the given arguments, waiting at most the given seconds.
    fn container_with_timeout(&self, args: &[&str], seconds: u64) -> Result<String> {
        let mut argv = vec![self.config.container_path.clone()];
        argv.extend(args.iter().map(|a| a.to_string()));
        self.run_with_timeout(&argv, Duration::from_secs(seconds + 30))
    }

    fn container(&self, args: &[&str]) -> Result<String> {
        self.container_with_timeout(args, self.config.wait_timeout)
    }

    fn require_vmname(&self) -> Result<()> {
        let name = &self.config.vmname;
        if name.is_empty() {
            return Err("Missing required field in JSON: cloudstack.vm.details.name".into());
        }
        if !name.chars().all(|c| c.is_ascii_alphanumeric() || "_.-".contains(c)) || name.starts_with(['.', '-']) {
            return Err(format!("Invalid instance name '{name}'"));
        }
        Ok(())
    }

    /// Start the container system service, without installing a kernel as that prompts.
    fn start_service(&self) -> Result<()> {
        let timeout = self.config.wait_timeout.to_string();
        self.container(&["system", "start", "--disable-kernel-install", "--timeout", &timeout])
            .map(|_| ())
            .map_err(|e| format!("The container system service is not running and failed to start: {e}"))
    }

    /// All containers, running or not, keyed by container ID. Containers do
    /// not survive the system service, so when it is down it is started to
    /// report them as stopped instead of failing.
    fn list_containers(&self) -> Result<BTreeMap<String, Value>> {
        let args = ["list", "--all", "--format", "json"];
        let output = match self.container(&args) {
            Err(e) if self.config.start_service && e.contains(SERVICE_DOWN_HINT) => {
                self.start_service()?;
                self.container(&args)?
            }
            result => result?,
        };
        let containers: Value = serde_json::from_str(output.trim())
            .map_err(|e| format!("Failed to parse the container list: {e}"))?;
        Ok(containers
            .as_array()
            .map(|list| list.iter().map(|c| (container_id(c), c.clone())).collect())
            .unwrap_or_default())
    }

    fn find_container(&self) -> Result<Option<Value>> {
        Ok(self.list_containers()?.remove(&self.config.vmname))
    }

    fn require_container(&self) -> Result<Value> {
        self.find_container()?
            .ok_or_else(|| format!("Container '{}' not found", self.config.vmname))
    }

    fn create_arguments(&self) -> Vec<String> {
        let c = &self.config;
        let mut args: Vec<String> = vec!["create".into(), "--name".into(), c.vmname.clone()];
        args.extend(["--label".to_string(), format!("{MANAGED_LABEL}=true")]);
        if let Some(cpus) = c.cpus {
            args.extend(["--cpus".to_string(), cpus.max(1).to_string()]);
        }
        if let Some(memory) = c.memory {
            args.extend(["--memory".to_string(), memory_argument(memory)]);
        }
        let networks = nic_networks(&c.networks, c.nics.len());
        for (i, network) in networks.iter().enumerate() {
            let nic = c.nics.get(i);
            let network = nic.and_then(|n| n.vmnet.as_ref()).map(|v| &v.name).unwrap_or(network);
            let spec = match nic.filter(|n| !n.mac.is_empty()) {
                Some(nic) => format!("{network},mac={}", nic.mac.to_lowercase()),
                None => network.clone(),
            };
            args.extend(["--network".to_string(), spec]);
        }
        if !c.platform.is_empty() {
            args.extend(["--platform".to_string(), c.platform.clone()]);
        }
        if c.init {
            args.push("--init".into());
        }
        if c.rosetta {
            args.push("--rosetta".into());
        }
        args.push(c.image.clone());
        args.extend(c.command.iter().cloned());
        args
    }

    /// The distinct vmnet extension networks of the instance's NICs.
    fn vmnet_networks(&self) -> Vec<&VmnetNetwork> {
        let mut networks: Vec<&VmnetNetwork> = Vec::new();
        for network in self.config.nics.iter().filter_map(|n| n.vmnet.as_ref()) {
            if !networks.iter().any(|n| n.name == network.name) {
                networks.push(network);
            }
        }
        networks
    }

    /// All container networks keyed by name.
    fn list_networks(&self) -> Result<BTreeMap<String, Value>> {
        let output = self.container(&["network", "list", "--format", "json"])?;
        let networks: Value = serde_json::from_str(output.trim())
            .map_err(|e| format!("Failed to parse the network list: {e}"))?;
        Ok(networks
            .as_array()
            .map(|list| list.iter().map(|n| (value_text(n.get("id")), n.clone())).collect())
            .unwrap_or_default())
    }

    /// Create the vmnet extension networks the instance needs and that do not
    /// exist yet. An existing network is only used when CloudStack created it.
    fn ensure_networks(&self) -> Result<()> {
        let wanted = self.vmnet_networks();
        if wanted.is_empty() {
            return Ok(());
        }
        let existing = self.list_networks()?;
        for network in wanted {
            match existing.get(&network.name) {
                Some(found) if is_managed(found) => continue,
                Some(_) => {
                    return Err(format!("Container network '{}' exists but was not created by CloudStack", network.name))
                }
                None => {}
            }
            let label = format!("{MANAGED_LABEL}=true");
            let mut args = vec!["network", "create", "--label", label.as_str()];
            if network.internal {
                args.push("--internal");
            }
            args.push(&network.name);
            if let Err(e) = self.container(&args) {
                // Another instance may have created it meanwhile.
                if !self.list_networks()?.get(&network.name).is_some_and(is_managed) {
                    return Err(format!("Failed to create container network '{}': {e}", network.name));
                }
            }
        }
        Ok(())
    }

    /// Delete the given networks when CloudStack created them and no other
    /// container uses them; the container tool refuses to delete networks in use.
    fn delete_unused_networks(&self, names: &[String]) -> Result<()> {
        if names.is_empty() {
            return Ok(());
        }
        let existing = self.list_networks()?;
        for name in names {
            if existing.get(name).is_some_and(is_managed) {
                let _ = self.container(&["network", "delete", name]);
            }
        }
        Ok(())
    }

    fn pull_image(&self) -> Result<()> {
        let c = &self.config;
        let mut args = vec!["image", "pull", "--progress", "none"];
        if !c.platform.is_empty() {
            args.extend(["--platform", c.platform.as_str()]);
        }
        args.push(c.image.as_str());
        self.container_with_timeout(&args, c.pull_timeout)
            .map(|_| ())
            .map_err(|e| format!("Failed to pull image '{}': {e}", c.image))
    }

    fn start_container(&self) -> Result<()> {
        self.container(&["start", &self.config.vmname]).map(|_| ())
    }

    fn stop_container(&self) -> Result<()> {
        let timeout = self.config.wait_timeout.to_string();
        self.container(&["stop", "--time", &timeout, &self.config.vmname]).map(|_| ())
    }

    fn delete_container(&self) -> Result<()> {
        self.container(&["delete", "--force", &self.config.vmname]).map(|_| ())
    }

    fn create(&mut self) -> Result<Value> {
        self.require_vmname()?;
        let name = self.config.vmname.clone();
        if self.config.image.is_empty() {
            return Err("Missing required field in JSON: image".into());
        }
        if self.config.cpus.is_none() || self.config.memory.is_none() {
            return Err("Missing CPU or memory in cloudstack.vm.details".into());
        }
        if self.find_container()?.is_some() {
            return Err(format!("A container named '{name}' already exists"));
        }
        self.pull_image()?;
        self.ensure_networks()?;
        let args = self.create_arguments();
        self.container(&args.iter().map(String::as_str).collect::<Vec<_>>())?;
        if let Err(e) = self.start_container() {
            let _ = self.delete_container();
            return Err(format!("Failed to start container '{name}': {e}"));
        }
        Ok(success_message("Instance created"))
    }

    fn start(&mut self) -> Result<Value> {
        self.require_vmname()?;
        if container_state(&self.require_container()?) != "running" {
            self.ensure_networks()?;
            self.start_container()?;
        }
        Ok(success_message("Instance started"))
    }

    fn stop(&mut self) -> Result<Value> {
        self.require_vmname()?;
        if let Some(snapshot) = self.find_container()? {
            if container_state(&snapshot) != "stopped" {
                self.stop_container()?;
            }
        }
        Ok(success_message("Instance stopped"))
    }

    fn reboot(&mut self) -> Result<Value> {
        self.require_vmname()?;
        if container_state(&self.require_container()?) != "stopped" {
            self.stop_container()?;
        }
        self.ensure_networks()?;
        self.start_container()?;
        Ok(success_message("Instance rebooted"))
    }

    fn delete(&mut self) -> Result<Value> {
        self.require_vmname()?;
        if let Some(snapshot) = self.find_container()? {
            // The expunge payload has no NICs, so take the networks from the container.
            let networks = network_names(&snapshot);
            self.delete_container()?;
            // Best effort: a leftover network is reused or deleted with a later instance.
            let _ = self.delete_unused_networks(&networks);
        }
        Ok(success_message("Instance deleted"))
    }

    fn status(&mut self) -> Result<Value> {
        self.require_vmname()?;
        let state = match self.find_container()? {
            Some(snapshot) => power_state(&container_state(&snapshot)),
            None => "unknown",
        };
        Ok(json!({"status": "success", "power_state": state}))
    }

    fn statuses(&mut self) -> Result<Value> {
        let mut power_states = Map::new();
        for (id, snapshot) in self.list_containers()? {
            if is_managed(&snapshot) {
                power_states.insert(id, json!(power_state(&container_state(&snapshot))));
            }
        }
        Ok(json!({"status": "success", "power_state": power_states}))
    }

    fn get_ip_addresses(&mut self) -> Result<Value> {
        self.require_vmname()?;
        let addresses = ip_addresses(&self.require_container()?);
        Ok(json!({"status": "success", "printmessage": "true", "message": addresses}))
    }

    fn get_logs(&mut self) -> Result<Value> {
        self.require_vmname()?;
        let lines = value_u64(self.config.parameters.get("lines")).unwrap_or(DEFAULT_LOG_LINES).to_string();
        let mut args = vec!["logs", "-n", lines.as_str()];
        if value_text(self.config.parameters.get("boot")).to_lowercase() == "true" {
            args.push("--boot");
        }
        args.push(&self.config.vmname);
        let logs = self.container(&args)?;
        Ok(json!({"status": "success", "printmessage": "true", "message": logs}))
    }
}

fn execute(operation: &str, json_file_path: &str) -> Result<Value> {
    // CloudStack also passes commands it has no extension operation for, such as
    // com.cloud.agent.api.GetVmIpAddressCommand, without host details.
    if !OPERATIONS.contains(&operation) {
        return Err(format!("Operation not supported: {operation}"));
    }
    let content = fs::read_to_string(json_file_path).map_err(|e| match e.kind() {
        std::io::ErrorKind::NotFound => format!("JSON file not found: {json_file_path}"),
        _ => format!("Failed to read {json_file_path}: {e}"),
    })?;
    let json_data: Value = serde_json::from_str(&content).map_err(|_| "Invalid JSON in file".to_string())?;
    let mut manager = ContainerManager { config: Config::parse(&json_data)? };

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
        "getlogs" => manager.get_logs(),
        _ => unreachable!("operation {operation} is checked above"),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let result = if args.len() < 3 {
        Err("Usage: apple-container <operation> '<json-file-path>'".to_string())
    } else {
        execute(&args[1].to_lowercase(), &args[2])
    };
    let mut stdout = std::io::stdout();
    match result {
        Ok(data) => {
            let _ = writeln!(stdout, "{data}");
        }
        Err(message) => {
            let _ = writeln!(stdout, "{}", json!({"status": "error", "error": message}));
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(data: Value) -> Config {
        Config::parse(&data).unwrap()
    }

    fn base(extra_vm: Value) -> Value {
        json!({
            "externaldetails": {"extension": {"url": "localhost"},
                                "host": {"network": "default, isolated"},
                                "virtualmachine": extra_vm},
            "cloudstack.vm.details": {"name": "i-2-10-VM", "cpus": 2, "minRam": 1610612736u64,
                                      "nics": [{"deviceId": 1, "mac": "02:00:0A:00:00:02"},
                                               {"deviceId": 0, "mac": "02:00:0a:00:00:01"},
                                               {"deviceId": 2, "mac": "02:00:0a:00:00:03"}]}
        })
    }

    #[test]
    fn quotes_shell_arguments() {
        assert_eq!(shell_quote("i-2-10-VM"), "i-2-10-VM");
        assert_eq!(shell_quote(""), "''");
        assert_eq!(shell_quote("a b"), "'a b'");
        assert_eq!(shell_quote("it's"), "'it'\"'\"'s'");
    }

    #[test]
    fn rounds_memory_up_to_mib() {
        assert_eq!(memory_argument(1610612736), "1536M");
        assert_eq!(memory_argument(1024 * 1024 + 1), "2M");
        assert_eq!(memory_argument(0), "1M");
    }

    #[test]
    fn repeats_last_network_for_extra_nics() {
        let networks = vec!["a".to_string(), "b".to_string()];
        assert_eq!(nic_networks(&networks, 3), vec!["a", "b", "b"]);
        assert_eq!(nic_networks(&networks, 0), vec!["a"]);
        assert_eq!(nic_networks(&[], 2), vec!["default", "default"]);
    }

    #[test]
    fn parses_details() {
        let c = config(base(json!({"image": "alpine:3.22", "command": "sleep  infinity", "init": "TRUE"})));
        assert!(c.local);
        assert_eq!(c.container_path, DEFAULT_CONTAINER_PATH);
        assert_eq!(c.networks, vec!["default", "isolated"]);
        let macs: Vec<&str> = c.nics.iter().map(|n| n.mac.as_str()).collect();
        assert_eq!(macs, vec!["02:00:0a:00:00:01", "02:00:0A:00:00:02", "02:00:0a:00:00:03"]);
        assert!(c.nics.iter().all(|n| n.vmnet.is_none()));
        assert_eq!(c.command, vec!["sleep", "infinity"]);
        assert!(c.init);
        assert!(!c.rosetta);
        assert_eq!(c.wait_timeout, 60);
        assert!(c.start_service);
        assert!(Config::parse(&json!({"externaldetails": {"extension": {"url": "mac"}}})).is_err());
        assert!(Config::parse(&json!({"externaldetails": {"extension": {"url": "localhost", "wait_timeout": "x"}}})).is_err());
    }

    #[test]
    fn instance_image_overrides_host_default() {
        let mut data = base(json!({"image": "alpine:3.22"}));
        data["externaldetails"]["host"]["image"] = json!("ubuntu:24.04");
        assert_eq!(config(data).image, "alpine:3.22");
        let mut data = base(json!({}));
        data["externaldetails"]["extension"]["image"] = json!("ubuntu:24.04");
        assert_eq!(config(data).image, "ubuntu:24.04");
    }

    #[test]
    fn builds_create_arguments() {
        let manager = ContainerManager {
            config: config(base(json!({"image": "alpine:3.22", "command": "sleep infinity", "init": "true"}))),
        };
        assert_eq!(
            manager.create_arguments(),
            vec![
                "create", "--name", "i-2-10-VM", "--label", "org.apache.cloudstack.managed=true",
                "--cpus", "2", "--memory", "1536M",
                "--network", "default,mac=02:00:0a:00:00:01",
                "--network", "isolated,mac=02:00:0a:00:00:02",
                "--network", "isolated,mac=02:00:0a:00:00:03",
                "--init", "alpine:3.22", "sleep", "infinity",
            ]
        );
    }

    #[test]
    fn parses_vmnet_broadcast_uris() {
        let net = |name: &str, internal| Some(VmnetNetwork { name: name.into(), internal });
        assert_eq!(vmnet_network("vs://cs-net-42?mode=nat").unwrap(), net("cs-net-42", false));
        assert_eq!(vmnet_network("vs://cs-net-7?mode=internal").unwrap(), net("cs-net-7", true));
        assert_eq!(vmnet_network("vs://cs-net-7").unwrap(), net("cs-net-7", false));
        assert_eq!(vmnet_network("vlan://300").unwrap(), None);
        assert_eq!(vmnet_network("").unwrap(), None);
        assert!(vmnet_network("vs://cs-net-7?mode=bridged").is_err());
        assert!(vmnet_network("vs://Bad_Name").is_err());
        assert!(vmnet_network("vs://").is_err());
    }

    #[test]
    fn attaches_vmnet_nics_to_their_own_networks() {
        let mut data = base(json!({"image": "alpine:3.22"}));
        data["cloudstack.vm.details"]["nics"] = json!([
            {"deviceId": 0, "mac": "02:00:0a:00:00:01", "broadcastUri": "vs://cs-net-42?mode=internal"},
            {"deviceId": 1, "mac": "02:00:0a:00:00:02", "broadcastUri": "vlan://300"},
            {"deviceId": 2, "mac": "02:00:0a:00:00:03", "broadcastUri": "vs://cs-net-42?mode=internal"},
        ]);
        let manager = ContainerManager { config: config(data) };
        assert_eq!(manager.vmnet_networks(), vec![&VmnetNetwork { name: "cs-net-42".into(), internal: true }]);
        let args = manager.create_arguments();
        let networks: Vec<&str> = args.iter().zip(args.iter().skip(1))
            .filter(|(flag, _)| *flag == "--network").map(|(_, spec)| spec.as_str()).collect();
        assert_eq!(networks, vec![
            "cs-net-42,mac=02:00:0a:00:00:01", "isolated,mac=02:00:0a:00:00:02", "cs-net-42,mac=02:00:0a:00:00:03",
        ]);
    }

    #[test]
    fn rejects_unsafe_instance_names() {
        let mut data = base(json!({}));
        for name in ["", "-rf", "../x", "a b"] {
            data["cloudstack.vm.details"]["name"] = json!(name);
            assert!(ContainerManager { config: config(data.clone()) }.require_vmname().is_err(), "{name}");
        }
    }

    #[test]
    fn rejects_unsupported_operations_before_reading_details() {
        let error = execute("com.cloud.agent.api.getvmipaddresscommand", "/nonexistent.json").unwrap_err();
        assert_eq!(error, "Operation not supported: com.cloud.agent.api.getvmipaddresscommand");
        assert!(execute("statuses", "/nonexistent.json").unwrap_err().starts_with("JSON file not found"));
    }

    #[test]
    fn reads_container_snapshots() {
        let current = json!({
            "configuration": {"id": "i-2-10-VM", "labels": {MANAGED_LABEL: "true"}},
            "status": "running",
            "networks": [{"network": "default", "hostname": "i-2-10-VM",
                          "ipv4Address": "192.168.64.3/24", "ipv4Gateway": "192.168.64.1",
                          "ipv6Address": "fd00::3/64"}]
        });
        assert_eq!(container_id(&current), "i-2-10-VM");
        assert_eq!(power_state(&container_state(&current)), "poweron");
        assert!(is_managed(&current));
        assert_eq!(ip_addresses(&current), vec!["192.168.64.3", "fd00::3"]);
        assert_eq!(network_names(&current), vec!["default"]);
        let stopped = json!({
            "configuration": {"id": "i-2-11-VM", "networks": [{"network": "cs-net-42", "options": {}},
                                                              {"network": "default", "options": {}}]},
            "status": "stopped"
        });
        assert_eq!(network_names(&stopped), vec!["cs-net-42", "default"]);

        let legacy = json!({
            "configuration": {"id": "buildkit", "labels": {}},
            "status": {"state": "stopped", "networks": [{"address": "192.168.64.2/24"}]}
        });
        assert_eq!(power_state(&container_state(&legacy)), "poweroff");
        assert!(!is_managed(&legacy));
        assert_eq!(ip_addresses(&legacy), vec!["192.168.64.2"]);
        assert_eq!(power_state("unknown"), "unknown");
    }
}
