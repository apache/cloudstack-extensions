#!/usr/bin/env bash
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

##############################################################################
# proxmox-sdn.sh  (Proxmox SDN Network Extension for Apache CloudStack)
#
# Runs on the CloudStack management server.
# Delegates network lifecycle operations to the Proxmox VE SDN API.
#
# Proxmox SDN concepts (https://pve.proxmox.com/pve-docs/chapter-pvesdn.html):
#
#   Zone    — A transport domain (Simple, VLAN, QinQ).
#             Each zone defines how traffic is isolated between VNets.
#
#   VNet    — A virtual network within a zone. VMs connect to VNets via
#             bridges. Each VNet has a tag (VLAN ID for VLAN zones).
#
#   Subnet  — An IP subnet within a VNet. Optionally provides DHCP via
#             dnsmasq and a gateway (SNAT) on the nodes.
#
# Mapping from CloudStack → Proxmox SDN:
#
#   CloudStack isolated network  →  Proxmox VNet (in a VLAN/Simple zone)
#                                   with a subnet for gateway/CIDR
#   CloudStack VPC               →  Proxmox VLAN zone (per-VPC)
#   CloudStack VPC tier          →  Proxmox VNet within the VPC zone
#   CloudStack VLAN tag          →  VNet tag
#   CloudStack gateway/CIDR      →  Proxmox subnet gateway/CIDR
#   CloudStack source NAT        →  Proxmox subnet SNAT flag
#   CloudStack DHCP              →  Proxmox subnet DHCP range
#   CloudStack firewall          →  Proxmox cluster firewall rules
#   CloudStack static NAT        →  Proxmox firewall DNAT rules on nodes
#   CloudStack port forwarding   →  Proxmox firewall DNAT rules on nodes
#
# Integration with Proxmox VM Orchestrator (Proxmox.sh):
#   This SDN extension creates VNet bridges in Proxmox.  The VNet name
#   returned by ensure-network-device (e.g. "cs42") is the bridge that
#   the Proxmox.sh VM orchestrator uses as network_bridge when attaching
#   VM NICs.  VM metadata (userdata, password, SSH key, network config)
#   is delivered via a small cloud-init ISO attached to the VM.
#
# ---- CLI arguments injected by NetworkExtensionElement ----
#
#   --physical-network-extension-details <json>
#       JSON object with all extension_resource_map_details.  Required keys:
#         url                     – Proxmox API host (e.g. proxmox1.example.com)
#         user                    – API token user (e.g. root@pam)
#         token                   – API token name (e.g. cloudstack)
#         secret                  – API token secret
#         node                    – Default Proxmox node name
#       Optional keys:
#         verify_tls_certificate  – "true" or "false" (default: "true")
#         sdn.zone               – SDN zone name (default: auto-generated)
#         sdn.zone.type          – Zone type: simple, vlan, qinq
#                                  (default: vlan)
#         sdn.bridge.prefix      – Bridge name prefix (default: vnet)
#         gateway.node           – Node acting as NAT gateway (default: same as node)
#         public.bridge          – Public network bridge on gateway node
#                                  (default: vmbr0)
#         guest.bridge           – Override guest bridge (default: auto from VNet)
#         cloudinit.storage      – Proxmox storage for cloud-init ISOs
#                                  (default: local)
#
#   --network-extension-details <json>
#       Per-network opaque JSON blob (from network_details key ext.details).
#       '{}' on the first ensure-network-device call.
#       Keys managed by this script:
#         zone      – Proxmox SDN zone name
#         vnet      – Proxmox SDN VNet name
#         subnet    – Proxmox SDN subnet CIDR
#         node      – Gateway node name
#
# Exit codes:
#   0  – success
#   1  – usage / configuration error
#   2  – API connection / authentication error
#   3  – API command returned non-zero / unexpected result
##############################################################################

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve paths for logging
# ---------------------------------------------------------------------------
_SELF="$(readlink -f "$0" 2>/dev/null \
         || realpath "$0" 2>/dev/null \
         || echo "$0")"
_SCRIPT_BASENAME="$(basename "${_SELF}" .sh)"
_EXT_DIR_NAME="$(basename "$(dirname "${_SELF}")")"

LOG_FILE="/var/log/cloudstack/extensions/${_EXT_DIR_NAME}.log"
mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true

STATE_DIR="/var/lib/cloudstack/${_EXT_DIR_NAME}"
mkdir -p "${STATE_DIR}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] %s\n' "${ts}" "$*" >> "${LOG_FILE}" 2>/dev/null || true
}

die() {
    local _msg="$1"
    local _code="${2:-1}"
    log "ERROR: ${_msg}"
    echo "ERROR: ${_msg}" >&2
    exit "${_code}"
}

# ---------------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------------

# json_get <json> <key> → unquoted string value or empty
json_get() {
    local _json="$1" _key="$2"
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "${_json}" | jq -r ".\"${_key}\" // empty" 2>/dev/null || true
    else
        printf '%s' "${_json}" | grep -o "\"${_key}\":\"[^\"]*\"" | cut -d'"' -f4 || true
    fi
}

# json_get_nested <json> <key1> <key2> → for nested objects
json_get_nested() {
    local _json="$1" _k1="$2" _k2="$3"
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "${_json}" | jq -r ".\"${_k1}\".\"${_k2}\" // empty" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Validate input and parse command
# ---------------------------------------------------------------------------

if [ $# -lt 1 ]; then
    die "Usage: proxmox-sdn.sh <command> [arguments...]" 1
fi

COMMAND="$1"
shift

# ---------------------------------------------------------------------------
# Parse CLI arguments
# ---------------------------------------------------------------------------

PHYS_DETAILS="{}"
EXTENSION_DETAILS="{}"
NETWORK_ID=""
CURRENT_DETAILS="{}"
VPC_ID=""
VLAN=""
GATEWAY=""
CIDR=""
PUBLIC_IP=""
PRIVATE_IP=""
PUBLIC_PORT=""
PRIVATE_PORT=""
PROTOCOL=""
SOURCE_NAT="false"
PUBLIC_GATEWAY=""
PUBLIC_CIDR=""
PUBLIC_VLAN=""
ZONE_ID=""
EXTENSION_IP=""
MAC=""
HOSTNAME=""
DNS_SERVER=""
DEFAULT_NIC="true"
DOMAIN=""
VM_DATA_FILE=""
FW_RULES_FILE=""
ACL_RULES_FILE=""
RESTORE_DATA_FILE=""
VM_IP=""
ACTION_NAME=""
ACTION_PARAMS="{}"
NIC_ID=""
USERDATA=""
VM_PASSWORD=""
VM_SSHKEY=""
HYPERVISOR_HOSTNAME=""
VM_DATA=""
PROXMOX_VMID=""
FORWARD_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --physical-network-extension-details)
            PHYS_DETAILS="${2:-{}}"
            shift 2 ;;
        --network-extension-details)
            EXTENSION_DETAILS="${2:-{}}"
            shift 2 ;;
        --network-id)
            NETWORK_ID="${2:-}"
            shift 2 ;;
        --vpc-id)
            VPC_ID="${2:-}"
            shift 2 ;;
        --current-details)
            CURRENT_DETAILS="${2:-{}}"
            shift 2 ;;
        --vlan)
            VLAN="${2:-}"
            shift 2 ;;
        --gateway)
            GATEWAY="${2:-}"
            shift 2 ;;
        --cidr)
            CIDR="${2:-}"
            shift 2 ;;
        --public-ip)
            PUBLIC_IP="${2:-}"
            shift 2 ;;
        --private-ip)
            PRIVATE_IP="${2:-}"
            shift 2 ;;
        --public-port)
            PUBLIC_PORT="${2:-}"
            shift 2 ;;
        --private-port)
            PRIVATE_PORT="${2:-}"
            shift 2 ;;
        --protocol)
            PROTOCOL="${2:-}"
            shift 2 ;;
        --source-nat)
            SOURCE_NAT="${2:-false}"
            shift 2 ;;
        --public-gateway)
            PUBLIC_GATEWAY="${2:-}"
            shift 2 ;;
        --public-cidr)
            PUBLIC_CIDR="${2:-}"
            shift 2 ;;
        --public-vlan)
            PUBLIC_VLAN="${2:-}"
            shift 2 ;;
        --zone-id)
            ZONE_ID="${2:-}"
            shift 2 ;;
        --extension-ip)
            EXTENSION_IP="${2:-}"
            shift 2 ;;
        --mac)
            MAC="${2:-}"
            shift 2 ;;
        --hostname)
            HOSTNAME="${2:-}"
            shift 2 ;;
        --dns)
            DNS_SERVER="${2:-}"
            shift 2 ;;
        --default-nic)
            DEFAULT_NIC="${2:-true}"
            shift 2 ;;
        --domain)
            DOMAIN="${2:-}"
            shift 2 ;;
        --ip)
            VM_IP="${2:-}"
            shift 2 ;;
        --vm-data-file)
            VM_DATA_FILE="${2:-}"
            shift 2 ;;
        --fw-rules-file)
            FW_RULES_FILE="${2:-}"
            shift 2 ;;
        --acl-rules-file)
            ACL_RULES_FILE="${2:-}"
            shift 2 ;;
        --restore-data-file)
            RESTORE_DATA_FILE="${2:-}"
            shift 2 ;;
        --action)
            ACTION_NAME="${2:-}"
            shift 2 ;;
        --action-params)
            ACTION_PARAMS="${2:-{}}"
            shift 2 ;;
        --lb-rules)
            # LB rules JSON (not used, but accept the argument)
            shift 2 ;;
        --options)
            # DHCP options JSON (not used, but accept the argument)
            shift 2 ;;
        --nic-id)
            NIC_ID="${2:-}"
            shift 2 ;;
        --userdata)
            USERDATA="${2:-}"
            shift 2 ;;
        --password)
            VM_PASSWORD="${2:-}"
            shift 2 ;;
        --sshkey)
            VM_SSHKEY="${2:-}"
            shift 2 ;;
        --hypervisor-hostname)
            HYPERVISOR_HOSTNAME="${2:-}"
            shift 2 ;;
        --vm-data)
            VM_DATA="${2:-}"
            shift 2 ;;
        --vmid)
            PROXMOX_VMID="${2:-}"
            shift 2 ;;
        *)
            FORWARD_ARGS+=("$1")
            shift ;;
    esac
