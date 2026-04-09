<!--
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 -->
# NetworkExtension for Apache CloudStack

This directory contains the **NetworkExtension** `NetworkOrchestrator` extension —
a CloudStack plugin that delegates all network operations to an external device
over SSH.  The device can be a Linux server (using network namespaces,
bridges, and iptables), a network appliance that accepts SSH commands, or any
other host that can run the `network-namespace-wrapper.sh` (or a compatible
script) to perform network configurations.

The extension is implemented in
`framework/extensions/src/main/java/org/apache/cloudstack/framework/extensions/network/NetworkExtensionElement.java`
and loaded automatically by the management server — **no separate plugin JAR is
required**.

---

## Table of Contents

1. [Architecture](#architecture)
2. [Directory contents](#directory-contents)
3. [How it works](#how-it-works)
4. [Installation](#installation)
   - [Management server](#management-server)
   - [Remote network device](#remote-network-device)
5. [Step-by-step API setup](#step-by-step-api-setup)
   - [1. Create the extension](#1-create-the-extension)
   - [2. Register the extension with a physical network](#2-register-the-extension-with-a-physical-network)
   - [3. Create a network offering](#3-create-a-network-offering)
   - [4. Create an isolated network](#4-create-an-isolated-network)
   - [5. Acquire a public IP and enable Source NAT](#5-acquire-a-public-ip-and-enable-source-nat)
   - [6. Enable / disable Static NAT](#6-enable--disable-static-nat)
   - [7. Add / delete Port Forwarding](#7-add--delete-port-forwarding)
   - [8. Delete the network](#8-delete-the-network)
   - [9. Unregister and delete the extension](#9-unregister-and-delete-the-extension)
6. [Multiple extensions on the same physical network](#multiple-extensions-on-the-same-physical-network)
7. [Wrapper script operations reference](#wrapper-script-operations-reference)
8. [CLI argument reference](#cli-argument-reference)
9. [Custom actions](#custom-actions)
10. [Developer / testing notes](#developer--testing-notes)

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  CloudStack Management Server                            │
│                                                          │
│  NetworkExtensionElement.java                            │
│      │ executes (path resolved from Extension record)    │
│      ▼                                                   │
│  /usr/share/cloudstack-management/extensions/<ext-name>/ │
│      <ext-name>.sh   (network-namespace.sh)              │
└──────────────────────┬───────────────────────────────────┘
                       │ SSH (host : port from extension details)
                       │ credentials from extension_resource_map_details
                       ▼
┌──────────────────────────────────────────────────────────┐
│  Remote Network Device  (KVM Linux server)               │
│                                                          │
│  network-namespace-wrapper.sh <command> [args...]        │
│                                                          │
│  Per-network data plane (guest VLAN 1910, network 209):  │
│                                                          │
│  HOST side                                               │
│  ─────────────────────────────────────────────────       │
│  eth1.1910  ─────────────────────────────────┐           │
│  (VLAN sub-iface)                            │           │
│                                    breth1-1910  (bridge) │
│  vh-1910-d1  ─────────────────────────────────┘          │
│      │                                                   │
│  NAMESPACE  cs-net-209  (isolated)                       │
│             cs-vpc-5    (VPC, vpc-id=5)                  │
│  ─────────────────────────────────────────────────       │
│  vn-1910-d1  ← gateway IP 10.1.1.1/24                    │
│                                                          │
│  PUBLIC side (source-NAT IP 10.0.56.4 on VLAN 101):      │
│                                                          │
│  HOST side                                               │
│  eth1.101   ─────────────────────────────────┐           │
│                                   breth1-101  (bridge)   │
│  vph-101-209 ────────────────────────────────┘           │
│      │                                                   │
│  NAMESPACE  cs-net-209  (or  cs-vpc-<vpcId>)             │
│  vpn-101-209  ← source-NAT IP  10.0.56.4/32              │
│  default route → 10.0.56.1 (upstream gateway)            │
└──────────────────────────────────────────────────────────┘
```

### Naming conventions

| Object | Name pattern | Example (VLAN 1910, net 209, pub-VLAN 101) |
|--------|--------------|-------------------------------------------|
| Namespace (isolated network)   | `cs-net-<networkId>` | `cs-net-209` |
| Namespace (VPC network)        | `cs-vpc-<vpcId>`     | `cs-vpc-5` |
| Guest host bridge              | `br<ethX>-<vlan>`    | `breth1-1910` |
| Guest veth – host side         | `vh-<vlan>-<id>`     | `vh-1910-d1` |
| Guest veth – namespace side    | `vn-<vlan>-<id>`     | `vn-1910-d1` |
| Public host bridge             | `br<pub_ethX>-<pvlan>` | `breth1-101` |
| Public veth – host side        | `vph-<pvlan>-<id>`   | `vph-101-209` |
| Public veth – namespace side   | `vpn-<pvlan>-<id>`   | `vpn-101-209` |

`ethX` (and `pub_ethX`) is the NIC specified in the `guest.network.device`
(and `public.network.device`) key when registering the extension on the
physical network.  Both default to `eth1` when not explicitly set.

> **Note:** when `<vlan>` or `<id>` would make the interface name exceed the
> Linux 15-character limit, the `<id>` portion is shortened to its hex
> representation (for numeric IDs) or a 6-character MD5 prefix (for
> non-numeric IDs).

**Key design principles:**

* The `network-namespace.sh` script runs on the **management server**.  All
  connection details (`host`, `port`, `username`, `sshkey`, etc.) are passed as
  two named CLI arguments injected by `NetworkExtensionElement` — the script
  itself is completely generic and requires no local configuration.
* The `network-namespace-wrapper.sh` script runs on the **remote KVM device**.
  It creates host-side bridges, veth pairs, and iptables rules.  Bridges and
  VLAN sub-interfaces live on the **host** (not inside the namespace) so that
  guest VMs whose NICs are connected to `brethX-<vlan>` reach the namespace
  gateway without any additional configuration.
* **VPC networks** share a single namespace per VPC (`cs-vpc-<vpcId>`).  Multiple
  guest VLANs are each connected via their own veth pair (`vh-<vlan>-<id>` /
  `vn-<vlan>-<id>`).
* **Isolated networks** each get their own namespace (`cs-net-<networkId>`).
* The two scripts are intentionally decoupled: you can replace either script
  with a custom implementation (Python, Go, etc.) as long as the interface
  contract (arguments and exit codes) is maintained.

---

## Directory contents

| File | Installed location | Purpose |
|------|--------------------|---------|
| `network-namespace.sh` | management server | SSH proxy — executed by `NetworkExtensionElement` |
| `network-namespace-wrapper.sh` | remote network device | Performs iptables / bridge operations |
| `README.md` | — | This documentation |

> **Source tree paths:**
> * `network-namespace.sh` → `extensions/network-namespace/network-namespace.sh`
> * `network-namespace-wrapper.sh` → `extensions/network-namespace/network-namespace-wrapper.sh`

---

## How it works

### Lifecycle of a CloudStack network operation

1. **CloudStack** decides that a network operation must be applied (e.g.
   `implement`, `addStaticNat`, `applyPortForwardingRules`).
2. **`NetworkExtensionElement`** (Java) resolves the extension that is registered
   on the physical network whose name matches the network's service provider.  It
   reads all device details stored in `extension_resource_map_details`.
3. `NetworkExtensionElement` builds a command line:
   ```
   <extension_path>/network-namespace.sh <command> --network-id <id> [--vlan V] [--gateway G] ...
       --physical-network-extension-details '<json>'
       --network-extension-details '<json>'
   ```
   Both JSON blobs are always appended as named CLI arguments:
   * `--physical-network-extension-details` — JSON object with all physical-network
     registration details (hosts, port, username, sshkey, …)
   * `--network-extension-details` — per-network JSON blob (selected host, namespace, …)
4. **`network-namespace.sh`** parses those CLI arguments, writes the SSH
   private key to a temporary file (if `sshkey` is set in the physical-network
   details), then SSHes to the remote host and runs the wrapper script with both
   JSON blobs forwarded as CLI arguments.
5. **`network-namespace-wrapper.sh`** parses the CLI arguments and executes the
   requested operation using `ip link`, `iptables`, `ip addr`, etc. inside the
   network namespace.
6. Exit code `0` = success; any non-zero exit causes CloudStack to treat the
   operation as failed.

### Authentication priority (network-namespace.sh)

1. `sshkey` field in `--physical-network-extension-details` — PEM key written
   to a temp file, used with `ssh -i`.  **Preferred** — the temp file is deleted
   on exit.
2. `password` field — passed to `sshpass(1)` if available.
3. Neither set — relies on the SSH agent or host key on the management server.

---

## Installation

### Management server

During package installation the `network-namespace.sh` script is deployed to:

```
/usr/share/cloudstack-management/extensions/<extension-name>/<extension-name>.sh
```

The extension path is set to `network-namespace` at creation time;
`NetworkExtensionElement` looks for `<extensionName>.sh` inside the directory.
In **developer mode** the extensions directory defaults to `extensions/` relative
to the repo root, so `extensions/network-namespace/network-namespace.sh` is
found automatically.

### Remote network device

Copy `network-namespace-wrapper.sh` to **each** remote device that will act as the
network gateway, inside a subdirectory named after the extension:

```bash
# From the CloudStack source tree:
DEVICE=root@<kvm-host>
EXT_NAME=network-namespace        # must match the extension name in CloudStack

ssh ${DEVICE} "mkdir -p /etc/cloudstack/extensions/${EXT_NAME}"
scp extensions/network-namespace/network-namespace-wrapper.sh \
    ${DEVICE}:/etc/cloudstack/extensions/${EXT_NAME}/${EXT_NAME}-wrapper.sh
ssh ${DEVICE} "chmod +x /etc/cloudstack/extensions/${EXT_NAME}/${EXT_NAME}-wrapper.sh"
```

The wrapper derives its state directory and log path from the directory it is
installed in:

* **State:** `/var/lib/cloudstack/<ext-name>/`
  (e.g. `/var/lib/cloudstack/network-namespace/`)
* **Log (wrapper):** `/var/log/cloudstack/extensions/<ext-name>/<ext-name>.log`
  (e.g. `/var/log/cloudstack/extensions/network-namespace/network-namespace.log`)
* **Log (proxy, on management server):** `/var/log/cloudstack/extensions/<ext-name>.log`

**Prerequisites on the remote device:**

| Package / tool | Purpose |
|----------------|---------|
| `iproute2` (`ip`, `ip netns`) | Namespace, bridge, veth, route management |
| `iptables` + `iptables-save` | NAT and filter rules inside namespace |
| `arping` | Gratuitous ARP after public IP assignment |
| `dnsmasq` | DHCP and DNS service inside namespace |
| `haproxy` | Load balancing inside namespace |
| `apache2` (Debian/Ubuntu) or `httpd` (RHEL/CentOS) | Metadata / user-data HTTP service (port 80) |
| `python3` | DHCP options parsing, haproxy config generation, vm-data processing |
| `util-linux` (`flock`) | Serialise concurrent operations per network |
| `sshd` | Reachable from the management server on the configured port (default 22) |

The SSH user must have permission to run `ip`, `iptables`, `iptables-save`,
and `ip netns exec` (root or passwordless `sudo` for those commands).

---

## Step-by-step API setup

All examples below use `cmk` (the CloudStack CLI).  Replace `<zone-uuid>`,
`<phys-net-uuid>`, etc. with real values from your environment.

### 1. Create the extension

```bash
cmk createExtension \
    name=my-extnet \
    type=NetworkOrchestrator \
    path=network-namespace \
    "details[0].key=network.services" \
    "details[0].value=SourceNat,StaticNat,PortForwarding,Firewall,Gateway" \
    "details[1].key=network.service.capabilities" \
    "details[1].value={\"SourceNat\":{\"SupportedSourceNatTypes\":\"peraccount\",\"RedundantRouter\":\"false\"},\"Firewall\":{\"TrafficStatistics\":\"per public ip\"}}"
```

The two details declare which services this extension provides and their
CloudStack capability values.  These are consulted when listing network service
providers and when validating network offerings.

**`network.services`** — comma-separated list of service names:
```
SourceNat,StaticNat,PortForwarding,Firewall,Gateway
```
Valid service names include: `Vpn`, `Dhcp`, `Dns`, `SourceNat`,
`PortForwarding`, `Lb`, `UserData`, `StaticNat`, `NetworkACL`, `Firewall`,
`Gateway`, `SecurityGroup`.

**`network.service.capabilities`** — JSON object mapping each service to its
CloudStack `Capability` key/value pairs:
```json
{
  "SourceNat": {
    "SupportedSourceNatTypes": "peraccount",
    "RedundantRouter": "false"
  },
  "Firewall": {
    "TrafficStatistics": "per public ip"
  }
}
```

Services listed in `network.services` that have no entry in
`network.service.capabilities` (e.g. `StaticNat`, `PortForwarding`,
`Gateway`) are still offered — CloudStack treats missing capability values as
"no constraint" and accepts any value when creating the network offering.

If you omit both details entirely, the extension defaults to an empty set of
services and no capabilities.

> **Backward compatibility:** the old combined `network.capabilities` JSON
> key (with a `"services"` array and `"capabilities"` object in one blob) is
> still accepted but deprecated.  Prefer the split keys above.

Verify the extension was created and its state is `Enabled`:
```bash
cmk listExtensions name=my-extnet
```

To enable or disable the extension:
```bash
cmk updateExtension id=<ext-uuid> state=Enabled
cmk updateExtension id=<ext-uuid> state=Disabled
```

### 2. Register the extension with a physical network

```bash
cmk registerExtension \
    id=<extension-uuid> \
    resourcetype=PhysicalNetwork \
    resourceid=<phys-net-uuid>
```

This creates a **Network Service Provider** (NSP) entry named `my-extnet` on the
physical network and enables it automatically.  The NSP name is the **extension
name** — not the generic string `NetworkExtension`.

After registering, set the connection details for the remote KVM device(s):

```bash
cmk updateRegisteredExtension \
    extensionid=<extension-uuid> \
    resourcetype=PhysicalNetwork \
    resourceid=<phys-net-uuid> \
    "details[0].key=hosts"                 "details[0].value=192.168.10.1,192.168.10.2" \
    "details[1].key=username"              "details[1].value=root" \
    "details[2].key=sshkey"                "details[2].value=<pem-key-contents>" \
    "details[3].key=guest.network.device"  "details[3].value=eth1" \
    "details[4].key=public.network.device" "details[4].value=eth1"
```

The `hosts` value is a comma-separated list of KVM host IPs; `ensure-network-device`
picks one per network and stores it in `--network-extension-details`.  Use `sshkey`
(PEM private key) for passwordless authentication, or `password` + `sshpass`.

Verify:
```bash
cmk listNetworkServiceProviders physicalnetworkid=<phys-net-uuid>
# → a provider named "my-extnet" should appear in state Enabled
```

To disable or re-enable the NSP:
```bash
cmk updateNetworkServiceProvider id=<nsp-uuid> state=Disabled
cmk updateNetworkServiceProvider id=<nsp-uuid> state=Enabled
```

To unregister:
```bash
cmk unregisterExtension \
    id=<extension-uuid> \
    resourcetype=PhysicalNetwork \
    resourceid=<phys-net-uuid>
```

### 3. Create a network offering

Use the **extension name** (`my-extnet`) as the service provider — not the
generic string `NetworkExtension`:

```bash
cmk createNetworkOffering \
    name="My ExtNet Offering" \
    displaytext="Isolated network via my-extnet" \
    guestiptype=Isolated \
    traffictype=GUEST \
    supportedservices="SourceNat,StaticNat,PortForwarding,Firewall,Gateway" \
    "serviceProviderList[0].service=SourceNat"      "serviceProviderList[0].provider=my-extnet" \
    "serviceProviderList[1].service=StaticNat"      "serviceProviderList[1].provider=my-extnet" \
    "serviceProviderList[2].service=PortForwarding" "serviceProviderList[2].provider=my-extnet" \
    "serviceProviderList[3].service=Firewall"       "serviceProviderList[3].provider=my-extnet" \
    "serviceProviderList[4].service=Gateway"        "serviceProviderList[4].provider=my-extnet" \
    "serviceCapabilityList[0].service=SourceNat" \
    "serviceCapabilityList[0].capabilitytype=SupportedSourceNatTypes" \
    "serviceCapabilityList[0].capabilityvalue=peraccount"
```

Enable the offering:
```bash
cmk updateNetworkOffering id=<offering-uuid> state=Enabled
```

> The `serviceCapabilityList` entries must match the values declared in the
> extension's `network.service.capabilities` detail.  If the extension's JSON does
> not declare a capability value for a service, CloudStack accepts any value (or no
> value) without error.

### 4. Create an isolated network

```bash
cmk createNetwork \
    name=my-network \
    displaytext="My isolated network" \
    networkofferingid=<offering-uuid> \
    zoneid=<zone-uuid>
```

When a VM is first deployed into this network, CloudStack calls
`NetworkExtensionElement.implement()`, which triggers the `implement` command:

```bash
# Management server executes:
network-namespace.sh implement \
    --network-id 42 \
    --vlan 100 \
    --gateway 10.0.1.1 \
    --cidr 10.0.1.0/24

# network-namespace.sh SSHes to the host and runs inside the host:
network-namespace-wrapper.sh implement \
    --network-id 42 \
    --vlan 100 \
    --gateway 10.0.1.1 \
    --cidr 10.0.1.0/24
```

The wrapper creates a VLAN sub-interface and Linux bridge, a guest veth pair
(`vh-100-2a`/`vn-100-2a`), assigns the gateway IP to the namespace veth,
enables IP forwarding inside the namespace, and creates per-network iptables
chains: `CS_EXTNET_42_PR` (nat PREROUTING), `CS_EXTNET_42_POST` (nat
POSTROUTING), and `CS_EXTNET_FWD_42` (filter FORWARD).

### 5. Acquire a public IP and enable Source NAT

```bash
cmk associateIpAddress networkid=<network-uuid>
```

CloudStack calls `applyIps()` which issues `assign-ip` with `--source-nat true`
for the source-NAT IP:

```bash
network-namespace.sh assign-ip \
    --network-id 42 \
    --vlan 100 \
    --public-ip 203.0.113.10 \
    --source-nat true \
    --gateway 10.0.1.1 \
    --cidr 10.0.1.0/24
```

The wrapper:
1. Creates public VLAN sub-interface `eth1.<pvlan>` and bridge `breth1-<pvlan>` on the host.
2. Creates veth pair `vph-<pvlan>-42` (host, in bridge) / `vpn-<pvlan>-42` (namespace).
3. Assigns `203.0.113.10/32` to `vpn-<pvlan>-42` **inside the namespace**.
4. Adds host route `203.0.113.10/32 dev vph-<pvlan>-42` so the host can reach it.
5. Adds an iptables SNAT rule in `CS_EXTNET_42_POST`: traffic from `10.0.1.0/24`
   out `vpn-<pvlan>-42` → source `203.0.113.10`.
6. Adds an iptables FORWARD ACCEPT rule in `CS_EXTNET_FWD_42` for the guest CIDR.
7. If `--public-gateway` is set, adds/replaces the namespace default route via
   `vpn-<pvlan>-42`.

When the IP is released (via `disassociateIpAddress`), `release-ip` is called,
which removes all associated rules and the IP address.

### 6. Enable / disable Static NAT

```bash
# Enable static NAT: map public IP 203.0.113.20 to VM private IP 10.0.1.5
cmk enableStaticNat \
    ipaddressid=<public-ip-uuid> \
    virtualmachineid=<vm-uuid> \
    networkid=<network-uuid>
```

CloudStack calls `applyStaticNats()` → `add-static-nat`:

```bash
network-namespace.sh add-static-nat \
    --network-id 42 \
    --vlan 100 \
    --public-ip 203.0.113.20 \
    --private-ip 10.0.1.5
```

iptables rules added (all run inside the namespace via `ip netns exec`):
```bash
# DNAT inbound  (CS_EXTNET_42_PR = nat PREROUTING chain)
iptables -t nat -A CS_EXTNET_42_PR -d 203.0.113.20 -j DNAT --to-destination 10.0.1.5
# SNAT outbound  (CS_EXTNET_42_POST = nat POSTROUTING chain)
iptables -t nat -A CS_EXTNET_42_POST -s 10.0.1.5 -o vpn-<pvlan>-42 -j SNAT --to-source 203.0.113.20
# FORWARD inbound + outbound  (CS_EXTNET_FWD_42 = filter FORWARD chain)
iptables -t filter -A CS_EXTNET_FWD_42 -d 10.0.1.5 -o vn-100-2a -j ACCEPT
iptables -t filter -A CS_EXTNET_FWD_42 -s 10.0.1.5 -i vn-100-2a -j ACCEPT
```

```bash
# Disable static NAT
cmk disableStaticNat ipaddressid=<public-ip-uuid>
```

CloudStack calls `delete-static-nat`, which removes all four rules above.

### 7. Add / delete Port Forwarding

```bash
# Forward TCP port 2222 on public IP 203.0.113.20 → VM port 22
cmk createPortForwardingRule \
    ipaddressid=<public-ip-uuid> \
    privateport=22 \
    publicport=2222 \
    protocol=TCP \
    virtualmachineid=<vm-uuid> \
    networkid=<network-uuid>
```

CloudStack calls `applyPFRules()` → `add-port-forward`:

```bash
network-namespace.sh add-port-forward \
    --network-id 42 \
    --vlan 100 \
    --public-ip 203.0.113.20 \
    --public-port 2222 \
    --private-ip 10.0.1.5 \
    --private-port 22 \
    --protocol TCP
```

iptables rules added (inside the namespace):
```bash
# DNAT inbound  (CS_EXTNET_42_PR = nat PREROUTING chain)
iptables -t nat -A CS_EXTNET_42_PR -p tcp -d 203.0.113.20 --dport 2222 \
    -j DNAT --to-destination 10.0.1.5:22
# FORWARD  (CS_EXTNET_FWD_42 = filter FORWARD chain)
iptables -t filter -A CS_EXTNET_FWD_42 -p tcp -d 10.0.1.5 --dport 22 \
    -o vn-100-2a -j ACCEPT
```

Port ranges (e.g. `80:90`) are supported and passed verbatim to iptables `--dport`.

```bash
# Delete the rule
cmk deletePortForwardingRule id=<rule-uuid>
```

This calls `delete-port-forward` which removes the DNAT and FORWARD rules.

### 8. Delete the network

```bash
cmk deleteNetwork id=<network-uuid>
```

CloudStack calls `shutdown()` (to clean up active state) then `destroy()` (full
removal).  Both commands perform identical cleanup:

```bash
network-namespace.sh shutdown --network-id 42 --vlan 100
network-namespace.sh destroy  --network-id 42 --vlan 100
```

The wrapper:
1. Removes jump rules from PREROUTING, POSTROUTING, and FORWARD.
2. Flushes and deletes iptables chains `CS_EXTNET_42_PR`, `CS_EXTNET_42_POST`,
   `CS_EXTNET_FWD_42`, and any `CS_EXTNET_FWRULES_42` / `CS_EXTNET_FWI_*` chains.
3. Deletes public veth pairs (`vph-<pvlan>-42` / `vpn-<pvlan>-42`) that were
   created during `assign-ip` (read from state files).
4. On `destroy`: also deletes the guest veth host-side (`vh-100-2a`) and removes
   the namespace `cs-net-42` entirely.
5. Removes all state under `/var/lib/cloudstack/<ext-name>/network-42/`.

> The host bridge `breth1-100` and VLAN sub-interface `eth1.100` are **not**
> removed — they may still be used by other networks or for VM connectivity.

### 9. Unregister and delete the extension

```bash
# Disable and delete the NSP
cmk updateNetworkServiceProvider id=<nsp-uuid> state=Disabled
cmk deleteNetworkServiceProvider id=<nsp-uuid>

# Remove external network device credentials (if any)
# Device credentials are stored as extension_resource_map_details for the
# extension registration. Remove or update them via `updateRegisteredExtension`
# (set cleanupdetails=true to wipe all details) or by supplying new details.
# Example: clear all registration details for a physical network:
cmk updateRegisteredExtension \
    extensionid=<extension-uuid> \
    resourcetype=PhysicalNetwork \
    resourceid=<phys-net-uuid> \
    cleanupdetails=true

# Unregister the extension from the physical network
cmk unregisterExtension \
    id=<extension-uuid> \
    resourcetype=PhysicalNetwork \
    resourceid=<phys-net-uuid>

# Delete the extension
# (only possible once it is unregistered from all physical networks)
cmk deleteExtension id=<extension-uuid>
```

---

## Multiple extensions on the same physical network

Because each extension is registered as its own NSP (named after the extension),
multiple independent external network providers can coexist on the same physical
network:

```bash
# Register two extensions, each backed by a different device
cmk registerExtension id=<ext-a-uuid> resourcetype=PhysicalNetwork resourceid=<pn-uuid>
cmk registerExtension id=<ext-b-uuid> resourcetype=PhysicalNetwork resourceid=<pn-uuid>

# Store device connection details as registration details for each extension.
# Details are stored in extension_resource_map_details for the registration.
# Example: set hosts and guest/public network devices for ext-a on the physical network:
cmk updateRegisteredExtension \
    extensionid=<ext-a-uuid> \
    resourcetype=PhysicalNetwork \
    resourceid=<pn-uuid> \
    "details[0].key=hosts"                 "details[0].value=10.0.0.1,10.0.0.2" \
    "details[1].key=guest.network.device"  "details[1].value=eth1" \
    "details[2].key=public.network.device" "details[2].value=eth1"
```

When creating network offerings, reference the specific extension name:

```bash
# Network offering backed by ext-a-name
cmk createNetworkOffering ... \
    "serviceProviderList[0].provider=ext-a-name" ...

# Network offering backed by ext-b-name
cmk createNetworkOffering ... \
    "serviceProviderList[0].provider=ext-b-name" ...
```

CloudStack resolves which extension to call by:
1. Looking up the service provider name stored in `ntwk_service_map` for the
   guest network.
2. Finding the registered extension on the physical network whose name matches
   that provider name.
3. Calling `NetworkExtensionElement` scoped to that specific provider/extension
   (via `NetworkExtensionElement.withProviderName()`).

---

## Wrapper script operations reference

The `network-namespace-wrapper.sh` script runs on the remote KVM device.
It receives the command as its first positional argument followed by named
`--option value` pairs.

All commands:
* Write timestamped entries to `/var/log/cloudstack/extensions/<ext-name>/<ext-name>.log`.
* Use a per-network flock file (`${STATE_DIR}/lock-network-<id>`) — or
  `lock-vpc-<id>` for VPC networks — to serialise concurrent operations.
* Persist state under `/var/lib/cloudstack/<ext-name>/network-<network-id>/`
  (or `vpc-<vpc-id>/` for VPC-wide shared state such as public IPs).

### `implement`

Called when CloudStack activates the network (typically on first VM deploy).

```
network-namespace-wrapper.sh implement \
    --network-id <id> \
    --vlan <vlan-id>       \
    --gateway <gateway-ip> \
    --cidr <cidr>          \
    [--vpc-id <vpc-id>]
```

Actions:
1. Create namespace `cs-vpc-<vpc-id>` (VPC) or `cs-net-<network-id>` (isolated).
2. Resolve `GUEST_ETH` from `guest.network.device` in `--physical-network-extension-details`
   (defaults to `eth1` when absent).
3. Create VLAN sub-interface `GUEST_ETH.<vlan>` on the host.
4. Create host bridge `br<GUEST_ETH>-<vlan>` and attach `GUEST_ETH.<vlan>` to it.
5. Create veth pair `vh-<vlan>-<id>` (host, in bridge) / `vn-<vlan>-<id>` (namespace).
6. Assign `<gateway>/<prefix>` to `vn-<vlan>-<id>` inside the namespace.
7. Enable IP forwarding inside the namespace.
8. Create iptables chains `CS_EXTNET_<id>_PR` (nat PREROUTING DNAT),
   `CS_EXTNET_<id>_POST` (nat POSTROUTING SNAT), and `CS_EXTNET_FWD_<id>` (filter FORWARD).
9. Save VLAN, gateway, CIDR, namespace, and network-id / vpc-id to state files.

### `shutdown`

Called when a network is shut down (may be restarted later).

```
network-namespace-wrapper.sh shutdown \
    --network-id <id> [--vlan <vlan-id>] [--vpc-id <vpc-id>]
```

Actions:
1. Stop dnsmasq, haproxy, apache2, and password-server processes running inside
   the namespace (if any).
2. Flush and remove iptables chains (PREROUTING, POSTROUTING, FORWARD jumps +
   chain contents), including `CS_EXTNET_FWRULES_<id>` and all `CS_EXTNET_FWI_*`
   ingress chains.
3. Delete public veth pairs (`vph-<pvlan>-<id>` / `vpn-<pvlan>-<id>`) that were
   created during `assign-ip` (read from state).
4. Keep namespace and guest veth (`vh-<vlan>-<id>` / `vn-<vlan>-<id>`) intact —
   guest VMs can still connect to `br<GUEST_ETH>-<vlan>`.

### `destroy`

Called when the network is permanently removed.

```
network-namespace-wrapper.sh destroy \
    --network-id <id> [--vlan <vlan-id>] [--vpc-id <vpc-id>]
```

Actions (superset of shutdown):
1. Delete guest veth host-side (`vh-<vlan>-<id>`).
2. Delete public veth pairs (`vph-<pvlan>-<id>` / `vpn-<pvlan>-<id>`).
3. Delete the namespace (removes all interfaces inside it).
4. Remove per-network state directory `network-<id>/`.

> The host bridge `br<GUEST_ETH>-<vlan>` and VLAN sub-interface `GUEST_ETH.<vlan>`
> are NOT removed on destroy — they may still be used by other networks or for
> VM connectivity.

### VPC lifecycle commands: `implement-vpc`, `shutdown-vpc`, `destroy-vpc`

These commands manage VPC-level state. Called by `NetworkExtensionElement` when
implementing, shutting down, or destroying a VPC (before or after per-tier
network operations).

#### `implement-vpc`

```
network-namespace-wrapper.sh implement-vpc \
    --vpc-id <vpc-id> \
    --cidr <vpc-cidr>
```

Actions:
1. Create the shared VPC namespace `cs-vpc-<vpc-id>`.
2. Enable IP forwarding inside the namespace.
3. Create iptables chains for NAT and filter rules.
4. Save VPC metadata (CIDR, gateway) to state files under `/var/lib/cloudstack/<ext-name>/vpc-<vpc-id>/`.

> This command runs **before** any tier networks are implemented. Tier networks
> inherit the same namespace and host assignment.

#### `shutdown-vpc`

```
network-namespace-wrapper.sh shutdown-vpc \
    --vpc-id <vpc-id>
```

Actions:
1. Flush all iptables rules (ingress, egress, NAT chains inside the namespace).
2. Stop all services (dnsmasq, haproxy, apache2, password-server) for all tiers.
3. Keep the namespace and tier veths intact (tiers may restart).

> Called when the VPC is shut down; tier networks may be restarted later.

#### `destroy-vpc`

```
network-namespace-wrapper.sh destroy-vpc \
    --vpc-id <vpc-id>
```

Actions:
1. Remove the entire namespace `cs-vpc-<vpc-id>` (deletes all interfaces inside).
2. Remove VPC-wide state directory `/var/lib/cloudstack/<ext-name>/vpc-<vpc-id>/`.

> This is the final cleanup step; after this, the VPC namespace is gone.

### `assign-ip`

Called when a public IP is associated with the network (including source NAT).

```
network-namespace-wrapper.sh assign-ip \
    --network-id <id>          \
    --vlan <guest-vlan>        \
    --public-ip <ip>           \
    --source-nat true|false    \
    --gateway <guest-gw>       \
    --cidr <guest-cidr>        \
    --public-vlan <pvlan>      \
    [--public-gateway <pub-gw>] \
    [--public-cidr <pub-cidr>]  \
    [--vpc-id <vpc-id>]
```

Actions:
1. Resolve `PUB_ETH` from `public.network.device` in `--physical-network-extension-details`
   (defaults to `eth1` when absent).
2. Create VLAN sub-interface `PUB_ETH.<pvlan>` and bridge `br<PUB_ETH>-<pvlan>` on the host.
3. Create veth pair `vph-<pvlan>-<id>` (host) / `vpn-<pvlan>-<id>` (namespace).
   Attach host end to `br<PUB_ETH>-<pvlan>`.
4. Assign `<public-ip>/32` (or `/<prefix>` if `--public-cidr` given) to
   `vpn-<pvlan>-<id>` inside the namespace.
5. Add host route `<public-ip>/32 dev vph-<pvlan>-<id>` so the host can reach it.
6. If `--public-gateway` is given, set/replace namespace default route via
   `vpn-<pvlan>-<id>`.
7. If `--source-nat true`:
   * SNAT rule: `<guest-cidr>` out `vpn-<pvlan>-<id>` → `<public-ip>`
     (POSTROUTING chain `CS_EXTNET_<id>_POST`).
   * FORWARD ACCEPT for `<guest-cidr>` towards `vpn-<pvlan>-<id>`.
8. Save public VLAN to state file `ips/<public-ip>.pvlan` (used by `add-static-nat`,
   `add-port-forward`, `release-ip`).

### `release-ip`

Called when a public IP is released / disassociated from the namespace.

```
network-namespace-wrapper.sh release-ip \
    --network-id <id>    \
    --public-ip <ip>     \
    [--public-vlan <pvlan>]   \
    [--public-cidr <pub-cidr>] \
    [--vpc-id <id>]
```

Actions:
1. Load `public_vlan` from `ips/<public-ip>.pvlan` state file.
2. Remove SNAT rule for guest CIDR → `<public-ip>`.
3. Remove any DNAT rules targeting `<public-ip>` from PREROUTING chain.
4. Remove host route `<public-ip>/32`.
5. Remove IP address from `vpn-<pvlan>-<id>` inside namespace.
6. If no other IPs share the same `<pvlan>/<id>` combination, delete
   `vph-<pvlan>-<id>` (host veth).
7. Remove state files.

### `add-static-nat`

Called when Static NAT (one-to-one NAT) is enabled for a public IP.

```
network-namespace-wrapper.sh add-static-nat \
    --network-id <id>          \
    --vlan <guest-vlan>        \
    --public-ip <public-ip>    \
    --private-ip <private-ip>  \
    [--vpc-id <vpc-id>]
```

The `public_vlan` for this IP is loaded from `ips/<public-ip>.pvlan` state
(written during `assign-ip`).

iptables rules added (chains `CS_EXTNET_<id>_PR` / `_POST` / `FWD_<id>`):

| Table | Chain | Rule |
|-------|-------|------|
| `nat` | `CS_EXTNET_<id>_PR`   | `-d <public-ip> -j DNAT --to-destination <private-ip>` |
| `nat` | `CS_EXTNET_<id>_POST` | `-s <private-ip> -o vpn-<pvlan>-<id> -j SNAT --to-source <public-ip>` |
| `filter` | `CS_EXTNET_FWD_<id>` | `-d <private-ip> -o vn-<vlan>-<id> -j ACCEPT` |
| `filter` | `CS_EXTNET_FWD_<id>` | `-s <private-ip> -i vn-<vlan>-<id> -j ACCEPT` |

State saved to `${STATE_DIR}/network-<id>/static-nat/<public-ip>`.

### `delete-static-nat`

```
network-namespace-wrapper.sh delete-static-nat \
    --network-id <id> \
    --public-ip <public-ip> \
    [--private-ip <private-ip>]
```

Removes all four rules added by `add-static-nat`.  If `--private-ip` is omitted,
it is read from the state file.

### `add-port-forward`

Called when a Port Forwarding rule is added.

```
network-namespace-wrapper.sh add-port-forward \
    --network-id <id> \
    --vlan <vlan-id> \
    --public-ip <public-ip> \
    --public-port <port-or-range> \
    --private-ip <private-ip> \
    --private-port <port-or-range> \
    --protocol tcp|udp
```

iptables rules added (inside the namespace):

| Table | Chain | Rule |
|-------|-------|------|
| `nat` | `CS_EXTNET_<id>_PR` | `-p <proto> -d <public-ip> --dport <public-port> -j DNAT --to-destination <private-ip>:<private-port>` |
| `filter` | `CS_EXTNET_FWD_<id>` | `-p <proto> -d <private-ip> --dport <private-port> -o vn-<vlan>-<id> -j ACCEPT` |

Port ranges (`80:90`) are passed verbatim to iptables `--dport`.

State saved to
`${STATE_DIR}/network-<id>/port-forward/<proto>_<public-ip>_<public-port>`.

### `delete-port-forward`

```
network-namespace-wrapper.sh delete-port-forward \
    --network-id <id> \
    --public-ip <public-ip> \
    --public-port <port-or-range> \
    --private-ip <private-ip> \
    --private-port <port-or-range> \
    --protocol tcp|udp
```

Removes the DNAT and FORWARD rules added by `add-port-forward`.

### `apply-fw-rules`

Called when CloudStack applies or removes firewall rules for the network.

```
network-namespace-wrapper.sh apply-fw-rules \
    --network-id <id> \
    --vlan <vlan-id> \
    --fw-rules <base64-json> \
    [--vpc-id <vpc-id>]
```

The `--fw-rules` value is a Base64-encoded JSON object:
```json
{
  "default_egress_allow": true,
  "cidr": "10.0.1.0/24",
  "rules": [
    {
      "type": "ingress",
      "protocol": "tcp",
      "portStart": 22,
      "portEnd": 22,
      "publicIp": "203.0.113.10",
      "sourceCidrs": ["0.0.0.0/0"]
    },
    {
      "type": "egress",
      "protocol": "all",
      "sourceCidrs": ["0.0.0.0/0"]
    }
  ]
}
```

iptables design (two independent parts, both inside the namespace):

* **Ingress** (mangle PREROUTING, per public IP):
  Per-public-IP chains `CS_EXTNET_FWI_<pubIp>` check traffic *before* DNAT so
  the match is against the real public destination IP.  Traffic not matched by
  explicit ALLOW rules is dropped.

* **Egress** (filter FORWARD, chain `CS_EXTNET_FWRULES_<networkId>`):
  Inserted at position 1 of `CS_EXTNET_FWD_<networkId>`.  Applies the
  `default_egress_allow` policy (allow-by-default or deny-by-default) to VM
  outbound traffic on `-i vn-<vlan>-<id>`.

### `apply-network-acl`

Apply Network ACL (Access Control List) rules for VPC networks.

```
network-namespace-wrapper.sh apply-network-acl \
    --network-id <id> \
    --vlan <vlan-id> \
    --acl-rules <base64-json> \
    [--vpc-id <vpc-id>]
```

The `--acl-rules` value is a Base64-encoded JSON array of ACL rule objects:
```json
[
  {
    "id": 1,
    "number": 100,
    "trafficType": "Ingress",
    "action": "Allow",
    "protocol": "tcp",
    "portStart": 80,
    "portEnd": 80,
    "sourceCidrs": ["0.0.0.0/0"]
  },
  {
    "id": 2,
    "number": 200,
    "trafficType": "Egress",
    "action": "Allow",
    "protocol": "all",
    "destCidrs": ["0.0.0.0/0"]
  }
]
```

iptables design:

* **Ingress rules** (filter FORWARD, chain `CS_EXTNET_ACL_IN_<networkId>`):
  Matches `-i vn-<vlan>-<id>` (traffic entering the VM namespace),
  ordered by rule number.  Actions: ACCEPT or DROP.

* **Egress rules** (filter FORWARD, chain `CS_EXTNET_ACL_OUT_<networkId>`):
  Matches `-o vn-<vlan>-<id>` (traffic leaving the VM namespace),
  ordered by rule number.  Actions: ACCEPT or DROP.

Both chains are inserted at position 1 of `CS_EXTNET_FWD_<networkId>` so ACL rules
take precedence over the catch-all ACCEPT rules.

### `config-dhcp-subnet` / `remove-dhcp-subnet`

Configure or tear down dnsmasq DHCP service for the network inside the namespace.

**`config-dhcp-subnet` arguments:**
```
network-namespace-wrapper.sh config-dhcp-subnet \
    --network-id <id>      \
    --gateway <gw>         \
    --cidr <cidr>          \
    [--dns <dns-server>]   \
    [--domain <domain>]    \
    [--vpc-id <vpc-id>]
```

Actions: writes a dnsmasq configuration file under
`${STATE_DIR}/network-<id>/dnsmasq/` and starts or reloads the dnsmasq process
inside the namespace.  DNS on port 53 is **disabled** by `config-dhcp-subnet`
(use `config-dns-subnet` to enable it).

**`remove-dhcp-subnet` arguments:**
```
network-namespace-wrapper.sh remove-dhcp-subnet --network-id <id>
```

Actions: stops dnsmasq and removes the dnsmasq configuration directory.

### `add-dhcp-entry` / `remove-dhcp-entry`

Add or remove a static DHCP host reservation (MAC → IP mapping) from dnsmasq.

```
network-namespace-wrapper.sh add-dhcp-entry \
    --network-id <id>    \
    --mac <mac>          \
    --ip <vm-ip>         \
    [--hostname <name>]  \
    [--default-nic true|false]
```

When `--default-nic false`, the DHCP option 3 (default gateway) is suppressed
for that MAC so the VM does not get a competing default route via a secondary NIC.

```
network-namespace-wrapper.sh remove-dhcp-entry \
    --network-id <id> \
    --mac <mac>
```

### `set-dhcp-options`

Set extra DHCP options for a specific NIC (identified by `--nic-id`) using a
JSON map of option-code → value pairs.

```
network-namespace-wrapper.sh set-dhcp-options \
    --network-id <id>           \
    --nic-id <nic-id>           \
    --options '{"119":"example.com"}'
```

### `config-dns-subnet` / `remove-dns-subnet`

Enable or disable DNS (port 53) in the dnsmasq instance.

```
network-namespace-wrapper.sh config-dns-subnet \
    --network-id <id>    \
    --gateway <gw>       \
    --cidr <cidr>        \
    [--extension-ip <ip>] \
    [--domain <domain>]  \
    [--vpc-id <vpc-id>]
```

Actions: like `config-dhcp-subnet` but enables DNS on port 53.  Also registers a
`data-server` hostname entry (using `--extension-ip` if provided, otherwise
`--gateway`) for metadata service discovery.

```
network-namespace-wrapper.sh remove-dns-subnet --network-id <id>
```

Actions: disables DNS (rewrites config to disable port 53) but keeps DHCP running.

### `add-dns-entry` / `remove-dns-entry`

Add or remove a hostname → IP mapping in the dnsmasq hosts file.

```
network-namespace-wrapper.sh add-dns-entry \
    --network-id <id>   \
    --ip <vm-ip>        \
    --hostname <name>

network-namespace-wrapper.sh remove-dns-entry \
    --network-id <id> \
    --ip <vm-ip>
```

### `save-vm-data`

Write the full VM metadata/userdata/password set for a VM in a single call.
Called on network restart and VM deploy.

```
network-namespace-wrapper.sh save-vm-data \
    --network-id <id>  \
    --ip <vm-ip>       \
    --vm-data <base64-json>
```

The `--vm-data` value is a Base64-encoded JSON array of `{dir, file, content}`
entries (same format as `generateVmData()` in the Java layer).  Writes files
under `${STATE_DIR}/network-<id>/metadata/<vm-ip>/latest/`.  After writing,
starts or reloads both the **apache2 metadata HTTP service** (port 80) and the
**VR-compatible password server** (port 8080) inside the namespace.

### `save-userdata` / `save-password` / `save-sshkey` / `save-hypervisor-hostname`

Granular variants that write individual VM metadata fields:

```
network-namespace-wrapper.sh save-userdata       --network-id <id> --ip <vm-ip> --userdata <base64>
network-namespace-wrapper.sh save-password       --network-id <id> --ip <vm-ip> --password <plain>
network-namespace-wrapper.sh save-sshkey         --network-id <id> --ip <vm-ip> --sshkey <base64>
network-namespace-wrapper.sh save-hypervisor-hostname \
    --network-id <id> --ip <vm-ip> --hypervisor-hostname <name>
```

Each command writes the relevant file and restarts/reloads apache2 (and
the password server, for `save-password`).

### `apply-lb-rules`

Apply or revoke load-balancing rules via haproxy inside the namespace.

```
network-namespace-wrapper.sh apply-lb-rules \
    --network-id <id>        \
    --lb-rules <json-array>  \
    [--vpc-id <vpc-id>]
```

`--lb-rules` is a JSON array of LB rule objects.  Set `"revoke": true` on a
rule to remove it.  The wrapper regenerates the haproxy configuration from the
persistent per-rule JSON files under `${STATE_DIR}/network-<id>/haproxy/` and
reloads haproxy inside the namespace.  haproxy is stopped when no active rules
remain.

### `restore-network`

Batch-restore DHCP/DNS/metadata/services for all VMs on a network in a single
call.  Invoked on network restart to rebuild all state at once instead of N
per-VM calls.

```
network-namespace-wrapper.sh restore-network \
    --network-id <id>          \
    --restore-data <base64-json> \
    [--gateway <gw>] [--cidr <cidr>] [--dns <dns>] \
    [--domain <dom>] [--extension-ip <ip>] [--vpc-id <vpc-id>]
```

### `custom-action`

```
network-namespace-wrapper.sh custom-action \
    --network-id <id> \
    --action <action-name>
```

Built-in actions:

| Action | Description |
|--------|-------------|
| `reboot-device` | Bounces the guest veth pair (`vh-<vlan>-<id>` down → up) |
| `dump-config` | Prints namespace IP addresses, iptables rules, and per-network state to stdout |
| `pbr-create-table` | Create or update a routing-table entry in `/etc/iproute2/rt_tables` |
| `pbr-delete-table` | Remove a routing-table entry from `/etc/iproute2/rt_tables` |
| `pbr-list-tables` | List non-comment routing-table entries from `/etc/iproute2/rt_tables` |
| `pbr-add-route` | Add/replace an `ip route` entry in a specific routing table inside the namespace |
| `pbr-delete-route` | Delete an `ip route` entry from a specific routing table inside the namespace |
| `pbr-list-routes` | List routes from one table (or all tables) inside the namespace |
| `pbr-add-rule` | Add an `ip rule` policy rule mapped to a specific routing table inside the namespace |
| `pbr-delete-rule` | Delete an `ip rule` policy rule mapped to a specific routing table inside the namespace |
| `pbr-list-rules` | List policy rules (or only rules for one table) inside the namespace |

PBR action parameter keys (`--action-params` JSON):

| Action | Required keys | Optional keys |
|--------|---------------|---------------|
| `pbr-create-table` | `table-id` (or `id`), `table-name` (or `table`) | — |
| `pbr-delete-table` | `table-id` or `table-name` | — |
| `pbr-list-tables` | — | — |
| `pbr-add-route` | `table`, `route` | — |
| `pbr-delete-route` | `table`, `route` | — |
| `pbr-list-routes` | — | `table` |
| `pbr-add-rule` | `table`, `rule` | — |
| `pbr-delete-rule` | `table`, `rule` | — |
| `pbr-list-rules` | — | `table` |

Examples (equivalent to direct Linux commands):

* `{"table-id":"100","table-name":"isp1"}` → `100 isp1`
* `{"table":"isp1","route":"default via 192.168.1.1 dev eth0"}`
* `{"table":"vpn1","route":"default dev wg0"}`
* `{"table":"isp1","rule":"from 10.10.1.0/24"}`
* `{"table":"vpn1","rule":"to 10.10.2.0/24"}`

To add custom actions, place an executable script at
`${STATE_DIR}/hooks/custom-action-<name>.sh`
(e.g. `/var/lib/cloudstack/network-namespace/hooks/custom-action-<name>.sh`).
Unknown action names are delegated to the hook if present; otherwise the command
fails with a descriptive error.

---

## CLI argument reference

### JSON blobs always forwarded by `network-namespace.sh`

| CLI Argument | Description |
|--------------|-------------|
| `--physical-network-extension-details <json>` | All `extension_resource_map_details` **plus** physical network metadata automatically added by `NetworkExtensionElement` (see table below). |
| `--network-extension-details <json>` | Per-network opaque JSON blob (selected host, namespace). |

### Connection details (keys in `--physical-network-extension-details`)

These keys are explicitly set when calling `registerExtension`:

| JSON key | Description |
|----------|-------------|
| `hosts` | Comma-separated list of candidate host IPs for HA selection |
| `host` | Single host IP (used when `hosts` is absent) |
| `port` | SSH port — default: `22` |
| `username` | SSH user — default: `root` |
| `password` | SSH password via `sshpass` — sensitive, not logged |
| `sshkey` | PEM-encoded SSH private key — sensitive, not logged; preferred over password |
| `guest.network.device` | Host NIC for guest (internal) traffic, e.g. `eth1` — defaults to `eth1` when absent |
| `public.network.device` | Host NIC for public (NAT/external) traffic, e.g. `eth1` — defaults to `eth1` when absent |

This key is **automatically injected** by `NetworkExtensionElement` from the
physical network record:

| JSON key | Description |
|----------|-------------|
| `physicalnetworkname` | Physical network name from CloudStack DB |

The wrapper script uses `guest.network.device` (and `public.network.device`) to
name bridges as `br<eth>-<vlan>` and veth pairs as `vh-<vlan>-<id>` /
`vn-<vlan>-<id>` (guest) and `vph-<pvlan>-<id>` / `vpn-<pvlan>-<id>` (public).

### Per-network details (keys in `--network-extension-details`)

| JSON key | Description |
|----------|-------------|
| `host` | Previously selected host IP (set by `ensure-network-device`) |
| `namespace` | Linux network namespace name (e.g. `cs-net-<networkId>` or `cs-vpc-<vpcId>`) |

### Additional per-command arguments

| CLI Argument | Commands | Description |
|--------------|----------|-------------|
| `--vpc-id <id>` | all | Present when the network belongs to a VPC; namespace becomes `cs-vpc-<vpcId>` |
| `--public-vlan <pvlan>` | `assign-ip`, `release-ip` | Public IP's VLAN tag (e.g. `101`) |
| `--network-id <id>` | most | Network ID — CHOSEN_ID for veth names is `<vpc-id>` when VPC, else `<network-id>` |

### Action parameters (custom-action only)

Caller-supplied parameters from `runNetworkCustomAction` are passed as a JSON
object via the `--action-params` CLI argument:

```bash
network-namespace.sh custom-action \
    --network-id <id> \
    --action <name> \
    --action-params '{"key1":"value1","key2":"value2"}' \
    --physical-network-extension-details '<json>' \
    --network-extension-details '<json>'
```

`network-namespace-wrapper.sh` receives `--action-params` and forwards it
unchanged to hook scripts.  Hook scripts should decode the JSON themselves
(e.g. using `jq`).

---

## Custom actions

Define custom actions per extension via the CloudStack API:

```bash
# Add a custom action to the extension
cmk addCustomAction \
    extensionid=<ext-uuid> \
    name=dump-config \
    description="Dump iptables rules and bridge state" \
    resourcetype=Network
```

Trigger the action on a network, optionally with parameters:
```bash
cmk runNetworkCustomAction \
    networkid=<network-uuid> \
    actionid=<custom-action-uuid> \
    "parameters[0].key=threshold" "parameters[0].value=90"
```

### PBR custom-action examples

```bash
# 1) Create action definitions (once per extension)
cmk addCustomAction extensionid=<ext-uuid> name=pbr-create-table resourcetype=Network
cmk addCustomAction extensionid=<ext-uuid> name=pbr-add-route    resourcetype=Network
cmk addCustomAction extensionid=<ext-uuid> name=pbr-add-rule     resourcetype=Network
cmk addCustomAction extensionid=<ext-uuid> name=pbr-list-tables  resourcetype=Network
cmk addCustomAction extensionid=<ext-uuid> name=pbr-list-routes  resourcetype=Network
cmk addCustomAction extensionid=<ext-uuid> name=pbr-list-rules   resourcetype=Network
cmk addCustomAction extensionid=<ext-uuid> name=pbr-delete-rule  resourcetype=Network
cmk addCustomAction extensionid=<ext-uuid> name=pbr-delete-route resourcetype=Network
cmk addCustomAction extensionid=<ext-uuid> name=pbr-delete-table resourcetype=Network

# 2) Execute against a network
cmk runNetworkCustomAction networkid=<network-uuid> actionid=<pbr-create-table-id> \
    "parameters[0].key=table-id" "parameters[0].value=100" \
    "parameters[1].key=table-name" "parameters[1].value=isp1"

cmk runNetworkCustomAction networkid=<network-uuid> actionid=<pbr-add-route-id> \
    "parameters[0].key=table" "parameters[0].value=isp1" \
    "parameters[1].key=route" "parameters[1].value=default via 192.168.1.1 dev eth0"

cmk runNetworkCustomAction networkid=<network-uuid> actionid=<pbr-add-rule-id> \
    "parameters[0].key=table" "parameters[0].value=isp1" \
    "parameters[1].key=rule" "parameters[1].value=from 10.10.1.0/24"
```

CloudStack calls `NetworkExtensionElement.runCustomAction()`, which issues:
```bash
network-namespace.sh custom-action \
    --network-id <id> \
    --action dump-config \
    --action-params '{"threshold":"90"}' \
    --physical-network-extension-details '<json>' \
    --network-extension-details '<json>'
```

`network-namespace.sh` SSHes to the device and runs `network-namespace-wrapper.sh`
with identical arguments.  The wrapper parses `--action-params` and dispatches
it to the built-in handler or hook script as the `--action-params` CLI
argument; hook scripts should parse the JSON argument as needed.

---

## Developer / testing notes

### VPC Support

The extension now supports **VPC (Virtual Private Cloud)** networks in addition to
isolated networks.  Key differences from isolated networks:

* **Namespace sharing**: All tiers of a VPC share a single namespace (`cs-vpc-<vpcId>`)
  instead of each network getting its own (`cs-net-<networkId>`).
* **Host affinity**: All tiers of a VPC land on the same KVM host via stable hash-based
  selection using the VPC ID as the routing key.
* **VPC-level operations**: `implement-vpc`, `shutdown-vpc`, `destroy-vpc` commands
  manage VPC-wide state (namespace creation/teardown).
* **VPC tier operations**: `implement-network`, `shutdown-network`, `destroy-network`
  commands manage per-tier bridges and routes; the namespace is preserved across
  tier lifecycle operations.

### Integration tests

The integration smoke test at
`test/integration/smoke/test_network_extension_namespace.py`
exercises the full lifecycle against real KVM hosts in the zone.

```
Management server
  └── /usr/share/cloudstack-management/extensions/<ext-name>/
        └── network-namespace.sh             ← deployed / referenced by test
              SSHes to KVM host
              runs network-namespace-wrapper.sh <cmd> <args>

KVM host(s) in the zone
  └── /etc/cloudstack/extensions/<ext-name>/
        └── network-namespace-wrapper.sh     ← copied to KVM hosts by test setup
              creates cs-net-<id> or cs-vpc-<id> namespaces
              manages bridges, veth pairs, iptables, dnsmasq, haproxy, apache2
```

The test covers:
* Create / list / update / delete external network device.
* Full network lifecycle: implement → assign-ip (source NAT) → static NAT →
  port forwarding → firewall rules → DHCP/DNS → shutdown / destroy.
* VPC multi-tier networks with shared namespace and automatic host affinity.
* NSP state transitions: Disabled → Enabled → Disabled → Deleted.
* Tests `test_04`, `test_05`, `test_06` (DHCP, DNS, LB) require `arping`,
  `dnsmasq`, and `haproxy` on the KVM hosts; the test skips them automatically
  if these tools are not installed.
* Script cleanup on both management server and KVM hosts after each test.

Run the test:
```bash
cd test/integration/smoke
python -m pytest test_network_extension_namespace.py \
    --with-marvin --marvin-config=<config.cfg> \
    -s -a 'tags=advanced,smoke' 2>&1 | tee /tmp/extnet-test.log
```

**Prerequisites on KVM hosts:**
* `iproute2` (`ip`, `ip netns`)
* `iptables` + `iptables-save`
* `arping` (for GARP on IP assignment)
* `dnsmasq` (DHCP + DNS — required for `test_04` / DNS tests)
* `haproxy` (LB — required for `test_05` / LB tests)
* `apache2` / `httpd` (metadata HTTP service — required for UserData tests)
* `python3` (vm-data processing, haproxy config generation)
* `util-linux` (`flock`) (lock serialization)
* SSH access from management server (root or sudo-capable user)

**Prerequisites on the Marvin / test runner node:**
* Python Marvin library installed (`pip install -r requirements.txt`)
* A valid Marvin config file pointing to the CloudStack environment
* The test runner must be able to SSH to the management server and to KVM hosts
