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
# Proxmox SDN Network Extension for Apache CloudStack

This directory contains the **Proxmox SDN** `NetworkOrchestrator` extension —
a CloudStack plugin that delegates network lifecycle operations to the
[Proxmox VE SDN](https://pve.proxmox.com/pve-docs/chapter-pvesdn.html) API.

The extension maps CloudStack network concepts (isolated networks, VPCs,
VLANs, source NAT, static NAT, port forwarding, firewall rules) onto
Proxmox SDN primitives (zones, VNets, subnets) and manages
NAT/firewall rules on the Proxmox gateway node via iptables.

This extension works alongside the **Proxmox.sh** VM orchestrator
extension: proxmox-sdn.sh creates VLAN networks (VNets) on Proxmox SDN,
while Proxmox.sh creates VMs and attaches NICs to those VNet bridges.
VM metadata (userdata, passwords, SSH keys, network config) is delivered
via a cloud-init ISO attached to the VM.

The extension is implemented as a shell script executed by
`NetworkExtensionElement` — **no separate plugin JAR is required**.

---

## Table of Contents

1. [Architecture](#architecture)
2. [Proxmox SDN Concepts](#proxmox-sdn-concepts)
3. [CloudStack ↔ Proxmox SDN Mapping](#cloudstack--proxmox-sdn-mapping)
4. [Directory Contents](#directory-contents)
5. [Prerequisites](#prerequisites)
6. [Installation](#installation)
7. [Step-by-step API Setup](#step-by-step-api-setup)
   - [1. Create the Extension](#1-create-the-extension)
   - [2. Register with Physical Network](#2-register-with-physical-network)
   - [3. Create Network Offering](#3-create-network-offering)
   - [4. Create an Isolated Network](#4-create-an-isolated-network)
   - [5. VPC Setup](#5-vpc-setup)
   - [6. Cleanup](#6-cleanup)
8. [Extension Details Reference](#extension-details-reference)
9. [Supported Commands](#supported-commands)
10. [Custom Actions](#custom-actions)
11. [Cloud-Init Integration](#cloud-init-integration)
12. [Integration with Proxmox VM Extension](#integration-with-proxmox-vm-extension)
13. [Proxmox SDN Zone Types](#proxmox-sdn-zone-types)
14. [Limitations and Future Work](#limitations-and-future-work)

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  CloudStack Management Server                                │
│                                                              │
│  NetworkExtensionElement.java                                │
│      │ executes (path resolved from Extension record)        │
│      ▼                                                       │
│  /usr/share/cloudstack-management/extensions/<ext-name>/     │
│      proxmox-sdn.sh                                          │
│          │                                                   │
│          │ 1. Proxmox REST API (HTTPS :8006)                 │
│          │    → /api2/json/cluster/sdn/zones                 │
│          │    → /api2/json/cluster/sdn/vnets                 │
│          │    → /api2/json/cluster/sdn/vnets/<vnet>/subnets  │
│          │    → PUT /api2/json/cluster/sdn  (apply changes)  │
│          │                                                   │
│          │ 2. SSH to gateway node (for iptables NAT/FW)      │
│          ▼                                                   │
└──────────┬───────────────────────────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────────────────────────┐
│  Proxmox VE Cluster                                          │
│                                                              │
│  SDN Layer (managed via API)                                 │
│  ┌────────────────────────────────────────────────────┐      │
│  │  Zone: cszone (type: vlan, bridge: vmbr0)          │      │
│  │                                                    │      │
│  │  ┌──────────────────────────────────────────┐      │      │
│  │  │  VNet: cs42 (tag: 100)                   │      │      │
│  │  │    Subnet: 10.0.1.0/24                   │      │      │
│  │  │      Gateway: 10.0.1.1                   │      │      │
│  │  │      SNAT: enabled                       │      │      │
│  │  └──────────────────────────────────────────┘      │      │
│  │                                                    │      │
│  │  ┌──────────────────────────────────────────┐      │      │
│  │  │  VNet: cs55 (tag: 200)                   │      │      │
│  │  │    Subnet: 10.0.2.0/24                   │      │      │
│  │  │      Gateway: 10.0.2.1                   │      │      │
│  │  └──────────────────────────────────────────┘      │      │
│  └────────────────────────────────────────────────────┘      │
│                                                              │
│  NAT/Firewall (iptables on gateway node)                     │
│  ┌────────────────────────────────────────────────────┐      │
│  │  Chain CS_PVE_SDN_42_PR (nat PREROUTING)           │      │
│  │    DNAT rules for static NAT / port forwarding     │      │
│  │                                                    │      │
│  │  Chain CS_PVE_SDN_42_POST (nat POSTROUTING)        │      │
│  │    SNAT rules for source NAT                       │      │
│  │                                                    │      │
│  │  Chain CS_PVE_SDN_FWD_42 (filter FORWARD)          │      │
│  │    Forwarding rules for guest traffic              │      │
│  └────────────────────────────────────────────────────┘      │
└──────────────────────────────────────────────────────────────┘
```

**Key design principles:**

* The `proxmox-sdn.sh` script runs entirely on the **management server**.
  Network topology (zones, VNets, subnets) is managed via the Proxmox
  REST API — no SSH is needed for SDN operations.

* NAT and firewall rules are managed via iptables on a designated
  **gateway node** in the Proxmox cluster, accessed via SSH or the
  Proxmox API execute endpoint.

* Proxmox SDN handles VLAN trunking and DHCP (via dnsmasq on nodes)
  natively.

* VMs connect to CloudStack networks via Proxmox VNet bridges that
  are automatically created on all cluster nodes when SDN changes
  are applied.

---

## Proxmox SDN Concepts

Refer to the [Proxmox SDN documentation](https://pve.proxmox.com/pve-docs/chapter-pvesdn.html)
for full details.

### Zones

A **Zone** defines a transport domain — the method by which VNets
are isolated from each other:

| Zone Type | Isolation Method | Use Case |
|-----------|-----------------|----------|
| **Simple** | No isolation (all VNets share the same bridge) | Testing, flat networks |
| **VLAN** | 802.1Q VLAN tags on a physical bridge | Traditional L2 isolation |
| **QinQ** | Stacked VLANs (802.1ad) | Service provider environments |

### VNets

A **VNet** is a virtual network within a zone. Each VNet:
- Has a unique name (max 8 characters in Proxmox)
- Has a tag (VLAN ID for VLAN zones)
- Creates a Linux bridge on each cluster node (e.g., `vnet0`)
- VMs connect to VNets by assigning their NICs to the VNet bridge

### Subnets

A **Subnet** within a VNet defines:
- IP address range (CIDR)
- Gateway IP
- SNAT flag (for source NAT on the nodes)
- DHCP range and DNS server
- IPAM integration (PVE, NetBox, phpIPAM)


---

## CloudStack ↔ Proxmox SDN Mapping

| CloudStack Concept | Proxmox SDN Concept | Notes |
|-------------------|---------------------|-------|
| Isolated network | VNet in a VLAN zone | One VNet per CS network |
| VLAN tag | VNet tag | Direct mapping |
| Network gateway | Subnet gateway | Proxmox applies it on nodes |
| Network CIDR | Subnet CIDR | — |
| Source NAT | Subnet SNAT + iptables on GW node | Proxmox subnet SNAT + custom rules |
| VPC | Per-VPC VLAN zone | One VLAN zone per VPC |
| VPC tier | VNet within VPC zone | — |
| Static NAT | iptables DNAT on GW node | — |
| Port forwarding | iptables DNAT on GW node | — |
| Firewall rules | iptables on GW node | — |
| DHCP | Proxmox SDN subnet DHCP | dnsmasq on nodes |
| VM metadata | Cloud-init ISO (cidata) | Attached via Proxmox API |

---

## Directory Contents

| File | Purpose |
|------|---------|
| `proxmox-sdn.sh` | Main extension script (runs on management server) |
| `README.md` | This documentation |

---

## Prerequisites

### Proxmox VE Cluster

* **Proxmox VE 7.x or 8.x** with SDN enabled
  - SDN is available in Proxmox VE 7.0+ (Technology Preview) and
    fully supported in Proxmox VE 8.1+
  - Ensure `libpve-network-perl` is installed:
    ```bash
    apt install libpve-network-perl
    ```

* **API Token** with SDN permissions:
  ```bash
  # On a Proxmox node, create an API token:
  pveum user token add root@pam cloudstack --privsep 0
  # Or with specific permissions:
  pveum role add CloudStackSDN -privs "SDN.Allocate SDN.Audit SDN.Use Sys.Modify Sys.Audit"
  pveum acl modify / --roles CloudStackSDN --users root@pam --tokens root@pam!cloudstack
  ```

* **SDN enabled** in the datacenter configuration:
  ```bash
  # Verify SDN is configured:
  pvesh get /cluster/sdn
  ```

* **Physical bridge** configured (e.g., `vmbr0`) that carries VLAN
  trunks (for VLAN zones) or has IP connectivity between nodes
  (for VXLAN/EVPN zones).

### CloudStack Management Server

* `curl` — for Proxmox API calls
* `jq` — for JSON parsing (recommended; fallback to grep-based parsing)
* `bash` 4+ — for associative arrays and advanced string handling
* SSH access to the gateway node (for iptables management)

---

## Installation

### Management Server

During package installation, `proxmox-sdn.sh` is deployed to:
```
/usr/share/cloudstack-management/extensions/<extension-name>/proxmox-sdn.sh
```

In **developer mode** the extensions directory defaults to `extensions/`
relative to the repo root, so `extensions/proxmox-sdn/proxmox-sdn.sh`
is found automatically.

---

## Step-by-step API Setup

### 1. Create the Extension

```bash
cmk createExtension \
    name=proxmox-sdn \
    type=NetworkOrchestrator \
    path=proxmox-sdn \
    "details[0].key=network.services" \
    "details[0].value=SourceNat,StaticNat,PortForwarding,Firewall,Gateway" \
    "details[1].key=network.service.capabilities" \
    "details[1].value={\"SourceNat\":{\"SupportedSourceNatTypes\":\"peraccount\",\"RedundantRouter\":\"false\"},\"Firewall\":{\"TrafficStatistics\":\"per public ip\"}}"
```

For a full-featured extension including DHCP:

```bash
cmk createExtension \
    name=proxmox-sdn-full \
    type=NetworkOrchestrator \
    path=proxmox-sdn \
    "details[0].key=network.services" \
    "details[0].value=SourceNat,StaticNat,PortForwarding,Firewall,Gateway,Dhcp,Dns" \
    "details[1].key=network.service.capabilities" \
    "details[1].value={\"SourceNat\":{\"SupportedSourceNatTypes\":\"peraccount\",\"RedundantRouter\":\"false\"},\"Firewall\":{\"TrafficStatistics\":\"per public ip\"}}"
```

Verify:
```bash
cmk listExtensions name=proxmox-sdn
```

### 2. Register with Physical Network

```bash
cmk registerExtension \
    id=<extension-uuid> \
    resourcetype=PhysicalNetwork \
    resourceid=<phys-net-uuid>
```

Set Proxmox connection details:

```bash
cmk updateRegisteredExtension \
    extensionid=<extension-uuid> \
    resourcetype=PhysicalNetwork \
    resourceid=<phys-net-uuid> \
    "details[0].key=url"                      "details[0].value=proxmox1.example.com" \
    "details[1].key=user"                     "details[1].value=root@pam" \
    "details[2].key=token"                    "details[2].value=cloudstack" \
    "details[3].key=secret"                   "details[3].value=<api-token-secret>" \
    "details[4].key=node"                     "details[4].value=pve1" \
    "details[5].key=verify_tls_certificate"   "details[5].value=false" \
    "details[6].key=sdn.zone.type"            "details[6].value=vlan" \
    "details[7].key=sdn.zone.bridge"          "details[7].value=vmbr0" \
    "details[8].key=public.bridge"            "details[8].value=vmbr0" \
    "details[9].key=gateway.node"             "details[9].value=pve1"
```

For SSH-based iptables management on the gateway node, add SSH credentials:

```bash
cmk updateRegisteredExtension \
    extensionid=<extension-uuid> \
    resourcetype=PhysicalNetwork \
    resourceid=<phys-net-uuid> \
    "details[0].key=ssh.key"   "details[0].value=$(cat ~/.ssh/id_rsa)" \
    "details[1].key=ssh.user"  "details[1].value=root"
```

Verify the NSP was created:
```bash
cmk listNetworkServiceProviders physicalnetworkid=<phys-net-uuid>
# → "proxmox-sdn" should appear as Enabled
```

### 3. Create Network Offering

```bash
cmk createNetworkOffering \
    name="Proxmox SDN Isolated" \
    displaytext="Isolated network via Proxmox SDN" \
    guestiptype=Isolated \
    traffictype=GUEST \
    supportedservices="SourceNat,StaticNat,PortForwarding,Firewall,Gateway" \
    "serviceProviderList[0].service=SourceNat"      "serviceProviderList[0].provider=proxmox-sdn" \
    "serviceProviderList[1].service=StaticNat"      "serviceProviderList[1].provider=proxmox-sdn" \
    "serviceProviderList[2].service=PortForwarding" "serviceProviderList[2].provider=proxmox-sdn" \
    "serviceProviderList[3].service=Firewall"       "serviceProviderList[3].provider=proxmox-sdn" \
    "serviceProviderList[4].service=Gateway"        "serviceProviderList[4].provider=proxmox-sdn" \
    "serviceCapabilityList[0].service=SourceNat" \
    "serviceCapabilityList[0].capabilitytype=SupportedSourceNatTypes" \
    "serviceCapabilityList[0].capabilityvalue=peraccount"

cmk updateNetworkOffering id=<offering-uuid> state=Enabled
```

### 4. Create an Isolated Network

```bash
cmk createNetwork \
    name=my-proxmox-network \
    displaytext="My Proxmox SDN network" \
    networkofferingid=<offering-uuid> \
    zoneid=<zone-uuid>
```

When a VM is deployed, CloudStack triggers `implement-network`, which:
1. Creates a VLAN zone `cszone` (if not already present) in Proxmox SDN
2. Creates a VNet `cs<networkId>` with the assigned VLAN tag
3. Creates a subnet with gateway and CIDR
4. Applies SDN changes (`PUT /cluster/sdn`)
5. Sets up iptables NAT chains on the gateway node

### 5. VPC Setup

For VPC networks, create a VPC offering and VPC:

```bash
# Create VPC offering
cmk createVPCOffering \
    name="Proxmox SDN VPC" \
    displaytext="VPC via Proxmox SDN" \
    supportedservices="SourceNat,StaticNat,PortForwarding,Firewall,NetworkACL" \
    "serviceProviderList[0].service=SourceNat"      "serviceProviderList[0].provider=proxmox-sdn" \
    "serviceProviderList[1].service=StaticNat"      "serviceProviderList[1].provider=proxmox-sdn" \
    "serviceProviderList[2].service=PortForwarding" "serviceProviderList[2].provider=proxmox-sdn" \
    "serviceProviderList[3].service=Firewall"       "serviceProviderList[3].provider=proxmox-sdn" \
    "serviceProviderList[4].service=NetworkACL"     "serviceProviderList[4].provider=proxmox-sdn"

# Create VPC
cmk createVPC \
    name=my-vpc \
    displaytext="My Proxmox SDN VPC" \
    vpcofferingid=<vpc-offering-uuid> \
    zoneid=<zone-uuid> \
    cidr=10.0.0.0/16

# Create VPC tier network offering and tiers...
```

Each VPC gets its own Proxmox SDN VLAN zone. VPC tier
networks are VNets within the VPC zone.

### 6. Cleanup

```bash
# Delete network
cmk deleteNetwork id=<network-uuid>

# Unregister and delete extension
cmk unregisterExtension id=<ext-uuid> resourcetype=PhysicalNetwork resourceid=<phys-net-uuid>
cmk deleteExtension id=<ext-uuid>
```

---

## Extension Details Reference

### Physical Network Extension Details

Set via `updateRegisteredExtension`:

| Key | Required | Default | Description |
|-----|----------|---------|-------------|
| `url` | **Yes** | — | Proxmox API hostname (e.g., `proxmox1.example.com`) |
| `user` | **Yes** | — | API token user (e.g., `root@pam`) |
| `token` | **Yes** | — | API token name (e.g., `cloudstack`) |
| `secret` | **Yes** | — | API token secret |
| `node` | **Yes** | — | Default Proxmox node name |
| `verify_tls_certificate` | No | `true` | Set to `false` to skip TLS verification |
| `sdn.zone` | No | `cszone` | SDN zone name for isolated networks |
| `sdn.zone.type` | No | `vlan` | Zone type: `simple`, `vlan`, `qinq` |
| `sdn.zone.bridge` | No | `vmbr0` | Physical bridge for the SDN zone |
| `sdn.service.vlan` | No | — | Service VLAN tag (for QinQ zones) |
| `gateway.node` | No | same as `node` | Node acting as NAT gateway |
| `gateway.ip` | No | same as `url` | IP address of the gateway node (for SSH) |
| `public.bridge` | No | `vmbr0` | Public network bridge on gateway node |
| `ssh.user` | No | `root` | SSH user for gateway node |
| `ssh.key` | No | — | SSH private key (PEM) for gateway node |
| `cloudinit.storage` | No | `local` | Proxmox storage for cloud-init ISOs |

### Per-Network Extension Details

Stored in `network_details` by `ensure-network-device`, forwarded as
`--network-extension-details`:

| Key | Description |
|-----|-------------|
| `zone` | Proxmox SDN zone name |
| `vnet` | Proxmox SDN VNet name |
| `node` | Gateway node name |
| `vpc_id` | VPC ID (for VPC tier networks) |

---

## Supported Commands

### Network Lifecycle

| Command | Description |
|---------|-------------|
| `ensure-network-device` | Validate Proxmox API connectivity, return zone/VNet/node details |
| `implement-network` | Create VNet + Subnet in Proxmox SDN, set up iptables chains |
| `shutdown-network` | Remove subnet and VNet, clean up iptables chains |
| `destroy-network` | Permanently remove VNet and all state |

### VPC Lifecycle

| Command | Description |
|---------|-------------|
| `implement-vpc` | Create SDN zone for VPC, set up VPC-level SNAT |
| `shutdown-vpc` | Remove VPC zone, clean up VPC SNAT |
| `destroy-vpc` | Permanently remove VPC zone and state |
| `update-vpc-source-nat-ip` | Update VPC-level SNAT to a new public IP |

### IP Management

| Command | Description |
|---------|-------------|
| `assign-ip` | Assign public IP to gateway node, configure SNAT |
| `release-ip` | Release public IP, remove SNAT/DNAT rules |
| `add-static-nat` | Configure 1:1 DNAT + SNAT on gateway node |
| `delete-static-nat` | Remove 1:1 NAT rules |
| `add-port-forward` | Configure port-based DNAT on gateway node |
| `delete-port-forward` | Remove port forwarding rules |

### Firewall

| Command | Description |
|---------|-------------|
| `apply-fw-rules` | Apply firewall rules (egress/ingress) via iptables |
| `apply-network-acl` | Apply VPC Network ACL rules via iptables |

### DHCP/DNS/Metadata

These commands are handled by Proxmox SDN natively or delegated to
cloud-init:

| Command | Behavior |
|---------|----------|
| `config-dhcp-subnet` | Updates Proxmox SDN subnet DHCP settings |
| `add-dhcp-entry` | No-op (Proxmox SDN IPAM handles this) |
| `config-dns-subnet` | Updates Proxmox SDN subnet DNS settings |
| `save-vm-data` | Creates cloud-init ISO with metadata and attaches to VM |
| `save-userdata` | Creates/updates cloud-init ISO with userdata |
| `save-password` | Adds password to cloud-init ISO |
| `save-sshkey` | Adds SSH key to cloud-init ISO |
| `apply-lb-rules` | No-op (LB not natively supported) |

---

## Custom Actions

| Action | Description |
|--------|-------------|
| `dump-config` | Dump Proxmox SDN zones, VNets, and local state |
| `apply-sdn` | Manually apply pending SDN configuration changes |

Example:
```bash
cmk addCustomAction extensionid=<ext-uuid> name=dump-config resourcetype=Network
cmk runNetworkCustomAction networkid=<network-uuid> actionid=<action-uuid>
```

---

## Cloud-Init Integration

VM metadata (userdata, passwords, SSH keys, network configuration) is
delivered via a **cloud-init ISO** (with the `cidata` volume label)
created by the extension and attached to the VM via the Proxmox API.

When CloudStack calls `save-vm-data`, `save-userdata`, `save-password`,
or `save-sshkey`, the extension:

1. Creates a temporary directory with three files:
   - **meta-data** — instance ID and local hostname
   - **network-config** — NoCloud v2 format with static IP, gateway,
     and DNS from the network details
   - **user-data** — CloudStack userdata, password, and/or SSH keys
     merged into a `#cloud-config` document

2. Generates an ISO image using `genisoimage` (or `mkisofs`/`xorrisofs`)
   with the `cidata` volume label

3. Uploads the ISO to Proxmox storage (configurable via
   `cloudinit.storage`, default: `local`)

4. Attaches the ISO to the VM as `ide2` (CD-ROM drive) via the
   Proxmox API

The VM's Proxmox VMID is resolved from the `--vmid` argument, the
`VM_DATA_FILE` JSON, or a local IP→VMID mapping maintained by the
extension.

---

## Integration with Proxmox VM Extension

This SDN extension is designed to work alongside the **Proxmox.sh**
VM orchestrator extension (`extensions/Proxmox/proxmox.sh`).

**Workflow:**

1. **Network creation** — CloudStack calls `proxmox-sdn.sh implement-network`,
   which creates a VNet (e.g., `cs42`) in Proxmox SDN with the assigned
   VLAN tag. The VNet name becomes a Linux bridge on every cluster node.

2. **VM creation** — CloudStack calls `proxmox.sh create`, which creates
   a QEMU VM and attaches NICs to the VNet bridge using the VLAN tag
   and MAC address from CloudStack.

3. **Metadata delivery** — CloudStack calls `proxmox-sdn.sh save-vm-data`
   (and related commands), which creates a cloud-init ISO with network
   config, userdata, password, and SSH keys, and attaches it to the VM.

The VNet name returned by `ensure-network-device` in the extension
details JSON (`"vnet": "cs42"`) is the bridge name that the VM
orchestrator uses as `network_bridge`.

---

## Proxmox SDN Zone Types

### VLAN Zone (Recommended for isolated networks)

Best for traditional L2 isolation. Requires 802.1Q VLAN trunk on the
physical bridge.

```
details: sdn.zone.type=vlan, sdn.zone.bridge=vmbr0
```

Each CloudStack network gets a VNet with the VLAN tag assigned by
CloudStack. The Proxmox VNet creates a VLAN-aware bridge on each
cluster node.

### Simple Zone (For testing)

No isolation — all VNets share the same bridge. Useful for testing.

```
details: sdn.zone.type=simple
```

### QinQ Zone (For service providers)

Stacked VLANs (802.1ad). Each VNet uses a customer VLAN inside a
service VLAN.

```
details: sdn.zone.type=qinq, sdn.zone.bridge=vmbr0, sdn.service.vlan=100
```

---

## Limitations and Future Work

### Current Limitations

1. **DHCP**: Proxmox SDN provides DHCP via dnsmasq on nodes, but
   per-MAC static reservations must be configured through Proxmox
   IPAM (PVE built-in, NetBox, or phpIPAM). The extension currently
   delegates DHCP to Proxmox SDN's native mechanisms.

2. **Load Balancing**: Not natively supported by Proxmox SDN. A
   future version could deploy HAProxy on the gateway node.

3. **VNet Name Length**: Proxmox limits VNet names to 8 characters.
   The extension generates short names (e.g., `cs42`, `vt5n42`) but
   this limits the maximum network/VPC IDs that can be represented
   without collision.

4. **Multi-node Gateway**: Currently, a single gateway node handles
   all NAT/firewall rules. A future version could distribute rules
   across multiple nodes for HA.

5. **Cloud-init ISO tools**: The management server must have
   `genisoimage`, `mkisofs`, or `xorrisofs` installed to create
   cloud-init ISOs.

### Future Enhancements

- **Proxmox IPAM Integration**: Register VM MAC→IP mappings in the
  Proxmox IPAM database for static DHCP reservations.
- **Proxmox Firewall API**: Use the Proxmox cluster/node firewall
  API instead of raw iptables for better integration.
- **HA Gateway**: Distribute NAT/firewall rules across multiple
  Proxmox nodes with VRRP or similar.
- **IPv6 Support**: Extend subnet configuration with IPv6 CIDR
  and dual-stack support.