done

# ---------------------------------------------------------------------------
# Read Proxmox connection details from physical-network extension details
# ---------------------------------------------------------------------------

PVE_URL=$(json_get "${PHYS_DETAILS}" "url")
PVE_USER=$(json_get "${PHYS_DETAILS}" "user")
PVE_TOKEN=$(json_get "${PHYS_DETAILS}" "token")
PVE_SECRET=$(json_get "${PHYS_DETAILS}" "secret")
PVE_NODE=$(json_get "${PHYS_DETAILS}" "node")
PVE_VERIFY_TLS=$(json_get "${PHYS_DETAILS}" "verify_tls_certificate")
PVE_VERIFY_TLS="${PVE_VERIFY_TLS:-true}"

SDN_ZONE_NAME=$(json_get "${PHYS_DETAILS}" "sdn.zone")
SDN_ZONE_TYPE=$(json_get "${PHYS_DETAILS}" "sdn.zone.type")
SDN_ZONE_TYPE="${SDN_ZONE_TYPE:-vlan}"
SDN_BRIDGE_PREFIX=$(json_get "${PHYS_DETAILS}" "sdn.bridge.prefix")
SDN_BRIDGE_PREFIX="${SDN_BRIDGE_PREFIX:-vnet}"

GW_NODE=$(json_get "${PHYS_DETAILS}" "gateway.node")
GW_NODE="${GW_NODE:-${PVE_NODE}}"
PUB_BRIDGE=$(json_get "${PHYS_DETAILS}" "public.bridge")
PUB_BRIDGE="${PUB_BRIDGE:-vmbr0}"

# VLAN zone bridge (physical bridge that carries VLAN trunks)
ZONE_BRIDGE=$(json_get "${PHYS_DETAILS}" "sdn.zone.bridge")
ZONE_BRIDGE="${ZONE_BRIDGE:-vmbr0}"

# Storage for cloud-init ISOs (must be an ISO-capable storage, e.g. "local")
CLOUDINIT_STORAGE=$(json_get "${PHYS_DETAILS}" "cloudinit.storage")
CLOUDINIT_STORAGE="${CLOUDINIT_STORAGE:-local}"

# ---------------------------------------------------------------------------
# Proxmox API helpers (reuse patterns from extensions/Proxmox/proxmox.sh)
# ---------------------------------------------------------------------------

call_proxmox_api() {
    local method="$1"
    local path="$2"
    local data="${3:-}"

    local curl_opts=(
        -s
        -w '\n%{http_code}'
        -X "${method}"
        -H "Authorization: PVEAPIToken=${PVE_USER}!${PVE_TOKEN}=${PVE_SECRET}"
    )

    if [ "${PVE_VERIFY_TLS}" = "false" ]; then
        curl_opts+=(-k)
    fi

    if [ -n "${data}" ]; then
        curl_opts+=(-d "${data}")
    fi

    local full_url="https://${PVE_URL}:8006/api2/json${path}"
    local response
    response=$(curl "${curl_opts[@]}" "${full_url}" 2>&1) || {
        log "API call failed: ${method} ${path} — curl error"
        echo ""
        return 1
    }

    # Split response body and HTTP status code
    local body http_code
    http_code=$(echo "${response}" | tail -1)
    body=$(echo "${response}" | sed '$d')

    if [ "${http_code}" -ge 200 ] && [ "${http_code}" -lt 300 ] 2>/dev/null; then
        echo "${body}"
        return 0
    elif [ "${http_code}" = "500" ] 2>/dev/null; then
        # 500 may indicate the resource already exists — check error message
        log "API ${method} ${path} returned HTTP ${http_code}: ${body}"
        echo "${body}"
        return 1
    else
        log "API ${method} ${path} returned HTTP ${http_code}: ${body}"
        echo "${body}"
        return 1
    fi
}

# api_get <path> → JSON body (exits on failure)
api_get() {
    call_proxmox_api GET "$1"
}

# api_post <path> [data] → JSON body (exits on failure)
api_post() {
    call_proxmox_api POST "$1" "${2:-}"
}

# api_put <path> [data] → JSON body
api_put() {
    call_proxmox_api PUT "$1" "${2:-}"
}

# api_delete <path> → JSON body
api_delete() {
    call_proxmox_api DELETE "$1"
}

# apply_sdn_changes — Apply pending SDN configuration changes
apply_sdn_changes() {
    log "Applying SDN configuration changes..."
    local resp
    resp=$(api_put "/cluster/sdn") || {
        log "WARNING: Failed to apply SDN changes (may require manual 'pvesh set /cluster/sdn')"
        return 0
    }
    log "SDN changes applied successfully"
    return 0
}

# ---------------------------------------------------------------------------
# VNet naming helpers
#
# Proxmox VNet names are limited to 8 characters (alphanumeric + dash).
# We generate deterministic short names from CloudStack network/VPC IDs.
#
# Isolated network:  cs<networkId>     e.g. cs42
# VPC tier:          vt<vpcId>x<netId> e.g. vt5x42  (truncated to 8 chars)
# VPC zone:          csz<vpcId>        e.g. csz5
# ---------------------------------------------------------------------------

vnet_name() {
    local net_id="$1"
    local vpc_id="${2:-}"
    if [ -n "${vpc_id}" ]; then
        local name="vt${vpc_id}n${net_id}"
    else
        local name="cs${net_id}"
    fi
    # Proxmox VNet names: max 8 chars, alphanumeric + dash, lowercase
    name=$(echo "${name}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
    echo "${name:0:8}"
}

# Zone name for a VPC (per-VPC VLAN zone)
vpc_zone_name() {
    local vpc_id="$1"
    local name="csz${vpc_id}"
    name=$(echo "${name}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
    echo "${name:0:8}"
}

# Zone name for isolated networks (shared VLAN zone)
isolated_zone_name() {
    if [ -n "${SDN_ZONE_NAME}" ]; then
        echo "${SDN_ZONE_NAME}"
    else
        echo "cszone"
    fi
}

# Subnet ID in Proxmox format: <vnet>-<cidr with / replaced by ->
subnet_id() {
    local vnet="$1"
    local cidr="$2"
    # Proxmox subnet format: <zone>-<cidr>  where cidr uses - instead of /
    local cidr_safe
    cidr_safe=$(echo "${cidr}" | tr '/' '-')
    echo "${vnet}-${cidr_safe}"
}

# ---------------------------------------------------------------------------
# SDN resource management helpers
# ---------------------------------------------------------------------------

# Ensure an SDN zone exists. Create it if not present.
ensure_sdn_zone() {
    local zone_name="$1"
    local zone_type="${2:-vlan}"
    local bridge="${3:-${ZONE_BRIDGE}}"

    log "ensure_sdn_zone: name=${zone_name} type=${zone_type} bridge=${bridge}"

    # Check if zone already exists
    local resp
    resp=$(api_get "/cluster/sdn/zones/${zone_name}" 2>/dev/null) && {
        log "SDN zone '${zone_name}' already exists"
        return 0
    }

    # Create the zone
    local data="zone=${zone_name}&type=${zone_type}"

    case "${zone_type}" in
        vlan)
            data+="&bridge=${bridge}"
            ;;
        simple)
            # Simple zones don't need a bridge or additional params
            ;;
        qinq)
            data+="&bridge=${bridge}"
            local service_vlan
            service_vlan=$(json_get "${PHYS_DETAILS}" "sdn.service.vlan")
            [ -n "${service_vlan}" ] && data+="&tag=${service_vlan}"
            ;;
    esac

    log "Creating SDN zone: ${data}"
    resp=$(api_post "/cluster/sdn/zones" "${data}") || {
        # Check if it failed because the zone already exists
        if echo "${resp}" | grep -qi "already exists"; then
            log "SDN zone '${zone_name}' already exists (race condition)"
            return 0
        fi
        log "WARNING: Failed to create SDN zone '${zone_name}': ${resp}"
        return 1
    }

    log "SDN zone '${zone_name}' created successfully"
    return 0
}

# Create a VNet in the specified zone
create_vnet() {
    local vnet_name="$1"
    local zone_name="$2"
    local tag="${3:-}"
    local alias="${4:-}"

    log "create_vnet: vnet=${vnet_name} zone=${zone_name} tag=${tag}"

    # Check if VNet already exists
    local resp
    resp=$(api_get "/cluster/sdn/vnets/${vnet_name}" 2>/dev/null) && {
        log "VNet '${vnet_name}' already exists"
        return 0
    }

    local data="vnet=${vnet_name}&zone=${zone_name}"
    [ -n "${tag}" ] && data+="&tag=${tag}"
    [ -n "${alias}" ] && data+="&alias=${alias}"

    resp=$(api_post "/cluster/sdn/vnets" "${data}") || {
        if echo "${resp}" | grep -qi "already exists"; then
            log "VNet '${vnet_name}' already exists (race condition)"
            return 0
        fi
        log "WARNING: Failed to create VNet '${vnet_name}': ${resp}"
        return 1
    }

    log "VNet '${vnet_name}' created successfully"
    return 0
}

# Delete a VNet
delete_vnet() {
    local vnet_name="$1"

    log "delete_vnet: vnet=${vnet_name}"

    api_delete "/cluster/sdn/vnets/${vnet_name}" || {
        log "WARNING: Failed to delete VNet '${vnet_name}' (may not exist)"
        return 0
    }

    log "VNet '${vnet_name}' deleted successfully"
    return 0
}

