#!/usr/bin/env python3
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

"""
CloudStack orchestrator extension for virtualOS on macOS.

virtualOS (https://github.com/yep/virtualOS) runs macOS guests on Apple
silicon through Apple's Virtualization framework. It has no command line
interface, so this script manages its VM bundles directly and starts a VM by
launching a separate virtualOS process with the autostartVMBundlePath user
default set as a launch argument. Stopping a VM terminates that process.

The management server reaches the Mac over SSH (or runs locally when the
management server itself runs on the Mac). Instances are created by cloning
an existing virtualOS VM bundle, which is a copy-on-write copy on APFS, after
which the clone gets a new machine identifier and the CPU count, memory and
MAC address of the CloudStack instance. The bundle is named after the
CloudStack instance's internal name.

Details (host details override extension details):
  url                   Mac hostname/IP, or "localhost" to run locally
  username              SSH user owning the virtualOS VMs (logged in to the GUI)
  password              optional, SSH password (requires sshpass on the
                        management server; key authentication is preferred)
  ssh_key               optional, private key path on the management server
  ssh_port              optional, defaults to 22
  verify_host_key       optional, "true" (default) or "false"
  app_path              optional, defaults to /Applications/virtualOS.app,
                        falling back to a Spotlight lookup of the app bundle
  vm_directory          optional, directory holding the VM bundles; must be
                        the "VM files" directory configured in virtualOS,
                        defaults to its sandbox container's Documents folder
  template_name         optional, default VM bundle to clone (without .bundle)
  network_mode          optional, nat|bridged; when set it is applied to the
                        instance, otherwise the template's mode is kept
  bridge_interface      optional, macOS interface for bridged mode, e.g. en0
  wait_timeout          optional, seconds to wait for state changes (120)

Instance/template details:
  template_name         VM bundle to clone, overrides the host/extension value
"""

import base64
import json
import math
import os
import plistlib
import re
import secrets
import shlex
import subprocess
import sys
import time

DEFAULT_APP_PATH = "/Applications/virtualOS.app"
VIRTUALOS_BUNDLE_ID = "com.github.yep.ios.virtualOS"
VIRTUALOS_LOG_SUBSYSTEM = "com.github.virtualOS"
DEFAULT_VM_DIRECTORY = f"~/Library/Containers/{VIRTUALOS_BUNDLE_ID}/Data/Documents"
AUTOSTART_ARGUMENT = "-autostartVMBundlePath"
NETWORK_MODES = {"nat": "NAT", "bridged": "Bridge"}
LOCAL_HOSTS = ("localhost", "127.0.0.1", "::1")
DHCP_LEASES = "/var/db/dhcpd_leases"
REQUIRED_BUNDLE_FILES = ("HardwareModel", "AuxiliaryStorage", "Parameters.txt")
START_CHECK_DELAY = 5


def fail(message):
    print(json.dumps({"status": "error", "error": message}))
    sys.exit(1)


def succeed(data):
    print(json.dumps(data))
    sys.exit(0)


def normalize_mac(mac):
    return ":".join(f"{int(octet, 16):02x}" for octet in mac.split(":"))


class VirtualOSError(Exception):
    pass


