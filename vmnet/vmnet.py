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
CloudStack NetworkOrchestrator extension for macOS vmnet networks.

The networks are local to the Macs that run the instances, so this provider
only names them: implement-network gives every CloudStack network a vmnet
network name and mode, which CloudStack stores as the network's broadcast
URI, e.g. vs://cs-net-42?mode=nat. The orchestrator extensions running the
instances (e.g. apple-container) read that URI from each NIC and create the
network on the Mac on first use. All other network commands are no-ops.

Only L2 networks are accepted: the vmnet networks hand out their own IP
addresses, so CloudStack cannot manage them. CloudStack only uses an
extension for networks whose offering names it as a service provider, and
L2 offerings may only have the UserData service, so the extension declares
UserData. It does not deliver user data yet: those commands are no-ops.

Physical network registration details (registerExtension):
  mode          optional, nat (default) or internal; nat networks reach the
                outside world through the Mac, internal (host-only) networks
                reach only the Mac and each other's instances
  name_prefix   optional, prefix of the vmnet network names, default cs-net-

Invocation: vmnet.py <command> <payload-file> <timeout-seconds>
"""

import json
import re
import sys

MODES = ("nat", "internal")
DEFAULT_MODE = "nat"
DEFAULT_PREFIX = "cs-net-"
BROADCAST_SCHEME = "vs"
BROADCAST_DOMAIN_TYPE = "Vswitch"

NO_OP_COMMANDS = {
    "shutdown-network", "destroy-network", "restore-network",
    "prepare-nic", "release-nic",
    "assign-ip", "release-ip",
    "add-static-nat", "delete-static-nat", "add-port-forward", "delete-port-forward",
    "apply-fw-rules", "apply-network-acl", "apply-lb-rules",
    "add-dhcp-entry", "remove-dhcp-entry", "config-dhcp-subnet", "remove-dhcp-subnet", "set-dhcp-options",
    "add-dns-entry", "remove-dns-entry", "config-dns-subnet", "remove-dns-subnet",
    "save-vm-data", "save-password", "save-userdata", "save-sshkey", "save-hypervisor-hostname",
}


class VmnetError(Exception):
    pass


def as_object(value):
    """Extension details arrive as a JSON object or as a JSON encoded string."""
    if isinstance(value, str):
        try:
            value = json.loads(value) if value.strip() else {}
        except ValueError:
            return {}
    return value if isinstance(value, dict) else {}


def text(value):
    return "" if value is None else str(value).strip()


def network_settings(data):
    details = as_object(data.get("physical-network-extension-details"))
    mode = text(details.get("mode")).lower() or DEFAULT_MODE
    if mode not in MODES:
        raise VmnetError(f"Invalid mode '{mode}', expected one of {', '.join(MODES)}")
    prefix = text(details.get("name_prefix")) or DEFAULT_PREFIX
    # The name ends up as the host part of the broadcast URI.
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", prefix):
        raise VmnetError(f"Invalid name_prefix '{prefix}', use lowercase letters, digits and dashes")
    return mode, prefix


def network_name(prefix, network_id):
    network_id = text(network_id)
    if not network_id.isdigit():
        raise VmnetError(f"Missing or invalid network_id '{network_id}'")
    return f"{prefix}{network_id}"


def broadcast_uri(name, mode):
    return f"{BROADCAST_SCHEME}://{name}?mode={mode}"


def implement_network(data):
    payload = as_object(data.get("payload"))
    guest_type = text(payload.get("guest_type")).lower()
    if guest_type and guest_type != "l2":
        raise VmnetError(f"vmnet networks assign their own IP addresses, so only L2 networks are supported, "
                         f"not {guest_type} network {payload.get('network_id')}")
    mode, prefix = network_settings(data)
    name = network_name(prefix, payload.get("network_id"))
    return {"network.broadcast_domain_type": BROADCAST_DOMAIN_TYPE,
            "network.broadcast_uri": broadcast_uri(name, mode)}


def execute(command, payload_file):
    if command not in NO_OP_COMMANDS and command not in ("ensure-network-device", "implement-network"):
        raise VmnetError(f"Unsupported command '{command}'")
    try:
        with open(payload_file, encoding="utf-8") as fh:
            data = json.load(fh)
    except OSError as e:
        raise VmnetError(f"Cannot read payload file {payload_file}: {e}")
    except ValueError:
        raise VmnetError(f"Invalid JSON in payload file {payload_file}")

    if command == "implement-network":
        return implement_network(data)
    if command == "ensure-network-device":
        # There is no central device: the networks live on the Macs.
        return {}
    return None


def main(argv):
    if len(argv) < 3:
        print("Usage: vmnet.py <command> <payload-file> [timeout-seconds]", file=sys.stderr)
        return 1
    try:
        output = execute(argv[1], argv[2])
    except VmnetError as e:
        print(str(e), file=sys.stderr)
        return 1
    if output is not None:
        print(json.dumps(output, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
