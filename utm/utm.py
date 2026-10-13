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
CloudStack orchestrator extension for UTM (https://mac.getutm.app) on macOS.

The management server reaches the Mac over SSH (or runs locally when the
management server itself runs on the Mac) and drives UTM through its
command line tool `utmctl` and its AppleScript interface (`osascript`).

Instances are created by cloning an existing UTM virtual machine that acts
as the template, after which CPU cores, memory and NIC MAC addresses are
set from the CloudStack instance. The UTM virtual machine is named after
the CloudStack instance's internal name.

Details (host details override extension details):
  url                   Mac hostname/IP, or "localhost" to run locally
  username              SSH user owning the UTM library (logged in to the GUI)
  password              optional, SSH password (requires sshpass on the
                        management server; key authentication is preferred)
  ssh_key               optional, private key path on the management server
  ssh_port              optional, defaults to 22
  verify_host_key       optional, "true" (default) or "false"
  utmctl_path           optional, by default /Applications/UTM.app is used,
                        falling back to a Spotlight lookup of the UTM bundle
  template_name         optional, default UTM VM to clone
  network_mode          optional, shared|bridged|host|emulated; when set it is
                        applied to every NIC, otherwise the template's mode is
                        kept and added NICs use "shared"
  bridge_interface      optional, macOS interface for bridged mode, e.g. en0
  wait_timeout          optional, seconds to wait for state changes (120)

Instance/template details:
  template_name         UTM VM to clone, overrides the host/extension value
"""

import json
import os
import shlex
import subprocess
import sys
import time

DEFAULT_UTMCTL = "/Applications/UTM.app/Contents/MacOS/utmctl"
UTM_BUNDLE_ID = "com.utmapp.UTM"
NETWORK_MODES = ("shared", "bridged", "host", "emulated")
LOCAL_HOSTS = ("localhost", "127.0.0.1", "::1")

POWER_ON_STATES = ("started", "starting", "paused", "pausing", "resuming")
POWER_OFF_STATES = ("stopped",)

CONFIGURE_SCRIPT = """
on run argv
    set vmName to item 1 of argv
    set cpuCount to (item 2 of argv) as integer
    set memMib to (item 3 of argv) as integer
    set bridgeIf to item 4 of argv
    set macs to {}
    repeat with i from 5 to count of argv
        set end of macs to item i of argv
    end repeat
    tell application "UTM"
        set vm to virtual machine named vmName
        set config to configuration of vm
        set cpu cores of config to cpuCount
        set memory of config to memMib
        set nics to network interfaces of config
        set newNics to {}
        repeat with i from 1 to count of macs
            if i <= (count of nics) then
                set nic to item i of nics
                set address of nic to item i of macs
                %(set_mode)s
            else
                %(new_nic)s
            end if
            set end of newNics to nic
        end repeat
        set network interfaces of config to newNics
        update configuration of vm with config
    end tell
end run
"""


def fail(message):
    print(json.dumps({"status": "error", "error": message}))
    sys.exit(1)


def succeed(data):
    print(json.dumps(data))
    sys.exit(0)


class UtmError(Exception):
    pass


class UtmManager:
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

        data = {
            "url": detail("url"),
            "username": detail("username"),
            "password": detail("password"),
            "ssh_key": detail("ssh_key"),
            "ssh_port": str(detail("ssh_port", "22")),
            "verify_host_key": str(detail("verify_host_key", "true")).lower() == "true",
            "utmctl": detail("utmctl_path"),
            "network_mode": detail("network_mode").lower(),
            "bridge_interface": detail("bridge_interface"),
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

        data["parameters"] = json_data.get("parameters", {}) or {}
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
            r = subprocess.run(cmd, input=stdin, capture_output=True, text=True,
                               timeout=self.data["wait_timeout"] + 30, env=env)
        except FileNotFoundError as e:
            raise UtmError(f"Command not found: {e.filename}")
        except subprocess.TimeoutExpired:
            raise UtmError(f"Timed out running: {' '.join(argv)}")
        # utmctl exits with 0 when the Apple Event it sends fails, so check its error output as well
        if r.returncode != 0 or "Error from event" in r.stderr:
            raise UtmError((r.stderr or r.stdout).strip() or f"'{' '.join(argv)}' exited with {r.returncode}")
        return r.stdout

    def resolve_utmctl(self):
        script = (f'p={shlex.quote(DEFAULT_UTMCTL)}; [ -x "$p" ] || '
                  f'p="$(mdfind "kMDItemCFBundleIdentifier == \'{UTM_BUNDLE_ID}\'" | head -n 1)/Contents/MacOS/utmctl"; '
                  '[ -x "$p" ] && echo "$p"')
        try:
            path = self.run(["sh", "-c", script]).strip()
        except UtmError:
            path = ""
        if not path:
            raise UtmError("UTM not found on the host, set the utmctl_path detail")
        return path

    def utmctl(self, *args):
        if not self.data["utmctl"]:
            self.data["utmctl"] = self.resolve_utmctl()
        return self.run([self.data["utmctl"]] + list(args))

    def osascript(self, script, *args):
        return self.run(["osascript", "-"] + list(args), stdin=script)

    def list_vms(self):
        vms = {}
        for line in self.utmctl("list").splitlines():
            parts = line.split(None, 2)
            if len(parts) < 3 or parts[0] == "UUID":
                continue
            vms[parts[2].strip()] = parts[1].strip().lower()
        return vms

    def vm_state(self, name=None):
        return self.list_vms().get(name or self.data["vmname"])

    def wait_for_state(self, states, name=None):
        deadline = time.time() + self.data["wait_timeout"]
        while True:
            state = self.vm_state(name)
            if state in states:
                return state
            if time.time() > deadline:
                raise UtmError(f"Timed out waiting for {name or self.data['vmname']} to reach {'/'.join(states)}, "
                               f"current state: {state}")
            time.sleep(2)

    def require_vmname(self):
        if not self.data["vmname"]:
            fail("Missing required field in JSON: cloudstack.vm.details.name")

    def configure_script(self):
        mode = self.data["network_mode"]
        set_mode = ""
        if mode:
            set_mode = f"set mode of nic to {mode}"
            if mode == "bridged":
                set_mode += "\n                set host interface of nic to bridgeIf"
        new_mode = mode or "shared"
        host_interface = ", host interface:bridgeIf" if new_mode == "bridged" else ""
        new_nic = f"set nic to {{mode:{new_mode}, address:item i of macs{host_interface}}}"
        return CONFIGURE_SCRIPT % {"set_mode": set_mode, "new_nic": new_nic}

    def stop_vm(self, name):
        state = self.vm_state(name)
        if state is None or state in POWER_OFF_STATES:
            return
        self.utmctl("stop", name)
        self.wait_for_state(POWER_OFF_STATES, name)

    def create(self):
        self.require_vmname()
        vm_name = self.data["vmname"]
        template = self.data["template_name"]
        if not template:
            fail("Missing required field in JSON: template_name")
        if self.data["cpus"] is None or self.data["memory"] is None:
            fail("Missing CPU or memory in cloudstack.vm.details")

        vms = self.list_vms()
        if template not in vms:
            fail(f"Template VM '{template}' not found in UTM")
        if vm_name in vms:
            fail(f"A UTM VM named '{vm_name}' already exists")

        cloned = False
        try:
            self.utmctl("clone", template, "--name", vm_name)
            cloned = True
            memory_mib = int(self.data["memory"]) // (1024 * 1024)
            self.osascript(self.configure_script(), vm_name, str(self.data["cpus"]), str(memory_mib),
                           self.data["bridge_interface"], *self.data["macs"])
            self.utmctl("start", vm_name)
            succeed({"status": "success", "message": "Instance created"})
        except UtmError as e:
            if cloned:
                try:
                    self.stop_vm(vm_name)
                    self.utmctl("delete", vm_name)
                except UtmError:
                    pass
            fail(str(e))

    def start(self):
        self.require_vmname()
        self.utmctl("start", self.data["vmname"])
        succeed({"status": "success", "message": "Instance started"})

    def stop(self):
        self.require_vmname()
        self.stop_vm(self.data["vmname"])
        succeed({"status": "success", "message": "Instance stopped"})

    def reboot(self):
        self.require_vmname()
        self.stop_vm(self.data["vmname"])
        self.utmctl("start", self.data["vmname"])
        succeed({"status": "success", "message": "Instance rebooted"})

    def delete(self):
        self.require_vmname()
        vm_name = self.data["vmname"]
        if self.vm_state(vm_name) is not None:
            self.stop_vm(vm_name)
            self.utmctl("delete", vm_name)
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
        self.utmctl("suspend", self.data["vmname"])
        succeed({"status": "success", "message": "Instance suspended"})

    def resume(self):
        self.require_vmname()
        self.utmctl("start", self.data["vmname"])
        succeed({"status": "success", "message": "Instance resumed"})

    def get_ip_addresses(self):
        self.require_vmname()
        addresses = [a.strip() for a in self.utmctl("ip-address", self.data["vmname"]).splitlines() if a.strip()]
        succeed({"status": "success", "printmessage": "true", "message": addresses})


def main():
    if len(sys.argv) < 3:
        fail("Usage: utm.py <operation> '<json-file-path>'")

    operation = sys.argv[1].lower()
    json_file_path = sys.argv[2]

    try:
        manager = UtmManager(json_file_path)
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
    }

    if operation not in operations:
        fail("Invalid action")

    try:
        operations[operation]()
    except UtmError as e:
        fail(str(e))


if __name__ == "__main__":
    main()