class VirtualOSManager:
    def __init__(self, config_path):
        self.data = self.parse_json(config_path)

    def parse_json(self, config_path):
        with open(config_path, 'r') as f:
            json_data = json.load(f)

        external = json_data.get("externaldetails", {})
        extension = external.get("extension", {}) or {}
        host = external.get("host", {}) or {}
        vm = external.get("virtualmachine", {}) or {}

        def detail(name, default=""):
            return host.get(name) or extension.get(name) or default

        def flag(name, default="false"):
            return str(detail(name, default)).lower() == "true"

        data = {
            "url": detail("url"),
            "username": detail("username"),
            "password": detail("password"),
            "ssh_key": detail("ssh_key"),
            "ssh_port": str(detail("ssh_port", "22")),
            "verify_host_key": flag("verify_host_key", "true"),
            "app_path": detail("app_path"),
            "vm_directory": detail("vm_directory", DEFAULT_VM_DIRECTORY).rstrip("/"),
            "network_mode": detail("network_mode").lower(),
            "bridge_interface": detail("bridge_interface"),
            "wait_timeout": int(detail("wait_timeout", "120")),
            "template_name": vm.get("template_name") or detail("template_name"),
        }
        if not data["url"]:
            fail("Missing required field in JSON: url")
        if data["network_mode"] and data["network_mode"] not in NETWORK_MODES:
            fail(f"Invalid network_mode '{data['network_mode']}', expected one of {', '.join(NETWORK_MODES)}")
        data["local"] = data["url"].lower() in LOCAL_HOSTS and not data["username"]
        if not data["local"] and not data["username"]:
            fail("Missing required field in JSON: username")

        vm_details = json_data.get("cloudstack.vm.details", {}) or {}
        data["vmname"] = vm_details.get("name", "")
        data["cpus"] = vm_details.get("cpus")
        data["memory"] = vm_details.get("minRam")
        nics = sorted(vm_details.get("nics", []) or [], key=lambda n: n.get("deviceId", 0))
        data["macs"] = [nic["mac"] for nic in nics if nic.get("mac")]
        return data

    def ssh_command(self, remote_argv):
        cmd = [
            "ssh",
            "-o", "ConnectTimeout=15",
            "-o", "StrictHostKeyChecking=" + ("yes" if self.data["verify_host_key"] else "no"),
            "-p", self.data["ssh_port"],
        ]
        if not self.data["verify_host_key"]:
            cmd += ["-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR"]
        if self.data["ssh_key"]:
            cmd += ["-i", self.data["ssh_key"]]
        if self.data["password"]:
            cmd = ["sshpass", "-e"] + cmd + ["-o", "BatchMode=no"]
        else:
            cmd += ["-o", "BatchMode=yes"]
        cmd += [f"{self.data['username']}@{self.data['url']}", "--",
                " ".join(shlex.quote(a) for a in remote_argv)]
        return cmd

    def run(self, argv, stdin=None):
        cmd = argv if self.data["local"] else self.ssh_command(argv)
        env = None
        if not self.data["local"] and self.data["password"]:
            env = dict(os.environ, SSHPASS=self.data["password"])
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, input=stdin,
                               timeout=self.data["wait_timeout"] + 30, env=env)
        except FileNotFoundError as e:
            raise VirtualOSError(f"Command not found: {e.filename}")
        except subprocess.TimeoutExpired:
            raise VirtualOSError(f"Timed out running: {' '.join(argv)}")
        if r.returncode != 0:
            raise VirtualOSError((r.stderr or r.stdout).strip() or f"'{' '.join(argv)}' exited with {r.returncode}")
        return r.stdout

    def sh(self, script, *args, stdin=None):
        return self.run(["sh", "-c", script, "sh"] + list(args), stdin=stdin)

    def vm_directory(self):
        directory = self.data["vm_directory"]
        if directory == "~" or directory.startswith("~/"):
            home = self.sh('printf %s "$HOME"').strip()
            directory = home + directory[1:]
            self.data["vm_directory"] = directory
        return directory

    def bundle_path(self, name=None):
        return f"{self.vm_directory()}/{name or self.data['vmname']}.bundle"

    def resolve_app(self):
        script = ('[ -d "$1" ] && echo "$1" && exit 0; '
                  f'mdfind "kMDItemCFBundleIdentifier == \'{VIRTUALOS_BUNDLE_ID}\'" | head -n 1')
        try:
            path = self.sh(script, DEFAULT_APP_PATH).strip()
        except VirtualOSError:
            path = ""
        if not path:
            raise VirtualOSError("virtualOS not found on the host, set the app_path detail")
        return path

    def app_path(self):
        if not self.data["app_path"]:
            self.data["app_path"] = self.resolve_app()
        return self.data["app_path"]

    def list_bundles(self):
        script = 'cd "$1" 2>/dev/null || exit 0; for b in *.bundle; do [ -d "$b" ] && echo "${b%.bundle}"; done; exit 0'
        return [name for name in self.sh(script, self.vm_directory()).splitlines() if name]

    def bundle_exists(self, name=None):
        return (name or self.data["vmname"]) in self.list_bundles()

    def running_vms(self):
        """Map bundle path to the pids of the virtualOS processes autostarting it."""
        executable = "/Contents/MacOS/virtualOS "
        marker = f" {AUTOSTART_ARGUMENT} "
        running = {}
        for line in self.run(["ps", "-axww", "-o", "pid=,command="]).splitlines():
            pid, _, command = line.strip().partition(" ")
            if executable in command and marker in command:
                running.setdefault(command.split(marker, 1)[1].strip(), []).append(pid)
        return running

    def vm_pids(self, name=None):
        return self.running_vms().get(self.bundle_path(name), [])

    def require_vmname(self):
        if not self.data["vmname"]:
            fail("Missing required field in JSON: cloudstack.vm.details.name")
        if "/" in self.data["vmname"] or self.data["vmname"].startswith("."):
            fail(f"Invalid instance name '{self.data['vmname']}'")

    def read_parameters(self, bundle):
        output = self.run(["cat", f"{bundle}/Parameters.txt"])
        try:
            return json.loads(output)
        except json.JSONDecodeError:
            raise VirtualOSError(f"Failed to parse {bundle}/Parameters.txt")

    def write_file(self, path, content):
        self.sh('cat > "$1"', path, stdin=content)

    def write_machine_identifier(self, bundle):
        # VZMacMachineIdentifier.dataRepresentation is a binary plist holding a random ECID
        identifier = plistlib.dumps({"ECID": secrets.randbits(63)}, fmt=plistlib.FMT_BINARY)
        self.sh('base64 -D > "$1"', f"{bundle}/MachineIdentifier",
                stdin=base64.b64encode(identifier).decode())

    def bridge_description(self):
        # virtualOS matches the bridge by its display name, e.g. "Wi-Fi (en0)"
        interface = self.data["bridge_interface"]
        if not interface or "(" in interface:
            return interface
        port = None
        for line in self.run(["networksetup", "-listallhardwareports"]).splitlines():
            if line.startswith("Hardware Port: "):
                port = line[len("Hardware Port: "):].strip()
            elif line.startswith("Device: ") and line[len("Device: "):].strip() == interface and port:
                return f"{port} ({interface})"
        return interface

    def configure(self, bundle):
        parameters = self.read_parameters(bundle)
        cpus = int(self.data["cpus"])
        memory_gb = max(1, math.ceil(int(self.data["memory"]) / (1024 ** 3)))
        parameters["cpuCount"] = cpus
        parameters["cpuCountMax"] = max(cpus, int(parameters.get("cpuCountMax", cpus)))
        parameters["cpuCountMin"] = min(cpus, int(parameters.get("cpuCountMin", cpus)))
        parameters["memorySizeInGB"] = memory_gb
        parameters["memorySizeInGBMax"] = max(memory_gb, int(parameters.get("memorySizeInGBMax", memory_gb)))
        parameters["memorySizeInGBMin"] = min(memory_gb, int(parameters.get("memorySizeInGBMin", memory_gb)))
        parameters["installFinished"] = True
        if self.data["macs"]:
            parameters["macAddress"] = normalize_mac(self.data["macs"][0])
        mode = self.data["network_mode"]
        if mode:
            parameters["networkType"] = NETWORK_MODES[mode]
            if mode == "bridged":
                parameters["networkBridge"] = self.bridge_description()
        self.write_file(f"{bundle}/Parameters.txt", json.dumps(parameters, indent=2))

    def start_errors(self, pid):
        output = self.run(["/usr/bin/log", "show", "--last", "2m", "--style", "compact", "--predicate",
                           f'subsystem == "{VIRTUALOS_LOG_SUBSYSTEM}" AND processID == {pid}'])
        errors = [line.rsplit("] ", 1)[1] for line in output.splitlines() if "] Error" in line]
        return list(dict.fromkeys(errors))

    def start_vm(self):
        if self.vm_pids():
            return
        bundle = self.bundle_path()
        self.run(["open", "-n", "-g", "-a", self.app_path(), "--args", AUTOSTART_ARGUMENT, bundle])
        deadline = time.time() + self.data["wait_timeout"]
        while not self.vm_pids():
            if time.time() > deadline:
                raise VirtualOSError(f"Timed out waiting for virtualOS to start {self.data['vmname']}")
            time.sleep(1)
        time.sleep(START_CHECK_DELAY)
        pids = self.vm_pids()
        if not pids:
            raise VirtualOSError(f"virtualOS exited while starting {self.data['vmname']}")
        try:
            errors = self.start_errors(pids[0])
        except VirtualOSError:
            errors = []
        if errors:
            self.stop_vm()
            raise VirtualOSError(f"virtualOS failed to start {self.data['vmname']}: {'; '.join(errors)}")

    def stop_vm(self, name=None):
        pids = self.vm_pids(name)
        if not pids:
            return
        self.run(["kill", "-TERM"] + pids)
        deadline = time.time() + self.data["wait_timeout"]
        while self.vm_pids(name):
            if time.time() > deadline:
                self.run(["kill", "-KILL"] + self.vm_pids(name))
                time.sleep(2)
                break
            time.sleep(1)
        if self.vm_pids(name):
            raise VirtualOSError(f"Failed to stop {name or self.data['vmname']}")

    def remove_bundle(self, name=None):
        bundle = self.bundle_path(name)
        if not bundle.endswith(".bundle") or not (name or self.data["vmname"]):
            raise VirtualOSError(f"Refusing to remove '{bundle}'")
        self.run(["rm", "-rf", bundle])

    def create(self):
        self.require_vmname()
        vm_name = self.data["vmname"]
        template = self.data["template_name"]
        if not template:
            fail("Missing required field in JSON: template_name")
        if self.data["cpus"] is None or self.data["memory"] is None:
            fail("Missing CPU or memory in cloudstack.vm.details")
        if len(self.data["macs"]) > 1:
            fail("virtualOS supports a single network interface per VM")

        bundles = self.list_bundles()
        if template not in bundles:
            fail(f"Template VM bundle '{template}' not found in {self.vm_directory()}")
        if vm_name in bundles:
            fail(f"A virtualOS VM named '{vm_name}' already exists")
        template_bundle = self.bundle_path(template)
        missing = self.sh('cd "$1" && shift && for f; do [ -e "$f" ] || echo "$f"; done; exit 0',
                          template_bundle, *REQUIRED_BUNDLE_FILES).split()
        if missing:
            fail(f"Template VM bundle '{template}' is incomplete, missing: {', '.join(missing)}")
        if self.vm_pids(template):
            fail(f"Template VM '{template}' is running, stop it before cloning")

        bundle = self.bundle_path()
        cloned = False
        try:
            # -c clones the files on APFS, plain copy elsewhere
            self.sh('cp -cR "$1" "$2" 2>/dev/null || { rm -rf "$2"; cp -R "$1" "$2"; }', template_bundle, bundle)
            cloned = True
            self.write_machine_identifier(bundle)
            self.configure(bundle)
            self.start_vm()
            succeed({"status": "success", "message": "Instance created"})
        except VirtualOSError as e:
            if cloned:
                try:
                    self.stop_vm()
                    self.remove_bundle()
                except VirtualOSError:
                    pass
            fail(str(e))

    def start(self):
        self.require_vmname()
        if not self.bundle_exists():
            fail(f"VM bundle '{self.data['vmname']}' not found in {self.vm_directory()}")
        self.start_vm()
        succeed({"status": "success", "message": "Instance started"})

    def stop(self):
        self.require_vmname()
        self.stop_vm()
        succeed({"status": "success", "message": "Instance stopped"})

    def reboot(self):
        self.require_vmname()
        self.stop_vm()
        self.start_vm()
        succeed({"status": "success", "message": "Instance rebooted"})

    def delete(self):
        self.require_vmname()
        self.stop_vm()
        if self.bundle_exists():
            self.remove_bundle()
        succeed({"status": "success", "message": "Instance deleted"})

    def power_state(self, name, running):
        if self.bundle_path(name) in running:
            return "poweron"
        return "poweroff"

    def status(self):
        self.require_vmname()
        if not self.bundle_exists():
            succeed({"status": "success", "power_state": "unknown"})
        succeed({"status": "success", "power_state": self.power_state(self.data["vmname"], self.running_vms())})

    def statuses(self):
        running = self.running_vms()
        power_state = {name: self.power_state(name, running) for name in self.list_bundles()}
        succeed({"status": "success", "power_state": power_state})

    def get_console(self):
        fail("Operation not supported")

    def get_ip_addresses(self):
        self.require_vmname()
        if not self.bundle_exists():
            fail(f"VM bundle '{self.data['vmname']}' not found in {self.vm_directory()}")
        mac = normalize_mac(self.read_parameters(self.bundle_path()).get("macAddress", "0"))
        leases = self.sh('[ -r "$1" ] && cat "$1"; exit 0', DHCP_LEASES)
        addresses = []
        for lease in re.findall(r"\{(.*?)\}", leases, re.S):
            fields = dict(line.strip().split("=", 1) for line in lease.splitlines() if "=" in line)
            hw_address = fields.get("hw_address", "").split(",", 1)[-1]
            if hw_address and normalize_mac(hw_address) == mac and fields.get("ip_address"):
                addresses.append(fields["ip_address"])
        succeed({"status": "success", "printmessage": "true", "message": addresses})


def main():
    if len(sys.argv) < 3:
        fail("Usage: virtualos.py <operation> '<json-file-path>'")

    operation = sys.argv[1].lower()
    json_file_path = sys.argv[2]

    try:
        manager = VirtualOSManager(json_file_path)
    except FileNotFoundError:
        fail(f"JSON file not found: {json_file_path}")
    except json.JSONDecodeError:
        fail("Invalid JSON in file")
    except (KeyError, ValueError) as e:
        fail(f"Error parsing JSON: {str(e)}")

    operations = {
        "create": manager.create,
        "start": manager.start,
        "stop": manager.stop,
        "reboot": manager.reboot,
        "delete": manager.delete,
        "status": manager.status,
        "statuses": manager.statuses,
        "getconsole": manager.get_console,
        "getipaddresses": manager.get_ip_addresses,
    }

    if operation not in operations:
        fail("Invalid action")

    try:
        operations[operation]()
    except VirtualOSError as e:
        fail(str(e))


if __name__ == "__main__":
    main()