# Create a subnet within a VNet
create_subnet() {
    local vnet_name="$1"
    local cidr="$2"
    local gateway="${3:-}"
    local snat="${4:-0}"
    local dhcp_enable="${5:-0}"
    local dns="${6:-}"

    log "create_subnet: vnet=${vnet_name} cidr=${cidr} gw=${gateway} snat=${snat} dhcp=${dhcp_enable}"

    local subnet_cidr="${cidr}"
    local data="subnet=${subnet_cidr}&type=subnet"

    [ -n "${gateway}" ] && data+="&gateway=${gateway}"

    # SNAT: Proxmox subnet supports snat flag (boolean)
    if [ "${snat}" = "1" ] || [ "${snat}" = "true" ]; then
        data+="&snat=1"
    fi

    # DHCP: Proxmox can enable DHCP on the subnet
    if [ "${dhcp_enable}" = "1" ] || [ "${dhcp_enable}" = "true" ]; then
        # Proxmox SDN DHCP is enabled by specifying dhcp-range
        local net_addr prefix
        net_addr=$(echo "${cidr}" | cut -d'/' -f1)
        prefix=$(echo "${cidr}" | cut -d'/' -f2)
        # Calculate a reasonable DHCP range
        # Use the gateway as excluded, start from .2 or next available
        local dhcp_start dhcp_end
        dhcp_start=$(json_get "${PHYS_DETAILS}" "sdn.dhcp.start")
        dhcp_end=$(json_get "${PHYS_DETAILS}" "sdn.dhcp.end")
        if [ -n "${dhcp_start}" ] && [ -n "${dhcp_end}" ]; then
            data+="&dhcp-range=start-address=${dhcp_start},end-address=${dhcp_end}"
        fi
    fi

    [ -n "${dns}" ] && data+="&dnszoneprefix=${dns}"

    local resp
    resp=$(api_post "/cluster/sdn/vnets/${vnet_name}/subnets" "${data}") || {
        if echo "${resp}" | grep -qi "already exists"; then
            log "Subnet '${cidr}' already exists on VNet '${vnet_name}'"
            # Update existing subnet
            local sub_id
            sub_id=$(subnet_id "${vnet_name}" "${cidr}")
            local update_data=""
            [ -n "${gateway}" ] && update_data+="gateway=${gateway}"
            if [ "${snat}" = "1" ] || [ "${snat}" = "true" ]; then
                [ -n "${update_data}" ] && update_data+="&"
                update_data+="snat=1"
            fi
            if [ -n "${update_data}" ]; then
                api_put "/cluster/sdn/vnets/${vnet_name}/subnets/${sub_id}" "${update_data}" || true
            fi
            return 0
        fi
        log "WARNING: Failed to create subnet '${cidr}' on VNet '${vnet_name}': ${resp}"
        return 1
    }

    log "Subnet '${cidr}' created on VNet '${vnet_name}'"
    return 0
}

# Delete a subnet from a VNet
delete_subnet() {
    local vnet_name="$1"
    local cidr="$2"

    local sub_id
    sub_id=$(subnet_id "${vnet_name}" "${cidr}")
    log "delete_subnet: vnet=${vnet_name} subnet=${sub_id}"

    api_delete "/cluster/sdn/vnets/${vnet_name}/subnets/${sub_id}" || {
        log "WARNING: Failed to delete subnet '${sub_id}' (may not exist)"
        return 0
    }

    log "Subnet '${sub_id}' deleted from VNet '${vnet_name}'"
    return 0
}

# Delete an SDN zone
delete_sdn_zone() {
    local zone_name="$1"

    log "delete_sdn_zone: zone=${zone_name}"

    api_delete "/cluster/sdn/zones/${zone_name}" || {
        log "WARNING: Failed to delete SDN zone '${zone_name}' (may not exist or have VNets)"
        return 0
    }

    log "SDN zone '${zone_name}' deleted"
    return 0
}

# ---------------------------------------------------------------------------
# Proxmox firewall helpers (for NAT/firewall rules on nodes)
#
# Proxmox SDN subnets can handle SNAT natively when the snat flag is set.
# For DNAT (static NAT, port forwarding), and for fine-grained firewall
# control, we use iptables on the gateway node via the Proxmox API's
# node exec endpoint or SSH.
# ---------------------------------------------------------------------------

# Execute a command on a Proxmox node via the API
# Uses /nodes/{node}/execute (if available) or falls back to SSH
node_exec() {
    local node="$1"
    local cmd="$2"

    log "node_exec: node=${node} cmd=${cmd}"

    # Try the Proxmox API execute endpoint first (PVE 8.x+)
    local resp
    resp=$(api_post "/nodes/${node}/execute" "command=$(urlencode "${cmd}")") 2>/dev/null && {
        echo "${resp}" | jq -r '.data // empty' 2>/dev/null || echo "${resp}"
        return 0
    }

    # Fallback: SSH to the node
    local node_ip
    node_ip=$(json_get "${PHYS_DETAILS}" "gateway.ip")
    if [ -z "${node_ip}" ]; then
        node_ip="${PVE_URL}"
    fi

    local ssh_user
    ssh_user=$(json_get "${PHYS_DETAILS}" "ssh.user")
    ssh_user="${ssh_user:-root}"

    local ssh_key
    ssh_key=$(json_get "${PHYS_DETAILS}" "ssh.key")

    local ssh_opts=(
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o LogLevel=ERROR
        -o ConnectTimeout=10
    )

    if [ -n "${ssh_key}" ]; then
        local keyfile
        keyfile=$(mktemp /tmp/.cs-pvesdn-key-XXXXXX)
        chmod 600 "${keyfile}"
        printf '%s\n' "${ssh_key}" > "${keyfile}"
        ssh_opts+=(-i "${keyfile}" -o IdentitiesOnly=yes -o BatchMode=yes)
        ssh "${ssh_opts[@]}" "${ssh_user}@${node_ip}" "${cmd}"
        local rc=$?
        rm -f "${keyfile}"
        return ${rc}
    else
        ssh "${ssh_opts[@]}" "${ssh_user}@${node_ip}" "${cmd}" 2>/dev/null
        return $?
    fi
}

urlencode() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import urllib.parse; print(urllib.parse.quote('''$1'''))"
    else
        echo "$1"
    fi
}

# ---------------------------------------------------------------------------
# NAT rule management on the gateway node
#
# We manage SNAT/DNAT/firewall rules via iptables on the gateway node.
# Rules are placed in dedicated chains to avoid conflicts with Proxmox's
# own firewall.
#
# Chain naming:
#   CS_PVE_SDN_<networkId>_PR    – PREROUTING DNAT
#   CS_PVE_SDN_<networkId>_POST  – POSTROUTING SNAT
#   CS_PVE_SDN_FWD_<networkId>   – FORWARD filter
# ---------------------------------------------------------------------------

CHAIN_PREFIX="CS_PVE_SDN"

nat_chain_pr()   { echo "${CHAIN_PREFIX}_${1}_PR"; }
nat_chain_post() { echo "${CHAIN_PREFIX}_${1}_POST"; }
filter_chain()   { echo "${CHAIN_PREFIX}_FWD_${1}"; }
fw_chain()       { echo "${CHAIN_PREFIX}_FW_${1}"; }

# Ensure iptables chain exists and is jumped to from parent
ensure_iptables_chain() {
    local node="$1" table="$2" chain="$3" parent="$4"

    node_exec "${node}" "iptables -t ${table} -n -L ${chain} >/dev/null 2>&1 || iptables -t ${table} -N ${chain}" || true
    node_exec "${node}" "iptables -t ${table} -C ${parent} -j ${chain} 2>/dev/null || iptables -t ${table} -I ${parent} 1 -j ${chain}" || true
}

# Setup per-network iptables chains on the gateway node
setup_network_chains() {
    local node="$1" net_id="$2"

    local pr_chain post_chain fwd_chain
    pr_chain=$(nat_chain_pr "${net_id}")
    post_chain=$(nat_chain_post "${net_id}")
    fwd_chain=$(filter_chain "${net_id}")

    ensure_iptables_chain "${node}" nat "${pr_chain}" PREROUTING
    ensure_iptables_chain "${node}" nat "${post_chain}" POSTROUTING
    ensure_iptables_chain "${node}" filter "${fwd_chain}" FORWARD

    log "setup_network_chains: created chains for network ${net_id} on ${node}"
}

# Remove per-network iptables chains from the gateway node
cleanup_network_chains() {
    local node="$1" net_id="$2"

    local pr_chain post_chain fwd_chain
    pr_chain=$(nat_chain_pr "${net_id}")
    post_chain=$(nat_chain_post "${net_id}")
    fwd_chain=$(filter_chain "${net_id}")

    # Remove jumps
    node_exec "${node}" "iptables -t nat -D PREROUTING -j ${pr_chain} 2>/dev/null; true" || true
    node_exec "${node}" "iptables -t nat -D POSTROUTING -j ${post_chain} 2>/dev/null; true" || true
    node_exec "${node}" "iptables -t filter -D FORWARD -j ${fwd_chain} 2>/dev/null; true" || true

    # Flush and delete chains
    node_exec "${node}" "iptables -t nat -F ${pr_chain} 2>/dev/null; iptables -t nat -X ${pr_chain} 2>/dev/null; true" || true
    node_exec "${node}" "iptables -t nat -F ${post_chain} 2>/dev/null; iptables -t nat -X ${post_chain} 2>/dev/null; true" || true
    node_exec "${node}" "iptables -t filter -F ${fwd_chain} 2>/dev/null; iptables -t filter -X ${fwd_chain} 2>/dev/null; true" || true

    log "cleanup_network_chains: removed chains for network ${net_id} on ${node}"
}

# ---------------------------------------------------------------------------
# State management
# ---------------------------------------------------------------------------

_net_state_dir() { echo "${STATE_DIR}/network-${NETWORK_ID}"; }
_vpc_state_dir() {
    if [ -n "${VPC_ID}" ]; then
        echo "${STATE_DIR}/vpc-${VPC_ID}"
    else
        echo "${STATE_DIR}/network-${NETWORK_ID}"
    fi
}

save_state() {
    local dir="$1" key="$2" value="$3"
    mkdir -p "${dir}"
    echo "${value}" > "${dir}/${key}"
}

read_state() {
    local dir="$1" key="$2" default="${3:-}"
    if [ -f "${dir}/${key}" ]; then
        cat "${dir}/${key}"
    else
        echo "${default}"
    fi
}

# ---------------------------------------------------------------------------
# Load persisted state
# ---------------------------------------------------------------------------

_load_state() {
    local nsd; nsd=$(_net_state_dir)
    local vsd; vsd=$(_vpc_state_dir)

    [ -z "${VLAN}" ] && VLAN=$(read_state "${nsd}" vlan "")
    [ -z "${CIDR}" ] && CIDR=$(read_state "${nsd}" cidr "")
    [ -z "${GATEWAY}" ] && GATEWAY=$(read_state "${nsd}" gateway "")

    # Load VNet and zone names from state
    STORED_VNET=$(read_state "${nsd}" vnet "")
    STORED_ZONE=$(read_state "${vsd}" zone "")
}

