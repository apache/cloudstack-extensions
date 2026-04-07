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
│  /etc/cloudstack/extensions/<ext-name>/                  │
│      network-namespace.sh                                │
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
│  eth0.1910  ─────────────────────────────────┐           │
│  (VLAN sub-iface)                            │           │
│                                    breth0-1910  (bridge) │
│  veth-host-1910  ────────────────────────────┘           │
│      │                                                   │
│  NAMESPACE  cs-net-209  (or  cs-net-<vpcId>)             │
│  ─────────────────────────────────────────────────       │
│  veth-ns-1910  ← gateway IP 10.1.1.1/24                  │
│                                                          │
│  PUBLIC side (source-NAT IP 10.0.56.4 on VLAN 101):      │
│                                                          │
│  HOST side                                               │
│  eth0.101   ─────────────────────────────────┐           │
│                                   breth0-101  (bridge)   │
│  vph-101-209 ────────────────────────────────┘           │
│      │                                                   │
│  NAMESPACE  cs-net-209  (or  cs-net-<vpcId>)             │
│  vpn-101-209  ← source-NAT IP  10.0.56.4/32              │
│  default route → 10.0.56.1 (upstream gateway)            │
└──────────────────────────────────────────────────────────┘
```

### Naming conventions

| Object | Name pattern | Example (VLAN 1910, net 209, pub-VLAN 101) |
|--------|--------------|-------------------------------------------|
| Namespace (standalone network) | `cs-net-<networkId>` | `cs-net-209` |
| Namespace (VPC network)        | `cs-net-<vpcId>`     | `cs-net-5` |
| Guest host bridge              | `br<ethX>-<vlan>`    | `breth0-1910` |
| Guest veth – host side         | `vh-<vlan>-<id>`     | `vh-1910-d1` |
| Guest veth – namespace side    | `vn-<vlan>-<id>`     | `vn-1910-d1` |
| Public host bridge             | `br<pub_ethX>-<pvlan>` | `breth0-101` |
| Public veth – host side        | `vph-<pvlan>-<id>`   | `vph-101-209` |
| Public veth – namespace side   | `vpn-<pvlan>-<id>`   | `vpn-101-209` |

`ethX` (and `pub_ethX`) is the **physical NIC** resolved from the
`kvmnetworklabel` (`public_kvmnetworklabel`) stored in the physical-network
extension details:

* `eth1`     → `eth1`  (not in `/sys/devices/virtual/net/` → already physical)
* `cloudbr1` → `eth1`  (virtual bridge → first non-virtual
  `/sys/class/net/cloudbr1/brif/` member)

Both labels are automatically included in `--physical-network-extension-details`
by `NetworkExtensionElement` — no extra registration step is needed.

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
* **VPC networks** share a single namespace per VPC (`cs-net-<vpcId>`).  Multiple
  guest VLANs are each connected via their own veth pair (`veth-host-<vlan>` /
  `veth-ns-<vlan>`).
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
/etc/cloudstack/extensions/<extension-name>/network-namespace.sh
```

In **developer mode** the extensions directory defaults to `extensions/` relative
to the repo root working directory, so `extensions/network-namespace/network-namespace.sh`
is found automatically when `path=network-namespace` is set at extension creation
time (CloudStack looks for `<extensionName>.sh` inside the directory).

### Remote network device

Copy `network-namespace-wrapper.sh` to each remote device that will act as the
network gateway:

```bash
# From the CloudStack source tree:
scp extensions/network-namespace/network-namespace-wrapper.sh \
    root@<device>:/etc/cloudstack/extensions/network-namespace-wrapper.sh
chmod +x /etc/cloudstack/extensions/network-namespace-wrapper.sh
```

The default path expected by `network-namespace.sh` is
`/etc/cloudstack/extensions/network-namespace/network-namespace-wrapper.sh`.
You can override this per-physical-network by passing a `script_path` detail
when calling `registerExtension` (see below).

