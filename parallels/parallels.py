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
CloudStack orchestrator extension for Parallels Desktop on macOS.

The management server reaches the Mac over SSH (or runs locally when the
management server itself runs on the Mac) and drives Parallels Desktop
through its command line tool `prlctl`, which requires the Pro or Business
edition of Parallels Desktop.

Instances are created by cloning an existing Parallels virtual machine or
template, after which CPU count, memory and NIC MAC addresses are set from
the CloudStack instance. The Parallels virtual machine is named after the
CloudStack instance's internal name.

Details (host details override extension details):
  url                   Mac hostname/IP, or "localhost" to run locally
  username              SSH user owning the Parallels VMs (logged in to the GUI)
  password              optional, SSH password (requires sshpass on the
                        management server; key authentication is preferred)
  ssh_key               optional, private key path on the management server
  ssh_port              optional, defaults to 22
  verify_host_key       optional, "true" (default) or "false"
  prlctl_path           optional, by default /usr/local/bin/prlctl or the one
                        in /Applications/Parallels Desktop.app is used,
                        falling back to a Spotlight lookup of the app bundle
  template_name         optional, default Parallels VM or template to clone
  linked_clone          optional, "true" to create linked clones (default
                        "false"); the template VM needs a snapshot for this
  network_mode          optional, shared|bridged|host-only; when set it is
                        applied to every NIC, otherwise the template's mode is
                        kept and added NICs use "shared"
  bridge_interface      optional, macOS interface for bridged mode, e.g. en0
  headless              optional, "true" to start instances without a window
  wait_timeout          optional, seconds to wait for state changes (120)

Instance/template details:
  template_name         Parallels VM to clone, overrides the host/extension value

Custom action parameters:
  snapshot_name         name of the snapshot for Create/Restore/DeleteSnapshot