##############################################################################
# Command: ensure-network-device
#
# Validate Proxmox SDN API connectivity and return the network device details.
# For isolated networks: ensure the shared VLAN zone exists.
# For VPC networks: the zone is created by implement-vpc.
##############################################################################

if [ "${COMMAND}" = "ensure-network-device" ]; then
    [ -z "${NETWORK_ID}" ] && [ -z "${VPC_ID}" ] && \
        die "ensure-network-device: missing --network-id or --vpc-id" 1

    # Validate required connection details
    if [ -z "${PVE_URL}" ] || [ -z "${PVE_USER}" ] || [ -z "${PVE_TOKEN}" ] || [ -z "${PVE_SECRET}" ]; then
        die "ensure-network-device: missing Proxmox API credentials. Set url, user, token, secret in extension details." 1
    fi

    # Test API connectivity by querying the SDN status
    log "ensure-network-device: testing Proxmox SDN API at ${PVE_URL}..."
    resp=$(api_get "/cluster/sdn" 2>/dev/null) || {
        die "ensure-network-device: cannot reach Proxmox SDN API at https://${PVE_URL}:8006" 2
    }
    log "ensure-network-device: Proxmox SDN API is reachable"

    # Determine the zone name
    if [ -n "${VPC_ID}" ]; then
        zone=$(vpc_zone_name "${VPC_ID}")
    else
        zone=$(isolated_zone_name)
    fi

    # Determine VNet name
    vnet=$(vnet_name "${NETWORK_ID:-0}" "${VPC_ID}")

    # Return device details
    if [ -n "${VPC_ID}" ]; then
        printf '{"zone":"%s","vnet":"%s","node":"%s","vpc_id":"%s"}\n' \
            "${zone}" "${vnet}" "${GW_NODE}" "${VPC_ID}"
    else
        printf '{"zone":"%s","vnet":"%s","node":"%s"}\n' \
            "${zone}" "${vnet}" "${GW_NODE}"
    fi

    log "ensure-network-device: ${NETWORK_ID:+network=${NETWORK_ID} }${VPC_ID:+vpc=${VPC_ID} }zone=${zone} vnet=${vnet} node=${GW_NODE}"
    exit 0
fi

##############################################################################
# Command: implement-network
#
# 1. Ensure the SDN zone exists (VLAN zone for isolated, per-VPC zone for VPC)
# 2. Create a VNet with the VLAN tag
# 3. Create a subnet with gateway and CIDR
# 4. Apply SDN changes
# 5. Set up iptables chains on the gateway node for NAT/firewall
##############################################################################

if [ "${COMMAND}" = "implement-network" ]; then
    [ -z "${NETWORK_ID}" ] && die "implement-network: missing --network-id" 1

    log "implement-network: network=${NETWORK_ID} vlan=${VLAN} gw=${GATEWAY} cidr=${CIDR} vpc=${VPC_ID}"

    # Determine zone and VNet names
    if [ -n "${VPC_ID}" ]; then
        zone=$(vpc_zone_name "${VPC_ID}")
    else
        zone=$(isolated_zone_name)
    fi
    vnet=$(vnet_name "${NETWORK_ID}" "${VPC_ID}")

    # Step 1: Ensure the SDN zone exists
    if [ -z "${VPC_ID}" ]; then
        # Isolated network: use shared VLAN zone
        ensure_sdn_zone "${zone}" "${SDN_ZONE_TYPE}" "${ZONE_BRIDGE}" || \
            die "implement-network: failed to create SDN zone '${zone}'" 3
    fi
    # For VPC tiers, the zone is created by implement-vpc

    # Step 2: Create VNet with VLAN tag
    local tag="${VLAN}"
    # Strip "vlan://" prefix if present
    tag="${tag#vlan://}"
    local alias_name="CloudStack network ${NETWORK_ID}"
    create_vnet "${vnet}" "${zone}" "${tag}" "${alias_name}" || \
        die "implement-network: failed to create VNet '${vnet}'" 3

    # Step 3: Create subnet with gateway and CIDR
    if [ -n "${CIDR}" ]; then
        local snat_flag="0"
        # Enable SNAT on subnet for isolated networks with SourceNat
        # (For VPC networks, SNAT is managed at VPC level)
        if [ -z "${VPC_ID}" ]; then
            snat_flag="1"
        fi

        create_subnet "${vnet}" "${CIDR}" "${GATEWAY}" "${snat_flag}" "0" "" || \
            log "WARNING: Failed to create subnet — may already exist"
    fi

    # Step 4: Apply SDN changes
    apply_sdn_changes

    # Step 5: Set up iptables chains on the gateway node (for DNAT/firewall)
    if [ -n "${GW_NODE}" ]; then
        setup_network_chains "${GW_NODE}" "${NETWORK_ID}" || \
            log "WARNING: Failed to set up iptables chains on ${GW_NODE}"
    fi

    # Enable IP forwarding on the gateway node
    if [ -n "${GW_NODE}" ]; then
        node_exec "${GW_NODE}" "sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1" || true
    fi

    # Step 6: Persist state
    local nsd; nsd=$(_net_state_dir)
    local vsd; vsd=$(_vpc_state_dir)
    mkdir -p "${nsd}" "${vsd}"
    save_state "${nsd}" vlan "${VLAN}"
    save_state "${nsd}" cidr "${CIDR}"
    save_state "${nsd}" gateway "${GATEWAY}"
    save_state "${nsd}" vnet "${vnet}"
    save_state "${nsd}" zone "${zone}"
    save_state "${vsd}" zone "${zone}"

    if [ -n "${VPC_ID}" ]; then
        mkdir -p "${vsd}/tiers"
        touch "${vsd}/tiers/${NETWORK_ID}"
    fi

    log "implement-network: done network=${NETWORK_ID} vnet=${vnet} zone=${zone}"
    exit 0
fi

##############################################################################
# Command: shutdown-network
#
# Remove the subnet and VNet from Proxmox SDN.
# Clean up iptables chains on the gateway node.
# For VPC tier networks, the zone is preserved.
##############################################################################

if [ "${COMMAND}" = "shutdown-network" ]; then
    [ -z "${NETWORK_ID}" ] && die "shutdown-network: missing --network-id" 1
    _load_state

    log "shutdown-network: network=${NETWORK_ID} vnet=${STORED_VNET} vpc=${VPC_ID}"

    # Clean up iptables chains on the gateway node
    if [ -n "${GW_NODE}" ]; then
        cleanup_network_chains "${GW_NODE}" "${NETWORK_ID}" || true
    fi

    # Remove subnet from VNet
    if [ -n "${STORED_VNET}" ] && [ -n "${CIDR}" ]; then
        delete_subnet "${STORED_VNET}" "${CIDR}" || true
    fi

    # Remove the VNet
    if [ -n "${STORED_VNET}" ]; then
        delete_vnet "${STORED_VNET}" || true
    fi

    # Apply SDN changes
    apply_sdn_changes

    # For isolated networks, clean up state fully
    if [ -z "${VPC_ID}" ]; then
        rm -rf "$(_net_state_dir)" 2>/dev/null || true
    else
        # VPC tier: remove from tier list
        local vsd; vsd=$(_vpc_state_dir)
        rm -f "${vsd}/tiers/${NETWORK_ID}" 2>/dev/null || true
    fi

    log "shutdown-network: done network=${NETWORK_ID}"
    exit 0
fi

##############################################################################
# Command: destroy-network
#
# Permanently remove the VNet and all associated state.
##############################################################################

if [ "${COMMAND}" = "destroy-network" ]; then
    [ -z "${NETWORK_ID}" ] && die "destroy-network: missing --network-id" 1
    _load_state

    log "destroy-network: network=${NETWORK_ID} vnet=${STORED_VNET} vpc=${VPC_ID}"

    # Clean up iptables chains on the gateway node
    if [ -n "${GW_NODE}" ]; then
        cleanup_network_chains "${GW_NODE}" "${NETWORK_ID}" || true
    fi

    # Remove subnet
    if [ -n "${STORED_VNET}" ] && [ -n "${CIDR}" ]; then
        delete_subnet "${STORED_VNET}" "${CIDR}" || true
    fi

    # Remove VNet
    if [ -n "${STORED_VNET}" ]; then
        delete_vnet "${STORED_VNET}" || true
    fi

    # Apply SDN changes
    apply_sdn_changes

    # Remove per-network state
    rm -rf "$(_net_state_dir)" 2>/dev/null || true

    # VPC tier cleanup
    if [ -n "${VPC_ID}" ]; then
        local vsd; vsd=$(_vpc_state_dir)
        rm -f "${vsd}/tiers/${NETWORK_ID}" 2>/dev/null || true
    fi

    log "destroy-network: done network=${NETWORK_ID}"
    exit 0
fi

##############################################################################
# Command: implement-vpc
#
# Create a per-VPC VLAN zone.
# Set up VPC-level source NAT if requested.
##############################################################################

if [ "${COMMAND}" = "implement-vpc" ]; then
    [ -z "${VPC_ID}" ] && die "implement-vpc: missing --vpc-id" 1

    log "implement-vpc: vpc=${VPC_ID} cidr=${CIDR} source_nat=${SOURCE_NAT} public_ip=${PUBLIC_IP}"

    local zone
    zone=$(vpc_zone_name "${VPC_ID}")

    # Use the configured zone type for VPC (defaults to vlan)
    local vpc_zone_type="${SDN_ZONE_TYPE}"

    # Create VPC zone
    ensure_sdn_zone "${zone}" "${vpc_zone_type}" "${ZONE_BRIDGE}" || \
        die "implement-vpc: failed to create SDN zone '${zone}'" 3

    # Apply SDN changes
    apply_sdn_changes

    # Set up VPC-level source NAT on the gateway node
    if [ "${SOURCE_NAT}" = "true" ] && [ -n "${PUBLIC_IP}" ] && [ -n "${CIDR}" ] && [ -n "${GW_NODE}" ]; then
        local post_chain
        post_chain="${CHAIN_PREFIX}_${VPC_ID}_VPC_POST"

        # Ensure the chain exists
        ensure_iptables_chain "${GW_NODE}" nat "${post_chain}" POSTROUTING

        # Add SNAT rule for VPC CIDR
        local pub_vlan="${PUBLIC_VLAN}"
        pub_vlan="${pub_vlan#vlan://}"

        node_exec "${GW_NODE}" "iptables -t nat -C ${post_chain} -s ${CIDR} -j SNAT --to-source ${PUBLIC_IP} 2>/dev/null || \
            iptables -t nat -A ${post_chain} -s ${CIDR} -j SNAT --to-source ${PUBLIC_IP}" || true

        log "implement-vpc: SNAT configured: ${CIDR} -> ${PUBLIC_IP} on ${GW_NODE}"
    fi

    # Persist VPC state
    local vsd; vsd=$(_vpc_state_dir)
    mkdir -p "${vsd}"
    save_state "${vsd}" zone "${zone}"
    [ -n "${CIDR}" ] && save_state "${vsd}" cidr "${CIDR}"

    log "implement-vpc: done vpc=${VPC_ID} zone=${zone}"
    exit 0