**Prerequisites on the remote device:**
* `iproute2` (`ip link`, `ip addr`, `ip netns`)
* `iptables`
* `sshd` running and reachable from the management server
* The SSH user must have permission to run `ip` and `iptables` (root or `sudo`)

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
> extension's `network.capabilities` detail.  If the extension's JSON does not
> declare a capability value for a service, CloudStack accepts any value (or no
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

The wrapper creates a VLAN sub-interface and Linux bridge, assigns the gateway
IP to the bridge, enables IP forwarding, and creates dedicated per-network
iptables chains (`CS_EXTNET_42` in `nat` and `CS_EXTNET_FWD_42` in `filter`).

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
1. Adds `203.0.113.10/32` as a secondary address on the physical interface.
2. Adds an iptables SNAT rule: traffic from `10.0.1.0/24` outbound → source `203.0.113.10`.
3. Adds an iptables FORWARD rule allowing traffic from the guest CIDR to the
   physical interface.

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

iptables rules added:
```bash
# DNAT inbound
iptables -t nat -A CS_EXTNET_42 -d 203.0.113.20 -j DNAT --to-destination 10.0.1.5
# SNAT outbound
iptables -t nat -A CS_EXTNET_42 -s 10.0.1.5 -o eth0 -j SNAT --to-source 203.0.113.20
# FORWARD inbound + outbound
iptables -t filter -A CS_EXTNET_FWD_42 -d 10.0.1.5 -o cs-br-42 -j ACCEPT
iptables -t filter -A CS_EXTNET_FWD_42 -s 10.0.1.5 -i cs-br-42 -j ACCEPT
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

iptables rules added:
```bash
# DNAT inbound
iptables -t nat -A CS_EXTNET_42 -p tcp -d 203.0.113.20 --dport 2222 \
    -j DNAT --to-destination 10.0.1.5:22
# FORWARD
iptables -t filter -A CS_EXTNET_FWD_42 -p tcp -d 10.0.1.5 --dport 22 \
    -o cs-br-42 -j ACCEPT
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
2. Flushes and deletes iptables chains `CS_EXTNET_42` and `CS_EXTNET_FWD_42`.
3. Brings down and deletes bridge `cs-br-42`.
4. Brings down and deletes VLAN interface `eth0.100` (VLAN ID read from state if
   not passed in arguments).
5. Removes all state under `/var/lib/cloudstack/network-namespace/42/`.

### 9. Unregister and delete the extension

```bash
# Disable and delete the NSP
cmk updateNetworkServiceProvider id=<nsp-uuid> state=Disabled
cmk deleteNetworkServiceProvider id=<nsp-uuid>

# Remove external network device credentials (if any)
# Device credentials are stored as `extension_resource_map_details` for the
# extension registration. Remove or update them via `updateExtension` or
# by unregistering the extension from the physical network (unregisterExtension)
# and then updating the Extension record if necessary.

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
```

# Store device connection details and script_path as registration details
# (use updateNetworkServiceProvider or updateExtension details in the API / CMK)
# Example: set hosts, sshkey, script_path for the registered extension on the physical network
# Note: details are stored in extension_resource_map_details for the registration
cmk updateExtension id=<ext-uuid> "details[0].key=hosts" "details[0].value=10.0.0.1,10.0.0.2" \
    "details[1].key=script_path" "details[1].value=/etc/cloudstack/extensions/network-namespace/network-namespace-wrapper.sh"

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
* Write timestamped entries to `/var/log/cloudstack/network-namespace.log`.
* Use a per-network flock file (`/var/lib/cloudstack/network-namespace/lock-<id>`)
  to serialise concurrent operations.
* Persist state under `/var/lib/cloudstack/network-namespace/<network-id>/`.

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
1. Create namespace `cs-net-<vpc-id>` (VPC) or `cs-net-<network-id>` (standalone).
2. Resolve `ethX` from `kvmnetworklabel` in `--physical-network-extension-details`.
3. Create VLAN sub-interface `ethX.<vlan>` on the host.
4. Create host bridge `brethX-<vlan>` and attach `ethX.<vlan>` to it.
5. Create veth pair `veth-host-<vlan>` (host) / `veth-ns-<vlan>` (namespace).
   Attach host end to `brethX-<vlan>`.
6. Assign `<gateway>/<prefix>` to `veth-ns-<vlan>` inside the namespace.
7. Enable IP forwarding inside the namespace.
8. Create iptables chains `CS_EXTNET_<id>_PR` (PREROUTING DNAT),
   `CS_EXTNET_<id>_POST` (POSTROUTING SNAT), and `CS_EXTNET_FWD_<id>` (FORWARD).
9. Save VLAN, gateway, CIDR, namespace, network-id or vpc-id to state files.

### `shutdown`

Called when a network is shut down (may be restarted later).

```
network-namespace-wrapper.sh shutdown \
    --network-id <id> [--vlan <vlan-id>] [--vpc-id <vpc-id>]
```

Actions:
1. Flush and remove iptables chains (PREROUTING, POSTROUTING, FORWARD jumps +
   chain contents).
2. Delete public veth pairs (`vph-<pvlan>-<id>`) that were created during
   `assign-ip` (read from state).
3. Keep namespace and guest veth (`veth-host-<vlan>` / `veth-ns-<vlan>`) intact —
   guest VMs can still connect to `brethX-<vlan>`.

### `destroy`

Called when the network is permanently removed.

```
network-namespace-wrapper.sh destroy \
    --network-id <id> [--vlan <vlan-id>] [--vpc-id <vpc-id>]
```

Actions (superset of shutdown):
1. Delete guest veth host-side (`veth-host-<vlan>`).
2. Delete public veth pairs.
3. Delete the namespace (removes all interfaces inside it).
4. Remove state directory.

> The host bridge `brethX-<vlan>` and VLAN sub-interface `ethX.<vlan>` are NOT
> removed on destroy — they may still be used by other networks or for VM
> connectivity.

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
1. Resolve `pub_ethX` from `public_kvmnetworklabel` (falls back to `kvmnetworklabel`).
2. Create VLAN sub-interface `pub_ethX.<pvlan>` and bridge `brpub_ethX-<pvlan>` on the host.
3. Create veth pair `vph-<pvlan>-<id>` (host) / `vpn-<pvlan>-<id>` (namespace).
   Attach host end to `brpub_ethX-<pvlan>`.
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
| `filter` | `CS_EXTNET_FWD_<id>` | `-d <private-ip> -o veth-ns-<vlan> -j ACCEPT` |
| `filter` | `CS_EXTNET_FWD_<id>` | `-s <private-ip> -i veth-ns-<vlan> -j ACCEPT` |

State saved to `/var/lib/cloudstack/network-namespace/<id>/static-nat/<public-ip>`.

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

iptables rules added:

| Table | Chain | Rule |
|-------|-------|------|
| `nat` | `CS_EXTNET_<id>` | `-p <proto> -d <public-ip> --dport <public-port> -j DNAT --to-destination <private-ip>:<private-port>` |
| `filter` | `CS_EXTNET_FWD_<id>` | `-p <proto> -d <private-ip> --dport <private-port> -o cs-br-<id> -j ACCEPT` |

Port ranges (`80:90`) are passed verbatim to iptables `--dport`.

State saved to
`/var/lib/cloudstack/network-namespace/<id>/port-forward/<proto>_<public-ip>_<public-port>`.

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

### `custom-action`

```
network-namespace-wrapper.sh custom-action \
    --network-id <id> \
    --action <action-name>
```

Built-in actions:

| Action | Description |
|--------|-------------|
| `reboot-device` | Bounces the bridge: `ip link set cs-br-<id> down && up` |
| `dump-config` | Prints iptables rules and bridge/interface state to stdout |

To add custom actions, place an executable script at
`/var/lib/cloudstack/network-namespace/hooks/custom-action-<name>.sh`.
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

These keys are **automatically injected** by `NetworkExtensionElement` from the
physical network record — no manual registration needed:

| JSON key | Description |
|----------|-------------|
| `physicalnetworkname` | Physical network name from CloudStack DB |
| `kvmnetworklabel` | KVM guest traffic label (e.g. `eth0`, `cloudbr0`) |
| `vmwarenetworklabel` | VMware guest traffic label |
| `xennetworklabel` | XenServer guest traffic label |
| `public_kvmnetworklabel` | KVM public traffic label (used for public bridges) |
| `public_vmwarenetworklabel` | VMware public traffic label |

The wrapper script uses `kvmnetworklabel` (and `public_kvmnetworklabel`) to
derive the physical NIC `ethX` via `/sys/devices/virtual/net/` inspection, then
names bridges as `brethX-<vlan>`.

### Per-network details (keys in `--network-extension-details`)

| JSON key | Description |
|----------|-------------|
| `host` | Previously selected host IP (set by `ensure-network-device`) |
| `namespace` | Linux network namespace name (e.g. `cs-net-<networkId>`) |

### Additional per-command arguments

| CLI Argument | Commands | Description |
|--------------|----------|-------------|
| `--vpc-id <id>` | all | Inject when network belongs to a VPC; namespace becomes `cs-net-<vpcId>` |
| `--public-vlan <pvlan>` | `assign-ip`, `release-ip` | Public IP's VLAN tag (e.g. `101`) |
| `--network-id <id>` | `assign-ip`, `release-ip`, `add-static-nat`, `delete-static-nat`, `add-port-forward`, `delete-port-forward` | VPC ID if VPC network, else network ID — used in public veth names (`vph-<pvlan>-<id>`, `vpn-<pvlan>-<id>`) |

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

The integration smoke test at
`test/integration/smoke/test_network_extension_namespace.py`
exercises the full lifecycle using a **Linux network namespace** on the Marvin
node as the simulated remote device:

```
Marvin node (this machine — also acts as the remote network device)
  ├── ip netns add cs-extnet-<id>            ← isolated namespace
  ├── ~/.ssh/authorized_keys ← test RSA key  ← management server connects here
  └── /etc/cloudstack/extensions/
        └── network-namespace-wrapper.sh     ← copied from repo by test

KVM hosts in the zone (best-effort, skipped if none found)
  └── /etc/cloudstack/extensions/
        └── network-namespace-wrapper.sh     ← copied by KvmHostDeployer

Management server (may be the same machine)
  └── /etc/cloudstack/extensions/<ext-name>/
        └── network-namespace.sh             ← deployed by test (static copy)
              reads CS_PHYSICAL_NETWORK_EXTENSION_DETAILS (JSON)
                    CS_NETWORK_EXTENSION_DETAILS          (JSON)
              SSHes back to Marvin node :22
              runs ip netns exec cs-extnet-<id> <script> <args>
```

The test covers:
* Create / list / update / delete external network device.
* Full network lifecycle: implement → assign-ip (source NAT) → static NAT →
  port forwarding → shutdown / destroy.
* NSP state transitions: Disabled → Enabled → Disabled → Deleted.

Run the test:
```bash
cd test/integration/smoke
nosetests test_network_extension_provider.py \
    --with-marvin --marvin-config=<config.cfg> \
    -s -a 'tags=advanced,smoke' 2>&1 | tee /tmp/extnet-test.log
```

**Prerequisites:**
* `iproute2` on the Marvin node (`ip netns list` must succeed).
* The Marvin node must be reachable by SSH from the management server on port 22.
* Set `MARVIN_NODE_IP=<ip>` if auto-detection of the Marvin node IP fails.