"""

import json
import os
import shlex
import subprocess
import sys
import time

DEFAULT_PRLCTL_PATHS = ("/usr/local/bin/prlctl",
                        "/Applications/Parallels Desktop.app/Contents/MacOS/prlctl")
PARALLELS_BUNDLE_ID = "com.parallels.desktop.console"
NETWORK_MODES = ("shared", "bridged", "host-only")
LOCAL_HOSTS = ("localhost", "127.0.0.1", "::1")

POWER_ON_STATES = ("running", "starting", "paused", "pausing", "continuing", "resuming", "resetting")
POWER_OFF_STATES = ("stopped", "suspended")


def fail(message):
    print(json.dumps({"status": "error", "error": message}))
    sys.exit(1)


def succeed(data):
    print(json.dumps(data))
    sys.exit(0)


class ParallelsError(Exception):
    pass


class ParallelsManager:
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
            "prlctl": detail("prlctl_path"),
            "linked_clone": flag("linked_clone"),
            "network_mode": detail("network_mode").lower(),
            "bridge_interface": detail("bridge_interface"),
            "headless": flag("headless"),
            "wait_timeout": int(detail("wait_timeout", "120")),
            "template_name": vm.get("template_name") or detail("template_name"),
        }
        if not data["url"]:
            fail("Missing required field in JSON: url")
        if data["network_mode"] and data["network_mode"] not in NETWORK_MODES:
            fail(f"Invalid network_mode '{data['network_mode']}', expected one of {', '.join(NETWORK_MODES)}")
        if data["network_mode"] == "bridged" and not data["bridge_interface"]:
            fail("Missing required field in JSON: bridge_interface (required for bridged network_mode)")
        data["local"] = data["url"].lower() in LOCAL_HOSTS and not data["username"]
        if not data["local"] and not data["username"]:
            fail("Missing required field in JSON: username")

        vm_details = json_data.get("cloudstack.vm.details", {}) or {}
        data["vmname"] = vm_details.get("name", "")
        data["cpus"] = vm_details.get("cpus")
        data["memory"] = vm_details.get("minRam")
        nics = sorted(vm_details.get("nics", []) or [], key=lambda n: n.get("deviceId", 0))
        data["macs"] = [nic["mac"] for nic in nics if nic.get("mac")]

        parameters = json_data.get("parameters", {}) or {}
        data["snapshot_name"] = str(parameters.get("snapshot_name", "")).strip()
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

    def run(self, argv):
        cmd = argv if self.data["local"] else self.ssh_command(argv)
        env = None
        if not self.data["local"] and self.data["password"]:
            env = dict(os.environ, SSHPASS=self.data["password"])
        try:
            r = subprocess.run(cmd, capture_output=True, text=True,
                               timeout=self.data["wait_timeout"] + 30, env=env)
        except FileNotFoundError as e:
            raise ParallelsError(f"Command not found: {e.filename}")
        except subprocess.TimeoutExpired:
            raise ParallelsError(f"Timed out running: {' '.join(argv)}")
        if r.returncode != 0:
            raise ParallelsError((r.stderr or r.stdout).strip() or f"'{' '.join(argv)}' exited with {r.returncode}")
        return r.stdout

    def resolve_prlctl(self):
        candidates = " ".join(shlex.quote(p) for p in DEFAULT_PRLCTL_PATHS)
        script = (f'for p in {candidates}; do [ -x "$p" ] && echo "$p" && exit 0; done; '
                  f'p="$(mdfind "kMDItemCFBundleIdentifier == \'{PARALLELS_BUNDLE_ID}\'" | head -n 1)/Contents/MacOS/prlctl"; '
                  '[ -x "$p" ] && echo "$p"')
        try:
            path = self.run(["sh", "-c", script]).strip()
        except ParallelsError:
            path = ""
        if not path:
            raise ParallelsError("Parallels Desktop not found on the host, set the prlctl_path detail")
        return path

    def prlctl(self, *args):
        if not self.data["prlctl"]:
            self.data["prlctl"] = self.resolve_prlctl()
        return self.run([self.data["prlctl"]] + list(args))

    def prlctl_json(self, *args):
        output = self.prlctl(*args).strip()
        if not output:
            return None
        try:
            return json.loads(output)
        except json.JSONDecodeError:
            raise ParallelsError(f"Failed to parse prlctl output: {output}")

    def list_vms(self, templates=False):
        args = ["list", "--all", "--json"] + (["--template"] if templates else [])
        return {vm["name"]: vm.get("status", "").lower() for vm in self.prlctl_json(*args) or [] if vm.get("name")}

    def vm_state(self, name=None):
        return self.list_vms().get(name or self.data["vmname"])

    def vm_info(self, name):
        info = self.prlctl_json("list", "--info", "--json", name)
        if isinstance(info, list):
            info = info[0] if info else {}
        return info or {}

    def wait_for_state(self, states, name=None):
        deadline = time.time() + self.data["wait_timeout"]
        while True:
            state = self.vm_state(name)
            if state in states:
                return state
            if time.time() > deadline:
                raise ParallelsError(f"Timed out waiting for {name or self.data['vmname']} to reach {'/'.join(states)}, "
                                     f"current state: {state}")
            time.sleep(2)

    def require_vmname(self):
        if not self.data["vmname"]:
            fail("Missing required field in JSON: cloudstack.vm.details.name")

    def require_snapshot_name(self):
        if not self.data["snapshot_name"]:
            fail("Missing required field in JSON: snapshot_name")

    def stop_vm(self, name):
        state = self.vm_state(name)
        if state is None or state == "stopped":
            return
        if state == "suspended":
            self.prlctl("stop", name, "--drop-state")
            return
        try:
            self.prlctl("stop", name)
            self.wait_for_state(("stopped",), name)
        except ParallelsError:
            self.prlctl("stop", name, "--kill")
            self.wait_for_state(("stopped",), name)

    def configure_nics(self, vm_name):
        hardware = self.vm_info(vm_name).get("Hardware", {}) or {}
        existing = sorted((d for d in hardware if d.startswith("net") and d[3:].isdigit()), key=lambda d: int(d[3:]))
        mode = self.data["network_mode"]
        mode_args = []
        if mode:
            mode_args = ["--type", mode]
            if mode == "bridged":
                mode_args += ["--iface", self.data["bridge_interface"]]
        for i, mac in enumerate(self.data["macs"]):
            mac = mac.replace(":", "").upper()
            if i < len(existing):
                self.prlctl("set", vm_name, "--device-set", existing[i], "--mac", mac, *mode_args)
            else:
                add_args = mode_args or ["--type", "shared"]
                self.prlctl("set", vm_name, "--device-add", "net", "--mac", mac, *add_args)
        for device in existing[len(self.data["macs"]):]:
            self.prlctl("set", vm_name, "--device-del", device)

    def create(self):
        self.require_vmname()
        vm_name = self.data["vmname"]
        template = self.data["template_name"]
        if not template:
            fail("Missing required field in JSON: template_name")
        if self.data["cpus"] is None or self.data["memory"] is None:
            fail("Missing CPU or memory in cloudstack.vm.details")

        vms = self.list_vms(templates=True)
        if template not in vms:
            fail(f"Template VM '{template}' not found in Parallels Desktop")
        if vm_name in vms:
            fail(f"A Parallels VM named '{vm_name}' already exists")

        cloned = False
        try:
            clone_args = ["clone", template, "--name", vm_name]
            if self.data["linked_clone"]:
                clone_args.append("--linked")
            self.prlctl(*clone_args)
            cloned = True
            memory_mib = int(self.data["memory"]) // (1024 * 1024)
            set_args = ["set", vm_name, "--cpus", str(self.data["cpus"]), "--memsize", str(memory_mib)]
            if self.data["headless"]:
                set_args += ["--startup-view", "headless"]
            self.prlctl(*set_args)
            self.configure_nics(vm_name)
            self.prlctl("start", vm_name)
            succeed({"status": "success", "message": "Instance created"})
        except ParallelsError as e:
            if cloned:
                try:
                    self.stop_vm(vm_name)
                    self.prlctl("delete", vm_name)
                except ParallelsError:
                    pass
            fail(str(e))

    def start(self):
        self.require_vmname()
        self.prlctl("start", self.data["vmname"])
        succeed({"status": "success", "message": "Instance started"})

    def stop(self):
        self.require_vmname()
        self.stop_vm(self.data["vmname"])
        succeed({"status": "success", "message": "Instance stopped"})

    def reboot(self):
        self.require_vmname()
        self.prlctl("restart", self.data["vmname"])
        succeed({"status": "success", "message": "Instance rebooted"})

    def delete(self):
        self.require_vmname()
        vm_name = self.data["vmname"]
        if self.vm_state(vm_name) is not None:
            self.stop_vm(vm_name)
            self.prlctl("delete", vm_name)
        succeed({"status": "success", "message": "Instance deleted"})

    @staticmethod
    def power_state(state):
        if state in POWER_ON_STATES:
            return "poweron"
        if state in POWER_OFF_STATES:
            return "poweroff"
        return "unknown"

    def status(self):
        self.require_vmname()
        succeed({"status": "success", "power_state": self.power_state(self.vm_state())})

    def statuses(self):
        power_state = {name: self.power_state(state) for name, state in self.list_vms().items()}
        succeed({"status": "success", "power_state": power_state})

    def get_console(self):
        fail("Operation not supported")

    def suspend(self):
        self.require_vmname()
        self.prlctl("pause", self.data["vmname"])
        succeed({"status": "success", "message": "Instance suspended"})

    def resume(self):
        self.require_vmname()
        self.prlctl("resume", self.data["vmname"])
        succeed({"status": "success", "message": "Instance resumed"})

    def get_ip_addresses(self):
        self.require_vmname()
        output = self.prlctl("list", "--full", "--no-header", "--output", "ip", self.data["vmname"])
        addresses = [a for a in output.replace(",", " ").split() if a != "-"]
        succeed({"status": "success", "printmessage": "true", "message": addresses})

    def snapshots(self):
        snapshots = self.prlctl_json("snapshot-list", self.data["vmname"], "--json") or {}
        if isinstance(snapshots, list):
            snapshots = {s.get("id", ""): s for s in snapshots}
        return snapshots

    def snapshot_id(self):
        matches = [sid for sid, s in self.snapshots().items() if s.get("name") == self.data["snapshot_name"]]
        if not matches:
            fail(f"Snapshot '{self.data['snapshot_name']}' not found")
        if len(matches) > 1:
            fail(f"Multiple snapshots named '{self.data['snapshot_name']}' found")
        return matches[0]

    def list_snapshots(self):
        self.require_vmname()
        snapshots = [{"Name": s.get("name", ""), "CreationTime": s.get("date", ""), "Current": bool(s.get("current"))}
                     for s in self.snapshots().values()]
        succeed({"status": "success", "printmessage": "true", "message": snapshots})

    def create_snapshot(self):
        self.require_vmname()
        self.require_snapshot_name()
        self.prlctl("snapshot", self.data["vmname"], "--name", self.data["snapshot_name"])
        succeed({"status": "success", "message": f"Snapshot '{self.data['snapshot_name']}' created"})

    def restore_snapshot(self):
        self.require_vmname()
        self.require_snapshot_name()
        self.prlctl("snapshot-switch", self.data["vmname"], "--id", self.snapshot_id())
        succeed({"status": "success", "message": f"Snapshot '{self.data['snapshot_name']}' restored"})

    def delete_snapshot(self):
        self.require_vmname()
        self.require_snapshot_name()
        self.prlctl("snapshot-delete", self.data["vmname"], "--id", self.snapshot_id())
        succeed({"status": "success", "message": f"Snapshot '{self.data['snapshot_name']}' deleted"})


def main():
    if len(sys.argv) < 3:
        fail("Usage: parallels.py <operation> '<json-file-path>'")

    operation = sys.argv[1].lower()
    json_file_path = sys.argv[2]

    try:
        manager = ParallelsManager(json_file_path)
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
        "suspend": manager.suspend,
        "resume": manager.resume,
        "getipaddresses": manager.get_ip_addresses,
        "listsnapshots": manager.list_snapshots,
        "createsnapshot": manager.create_snapshot,
        "restoresnapshot": manager.restore_snapshot,
        "deletesnapshot": manager.delete_snapshot,
    }

    if operation not in operations:
        fail("Invalid action")

    try:
        operations[operation]()
    except ParallelsError as e:
        fail(str(e))


if __name__ == "__main__":
    main()