fi

##############################################################################
# Command: shutdown-vpc
#
# Remove the VPC namespace (zone) if no tiers remain.
##############################################################################

if [ "${COMMAND}" = "shutdown-vpc" ]; then
    [ -z "${VPC_ID}" ] && die "shutdown-vpc: missing --vpc-id" 1

    log "shutdown-vpc: vpc=${VPC_ID}"

    local vsd; vsd=$(_vpc_state_dir)
    local zone
    zone=$(read_state "${vsd}" zone "$(vpc_zone_name "${VPC_ID}")")

    # Clean up VPC-level SNAT chain on gateway node
    if [ -n "${GW_NODE}" ]; then
        local post_chain="${CHAIN_PREFIX}_${VPC_ID}_VPC_POST"
        node_exec "${GW_NODE}" "iptables -t nat -D POSTROUTING -j ${post_chain} 2>/dev/null; true" || true
        node_exec "${GW_NODE}" "iptables -t nat -F ${post_chain} 2>/dev/null; iptables -t nat -X ${post_chain} 2>/dev/null; true" || true
    fi

    # Delete the VPC SDN zone (will fail if VNets still exist)
    delete_sdn_zone "${zone}" || true

    # Apply SDN changes
    apply_sdn_changes

    log "shutdown-vpc: done vpc=${VPC_ID}"
    exit 0
fi

##############################################################################
# Command: destroy-vpc
#
# Permanently remove the VPC zone and all state.
##############################################################################

if [ "${COMMAND}" = "destroy-vpc" ]; then
    [ -z "${VPC_ID}" ] && die "destroy-vpc: missing --vpc-id" 1

    log "destroy-vpc: vpc=${VPC_ID}"

    local vsd; vsd=$(_vpc_state_dir)
    local zone
    zone=$(read_state "${vsd}" zone "$(vpc_zone_name "${VPC_ID}")")

    # Clean up VPC-level SNAT chain on gateway node
    if [ -n "${GW_NODE}" ]; then
        local post_chain="${CHAIN_PREFIX}_${VPC_ID}_VPC_POST"
        node_exec "${GW_NODE}" "iptables -t nat -D POSTROUTING -j ${post_chain} 2>/dev/null; true" || true
        node_exec "${GW_NODE}" "iptables -t nat -F ${post_chain} 2>/dev/null; iptables -t nat -X ${post_chain} 2>/dev/null; true" || true
    fi

    # Delete the VPC SDN zone
    delete_sdn_zone "${zone}" || true

    # Apply SDN changes
    apply_sdn_changes

    # Remove VPC state
    rm -rf "${vsd}" 2>/dev/null || true

    log "destroy-vpc: done vpc=${VPC_ID}"
    exit 0
fi

##############################################################################
# Command: assign-ip
#
# Assign a public IP address. For source NAT, configure SNAT on the
# gateway node.
##############################################################################

if [ "${COMMAND}" = "assign-ip" ]; then
    [ -z "${NETWORK_ID}" ] && die "assign-ip: missing --network-id" 1
    [ -z "${PUBLIC_IP}" ] && die "assign-ip: missing --public-ip" 1
    _load_state

    log "assign-ip: network=${NETWORK_ID} ip=${PUBLIC_IP} source_nat=${SOURCE_NAT} vpc=${VPC_ID}"

    if [ -n "${GW_NODE}" ]; then
        local post_chain fwd_chain
        post_chain=$(nat_chain_post "${NETWORK_ID}")
        fwd_chain=$(filter_chain "${NETWORK_ID}")

        # Ensure chains exist
        setup_network_chains "${GW_NODE}" "${NETWORK_ID}" || true

        # Assign the public IP to the public bridge on the gateway node
        if [ -n "${PUBLIC_CIDR}" ] && echo "${PUBLIC_CIDR}" | grep -q '/'; then
            local prefix
            prefix=$(echo "${PUBLIC_CIDR}" | cut -d'/' -f2)
            node_exec "${GW_NODE}" "ip addr show dev ${PUB_BRIDGE} | grep -q '${PUBLIC_IP}/' || \
                ip addr add ${PUBLIC_IP}/${prefix} dev ${PUB_BRIDGE}" || true
        else
            node_exec "${GW_NODE}" "ip addr show dev ${PUB_BRIDGE} | grep -q '${PUBLIC_IP}/' || \
                ip addr add ${PUBLIC_IP}/32 dev ${PUB_BRIDGE}" || true
        fi

        # Set default route via public gateway if provided
        if [ -n "${PUBLIC_GATEWAY}" ]; then
            node_exec "${GW_NODE}" "ip route replace default via ${PUBLIC_GATEWAY} dev ${PUB_BRIDGE} 2>/dev/null || true" || true
        fi

        # Source NAT: add SNAT rule for isolated networks
        if [ "${SOURCE_NAT}" = "true" ] && [ -n "${CIDR}" ] && [ -z "${VPC_ID}" ]; then
            node_exec "${GW_NODE}" "iptables -t nat -C ${post_chain} -s ${CIDR} -j SNAT --to-source ${PUBLIC_IP} 2>/dev/null || \
                iptables -t nat -A ${post_chain} -s ${CIDR} -j SNAT --to-source ${PUBLIC_IP}" || true

            node_exec "${GW_NODE}" "iptables -t filter -C ${fwd_chain} -s ${CIDR} -j ACCEPT 2>/dev/null || \
                iptables -t filter -A ${fwd_chain} -s ${CIDR} -j ACCEPT" || true

            log "assign-ip: SNAT configured: ${CIDR} -> ${PUBLIC_IP}"
        fi

        # Send gratuitous ARP
        node_exec "${GW_NODE}" "arping -c 3 -U -I ${PUB_BRIDGE} ${PUBLIC_IP} >/dev/null 2>&1 || true" || true
    fi

    # Persist public IP state
    local vsd; vsd=$(_vpc_state_dir)
    mkdir -p "${vsd}/ips"
    save_state "${vsd}/ips" "${PUBLIC_IP}" "${SOURCE_NAT}"
    save_state "${vsd}/ips" "${PUBLIC_IP}.pvlan" "${PUBLIC_VLAN}"
    save_state "${vsd}/ips" "${PUBLIC_IP}.tier" "${NETWORK_ID}"

    log "assign-ip: done ${PUBLIC_IP} on network ${NETWORK_ID}"
    exit 0
fi

##############################################################################
# Command: release-ip
#
# Release a public IP address. Remove SNAT rules.
##############################################################################

if [ "${COMMAND}" = "release-ip" ]; then
    [ -z "${NETWORK_ID}" ] && die "release-ip: missing --network-id" 1
    [ -z "${PUBLIC_IP}" ] && die "release-ip: missing --public-ip" 1
    _load_state

    log "release-ip: network=${NETWORK_ID} ip=${PUBLIC_IP}"

    if [ -n "${GW_NODE}" ]; then
        local post_chain fwd_chain pr_chain
        post_chain=$(nat_chain_post "${NETWORK_ID}")
        fwd_chain=$(filter_chain "${NETWORK_ID}")
        pr_chain=$(nat_chain_pr "${NETWORK_ID}")

        # Remove SNAT rule
        if [ -n "${CIDR}" ]; then
            node_exec "${GW_NODE}" "iptables -t nat -D ${post_chain} -s ${CIDR} -j SNAT --to-source ${PUBLIC_IP} 2>/dev/null || true" || true
            node_exec "${GW_NODE}" "iptables -t filter -D ${fwd_chain} -s ${CIDR} -j ACCEPT 2>/dev/null || true" || true
        fi

        # Remove all DNAT rules for this public IP
        node_exec "${GW_NODE}" "iptables -t nat -S ${pr_chain} 2>/dev/null | grep -- '-d ${PUBLIC_IP}' | while read rule; do \
            iptables -t nat -D ${pr_chain} \${rule#-A ${pr_chain}} 2>/dev/null || true; done" || true

        # Remove IP from public bridge
        node_exec "${GW_NODE}" "ip addr del ${PUBLIC_IP}/32 dev ${PUB_BRIDGE} 2>/dev/null || \
            ip addr show dev ${PUB_BRIDGE} | grep '${PUBLIC_IP}/' | awk '{print \$2}' | \
            xargs -I{} ip addr del {} dev ${PUB_BRIDGE} 2>/dev/null || true" || true
    fi

    # Remove state
    local vsd; vsd=$(_vpc_state_dir)
    rm -f "${vsd}/ips/${PUBLIC_IP}" \
          "${vsd}/ips/${PUBLIC_IP}.pvlan" \
          "${vsd}/ips/${PUBLIC_IP}.tier" 2>/dev/null || true

    log "release-ip: done ${PUBLIC_IP} on network ${NETWORK_ID}"
    exit 0
fi

##############################################################################
# Command: add-static-nat
#
# Configure 1:1 NAT (DNAT + SNAT) for a public IP ↔ private IP.
##############################################################################

if [ "${COMMAND}" = "add-static-nat" ]; then
    [ -z "${NETWORK_ID}" ] && die "add-static-nat: missing --network-id" 1
    [ -z "${PUBLIC_IP}" ] && die "add-static-nat: missing --public-ip" 1
    [ -z "${PRIVATE_IP}" ] && die "add-static-nat: missing --private-ip" 1
    _load_state

    log "add-static-nat: network=${NETWORK_ID} ${PUBLIC_IP} <-> ${PRIVATE_IP}"

    if [ -n "${GW_NODE}" ]; then
        local pr_chain post_chain fwd_chain
        pr_chain=$(nat_chain_pr "${NETWORK_ID}")
        post_chain=$(nat_chain_post "${NETWORK_ID}")
        fwd_chain=$(filter_chain "${NETWORK_ID}")

        # DNAT: inbound public IP → private IP
        node_exec "${GW_NODE}" "iptables -t nat -C ${pr_chain} -d ${PUBLIC_IP} -j DNAT --to-destination ${PRIVATE_IP} 2>/dev/null || \
            iptables -t nat -A ${pr_chain} -d ${PUBLIC_IP} -j DNAT --to-destination ${PRIVATE_IP}" || true

        # SNAT: outbound private IP → public IP
        node_exec "${GW_NODE}" "iptables -t nat -C ${post_chain} -s ${PRIVATE_IP} -j SNAT --to-source ${PUBLIC_IP} 2>/dev/null || \
            iptables -t nat -A ${post_chain} -s ${PRIVATE_IP} -j SNAT --to-source ${PUBLIC_IP}" || true

        # FORWARD: allow traffic to/from private IP
        node_exec "${GW_NODE}" "iptables -t filter -C ${fwd_chain} -d ${PRIVATE_IP} -j ACCEPT 2>/dev/null || \
            iptables -t filter -A ${fwd_chain} -d ${PRIVATE_IP} -j ACCEPT" || true
        node_exec "${GW_NODE}" "iptables -t filter -C ${fwd_chain} -s ${PRIVATE_IP} -j ACCEPT 2>/dev/null || \
            iptables -t filter -A ${fwd_chain} -s ${PRIVATE_IP} -j ACCEPT" || true
    fi

    # Persist state
    local vsd; vsd=$(_vpc_state_dir)
    mkdir -p "${vsd}/static-nat"
    save_state "${vsd}/static-nat" "${PUBLIC_IP}" "${PRIVATE_IP}"

    log "add-static-nat: done ${PUBLIC_IP} <-> ${PRIVATE_IP}"
    exit 0
fi

##############################################################################
# Command: delete-static-nat
##############################################################################

if [ "${COMMAND}" = "delete-static-nat" ]; then
    [ -z "${NETWORK_ID}" ] && die "delete-static-nat: missing --network-id" 1
    [ -z "${PUBLIC_IP}" ] && die "delete-static-nat: missing --public-ip" 1
    _load_state

    # Load private IP from state if not provided
    local vsd; vsd=$(_vpc_state_dir)
    if [ -z "${PRIVATE_IP}" ] && [ -f "${vsd}/static-nat/${PUBLIC_IP}" ]; then
        PRIVATE_IP=$(cat "${vsd}/static-nat/${PUBLIC_IP}")
    fi
    [ -z "${PRIVATE_IP}" ] && die "delete-static-nat: missing --private-ip and no saved state" 1

    log "delete-static-nat: network=${NETWORK_ID} ${PUBLIC_IP} <-> ${PRIVATE_IP}"

    if [ -n "${GW_NODE}" ]; then
        local pr_chain post_chain fwd_chain
        pr_chain=$(nat_chain_pr "${NETWORK_ID}")
        post_chain=$(nat_chain_post "${NETWORK_ID}")
        fwd_chain=$(filter_chain "${NETWORK_ID}")

        node_exec "${GW_NODE}" "iptables -t nat -D ${pr_chain} -d ${PUBLIC_IP} -j DNAT --to-destination ${PRIVATE_IP} 2>/dev/null || true" || true
        node_exec "${GW_NODE}" "iptables -t nat -D ${post_chain} -s ${PRIVATE_IP} -j SNAT --to-source ${PUBLIC_IP} 2>/dev/null || true" || true
        node_exec "${GW_NODE}" "iptables -t filter -D ${fwd_chain} -d ${PRIVATE_IP} -j ACCEPT 2>/dev/null || true" || true
        node_exec "${GW_NODE}" "iptables -t filter -D ${fwd_chain} -s ${PRIVATE_IP} -j ACCEPT 2>/dev/null || true" || true
    fi

    rm -f "${vsd}/static-nat/${PUBLIC_IP}" 2>/dev/null || true

    log "delete-static-nat: done ${PUBLIC_IP} <-> ${PRIVATE_IP}"
    exit 0
fi

##############################################################################
# Command: add-port-forward
##############################################################################

if [ "${COMMAND}" = "add-port-forward" ]; then
    [ -z "${NETWORK_ID}" ] && die "add-port-forward: missing --network-id" 1
    [ -z "${PUBLIC_IP}" ] && die "add-port-forward: missing --public-ip" 1
    [ -z "${PUBLIC_PORT}" ] && die "add-port-forward: missing --public-port" 1
    [ -z "${PRIVATE_IP}" ] && die "add-port-forward: missing --private-ip" 1
    [ -z "${PRIVATE_PORT}" ] && die "add-port-forward: missing --private-port" 1
    _load_state
    [ -z "${PROTOCOL}" ] && PROTOCOL="tcp"

    log "add-port-forward: network=${NETWORK_ID} ${PUBLIC_IP}:${PUBLIC_PORT} -> ${PRIVATE_IP}:${PRIVATE_PORT} (${PROTOCOL})"

    if [ -n "${GW_NODE}" ]; then
        local pr_chain fwd_chain
        pr_chain=$(nat_chain_pr "${NETWORK_ID}")
        fwd_chain=$(filter_chain "${NETWORK_ID}")

        # DNAT
        node_exec "${GW_NODE}" "iptables -t nat -C ${pr_chain} -p ${PROTOCOL} -d ${PUBLIC_IP} --dport ${PUBLIC_PORT} \
            -j DNAT --to-destination ${PRIVATE_IP}:${PRIVATE_PORT} 2>/dev/null || \
            iptables -t nat -A ${pr_chain} -p ${PROTOCOL} -d ${PUBLIC_IP} --dport ${PUBLIC_PORT} \
            -j DNAT --to-destination ${PRIVATE_IP}:${PRIVATE_PORT}" || true

        # FORWARD
        node_exec "${GW_NODE}" "iptables -t filter -C ${fwd_chain} -p ${PROTOCOL} -d ${PRIVATE_IP} --dport ${PRIVATE_PORT} -j ACCEPT 2>/dev/null || \
            iptables -t filter -A ${fwd_chain} -p ${PROTOCOL} -d ${PRIVATE_IP} --dport ${PRIVATE_PORT} -j ACCEPT" || true
        node_exec "${GW_NODE}" "iptables -t filter -C ${fwd_chain} -p ${PROTOCOL} -s ${PRIVATE_IP} --sport ${PRIVATE_PORT} -j ACCEPT 2>/dev/null || \
            iptables -t filter -A ${fwd_chain} -p ${PROTOCOL} -s ${PRIVATE_IP} --sport ${PRIVATE_PORT} -j ACCEPT" || true
    fi

    # Persist state
    local safe_port
    safe_port=$(echo "${PUBLIC_PORT}" | tr ':' '-')
    local vsd; vsd=$(_vpc_state_dir)
    mkdir -p "${vsd}/port-forward"
    echo "${PROTOCOL} ${PUBLIC_IP} ${PUBLIC_PORT} ${PRIVATE_IP} ${PRIVATE_PORT}" > \
        "${vsd}/port-forward/${PROTOCOL}_${PUBLIC_IP}_${safe_port}"

    log "add-port-forward: done ${PUBLIC_IP}:${PUBLIC_PORT} -> ${PRIVATE_IP}:${PRIVATE_PORT}"
    exit 0
fi

##############################################################################
# Command: delete-port-forward
##############################################################################

if [ "${COMMAND}" = "delete-port-forward" ]; then
    [ -z "${NETWORK_ID}" ] && die "delete-port-forward: missing --network-id" 1
    [ -z "${PUBLIC_IP}" ] && die "delete-port-forward: missing --public-ip" 1
    [ -z "${PUBLIC_PORT}" ] && die "delete-port-forward: missing --public-port" 1
    [ -z "${PRIVATE_IP}" ] && die "delete-port-forward: missing --private-ip" 1
    [ -z "${PRIVATE_PORT}" ] && die "delete-port-forward: missing --private-port" 1
    _load_state
    [ -z "${PROTOCOL}" ] && PROTOCOL="tcp"

    log "delete-port-forward: network=${NETWORK_ID} ${PUBLIC_IP}:${PUBLIC_PORT} -> ${PRIVATE_IP}:${PRIVATE_PORT}"

    if [ -n "${GW_NODE}" ]; then
        local pr_chain fwd_chain
        pr_chain=$(nat_chain_pr "${NETWORK_ID}")
        fwd_chain=$(filter_chain "${NETWORK_ID}")

        node_exec "${GW_NODE}" "iptables -t nat -D ${pr_chain} -p ${PROTOCOL} -d ${PUBLIC_IP} --dport ${PUBLIC_PORT} \
            -j DNAT --to-destination ${PRIVATE_IP}:${PRIVATE_PORT} 2>/dev/null || true" || true
        node_exec "${GW_NODE}" "iptables -t filter -D ${fwd_chain} -p ${PROTOCOL} -d ${PRIVATE_IP} --dport ${PRIVATE_PORT} -j ACCEPT 2>/dev/null || true" || true
        node_exec "${GW_NODE}" "iptables -t filter -D ${fwd_chain} -p ${PROTOCOL} -s ${PRIVATE_IP} --sport ${PRIVATE_PORT} -j ACCEPT 2>/dev/null || true" || true
    fi

    local safe_port
    safe_port=$(echo "${PUBLIC_PORT}" | tr ':' '-')
    local vsd; vsd=$(_vpc_state_dir)
    rm -f "${vsd}/port-forward/${PROTOCOL}_${PUBLIC_IP}_${safe_port}" 2>/dev/null || true

    log "delete-port-forward: done"
    exit 0
fi

##############################################################################
# Command: apply-fw-rules
#
# Apply firewall rules. Reads base64-encoded JSON from --fw-rules-file.
# Uses iptables on the gateway node.
##############################################################################

if [ "${COMMAND}" = "apply-fw-rules" ]; then
    [ -z "${NETWORK_ID}" ] && die "apply-fw-rules: missing --network-id" 1
    _load_state

    log "apply-fw-rules: network=${NETWORK_ID}"

    # Read and decode the firewall rules payload
    local rules_json=""
    if [ -n "${FW_RULES_FILE}" ] && [ -f "${FW_RULES_FILE}" ]; then
        rules_json=$(base64 -d < "${FW_RULES_FILE}" 2>/dev/null || cat "${FW_RULES_FILE}")
    fi

    if [ -z "${rules_json}" ] || [ "${rules_json}" = "{}" ]; then
        log "apply-fw-rules: no rules to apply"
        exit 0
    fi

    if [ -n "${GW_NODE}" ] && command -v jq >/dev/null 2>&1; then
        local fwd_chain fw_chain
        fwd_chain=$(filter_chain "${NETWORK_ID}")
        fw_chain=$(fw_chain "${NETWORK_ID}")

        # Ensure firewall chain exists
        ensure_iptables_chain "${GW_NODE}" filter "${fw_chain}" "${fwd_chain}"

        # Flush the firewall chain and rebuild
        node_exec "${GW_NODE}" "iptables -t filter -F ${fw_chain}" || true

        local default_egress_allow
        default_egress_allow=$(echo "${rules_json}" | jq -r '.default_egress_allow // true')
        local cidr
        cidr=$(echo "${rules_json}" | jq -r '.cidr // ""')

        # Process each rule
        echo "${rules_json}" | jq -c '.rules[]?' 2>/dev/null | while IFS= read -r rule; do
            local rule_type protocol port_start port_end public_ip
            rule_type=$(echo "${rule}" | jq -r '.type // "ingress"')
            protocol=$(echo "${rule}" | jq -r '.protocol // "all"')
            port_start=$(echo "${rule}" | jq -r '.portStart // empty')
            port_end=$(echo "${rule}" | jq -r '.portEnd // empty')
            public_ip=$(echo "${rule}" | jq -r '.publicIp // empty')

            local src_cidrs
            src_cidrs=$(echo "${rule}" | jq -r '.sourceCidrs[]? // empty' 2>/dev/null)

            if [ "${rule_type}" = "egress" ]; then
                # Egress rules
                local action="ACCEPT"
                [ "${default_egress_allow}" = "true" ] && action="DROP"

                local ipt_args="-t filter"
                if [ "${protocol}" != "all" ] && [ -n "${protocol}" ]; then
                    ipt_args+=" -p ${protocol}"
                    if [ -n "${port_start}" ]; then
                        if [ -n "${port_end}" ] && [ "${port_end}" != "${port_start}" ]; then
                            ipt_args+=" --dport ${port_start}:${port_end}"
                        else
                            ipt_args+=" --dport ${port_start}"
                        fi
                    fi
                fi

                for src in ${src_cidrs}; do
                    node_exec "${GW_NODE}" "iptables ${ipt_args} -A ${fw_chain} -s ${cidr} -d ${src} -j ${action}" || true
                done
            else
                # Ingress rules
                local ipt_args="-t filter"
                if [ "${protocol}" != "all" ] && [ -n "${protocol}" ]; then
                    ipt_args+=" -p ${protocol}"
                    if [ -n "${port_start}" ]; then
                        if [ -n "${port_end}" ] && [ "${port_end}" != "${port_start}" ]; then
                            ipt_args+=" --dport ${port_start}:${port_end}"
                        else
                            ipt_args+=" --dport ${port_start}"
                        fi
                    fi
                fi

                if [ -n "${public_ip}" ]; then
                    ipt_args+=" -d ${public_ip}"
                fi

                for src in ${src_cidrs}; do
                    node_exec "${GW_NODE}" "iptables ${ipt_args} -A ${fw_chain} -s ${src} -j ACCEPT" || true
                done
            fi
        done

        # Add default egress policy
        if [ "${default_egress_allow}" = "true" ] && [ -n "${cidr}" ]; then
            node_exec "${GW_NODE}" "iptables -t filter -A ${fw_chain} -s ${cidr} -j ACCEPT" || true
        elif [ -n "${cidr}" ]; then
            node_exec "${GW_NODE}" "iptables -t filter -A ${fw_chain} -s ${cidr} -j DROP" || true
        fi

        log "apply-fw-rules: firewall rules applied on ${GW_NODE}"
    else
        log "apply-fw-rules: skipped (no gateway node or jq not available)"
    fi

    exit 0
fi

##############################################################################
# Command: apply-network-acl
#
# Apply VPC Network ACL rules on the gateway node.
##############################################################################

if [ "${COMMAND}" = "apply-network-acl" ]; then
    [ -z "${NETWORK_ID}" ] && die "apply-network-acl: missing --network-id" 1
    _load_state

    log "apply-network-acl: network=${NETWORK_ID}"

    local acl_json=""
    if [ -n "${ACL_RULES_FILE}" ] && [ -f "${ACL_RULES_FILE}" ]; then
        acl_json=$(base64 -d < "${ACL_RULES_FILE}" 2>/dev/null || cat "${ACL_RULES_FILE}")
    fi

    if [ -z "${acl_json}" ] || [ "${acl_json}" = "[]" ]; then
        log "apply-network-acl: no ACL rules to apply"
        exit 0
    fi

    if [ -n "${GW_NODE}" ] && command -v jq >/dev/null 2>&1; then
        local fwd_chain acl_chain
        fwd_chain=$(filter_chain "${NETWORK_ID}")
        acl_chain="${CHAIN_PREFIX}_ACL_${NETWORK_ID}"

        # Ensure ACL chain exists
        ensure_iptables_chain "${GW_NODE}" filter "${acl_chain}" "${fwd_chain}"

        # Flush and rebuild
        node_exec "${GW_NODE}" "iptables -t filter -F ${acl_chain}" || true

        # Allow established connections
        node_exec "${GW_NODE}" "iptables -t filter -A ${acl_chain} -m state --state RELATED,ESTABLISHED -j ACCEPT" || true

        # Process rules in order
        echo "${acl_json}" | jq -c '.[]?' 2>/dev/null | while IFS= read -r rule; do
            local action traffic_type protocol port_start port_end
            action=$(echo "${rule}" | jq -r '.action // "Allow"')
            traffic_type=$(echo "${rule}" | jq -r '.trafficType // "Ingress"')
            protocol=$(echo "${rule}" | jq -r '.protocol // "all"')
            port_start=$(echo "${rule}" | jq -r '.portStart // empty')
            port_end=$(echo "${rule}" | jq -r '.portEnd // empty')

            local ipt_action="ACCEPT"
            [ "${action}" = "Deny" ] && ipt_action="DROP"

            local ipt_args=""
            if [ "${protocol}" != "all" ] && [ -n "${protocol}" ]; then
                ipt_args+=" -p ${protocol}"
                if [ -n "${port_start}" ]; then
                    if [ -n "${port_end}" ] && [ "${port_end}" != "${port_start}" ]; then
                        ipt_args+=" --dport ${port_start}:${port_end}"
                    else
                        ipt_args+=" --dport ${port_start}"
                    fi
                fi
            fi

            local src_cidrs
            src_cidrs=$(echo "${rule}" | jq -r '.sourceCidrs[]? // empty' 2>/dev/null)
            local dest_cidrs
            dest_cidrs=$(echo "${rule}" | jq -r '.destCidrs[]? // empty' 2>/dev/null)

            if [ "${traffic_type}" = "Ingress" ]; then
                for src in ${src_cidrs:-0.0.0.0/0}; do
                    node_exec "${GW_NODE}" "iptables -t filter -A ${acl_chain}${ipt_args} -s ${src} -j ${ipt_action}" || true
                done
            else
                for dst in ${dest_cidrs:-0.0.0.0/0}; do
                    node_exec "${GW_NODE}" "iptables -t filter -A ${acl_chain}${ipt_args} -d ${dst} -j ${ipt_action}" || true
                done
            fi
        done

        # Default deny at end
        node_exec "${GW_NODE}" "iptables -t filter -A ${acl_chain} -j DROP" || true

        log "apply-network-acl: ACL rules applied on ${GW_NODE}"
    fi

    exit 0
fi

##############################################################################
# DHCP/DNS/UserData commands
#
# Proxmox SDN can provide DHCP natively via dnsmasq on nodes when
# subnets are configured with DHCP ranges.  For basic DHCP operations
# we update the Proxmox SDN subnet configuration.
#
# VM metadata (userdata, password, SSH key, network config) is delivered
# via a small cloud-init ISO (cidata label) created by the
# save-vm-data / save-userdata / save-password / save-sshkey commands
# and attached to the VM via the Proxmox API.
#
# This integrates with the Proxmox.sh VM orchestrator: the VM is created
# by Proxmox.sh, then this extension attaches the cloud-init drive with
# the network and metadata information.
##############################################################################

case "${COMMAND}" in
    config-dhcp-subnet|config-dns-subnet)
        log "${COMMAND}: network=${NETWORK_ID} (handled by Proxmox SDN subnet DHCP)"
        # Update the Proxmox SDN subnet to enable DHCP if needed
        _load_state
        if [ -n "${STORED_VNET}" ] && [ -n "${CIDR}" ] && [ -n "${GATEWAY}" ]; then
            local sub_id
            sub_id=$(subnet_id "${STORED_VNET}" "${CIDR}")
            # Try to enable DHCP on the subnet via dhcp-dns-server
            local dns_ip="${EXTENSION_IP:-${GATEWAY}}"
            api_put "/cluster/sdn/vnets/${STORED_VNET}/subnets/${sub_id}" \
                "gateway=${GATEWAY}&dhcp-dns-server=${dns_ip}" 2>/dev/null || true
            apply_sdn_changes
        fi
        exit 0
        ;;

    remove-dhcp-subnet|remove-dns-subnet)
        log "${COMMAND}: network=${NETWORK_ID} (Proxmox SDN manages DHCP lifecycle)"
        exit 0
        ;;

    add-dhcp-entry)
        log "add-dhcp-entry: network=${NETWORK_ID} mac=${MAC} ip=${VM_IP} (delegated to Proxmox SDN IPAM)"
        # Proxmox SDN IPAM can manage DHCP entries.  If the PVE cluster has
        # IPAM configured (e.g., PVE IPAM, Netbox, phpIPAM), we could
        # register the MAC→IP mapping via the IPAM API.  For now, Proxmox
        # SDN's built-in dnsmasq handles DHCP from the subnet range.
        exit 0
        ;;

    remove-dhcp-entry)
        log "remove-dhcp-entry: network=${NETWORK_ID} mac=${MAC} (delegated to Proxmox SDN IPAM)"
        exit 0
        ;;

    set-dhcp-options)
        log "set-dhcp-options: network=${NETWORK_ID} (not supported by Proxmox SDN)"
        exit 0
        ;;

    add-dns-entry|remove-dns-entry)
        log "${COMMAND}: network=${NETWORK_ID} (delegated to Proxmox SDN DNS)"
        exit 0
        ;;

    save-vm-data|save-userdata|save-password|save-sshkey|save-hypervisor-hostname)
        log "${COMMAND}: network=${NETWORK_ID} ip=${VM_IP} vmid=${PROXMOX_VMID}"
        _load_state

        # Resolve the Proxmox VMID — may be passed via --vmid, found in
        # VM_DATA_FILE JSON, or looked up from our state directory.
        local vmid="${PROXMOX_VMID}"
        if [ -z "${vmid}" ] && [ -n "${VM_DATA_FILE}" ] && [ -f "${VM_DATA_FILE}" ]; then
            vmid=$(jq -r '.details.proxmox_vmid // empty' "${VM_DATA_FILE}" 2>/dev/null || true)
        fi
        if [ -z "${vmid}" ] && [ -n "${VM_IP}" ]; then
            local nsd; nsd=$(_net_state_dir)
            vmid=$(read_state "${nsd}/vms" "${VM_IP}" "")
        fi
        if [ -z "${vmid}" ]; then
            log "${COMMAND}: cannot determine Proxmox VMID — skipping cloud-init"
            exit 0
        fi

        # Determine the node where the VM lives
        local ci_node="${GW_NODE:-${PVE_NODE}}"

        # Build cloud-init data directory
        local ci_dir
        ci_dir=$(mktemp -d /tmp/cs-cloudinit-XXXXXX)
        trap 'rm -rf "${ci_dir}"' EXIT

        # -- meta-data --
        local instance_id="${HOSTNAME:-${VM_IP:-i-unknown}}"
        local local_hostname="${HOSTNAME:-${VM_IP:-localhost}}"
        cat > "${ci_dir}/meta-data" <<EOMETA
instance-id: ${instance_id}
local-hostname: ${local_hostname}
EOMETA

        # -- network-config (NoCloud v2 format) --
        if [ -n "${VM_IP}" ] && [ -n "${CIDR}" ]; then
            local prefix
            prefix=$(echo "${CIDR}" | cut -d'/' -f2)
            local gw="${GATEWAY}"
            local dns="${DNS_SERVER:-${GATEWAY}}"
            cat > "${ci_dir}/network-config" <<EONET
version: 2
ethernets:
  id0:
    match:
      name: "e*"
    addresses:
      - ${VM_IP}/${prefix}
    gateway4: ${gw}
    nameservers:
      addresses:
        - ${dns}
EONET
        fi

        # -- user-data --
        local ud_content=""
        if [ -n "${USERDATA}" ]; then
            ud_content="${USERDATA}"
        elif [ -n "${VM_DATA_FILE}" ] && [ -f "${VM_DATA_FILE}" ]; then
            ud_content=$(jq -r '.userdata // empty' "${VM_DATA_FILE}" 2>/dev/null || true)
        fi

        if [ -n "${ud_content}" ]; then
            # If user-data starts with #cloud-config or #! use it as-is
            printf '%s\n' "${ud_content}" > "${ci_dir}/user-data"
        else
            printf '#cloud-config\n' > "${ci_dir}/user-data"
        fi

        # Append password / SSH key if provided
        if [ -n "${VM_PASSWORD}" ]; then
            {
                grep -q '^#cloud-config' "${ci_dir}/user-data" || printf '#cloud-config\n'
                printf 'password: %s\nchpasswd:\n  expire: false\nssh_pwauth: true\n' "${VM_PASSWORD}"
            } >> "${ci_dir}/user-data"
        fi
        if [ -n "${VM_SSHKEY}" ]; then
            {
                grep -q '^#cloud-config' "${ci_dir}/user-data" || printf '#cloud-config\n'
                printf 'ssh_authorized_keys:\n  - %s\n' "${VM_SSHKEY}"
            } >> "${ci_dir}/user-data"
        fi

        # Create the cloud-init ISO (cidata label)
        local iso_name="cloudinit-${vmid}.iso"
        local iso_path="${ci_dir}/${iso_name}"
        if command -v genisoimage >/dev/null 2>&1; then
            genisoimage -o "${iso_path}" -V cidata -J -R \
                "${ci_dir}/meta-data" \
                "${ci_dir}/network-config" \
                "${ci_dir}/user-data" >/dev/null 2>&1
        elif command -v mkisofs >/dev/null 2>&1; then
            mkisofs -o "${iso_path}" -V cidata -J -R \
                "${ci_dir}/meta-data" \
                "${ci_dir}/network-config" \
                "${ci_dir}/user-data" >/dev/null 2>&1
        elif command -v xorrisofs >/dev/null 2>&1; then
            xorrisofs -o "${iso_path}" -V cidata -J -R \
                "${ci_dir}/meta-data" \
                "${ci_dir}/network-config" \
                "${ci_dir}/user-data" >/dev/null 2>&1
        else
            log "${COMMAND}: no ISO creation tool found (genisoimage/mkisofs/xorrisofs) — skipping"
            exit 0
        fi

        if [ ! -f "${iso_path}" ]; then
            log "${COMMAND}: failed to create cloud-init ISO"
            exit 0
        fi

        # Upload the ISO to Proxmox storage
        local upload_resp
        upload_resp=$(curl -s -w '\n%{http_code}' \
            -X POST \
            -H "Authorization: PVEAPIToken=${PVE_USER}!${PVE_TOKEN}=${PVE_SECRET}" \
            ${PVE_VERIFY_TLS:+"$([ "${PVE_VERIFY_TLS}" = "false" ] && echo '-k')"} \
            -F "content=iso" \
            -F "filename=@${iso_path}" \
            "https://${PVE_URL}:8006/api2/json/nodes/${ci_node}/storage/${CLOUDINIT_STORAGE}/upload" \
            2>&1) || true
        local upload_code
        upload_code=$(echo "${upload_resp}" | tail -1)
        log "${COMMAND}: ISO upload to ${CLOUDINIT_STORAGE} on ${ci_node}: HTTP ${upload_code}"

        # Attach the ISO to the VM as ide2 (cloud-init drive)
        local ide2_val="${CLOUDINIT_STORAGE}:iso/${iso_name},media=cdrom"
        api_put "/nodes/${ci_node}/qemu/${vmid}/config" "ide2=$(urlencode "${ide2_val}")" || {
            log "${COMMAND}: WARNING — failed to attach cloud-init ISO to VM ${vmid}"
        }

        # Save VM IP → VMID mapping for future lookups
        if [ -n "${VM_IP}" ]; then
            local nsd; nsd=$(_net_state_dir)
            mkdir -p "${nsd}/vms"
            save_state "${nsd}/vms" "${VM_IP}" "${vmid}"
        fi

        log "${COMMAND}: cloud-init ISO attached to VM ${vmid} on ${ci_node}"
        exit 0
        ;;

    apply-lb-rules)
        log "apply-lb-rules: network=${NETWORK_ID} (LB not natively supported by Proxmox SDN)"
        # Load balancing would require an external LB (HAProxy, etc.)
        # on the gateway node.  For now, this is a no-op.
        exit 0
        ;;

    restore-network)
        log "restore-network: network=${NETWORK_ID} (state managed by Proxmox SDN)"
        exit 0
        ;;

    update-vpc-source-nat-ip)
        [ -z "${VPC_ID}" ] && die "update-vpc-source-nat-ip: missing --vpc-id" 1
        _load_state
        log "update-vpc-source-nat-ip: vpc=${VPC_ID} public_ip=${PUBLIC_IP}"

        if [ -n "${GW_NODE}" ] && [ -n "${PUBLIC_IP}" ] && [ -n "${CIDR}" ]; then
            local post_chain="${CHAIN_PREFIX}_${VPC_ID}_VPC_POST"

            # Flush and recreate the VPC SNAT chain
            node_exec "${GW_NODE}" "iptables -t nat -F ${post_chain} 2>/dev/null || true" || true
            node_exec "${GW_NODE}" "iptables -t nat -A ${post_chain} -s ${CIDR} -j SNAT --to-source ${PUBLIC_IP}" || true

            log "update-vpc-source-nat-ip: SNAT updated to ${PUBLIC_IP} for VPC ${VPC_ID}"
        fi
        exit 0
        ;;

    custom-action)
        log "custom-action: network=${NETWORK_ID} action=${ACTION_NAME}"

        case "${ACTION_NAME}" in
            dump-config)
                # Dump SDN configuration from Proxmox
                echo "=== Proxmox SDN Zones ==="
                api_get "/cluster/sdn/zones" 2>/dev/null | jq '.' 2>/dev/null || echo "(failed)"
                echo ""
                echo "=== Proxmox SDN VNets ==="
                api_get "/cluster/sdn/vnets" 2>/dev/null | jq '.' 2>/dev/null || echo "(failed)"
                echo ""
                echo "=== Local State ==="
                find "${STATE_DIR}" -type f 2>/dev/null | sort | while read f; do
                    echo "${f}: $(cat "${f}" 2>/dev/null)"
                done
                ;;
            apply-sdn)
                apply_sdn_changes
                echo "SDN changes applied"
                ;;
            *)
                echo "Unknown custom action: ${ACTION_NAME}"
                exit 1
                ;;
        esac
        exit 0
        ;;

    *)
        log "Unknown command: ${COMMAND} (ignoring)"
        # Unknown commands succeed silently for forward compatibility
        exit 0
        ;;
esac

