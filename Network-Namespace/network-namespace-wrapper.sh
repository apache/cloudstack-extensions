#!/bin/bash
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
# network-namespace-wrapper.sh
#
# Network Extension wrapper script for Apache CloudStack.
# Runs on a KVM host; manages Linux network namespaces, VLAN bridges,
# and iptables rules to implement isolated guest networks.
#
# Architecture
# ============
#
# Guest (internal) side
# ---------------------
# Each CloudStack isolated network has a VLAN.  On the KVM host:
#
#   ethX.<vlan>         – VLAN sub-interface on the physical NIC (ethX)
#   br<ethX>-<vlan>     – Linux bridge: ethX.<vlan> + vh-<vlan>-<id>
#   vh-<vlan>-<id>      – host end of the veth pair → in the bridge
#   vn-<vlan>-<id>      – namespace end → assigned the extension IP
#                         (= gateway when SourceNat/Gateway is enabled;
#                          = allocated placeholder IP otherwise)
#
# ethX is read from guest.network.device in the physical-network extension
# details (defaults to eth1 when absent).
#
# Namespace
# ---------
#   Isolated network : cs-net-<networkId>   (--network-id)
#   VPC network      : cs-vpc-<vpcId>       (--vpc-id)
#
# Public (NAT) side
# -----------------
# For each public IP assigned to the network a veth pair is created:
#
#   vph-<pvlan>-<id>   – host end → added to br<pub_ethX>-<pvlan>
#   vpn-<pvlan>-<id>   – namespace end → assigned the public IP
#
# where <pvlan>  = public VLAN tag (from --public-vlan)
#       <id>     = vpc-id if present, else network-id
#       pub_ethX = read from public.network.device in extension details
#                  (defaults to eth1 when absent)
#
# Interface name lengths (Linux limit: 15 chars)
#   vh-<vlan>-<id>     max 15 (shorten_id applied when needed) ✓
#   vn-<vlan>-<id>     max 15 (shorten_id applied when needed) ✓
#   vph-<pvlan>-<id>   max 15 ✓
#   vpn-<pvlan>-<id>   max 15 ✓
#
# iptables chains (inside namespace)
# ------------------------------------
#   CS_EXTNET_<networkId>_PR   – PREROUTING  DNAT chain
#   CS_EXTNET_<networkId>_POST – POSTROUTING SNAT chain
#   CS_EXTNET_FWD_<networkId>  – FORWARD filter chain
#
# CLI arguments (forwarded by network-namespace.sh):
#   --physical-network-extension-details <json>
#       kvmnetworklabel, public_kvmnetworklabel, hosts, username, …
#   --network-extension-details <json>
#       host, namespace, …
##############################################################################

set -e

# ---------------------------------------------------------------------------
# Derive log path from this wrapper's own directory name so that each
# renamed deployment writes to its own log file.
#   /etc/cloudstack/extensions/<name>/<name>-wrapper.sh
#   → /var/log/cloudstack/extensions/<name>/<name>.log
# ---------------------------------------------------------------------------
_WRAPPER_SELF="$(readlink -f "$0" 2>/dev/null \
                 || realpath "$0" 2>/dev/null \
                 || echo "$0")"
_WRAPPER_EXT_DIR="$(basename "$(dirname "${_WRAPPER_SELF}")")"
LOG_FILE="/var/log/cloudstack/extensions/${_WRAPPER_EXT_DIR}/${_WRAPPER_EXT_DIR}.log"
mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true

STATE_DIR="/var/lib/cloudstack/${_WRAPPER_EXT_DIR}"

# ---------------------------------------------------------------------------
# JSON helpers (no jq dependency)
# ---------------------------------------------------------------------------

_json_get() {
    # _json_get <json> <key>  →  value (unquoted string) or empty
    printf '%s' "$1" | grep -o "\"$2\":\"[^\"]*\"" | cut -d'"' -f4 || true
}

# ---------------------------------------------------------------------------
# Pre-scan all arguments for the two JSON blobs.
# ---------------------------------------------------------------------------

PHYS_DETAILS="${CS_PHYSICAL_NETWORK_EXTENSION_DETAILS:-{}}"
EXTENSION_DETAILS="${CS_NETWORK_EXTENSION_DETAILS:-{}}"

_pre_scan_args() {
    local i=1
    local args=("$@")
    while [ $i -le $# ]; do
        case "${args[$i-1]}" in
            --physical-network-extension-details)
                PHYS_DETAILS="${args[$i]:-{}}"
                i=$((i+2)) ;;
            --network-extension-details)
                EXTENSION_DETAILS="${args[$i]:-{}}"
                i=$((i+2)) ;;
            *) i=$((i+1)) ;;
        esac
    done
}

_pre_scan_args "$@"

# ---------------------------------------------------------------------------
# Resolve host network interfaces from physical-network extension details.
#
# Register guest.network.device and public.network.device when attaching the
# extension to a physical network, e.g.:
#   details[N].key=guest.network.device  details[N].value=eth1
#   details[M].key=public.network.device details[M].value=eth1
#
# Both default to eth1 when absent.
# ---------------------------------------------------------------------------

GUEST_ETH=$(_json_get "${PHYS_DETAILS}" "guest.network.device")
GUEST_ETH="${GUEST_ETH:-eth1}"

PUB_ETH=$(_json_get "${PHYS_DETAILS}" "public.network.device")
PUB_ETH="${PUB_ETH:-eth1}"

# iptables chain prefix
CHAIN_PREFIX="CS_EXTNET"

##############################################################################
# Helpers
##############################################################################

log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${ts}] $*" >> "${LOG_FILE}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# State directory helpers
#
# Per-network state (unique to each tier / isolated network):
#   ${STATE_DIR}/network-<networkId>/
#
# VPC-wide shared state (public IPs, namespace, iptables dump):
#   ${STATE_DIR}/vpc-<vpcId>/          (VPC network)
#   ${STATE_DIR}/network-<networkId>/  (isolated — same as _net_state_dir)
#
# Call these only after parse_args has set NETWORK_ID / VPC_ID.
# ---------------------------------------------------------------------------
_net_state_dir() { echo "${STATE_DIR}/network-${NETWORK_ID}"; }

_vpc_state_dir() {
    if [ -n "${VPC_ID}" ]; then
        echo "${STATE_DIR}/vpc-${VPC_ID}"
    else
        echo "${STATE_DIR}/network-${NETWORK_ID}"
    fi
}

# Save the current iptables-save output to the log and to
# <vpc-or-net-state-dir>/iptables.dump (full namespace snapshot).
# Call this after any command that modifies iptables rules.
_dump_iptables() {
    local ns="${1:-${NAMESPACE}}"
    [ -z "${ns}" ] && return
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local ipt_out
    ipt_out=$(ip netns exec "${ns}" iptables-save 2>/dev/null || echo "(iptables-save failed)")
    {
        printf '\n=== iptables-save [%s] ns=%s ===\n' "${ts}" "${ns}"
        printf '%s\n' "${ipt_out}"
        printf '=== end iptables-save ===\n\n'
    } >> "${LOG_FILE}" 2>/dev/null || true
    # Persist a current snapshot under the VPC/network state dir.
    if [ -n "${NETWORK_ID}" ]; then
        local dump_dir; dump_dir=$(_vpc_state_dir)
        mkdir -p "${dump_dir}" 2>/dev/null || true
        printf '# iptables-save %s ns=%s\n%s\n' "${ts}" "${ns}" "${ipt_out}" \
            > "${dump_dir}/iptables.dump" 2>/dev/null || true
    fi
}

die() {
    log "ERROR: $*"
    release_lock
    exit 1
}

ensure_dirs() {
    mkdir -p "${STATE_DIR}" "$(dirname "${LOG_FILE}")" 2>/dev/null || true
}

acquire_lock() {
    local network_id="$1"
    # For VPC networks serialize on the VPC ID so all tiers sharing the same
    # namespace are protected by a single lock.
    local lockfile
    if [ -n "${VPC_ID:-}" ]; then
        lockfile="${STATE_DIR}/lock-vpc-${VPC_ID}"
    else
        lockfile="${STATE_DIR}/lock-network-${network_id}"
    fi
    mkdir -p "${STATE_DIR}"
    # Record the current lockfile path so release_lock can remove it later
    GLOBAL_LOCKFILE="${lockfile}"
    log "acquire_lock: attempting to acquire lock ${GLOBAL_LOCKFILE}"
    exec 200>"${lockfile}"
    flock -w 30 200 || die "Failed to acquire lock for network ${network_id}"
}

release_lock() {
    # Close the fd holding the flock (releases the lock) then remove the
    # lockfile path if we have it recorded. It's OK if the file no longer
    # exists; we ignore errors.
    exec 200>&- 2>/dev/null || true
    if [ -n "${GLOBAL_LOCKFILE:-}" ]; then
        log "release_lock: releasing and removing ${GLOBAL_LOCKFILE}"
        rm -f "${GLOBAL_LOCKFILE}" 2>/dev/null || true
        GLOBAL_LOCKFILE=""
    else
        log "release_lock: no GLOBAL_LOCKFILE recorded"
    fi
}

# Ensure we attempt to release any held lock on exit (safe no-op if none).
trap 'release_lock' EXIT

# ---------------------------------------------------------------------------
# Interface / bridge name helpers
# ---------------------------------------------------------------------------

# Host bridge for a VLAN on a given physical NIC:  br<eth>-<vlan>
host_bridge_name() {
    local eth="$1" vlan_raw="$2" vlan
    vlan=$(normalize_vlan "${vlan_raw}")
    echo "br${eth}-${vlan}"
}

# Internal guest veth pair (keyed on VLAN ID and network id):
#   vh-<vlan>-<id>  (host, in bridge)
#   vn-<vlan>-<id>  (namespace, gets gateway IP)

# shorten_id <id> -> short deterministic id portion suitable for interface names
shorten_id() {
    local id="$1"
    [ -z "${id}" ] && echo "" && return
    # If purely numeric, use hex to shorten (stable)
    if printf '%d' "${id}" >/dev/null 2>&1; then
        printf '%x' "${id}"
        return
    fi
    # For non-numeric, prefer an md5 prefix if available
    if command -v md5sum >/dev/null 2>&1; then
        echo -n "${id}" | md5sum | awk '{print $1}' | cut -c1-6
        return
    fi
    # Fallback: last 6 chars
    echo "${id}" | awk '{n=length($0); print substr($0, n-5)}'
}

# normalize_vlan <vlan_raw> -> prints the normalized vlan id (strip vlan:// prefix)
normalize_vlan() {
    local vlan_raw="$1"
    if [ -z "${vlan_raw}" ]; then
        printf '%s' ""
        return
    fi
    if printf '%s' "${vlan_raw}" | grep -q '^vlan://'; then
        printf '%s' "${vlan_raw#vlan://}"
    else
        printf '%s' "${vlan_raw}"
    fi
}

# Generate guest host veth name: vh-<vlan>-<id> (ensure <=15 chars)
veth_host_name() {
    local vlan_raw="$1" id="$2" name short
    vlan=$(normalize_vlan "${vlan_raw}")
    name="vh-${vlan}-${id}"
    if [ ${#name} -le 15 ]; then
        echo "${name}"
        return
    fi
    short=$(shorten_id "${id}")
    name="vh-${vlan}-${short}"
    if [ ${#name} -le 15 ]; then
        echo "${name}"
        return
    fi
    echo "${name:0:15}"
}

# Generate guest namespace veth name: vn-<vlan>-<id> (ensure <=15 chars)
veth_ns_name() {
    local vlan_raw="$1" id="$2" name short
    vlan=$(normalize_vlan "${vlan_raw}")
    name="vn-${vlan}-${id}"
    if [ ${#name} -le 15 ]; then
        echo "${name}"
        return
    fi
    short=$(shorten_id "${id}")
    name="vn-${vlan}-${short}"
    if [ ${#name} -le 15 ]; then
        echo "${name}"
        return
    fi
    echo "${name:0:15}"
}

# Public veth pair (keyed on public VLAN and network/vpc id):
#   vph-<pvlan>-<id>  (host, in public bridge)
#   vpn-<pvlan>-<id>  (namespace, gets public IP)
pub_veth_host_name() {
    local pvlan_raw="$1" id="$2" pvlan
    pvlan=$(normalize_vlan "${pvlan_raw}")
    echo "vph-${pvlan}-${id}"
}

pub_veth_ns_name() {
    local pvlan_raw="$1" id="$2" pvlan
    pvlan=$(normalize_vlan "${pvlan_raw}")
    echo "vpn-${pvlan}-${id}"
}

nat_chain()    { echo "${CHAIN_PREFIX}_${1}"; }
filter_chain()   { echo "${CHAIN_PREFIX}_FWD_${1}"; }
firewall_chain() { echo "${CHAIN_PREFIX}_FWRULES_${1}"; }

ensure_public_ip_on_namespace() {
    local public_ip="$1" public_cidr="$2" pveth_n="$3" pveth_h="$4" addr_spec prefix

    if [ -n "${public_cidr}" ] && echo "${public_cidr}" | grep -q '/'; then
        prefix=$(echo "${public_cidr}" | cut -d'/' -f2)
        addr_spec="${public_ip}/${prefix}"
    else
        addr_spec="${public_ip}/32"
    fi

    # Do not add a second address when the IP is already present with another prefix.
    ip netns exec "${NAMESPACE}" ip addr show "${pveth_n}" 2>/dev/null | grep -q "${public_ip}/" || \
        ip netns exec "${NAMESPACE}" ip addr add "${addr_spec}" dev "${pveth_n}" 2>/dev/null || true

    # Keep the host route in place for inbound traffic.
    ip route show | grep -q "^${public_ip}" || \
        ip route add "${public_ip}/32" dev "${pveth_h}" 2>/dev/null || true

    # Disable IPv6 on the public veth interface inside namespace to prevent
    # IPv6 autoconf and link-local addresses appearing. Idempotent.
    ip netns exec "${NAMESPACE}" sysctl -w net.ipv6.conf."${pveth_n}".disable_ipv6=1 >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# ensure_host_bridge <eth> <vlan>
# Idempotently creates br<eth>-<vlan> with <eth>.<vlan> as a member.
# Prints the bridge name.
# ---------------------------------------------------------------------------

ensure_host_bridge() {
    local eth="$1"
    local vlan_raw="$2"
    local vlan=$(normalize_vlan "${vlan_raw}")
    local br vif current_master

    br=$(host_bridge_name "${eth}" "${vlan}")
    vif="${eth}.${vlan}"

    # VLAN sub-interface
    if ! ip link show "${vif}" >/dev/null 2>&1; then
        ip link add link "${eth}" name "${vif}" type vlan id "${vlan}"
        log "Created VLAN interface ${vif}"
    fi
    ip link set "${vif}" up 2>/dev/null || true

    # Bridge
    if ! ip link show "${br}" >/dev/null 2>&1; then
        ip link add name "${br}" type bridge
        ip link set "${br}" up
        log "Created host bridge ${br}"
    fi

    # Attach VLAN interface to bridge (if not already there)
    current_master=$(ip link show "${vif}" 2>/dev/null | grep -o 'master [^ ]*' | awk '{print $2}' || true)
    if [ "${current_master}" != "${br}" ]; then
        ip link set "${vif}" master "${br}" 2>/dev/null || true
    fi

    echo "${br}"
}

ensure_chain() {
    local table="$1" chain="$2"
    ip netns exec "${NAMESPACE}" iptables -t "${table}" -n -L "${chain}" >/dev/null 2>&1 || \
        ip netns exec "${NAMESPACE}" iptables -t "${table}" -N "${chain}"
}

ensure_jump() {
    local table="$1" parent="$2" chain="$3"
    ip netns exec "${NAMESPACE}" iptables -t "${table}" \
        -C "${parent}" -j "${chain}" 2>/dev/null || \
    ip netns exec "${NAMESPACE}" iptables -t "${table}" \
        -I "${parent}" 1 -j "${chain}"
}

##############################################################################
# Parse common arguments
##############################################################################

parse_args() {
    NETWORK_ID=""
    NAMESPACE=""
    VPC_ID=""
    CHOSEN_ID=""
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
    # --- new fields ---
    MAC=""
    HOSTNAME=""
    DNS_SERVER=""
    NIC_ID=""
    DHCP_OPTIONS_JSON="{}"
    VM_IP=""
    USERDATA=""
    PASSWORD=""
    SSH_KEY=""
    HYPERVISOR_HOSTNAME=""
    LB_RULES_JSON="[]"
    DEFAULT_NIC="true"
    VM_DATA=""
    DOMAIN=""
    EXTENSION_IP=""
    RESTORE_DATA=""
    FW_RULES_JSON=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --network-id)          NETWORK_ID="$2";         shift 2 ;;
            --namespace)           NAMESPACE="$2";           shift 2 ;;
            --vpc-id)              VPC_ID="$2";              shift 2 ;;
            --vlan)                VLAN="$2";                shift 2 ;;
            --gateway)             GATEWAY="$2";             shift 2 ;;
            --cidr)                CIDR="$2";                shift 2 ;;
            --public-ip)           PUBLIC_IP="$2";           shift 2 ;;
            --private-ip)          PRIVATE_IP="$2";          shift 2 ;;
            --public-port)         PUBLIC_PORT="$2";         shift 2 ;;
            --private-port)        PRIVATE_PORT="$2";        shift 2 ;;
            --protocol)            PROTOCOL="$2";            shift 2 ;;
            --source-nat)          SOURCE_NAT="$2";          shift 2 ;;
            --public-gateway)      PUBLIC_GATEWAY="$2";      shift 2 ;;
            --public-cidr)         PUBLIC_CIDR="$2";         shift 2 ;;
            --public-vlan)         PUBLIC_VLAN="$2";         shift 2 ;;
            --mac)                 MAC="$2";                 shift 2 ;;
            --hostname)            HOSTNAME="$2";            shift 2 ;;
            --dns)                 DNS_SERVER="$2";          shift 2 ;;
            --nic-id)              NIC_ID="$2";              shift 2 ;;
            --options)             DHCP_OPTIONS_JSON="$2";   shift 2 ;;
            --ip)                  VM_IP="$2";               shift 2 ;;
            --userdata)            USERDATA="$2";            shift 2 ;;
            --password)            PASSWORD="$2";            shift 2 ;;
            --sshkey)              SSH_KEY="$2";             shift 2 ;;
            --hypervisor-hostname) HYPERVISOR_HOSTNAME="$2"; shift 2 ;;
            --lb-rules)            LB_RULES_JSON="$2";       shift 2 ;;
            --default-nic)         DEFAULT_NIC="$2";         shift 2 ;;
            --vm-data)             VM_DATA="$2";             shift 2 ;;
            --domain)              DOMAIN="$2";              shift 2 ;;
            --extension-ip)        EXTENSION_IP="$2";        shift 2 ;;
            --restore-data)        RESTORE_DATA="$2";        shift 2 ;;
            --fw-rules)            FW_RULES_JSON="$2";       shift 2 ;;
            # consumed by _pre_scan_args — skip silently
            --physical-network-extension-details|--network-extension-details)
                                   shift 2 ;;
            *)                     shift ;;
        esac
    done

    [ -z "${NETWORK_ID}" ] && die "Missing --network-id"

    # Namespace: VPC → cs-vpc-<vpcId>; standalone → cs-net-<networkId>
    if [ -z "${NAMESPACE}" ]; then
        if [ -n "${VPC_ID}" ]; then
            NAMESPACE="cs-vpc-${VPC_ID}"
        else
            local NS_FROM_DETAILS
            NS_FROM_DETAILS=$(_json_get "${EXTENSION_DETAILS}" "namespace")
            NAMESPACE="${NS_FROM_DETAILS:-cs-net-${NETWORK_ID}}"
        fi
    fi

    # CHOSEN_ID selects vpc-id when present, otherwise network-id
    CHOSEN_ID="${VPC_ID:-${NETWORK_ID}}"

    # Normalize VLAN if provided as 'vlan://<id>' (common in some callers)
    if [ -n "${VLAN}" ]; then
      VLAN=$(normalize_vlan "${VLAN}")
    fi
    # Normalize PUBLIC_VLAN as well
    if [ -n "${PUBLIC_VLAN}" ]; then
      PUBLIC_VLAN=$(normalize_vlan "${PUBLIC_VLAN}")
    fi
}

# Load persisted state (shutdown, destroy, IP operations).
# Reads from the new network-<id>/vpc-<id> layout first; falls back to the
# legacy ${STATE_DIR}/${NETWORK_ID} path for backward compatibility.
_load_state() {
    local nsd; nsd=$(_net_state_dir)
    local vsd; vsd=$(_vpc_state_dir)
    local old="${STATE_DIR}/${NETWORK_ID}"  # legacy path

    _read_sf() {
        # _read_sf <varname> <filename> [<dir>...]
        # Sets <varname> from the first dir that contains <filename>.
        local _var="$1" _file="$2"; shift 2
        eval "local _cur=\${${_var}}"
        [ -n "${_cur}" ] && return
        local _d
        for _d in "$@"; do
            if [ -f "${_d}/${_file}" ]; then
                eval "${_var}=\$(cat '${_d}/${_file}')"
                return
            fi
        done
    }

    _read_sf VLAN        vlan        "${nsd}" "${old}"
    _read_sf CIDR        cidr        "${nsd}" "${old}"
    _read_sf GATEWAY     gateway     "${nsd}" "${old}"
    _read_sf EXTENSION_IP extension-ip "${nsd}" "${old}"

    if [ -z "${NAMESPACE}" ]; then
        # Namespace is VPC-wide: check vpc state dir, then per-net, then legacy.
        _read_sf NAMESPACE namespace "${vsd}" "${nsd}" "${old}"
        if [ -z "${NAMESPACE}" ]; then
            local NS_FROM_DETAILS
            NS_FROM_DETAILS=$(_json_get "${EXTENSION_DETAILS}" "namespace")
            if [ -n "${VPC_ID}" ]; then
                NAMESPACE="${NS_FROM_DETAILS:-cs-vpc-${VPC_ID}}"
            else
                NAMESPACE="${NS_FROM_DETAILS:-cs-net-${NETWORK_ID}}"
            fi
        fi
    fi
    # CHOSEN_ID will be set by parse_args; do not read or persist legacy network_or_vpc_id
}

##############################################################################
# Command: implement
#
# 1. Create namespace cs-net-<id>
# 2. Create host bridge br<ethX>-<vlan> with ethX.<vlan> sub-interface
# 3. Create veth pair: veth-host-<vlan> (host, in bridge) / veth-ns-<vlan> (namespace)
# 4. Assign gateway IP to veth-ns-<vlan> inside namespace
# 5. Set up iptables chains inside namespace
##############################################################################

cmd_implement() {
    parse_args "$@"
    acquire_lock "${NETWORK_ID}"

    log "implement: network=${NETWORK_ID} ns=${NAMESPACE} vlan=${VLAN} gw=${GATEWAY} cidr=${CIDR}"

    local veth_h veth_n nchain_pr nchain_post fchain
    veth_h=$(veth_host_name "${VLAN}" "${CHOSEN_ID}")
    veth_n=$(veth_ns_name   "${VLAN}" "${CHOSEN_ID}")
    nchain_pr="${CHAIN_PREFIX}_${NETWORK_ID}_PR"
    nchain_post="${CHAIN_PREFIX}_${NETWORK_ID}_POST"
    fchain=$(filter_chain "${NETWORK_ID}")

    # ---- 1. Create namespace ----
    if ! ip netns list 2>/dev/null | grep -q "^${NAMESPACE}\b"; then
        ip netns add "${NAMESPACE}"
        log "Created namespace ${NAMESPACE}"
    fi
    ip netns exec "${NAMESPACE}" ip link set lo up 2>/dev/null || true

    # Disable IPv6 inside the namespace to avoid IPv6 autoconf/link-local behavior
    # Apply globally and to the default and loopback interfaces. Idempotent.
    ip netns exec "${NAMESPACE}" sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
    ip netns exec "${NAMESPACE}" sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
    ip netns exec "${NAMESPACE}" sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1 || true

    # ---- 2. Host bridge + VLAN sub-interface ----
    if [ -n "${VLAN}" ]; then
        ensure_host_bridge "${GUEST_ETH}" "${VLAN}"
        local br
        br=$(host_bridge_name "${GUEST_ETH}" "${VLAN}")

        # ---- 3. Guest veth pair ----
        if ! ip link show "${veth_h}" >/dev/null 2>&1; then
            ip link add "${veth_h}" type veth peer name "${veth_n}"
            ip link set "${veth_n}" netns "${NAMESPACE}"
            ip link set "${veth_h}" master "${br}"
            ip link set "${veth_h}" up
            ip netns exec "${NAMESPACE}" ip link set "${veth_n}" up
            log "Created guest veth ${veth_h} (host→${br}) <-> ${veth_n} (namespace)"
        else
            ip link set "${veth_h}" up 2>/dev/null || true
            ip netns exec "${NAMESPACE}" ip link set "${veth_n}" up 2>/dev/null || true
        fi
    fi

    # ---- 4. Assign extension IP to namespace veth ----
    # EXTENSION_IP is the IP that this namespace "owns" on the guest subnet.
    # When SourceNat/Gateway service is enabled this equals the network gateway;
    # otherwise it is a dedicated placeholder IP allocated for DHCP/DNS/UserData.
    # If --extension-ip was not supplied fall back to the gateway.
    local ext_ip; ext_ip="${EXTENSION_IP:-${GATEWAY}}"
    if [ -n "${ext_ip}" ] && [ -n "${CIDR}" ]; then
        local prefix
        prefix=$(echo "${CIDR}" | cut -d'/' -f2)
        ip netns exec "${NAMESPACE}" ip addr show "${veth_n}" 2>/dev/null | \
            grep -q "${ext_ip}/${prefix}" || \
            ip netns exec "${NAMESPACE}" ip addr add "${ext_ip}/${prefix}" dev "${veth_n}"
        log "Assigned ${ext_ip}/${prefix} to ${veth_n} in ${NAMESPACE}"

        # When the extension IP differs from the gateway the namespace is not
        # the default router for the guest subnet.  Add a default route toward
        # the actual gateway so the namespace can reach external destinations
        # (e.g. metadata proxy, outbound health-checks).
        if [ -n "${GATEWAY}" ] && [ "${ext_ip}" != "${GATEWAY}" ]; then
            ip netns exec "${NAMESPACE}" ip route replace default \
                via "${GATEWAY}" dev "${veth_n}" 2>/dev/null || \
            ip netns exec "${NAMESPACE}" ip route add default \
                via "${GATEWAY}" dev "${veth_n}" 2>/dev/null || true
            log "Default route in ${NAMESPACE}: via ${GATEWAY} dev ${veth_n}"
        fi
    fi

    # Disable IPv6 on the guest veth namespace interface to prevent IPv6 addresses
    # from appearing on the interface (idempotent)
    ip netns exec "${NAMESPACE}" sysctl -w net.ipv6.conf."${veth_n}".disable_ipv6=1 >/dev/null 2>&1 || true

    # ---- 5. IP forwarding ----
    ip netns exec "${NAMESPACE}" sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

    # ---- 6. iptables chains ----
    ensure_chain nat    "${nchain_pr}"
    ensure_chain nat    "${nchain_post}"
    ensure_chain filter "${fchain}"
    ensure_jump  nat    PREROUTING  "${nchain_pr}"
    ensure_jump  nat    POSTROUTING "${nchain_post}"
    ensure_jump  filter FORWARD     "${fchain}"

    # Allow forwarding for guest traffic in/out of veth-ns-<vlan>
    ip netns exec "${NAMESPACE}" iptables -t filter \
        -C "${fchain}" -i "${veth_n}" -j ACCEPT 2>/dev/null || \
    ip netns exec "${NAMESPACE}" iptables -t filter \
        -A "${fchain}" -i "${veth_n}" -j ACCEPT

    ip netns exec "${NAMESPACE}" iptables -t filter \
        -C "${fchain}" -o "${veth_n}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    ip netns exec "${NAMESPACE}" iptables -t filter \
        -A "${fchain}" -o "${veth_n}" -m state --state RELATED,ESTABLISHED -j ACCEPT

    # ---- 7. Persist state ----
    # Per-network state → network-<networkId>/
    local nsd; nsd=$(_net_state_dir)
    mkdir -p "${nsd}"
    echo "${VLAN}"    > "${nsd}/vlan"
    echo "${GATEWAY}" > "${nsd}/gateway"
    echo "${CIDR}"    > "${nsd}/cidr"
    echo "${ext_ip}"  > "${nsd}/extension-ip"

    # Namespace + VPC tier tracking → vpc-<vpcId>/ (or network-<networkId>/ for isolated)
    local vsd; vsd=$(_vpc_state_dir)
    mkdir -p "${vsd}"
    echo "${NAMESPACE}" > "${vsd}/namespace"
    # Register this network as an active tier under the VPC (for destroy tracking)
    if [ -n "${VPC_ID}" ]; then
        mkdir -p "${vsd}/tiers"
        touch "${vsd}/tiers/${NETWORK_ID}"
    fi

    _dump_iptables "${NAMESPACE}"
    release_lock
    log "implement: done network=${NETWORK_ID} namespace=${NAMESPACE}"
}

##############################################################################
# Command: shutdown
# Flush iptables chains and remove this network's veth pairs.
# For VPC networks the shared namespace is preserved (other tiers still use it).
# For isolated networks the namespace is also removed.
##############################################################################

cmd_shutdown() {
    parse_args "$@"
    _load_state
    acquire_lock "${NETWORK_ID}"

    log "shutdown: network=${NETWORK_ID} ns=${NAMESPACE} vpc=${VPC_ID}"

    local nchain_pr nchain_post fchain
    nchain_pr="${CHAIN_PREFIX}_${NETWORK_ID}_PR"
    nchain_post="${CHAIN_PREFIX}_${NETWORK_ID}_POST"
    fchain=$(filter_chain "${NETWORK_ID}")

    # Remove iptables chain jumps for this network
    ip netns exec "${NAMESPACE}" iptables -t nat    -D PREROUTING  -j "${nchain_pr}"   2>/dev/null || true
    ip netns exec "${NAMESPACE}" iptables -t nat    -D POSTROUTING -j "${nchain_post}" 2>/dev/null || true
    ip netns exec "${NAMESPACE}" iptables -t filter -D FORWARD     -j "${fchain}"      2>/dev/null || true

    # Flush and delete this network's chains
    ip netns exec "${NAMESPACE}" iptables -t nat    -F "${nchain_pr}"   2>/dev/null || true
    ip netns exec "${NAMESPACE}" iptables -t nat    -X "${nchain_pr}"   2>/dev/null || true
    ip netns exec "${NAMESPACE}" iptables -t nat    -F "${nchain_post}" 2>/dev/null || true
    ip netns exec "${NAMESPACE}" iptables -t nat    -X "${nchain_post}" 2>/dev/null || true
    ip netns exec "${NAMESPACE}" iptables -t filter -F "${fchain}"      2>/dev/null || true
    ip netns exec "${NAMESPACE}" iptables -t filter -X "${fchain}"      2>/dev/null || true

    # Remove public veth pairs owned by THIS tier only (guarded by .tier file).
    # IPs owned by other tiers are left untouched so those tiers keep working.
    # Backward compat: if no .tier file exists assume the IP belongs here.
    local vsd; vsd=$(_vpc_state_dir)
    if [ -d "${vsd}/ips" ]; then
        for f in "${vsd}/ips/"*.pvlan; do
            [ -f "${f}" ] || continue
            local tier_f; tier_f="${f%.pvlan}.tier"
            if [ -f "${tier_f}" ]; then
                local owner_tier; owner_tier=$(cat "${tier_f}" 2>/dev/null || true)
                if [ -n "${owner_tier}" ] && [ "${owner_tier}" != "${NETWORK_ID}" ]; then
                    log "shutdown: skipping veth for $(basename "${f%.pvlan}") (owned by tier ${owner_tier})"
                    continue
                fi
            fi
            local pvlan pveth_h
            pvlan=$(cat "${f}")
            pveth_h=$(pub_veth_host_name "${pvlan}" "${CHOSEN_ID}")
            ip link del "${pveth_h}" 2>/dev/null || true
            log "shutdown: removed public veth ${pveth_h}"
        done
    fi

    # Remove this tier's guest veth pair (host-side)
    local veth_h
    veth_h=$(veth_host_name "${VLAN}" "${CHOSEN_ID}")
    ip link del "${veth_h}" 2>/dev/null || true
    log "shutdown: removed guest veth ${veth_h}"

    # Clean transient public IP state.
    # For isolated networks the state dir is per-network, so wipe it entirely.
    # For VPC networks the ips/ dir is shared across all tiers; only remove the
    # per-tier rule directories so other tiers are not affected.
    if [ -z "${VPC_ID}" ]; then
        rm -rf "${vsd}/ips" "${vsd}/static-nat" "${vsd}/port-forward"
    else
        rm -rf "${STATE_DIR}/network-${NETWORK_ID}/static-nat" \
               "${STATE_DIR}/network-${NETWORK_ID}/port-forward" 2>/dev/null || true
    fi

    # Stop per-network services (dnsmasq, haproxy, apache2, passwd-server)
    _svc_stop_dnsmasq
    _svc_stop_haproxy
    _svc_stop_apache2
    _svc_stop_passwd_server

    # For isolated networks delete the namespace; VPC namespaces are shared
    # across tiers and must only be deleted when the last tier is destroyed.
    if [ -z "${VPC_ID}" ]; then
        ip netns del "${NAMESPACE}" 2>/dev/null || true
        log "shutdown: deleted namespace ${NAMESPACE}"
    else
        log "shutdown: preserved shared namespace ${NAMESPACE} (VPC tier)"
    fi

    release_lock
    log "shutdown: done network=${NETWORK_ID}"
}

##############################################################################
# Command: destroy
# Delete this network's state entirely.
# For VPC networks the shared namespace is only deleted when this is the last
# remaining tier (tracked via vpc-<vpcId>/tiers/<networkId> marker files).
##############################################################################

cmd_destroy() {
    parse_args "$@"
    _load_state
    acquire_lock "${NETWORK_ID}"

    log "destroy: network=${NETWORK_ID} ns=${NAMESPACE} vpc=${VPC_ID}"

    # Remove this tier's guest veth host-side
    local veth_h
    veth_h=$(veth_host_name "${VLAN}" "${CHOSEN_ID}")
    ip link del "${veth_h}" 2>/dev/null || true

    local vsd; vsd=$(_vpc_state_dir)

    # Remove public veth pairs that belong to THIS tier (guarded by .tier file).
    # IPs owned by other tiers are left untouched so those tiers keep working.
    # Backward compat: if no .tier file exists assume the IP belongs here.
    if [ -d "${vsd}/ips" ]; then
        for f in "${vsd}/ips/"*.pvlan; do
            [ -f "${f}" ] || continue
            local tier_f; tier_f="${f%.pvlan}.tier"
            if [ -f "${tier_f}" ]; then
                local owner_tier; owner_tier=$(cat "${tier_f}" 2>/dev/null || true)
                if [ -n "${owner_tier}" ] && [ "${owner_tier}" != "${NETWORK_ID}" ]; then
                    log "destroy: skipping veth for $(basename "${f%.pvlan}") (owned by tier ${owner_tier})"
                    continue
                fi
            fi
            local pvlan pveth_h
            pvlan=$(cat "${f}")
            pveth_h=$(pub_veth_host_name "${pvlan}" "${CHOSEN_ID}")
            ip link del "${pveth_h}" 2>/dev/null || true
            rm -f "${f}" "${f%.pvlan}" "${tier_f}" 2>/dev/null || true
        done
    fi

    # Stop per-network services before removing state
    _svc_stop_dnsmasq
    _svc_stop_haproxy
    _svc_stop_apache2
    _svc_stop_passwd_server

    # Remove this network's per-tier state directory
    rm -rf "$(_net_state_dir)"

    # Deregister this tier from VPC tracking
    if [ -n "${VPC_ID}" ]; then
        rm -f "${vsd}/tiers/${NETWORK_ID}" 2>/dev/null || true
        # Only delete the VPC-wide namespace and state when no more tiers remain
        local remaining_tiers
        remaining_tiers=$(find "${vsd}/tiers/" -type f 2>/dev/null | wc -l)
        if [ "${remaining_tiers}" -le 0 ]; then
            if ip netns list 2>/dev/null | grep -q "^${NAMESPACE}\b"; then
                ip netns del "${NAMESPACE}"
                log "destroy: deleted shared namespace ${NAMESPACE} (last VPC tier)"
            fi
            rm -rf "${vsd}"
            log "destroy: removed VPC state dir ${vsd}"
        else
            log "destroy: preserved namespace ${NAMESPACE} (${remaining_tiers} tier(s) remaining)"
        fi
    else
        # Isolated network: delete the namespace directly
        if ip netns list 2>/dev/null | grep -q "^${NAMESPACE}\b"; then
            ip netns del "${NAMESPACE}"
            log "destroy: deleted namespace ${NAMESPACE}"
        fi
    fi

    release_lock
    log "destroy: done network=${NETWORK_ID}"
}

##############################################################################
# Command: assign-ip
#
# Creates a public veth pair for the given public IP/VLAN, assigns the IP
# to the namespace end, and configures source NAT if requested.
##############################################################################

cmd_assign_ip() {
    parse_args "$@"
    _load_state
    acquire_lock "${NETWORK_ID}"

    log "assign-ip: network=${NETWORK_ID} ns=${NAMESPACE} ip=${PUBLIC_IP} source_nat=${SOURCE_NAT}"
    [ -z "${PUBLIC_IP}" ]   && die "Missing --public-ip"
    [ -z "${PUBLIC_VLAN}" ] && die "Missing --public-vlan"

    local pveth_h pveth_n nchain_post fchain
    pveth_h=$(pub_veth_host_name "${PUBLIC_VLAN}" "${CHOSEN_ID}")
    pveth_n=$(pub_veth_ns_name   "${PUBLIC_VLAN}" "${CHOSEN_ID}")
    nchain_post="${CHAIN_PREFIX}_${NETWORK_ID}_POST"
    fchain=$(filter_chain "${NETWORK_ID}")

    # ---- Ensure public host bridge ----
    ensure_host_bridge "${PUB_ETH}" "${PUBLIC_VLAN}"
    local pub_br
    pub_br=$(host_bridge_name "${PUB_ETH}" "${PUBLIC_VLAN}")

    # ---- Create public veth pair (idempotent) ----
    if ! ip link show "${pveth_h}" >/dev/null 2>&1; then
        ip link add "${pveth_h}" type veth peer name "${pveth_n}"
        ip link set "${pveth_n}" netns "${NAMESPACE}"
        ip link set "${pveth_h}" master "${pub_br}"
        ip link set "${pveth_h}" up
        ip netns exec "${NAMESPACE}" ip link set "${pveth_n}" up
        log "Created public veth ${pveth_h} (host→${pub_br}) <-> ${pveth_n} (namespace)"
    else
        ip link set "${pveth_h}" up 2>/dev/null || true
        ip netns exec "${NAMESPACE}" ip link set "${pveth_n}" up 2>/dev/null || true
    fi

    # ---- Assign public IP to namespace end ----
    local ADDR_SPEC
    if [ -n "${PUBLIC_CIDR}" ] && echo "${PUBLIC_CIDR}" | grep -q '/'; then
        local PREFIX
        PREFIX=$(echo "${PUBLIC_CIDR}" | cut -d'/' -f2)
        ADDR_SPEC="${PUBLIC_IP}/${PREFIX}"
    else
        ADDR_SPEC="${PUBLIC_IP}/32"
    fi
    ip netns exec "${NAMESPACE}" ip addr show "${pveth_n}" 2>/dev/null | \
        grep -q "${PUBLIC_IP}/" || \
        ip netns exec "${NAMESPACE}" ip addr add "${ADDR_SPEC}" dev "${pveth_n}"

    # ---- Host route for incoming traffic ----
    ip route show | grep -q "^${PUBLIC_IP}" || \
        ip route add "${PUBLIC_IP}/32" dev "${pveth_h}" 2>/dev/null || true

    # ---- Gratuitous ARP to flush upstream gateway's ARP cache ----
    # After a network restart the veth is recreated with a new MAC address.
    # Without a gratuitous ARP the upstream gateway retains the stale ARP entry
    # for the old MAC and packets cannot reach the new veth.
    # Use _find_arping to locate the binary in PATH and common sbin locations.
    local _arping_bin; _arping_bin=$(_find_arping) || true
    if [ -n "${_arping_bin}" ]; then
        ip netns exec "${NAMESPACE}" "${_arping_bin}" -c 3 -U -I "${pveth_n}" "${PUBLIC_IP}" \
            >/dev/null 2>&1 || true
        log "assign-ip: sent gratuitous ARP for ${PUBLIC_IP} on ${pveth_n}"
    else
        log "assign-ip: arping not available — skipping gratuitous ARP for ${PUBLIC_IP}"
    fi

    # ---- Default route inside namespace toward upstream gateway ----
    if [ -n "${PUBLIC_GATEWAY}" ]; then
        ip netns exec "${NAMESPACE}" ip route replace default \
            via "${PUBLIC_GATEWAY}" dev "${pveth_n}" 2>/dev/null || \
        ip netns exec "${NAMESPACE}" ip route add default \
            via "${PUBLIC_GATEWAY}" dev "${pveth_n}" 2>/dev/null || true
        log "Default route in ${NAMESPACE}: via ${PUBLIC_GATEWAY} dev ${pveth_n}"
    fi

    # ---- Source NAT ----
    if [ "${SOURCE_NAT}" = "true" ] && [ -n "${CIDR}" ]; then
        ip netns exec "${NAMESPACE}" iptables -t nat \
            -C "${nchain_post}" -s "${CIDR}" -o "${pveth_n}" -j SNAT --to-source "${PUBLIC_IP}" 2>/dev/null || \
        ip netns exec "${NAMESPACE}" iptables -t nat \
            -A "${nchain_post}" -s "${CIDR}" -o "${pveth_n}" -j SNAT --to-source "${PUBLIC_IP}"
        ip netns exec "${NAMESPACE}" iptables -t filter \
            -C "${fchain}" -o "${pveth_n}" -s "${CIDR}" -j ACCEPT 2>/dev/null || \
        ip netns exec "${NAMESPACE}" iptables -t filter \
            -A "${fchain}" -o "${pveth_n}" -s "${CIDR}" -j ACCEPT
        log "Source NAT: ${CIDR} -> ${PUBLIC_IP} via ${pveth_n}"
    fi

    # ---- Persist state ----
    # Public IP state is VPC-wide (shared across all tiers in a VPC)
    local vsd; vsd=$(_vpc_state_dir)
    mkdir -p "${vsd}/ips"
    echo "${SOURCE_NAT}"  > "${vsd}/ips/${PUBLIC_IP}"
    # Save public VLAN so add-static-nat / add-port-forward can look it up
    echo "${PUBLIC_VLAN}" > "${vsd}/ips/${PUBLIC_IP}.pvlan"
    # Save owning tier (network ID) so cmd_destroy only cleans up its own IPs
    echo "${NETWORK_ID}"  > "${vsd}/ips/${PUBLIC_IP}.tier"

    _dump_iptables "${NAMESPACE}"
    release_lock
    log "assign-ip: done ${PUBLIC_IP} on network ${NETWORK_ID}"
}

##############################################################################
# Command: release-ip
##############################################################################

cmd_release_ip() {
    parse_args "$@"
    _load_state
    acquire_lock "${NETWORK_ID}"

    log "release-ip: network=${NETWORK_ID} ns=${NAMESPACE} ip=${PUBLIC_IP}"
    [ -z "${PUBLIC_IP}" ] && die "Missing --public-ip"

    # Restore PUBLIC_VLAN from state if not on CLI
    local vsd; vsd=$(_vpc_state_dir)
    if [ -z "${PUBLIC_VLAN}" ] && [ -f "${vsd}/ips/${PUBLIC_IP}.pvlan" ]; then
        PUBLIC_VLAN=$(cat "${vsd}/ips/${PUBLIC_IP}.pvlan")
    fi
    [ -z "${PUBLIC_VLAN}" ] && die "release-ip: cannot determine public VLAN for ${PUBLIC_IP}"

    local pveth_h pveth_n nchain_post fchain
    pveth_h=$(pub_veth_host_name "${PUBLIC_VLAN}" "${CHOSEN_ID}")
    pveth_n=$(pub_veth_ns_name   "${PUBLIC_VLAN}" "${CHOSEN_ID}")
    nchain_post="${CHAIN_PREFIX}_${NETWORK_ID}_POST"
    fchain=$(filter_chain "${NETWORK_ID}")

    # Remove SNAT rule
    if [ -n "${CIDR}" ]; then
        ip netns exec "${NAMESPACE}" iptables -t nat \
            -D "${nchain_post}" -s "${CIDR}" -o "${pveth_n}" -j SNAT --to-source "${PUBLIC_IP}" 2>/dev/null || true
        ip netns exec "${NAMESPACE}" iptables -t filter \
            -D "${fchain}" -o "${pveth_n}" -s "${CIDR}" -j ACCEPT 2>/dev/null || true
    fi

    # Remove DNAT rules for this public IP
    local nchain_pr
    nchain_pr="${CHAIN_PREFIX}_${NETWORK_ID}_PR"
    ip netns exec "${NAMESPACE}" iptables -t nat -S "${nchain_pr}" 2>/dev/null | \
        grep -- "-d ${PUBLIC_IP}" | \
        while read -r rule; do
            ip netns exec "${NAMESPACE}" iptables -t nat \
                -D "${nchain_pr}" ${rule#-A ${nchain_pr}} 2>/dev/null || true
        done

    # Remove host route
    ip route del "${PUBLIC_IP}/32" 2>/dev/null || true

    # Remove IP from namespace veth
    if [ -n "${PUBLIC_CIDR}" ] && echo "${PUBLIC_CIDR}" | grep -q '/'; then
        local PREFIX
        PREFIX=$(echo "${PUBLIC_CIDR}" | cut -d'/' -f2)
        ip netns exec "${NAMESPACE}" ip addr del "${PUBLIC_IP}/${PREFIX}" dev "${pveth_n}" 2>/dev/null || true
    fi
    ip netns exec "${NAMESPACE}" ip addr del "${PUBLIC_IP}/32" dev "${pveth_n}" 2>/dev/null || true

    # Delete public veth if no other IPs share the same public VLAN + network id
    local remaining
    remaining=$(find "${vsd}/ips/" -name "*.pvlan" \
        ! -name "${PUBLIC_IP}.pvlan" -exec grep -l "^${PUBLIC_VLAN}$" {} \; 2>/dev/null | wc -l)
    if [ "${remaining}" -eq 0 ]; then
        ip link del "${pveth_h}" 2>/dev/null || true
        log "release-ip: removed public veth ${pveth_h}"
    fi

    # Remove default route if no IPs remain
    if [ -n "${PUBLIC_GATEWAY}" ]; then
        local total_ips
        total_ips=$(find "${vsd}/ips/" -maxdepth 1 \
            -not -name "*.pvlan" -type f 2>/dev/null | wc -l)
        if [ "${total_ips}" -le 1 ]; then
            ip netns exec "${NAMESPACE}" ip route del default \
                via "${PUBLIC_GATEWAY}" dev "${pveth_n}" 2>/dev/null || true
        fi
    fi

    rm -f "${vsd}/ips/${PUBLIC_IP}" \
          "${vsd}/ips/${PUBLIC_IP}.pvlan" \
          "${vsd}/ips/${PUBLIC_IP}.tier"

    _dump_iptables "${NAMESPACE}"
    release_lock
    log "release-ip: done ${PUBLIC_IP} on network ${NETWORK_ID}"
}

##############################################################################
# Command: add-static-nat
##############################################################################

cmd_add_static_nat() {
    parse_args "$@"
    _load_state
    acquire_lock "${NETWORK_ID}"

    log "add-static-nat: network=${NETWORK_ID} ns=${NAMESPACE} ${PUBLIC_IP} <-> ${PRIVATE_IP}"
    [ -z "${PUBLIC_IP}" ]  && die "Missing --public-ip"
    [ -z "${PRIVATE_IP}" ] && die "Missing --private-ip"

    # Restore PUBLIC_VLAN from state (written by assign-ip)
    local vsd; vsd=$(_vpc_state_dir)
    if [ -z "${PUBLIC_VLAN}" ] && [ -f "${vsd}/ips/${PUBLIC_IP}.pvlan" ]; then
        PUBLIC_VLAN=$(cat "${vsd}/ips/${PUBLIC_IP}.pvlan")
    fi
    [ -z "${PUBLIC_VLAN}" ] && die "add-static-nat: cannot determine public VLAN for ${PUBLIC_IP}"

    local pveth_h pveth_n veth_n nchain_pr nchain_post fchain
    pveth_h=$(pub_veth_host_name "${PUBLIC_VLAN}" "${CHOSEN_ID}")
    pveth_n=$(pub_veth_ns_name   "${PUBLIC_VLAN}" "${CHOSEN_ID}")
    veth_n=$(veth_ns_name "${VLAN}" "${CHOSEN_ID}")
    nchain_pr="${CHAIN_PREFIX}_${NETWORK_ID}_PR"
    nchain_post="${CHAIN_PREFIX}_${NETWORK_ID}_POST"
    fchain=$(filter_chain "${NETWORK_ID}")

    ensure_public_ip_on_namespace "${PUBLIC_IP}" "${PUBLIC_CIDR}" "${pveth_n}" "${pveth_h}"

    # DNAT: inbound public IP → private IP (PREROUTING)
    ip netns exec "${NAMESPACE}" iptables -t nat \
        -C "${nchain_pr}" -d "${PUBLIC_IP}" -j DNAT --to-destination "${PRIVATE_IP}" 2>/dev/null || \
    ip netns exec "${NAMESPACE}" iptables -t nat \
        -A "${nchain_pr}" -d "${PUBLIC_IP}" -j DNAT --to-destination "${PRIVATE_IP}"

    # SNAT: outbound private IP → public IP (POSTROUTING, out public veth)
    ip netns exec "${NAMESPACE}" iptables -t nat \
        -C "${nchain_post}" -s "${PRIVATE_IP}" -o "${pveth_n}" -j SNAT --to-source "${PUBLIC_IP}" 2>/dev/null || \
    ip netns exec "${NAMESPACE}" iptables -t nat \
        -A "${nchain_post}" -s "${PRIVATE_IP}" -o "${pveth_n}" -j SNAT --to-source "${PUBLIC_IP}"

    # FORWARD: allow traffic to/from private IP via guest veth
    ip netns exec "${NAMESPACE}" iptables -t filter \
        -C "${fchain}" -d "${PRIVATE_IP}" -o "${veth_n}" -j ACCEPT 2>/dev/null || \
    ip netns exec "${NAMESPACE}" iptables -t filter \
        -A "${fchain}" -d "${PRIVATE_IP}" -o "${veth_n}" -j ACCEPT
    ip netns exec "${NAMESPACE}" iptables -t filter \
        -C "${fchain}" -s "${PRIVATE_IP}" -i "${veth_n}" -j ACCEPT 2>/dev/null || \
    ip netns exec "${NAMESPACE}" iptables -t filter \
        -A "${fchain}" -s "${PRIVATE_IP}" -i "${veth_n}" -j ACCEPT

    mkdir -p "${vsd}/static-nat"
    echo "${PRIVATE_IP}" > "${vsd}/static-nat/${PUBLIC_IP}"

    _dump_iptables "${NAMESPACE}"
    release_lock
    log "add-static-nat: done ${PUBLIC_IP} <-> ${PRIVATE_IP} in ${NAMESPACE}"
}

##############################################################################
# Command: delete-static-nat
##############################################################################

cmd_delete_static_nat() {
    parse_args "$@"
    _load_state
    acquire_lock "${NETWORK_ID}"

    log "delete-static-nat: network=${NETWORK_ID} ns=${NAMESPACE} ${PUBLIC_IP}"
    [ -z "${PUBLIC_IP}" ] && die "Missing --public-ip"

    local vsd; vsd=$(_vpc_state_dir)
    if [ -z "${PRIVATE_IP}" ] && [ -f "${vsd}/static-nat/${PUBLIC_IP}" ]; then
        PRIVATE_IP=$(cat "${vsd}/static-nat/${PUBLIC_IP}")
    fi
    [ -z "${PRIVATE_IP}" ] && die "Missing --private-ip and no saved state"

    # Restore PUBLIC_VLAN from state
    if [ -z "${PUBLIC_VLAN}" ] && [ -f "${vsd}/ips/${PUBLIC_IP}.pvlan" ]; then
        PUBLIC_VLAN=$(cat "${vsd}/ips/${PUBLIC_IP}.pvlan")
    fi
    [ -z "${PUBLIC_VLAN}" ] && die "delete-static-nat: cannot determine public VLAN for ${PUBLIC_IP}"

    local pveth_n veth_n nchain_pr nchain_post fchain
    pveth_n=$(pub_veth_ns_name "${PUBLIC_VLAN}" "${CHOSEN_ID}")
    veth_n=$(veth_ns_name "${VLAN}" "${CHOSEN_ID}")
    nchain_pr="${CHAIN_PREFIX}_${NETWORK_ID}_PR"
    nchain_post="${CHAIN_PREFIX}_${NETWORK_ID}_POST"
    fchain=$(filter_chain "${NETWORK_ID}")

    ip netns exec "${NAMESPACE}" iptables -t nat \
        -D "${nchain_pr}" -d "${PUBLIC_IP}" -j DNAT --to-destination "${PRIVATE_IP}" 2>/dev/null || true
    ip netns exec "${NAMESPACE}" iptables -t nat \
        -D "${nchain_post}" -s "${PRIVATE_IP}" -o "${pveth_n}" -j SNAT --to-source "${PUBLIC_IP}" 2>/dev/null || true
    ip netns exec "${NAMESPACE}" iptables -t filter \
        -D "${fchain}" -d "${PRIVATE_IP}" -o "${veth_n}" -j ACCEPT 2>/dev/null || true
    ip netns exec "${NAMESPACE}" iptables -t filter \
        -D "${fchain}" -s "${PRIVATE_IP}" -i "${veth_n}" -j ACCEPT 2>/dev/null || true

    rm -f "${vsd}/static-nat/${PUBLIC_IP}"

    _dump_iptables "${NAMESPACE}"
    release_lock
    log "delete-static-nat: done ${PUBLIC_IP} <-> ${PRIVATE_IP}"
}

##############################################################################
# Command: add-port-forward
##############################################################################

cmd_add_port_forward() {
    parse_args "$@"
    _load_state
    acquire_lock "${NETWORK_ID}"

    log "add-port-forward: network=${NETWORK_ID} ns=${NAMESPACE} ${PUBLIC_IP}:${PUBLIC_PORT} -> ${PRIVATE_IP}:${PRIVATE_PORT} (${PROTOCOL})"
    [ -z "${PUBLIC_IP}" ]    && die "Missing --public-ip"
    [ -z "${PUBLIC_PORT}" ]  && die "Missing --public-port"
    [ -z "${PRIVATE_IP}" ]   && die "Missing --private-ip"
    [ -z "${PRIVATE_PORT}" ] && die "Missing --private-port"
    [ -z "${PROTOCOL}" ]     && PROTOCOL="tcp"

    # Restore PUBLIC_VLAN from state
    local vsd; vsd=$(_vpc_state_dir)
    if [ -z "${PUBLIC_VLAN}" ] && [ -f "${vsd}/ips/${PUBLIC_IP}.pvlan" ]; then
        PUBLIC_VLAN=$(cat "${vsd}/ips/${PUBLIC_IP}.pvlan")
    fi
    [ -z "${PUBLIC_VLAN}" ] && die "add-port-forward: cannot determine public VLAN for ${PUBLIC_IP}"

    local pveth_h pveth_n veth_n nchain_pr fchain
    pveth_h=$(pub_veth_host_name "${PUBLIC_VLAN}" "${CHOSEN_ID}")
    pveth_n=$(pub_veth_ns_name   "${PUBLIC_VLAN}" "${CHOSEN_ID}")
    veth_n=$(veth_ns_name "${VLAN}" "${CHOSEN_ID}")
    nchain_pr="${CHAIN_PREFIX}_${NETWORK_ID}_PR"
    fchain=$(filter_chain "${NETWORK_ID}")

    ensure_public_ip_on_namespace "${PUBLIC_IP}" "${PUBLIC_CIDR}" "${pveth_n}" "${pveth_h}"

    # DNAT
    ip netns exec "${NAMESPACE}" iptables -t nat \
        -C "${nchain_pr}" -p "${PROTOCOL}" -d "${PUBLIC_IP}" --dport "${PUBLIC_PORT}" \
        -j DNAT --to-destination "${PRIVATE_IP}:${PRIVATE_PORT}" 2>/dev/null || \
    ip netns exec "${NAMESPACE}" iptables -t nat \
        -A "${nchain_pr}" -p "${PROTOCOL}" -d "${PUBLIC_IP}" --dport "${PUBLIC_PORT}" \
        -j DNAT --to-destination "${PRIVATE_IP}:${PRIVATE_PORT}"

    # Allow forwarding for the mapped private port via guest veth
    ip netns exec "${NAMESPACE}" iptables -t filter \
        -C "${fchain}" -p "${PROTOCOL}" -d "${PRIVATE_IP}" --dport "${PRIVATE_PORT}" \
        -o "${veth_n}" -j ACCEPT 2>/dev/null || \
    ip netns exec "${NAMESPACE}" iptables -t filter \
        -A "${fchain}" -p "${PROTOCOL}" -d "${PRIVATE_IP}" --dport "${PRIVATE_PORT}" \
        -o "${veth_n}" -j ACCEPT
    ip netns exec "${NAMESPACE}" iptables -t filter \
        -C "${fchain}" -p "${PROTOCOL}" -s "${PRIVATE_IP}" --sport "${PRIVATE_PORT}" \
        -i "${veth_n}" -j ACCEPT 2>/dev/null || \
    ip netns exec "${NAMESPACE}" iptables -t filter \
        -A "${fchain}" -p "${PROTOCOL}" -s "${PRIVATE_IP}" --sport "${PRIVATE_PORT}" \
        -i "${veth_n}" -j ACCEPT

    local safe_port
    safe_port=$(echo "${PUBLIC_PORT}" | tr ':' '-')
    mkdir -p "${vsd}/port-forward"
    echo "${PROTOCOL} ${PUBLIC_IP} ${PUBLIC_PORT} ${PRIVATE_IP} ${PRIVATE_PORT}" > \
        "${vsd}/port-forward/${PROTOCOL}_${PUBLIC_IP}_${safe_port}"

    _dump_iptables "${NAMESPACE}"
    release_lock
    log "add-port-forward: done ${PUBLIC_IP}:${PUBLIC_PORT} -> ${PRIVATE_IP}:${PRIVATE_PORT}"
}

##############################################################################
# Command: delete-port-forward
##############################################################################

cmd_delete_port_forward() {
    parse_args "$@"
    _load_state
    acquire_lock "${NETWORK_ID}"

    log "delete-port-forward: network=${NETWORK_ID} ns=${NAMESPACE} ${PUBLIC_IP}:${PUBLIC_PORT} -> ${PRIVATE_IP}:${PRIVATE_PORT}"
    [ -z "${PUBLIC_IP}" ]    && die "Missing --public-ip"
    [ -z "${PUBLIC_PORT}" ]  && die "Missing --public-port"
    [ -z "${PRIVATE_IP}" ]   && die "Missing --private-ip"
    [ -z "${PRIVATE_PORT}" ] && die "Missing --private-port"
    [ -z "${PROTOCOL}" ]     && PROTOCOL="tcp"

    local veth_n nchain_pr fchain
    veth_n=$(veth_ns_name "${VLAN}" "${CHOSEN_ID}")
    nchain_pr="${CHAIN_PREFIX}_${NETWORK_ID}_PR"
    fchain=$(filter_chain "${NETWORK_ID}")

    ip netns exec "${NAMESPACE}" iptables -t nat \
        -D "${nchain_pr}" -p "${PROTOCOL}" -d "${PUBLIC_IP}" --dport "${PUBLIC_PORT}" \
        -j DNAT --to-destination "${PRIVATE_IP}:${PRIVATE_PORT}" 2>/dev/null || true
    ip netns exec "${NAMESPACE}" iptables -t filter \
        -D "${fchain}" -p "${PROTOCOL}" -d "${PRIVATE_IP}" --dport "${PRIVATE_PORT}" \
        -o "${veth_n}" -j ACCEPT 2>/dev/null || true
    ip netns exec "${NAMESPACE}" iptables -t filter \
        -D "${fchain}" -p "${PROTOCOL}" -s "${PRIVATE_IP}" --sport "${PRIVATE_PORT}" \
        -i "${veth_n}" -j ACCEPT 2>/dev/null || true

    local safe_port
    safe_port=$(echo "${PUBLIC_PORT}" | tr ':' '-')
    local vsd; vsd=$(_vpc_state_dir)
    rm -f "${vsd}/port-forward/${PROTOCOL}_${PUBLIC_IP}_${safe_port}"

    _dump_iptables "${NAMESPACE}"
    release_lock
    log "delete-port-forward: done"
}

##############################################################################
# Helpers: path accessors  (require NETWORK_ID to be set)
#
# Per-network state  → _net_state_dir() = ${STATE_DIR}/network-<networkId>
# VPC-wide state     → _vpc_state_dir() = ${STATE_DIR}/vpc-<vpcId>  (or same as net for isolated)
##############################################################################

_dnsmasq_dir()        { echo "$(_net_state_dir)/dnsmasq"; }
_dnsmasq_conf()       { echo "$(_net_state_dir)/dnsmasq/dnsmasq.conf"; }
_dnsmasq_pid()        { echo "$(_net_state_dir)/dnsmasq/dnsmasq.pid"; }
_dnsmasq_hosts()      { echo "$(_net_state_dir)/dnsmasq/hosts"; }
_dnsmasq_dhcp_hosts() { echo "$(_net_state_dir)/dnsmasq/dhcp-hosts"; }
_dnsmasq_dhcp_opts()  { echo "$(_net_state_dir)/dnsmasq/dhcp-opts"; }

_haproxy_dir()  { echo "$(_net_state_dir)/haproxy"; }
_haproxy_conf() { echo "$(_net_state_dir)/haproxy/haproxy.cfg"; }
_haproxy_pid()  { echo "$(_net_state_dir)/haproxy/haproxy.pid"; }
_haproxy_sock() { echo "$(_net_state_dir)/haproxy/haproxy.sock"; }

_apache2_dir()  { echo "$(_net_state_dir)/apache2"; }
_apache2_conf() { echo "$(_net_state_dir)/apache2/apache2.conf"; }
_apache2_pid()  { echo "$(_net_state_dir)/apache2/apache2.pid"; }
_metadata_dir() { echo "$(_net_state_dir)/metadata"; }
_apache2_cgi()  { echo "$(_net_state_dir)/apache2/metadata.cgi"; }

# Password server (VR-compatible, port 8080, DomU_Request protocol)
_passwd_file()          { echo "$(_net_state_dir)/passwords"; }
_passwd_server_pid()    { echo "$(_net_state_dir)/passwd-server.pid"; }
_passwd_server_script() { echo "$(_net_state_dir)/passwd-server.py"; }

##############################################################################
# Helpers: binary detection
##############################################################################

_find_apache2_bin() {
    for bin in apache2 httpd /usr/sbin/apache2 /usr/sbin/httpd; do
        command -v "${bin}" >/dev/null 2>&1 && echo "${bin}" && return
    done
    echo "apache2"
}

_find_apache2_modules_dir() {
    for d in /usr/lib/apache2/modules /usr/lib64/apache2/modules \
              /usr/libexec/apache2   /usr/lib/httpd/modules \
              /usr/libexec/httpd  /usr/lib64/httpd/modules/; do
        [ -d "${d}" ] && echo "${d}" && return
    done
    echo "/usr/lib/apache2/modules"
}

_apache2_user() {
    id www-data >/dev/null 2>&1 && echo "www-data" && return
    id apache    >/dev/null 2>&1 && echo "apache"   && return
    echo "nobody"
}

# Locate the arping binary; checks PATH first, then common sbin paths.
# Prints the path and returns 0 on success, returns 1 when not found.
_find_arping() {
    local bin
    for bin in arping /usr/bin/arping /usr/sbin/arping /sbin/arping; do
        if command -v "${bin}" >/dev/null 2>&1 || [ -x "${bin}" ]; then
            echo "${bin}"
            return 0
        fi
    done
    return 1
}

##############################################################################
# Helpers: dnsmasq  (DHCP + DNS via the same process)
##############################################################################

# _cidr_dhcp_range <cidr> <gateway>  → "<start>,<end>,<netmask>"
_cidr_dhcp_range() {
    local ext_ip; ext_ip="${EXTENSION_IP:-${GATEWAY}}"
    echo "${ext_ip},static"
}

# _write_dnsmasq_conf <dns_enabled: true|false>
# Requires: NETWORK_ID, VLAN, CHOSEN_ID, CIDR, GATEWAY, DNS_SERVER
_write_dnsmasq_conf() {
    local dns_enabled="${1:-false}"
    local dir; dir=$(_dnsmasq_dir)
    mkdir -p "${dir}"

    local dhcp_hosts; dhcp_hosts=$(_dnsmasq_dhcp_hosts)
    local hosts;      hosts=$(_dnsmasq_hosts)
    local dhcp_opts;  dhcp_opts=$(_dnsmasq_dhcp_opts)
    touch "${dhcp_hosts}" "${hosts}" "${dhcp_opts}"

    local veth_n; veth_n=$(veth_ns_name "${VLAN}" "${CHOSEN_ID}")
    local dhcp_range; dhcp_range=$(_cidr_dhcp_range "${CIDR}" "${GATEWAY}")
    local port_line="port=0"
    [ "${dns_enabled}" = "true" ] && port_line="port=53"

    cat > "$(_dnsmasq_conf)" << EOF
# Auto-generated by network-namespace-wrapper.sh — do not edit
${port_line}
interface=${veth_n}
#no-hosts
bind-interfaces
localise-queries
pid-file=$(_dnsmasq_pid)
dhcp-range=${dhcp_range},12h
dhcp-option=3,${GATEWAY}
dhcp-hostsfile=${dhcp_hosts}
addn-hosts=${hosts}
dhcp-optsfile=${dhcp_opts}
log-facility=/var/log/cloudstack/network-namespace-dnsmasq-${NETWORK_ID}.log
EOF
    # Add DHCP option 15 (domain-search) when provided by the caller
    if [ -n "${DOMAIN}" ]; then
        echo "dhcp-option=15,\"${DOMAIN}\"" >> "$(_dnsmasq_conf)"
        echo "domain=${DOMAIN}" >> "$(_dnsmasq_conf)"
        echo "expand-hosts" >> "$(_dnsmasq_conf)"
    fi
    local ext_ip; ext_ip="${EXTENSION_IP:-${GATEWAY}}"
    [ -n "${DNS_SERVER}" ] && echo "dhcp-option=6,${ext_ip},${DNS_SERVER}" >> "$(_dnsmasq_conf)"
    [ -z "${DNS_SERVER}" ] && echo "dhcp-option=6,${ext_ip}" >> "$(_dnsmasq_conf)"
    log "dnsmasq: wrote config $(_dnsmasq_conf) (dns_enabled=${dns_enabled})"
}

_svc_start_or_reload_dnsmasq() {
    local pid_f; pid_f=$(_dnsmasq_pid)
    if [ -f "${pid_f}" ] && kill -0 "$(cat "${pid_f}")" 2>/dev/null; then
        log "dnsmasq: sending SIGHUP to reload (pid=$(cat "${pid_f}"))"
        ip netns exec "${NAMESPACE}" kill -HUP "$(cat "${pid_f}")" 2>/dev/null || true
    else
        log "dnsmasq: starting in namespace ${NAMESPACE}"
        if ! ip netns exec "${NAMESPACE}" dnsmasq --conf-file="$(_dnsmasq_conf)"; then
            log "WARNING: dnsmasq start failed — is dnsmasq installed on this host?"
        fi
    fi
}

_svc_stop_dnsmasq() {
    local pid_f; pid_f=$(_dnsmasq_pid)
    if [ -f "${pid_f}" ]; then
        local pid; pid=$(cat "${pid_f}")
        kill "${pid}" 2>/dev/null || true
        rm -f "${pid_f}"
        log "dnsmasq: stopped (pid=${pid})"
    fi
    # Kill any orphaned dnsmasq for this network
    pkill -f "dnsmasq.*${NETWORK_ID}" 2>/dev/null || true
}

##############################################################################
# Helpers: haproxy  (LB via haproxy)
##############################################################################

# Regenerate haproxy config from all persisted per-rule JSON files.
# Requires: NETWORK_ID
_write_haproxy_conf() {
    local lb_dir; lb_dir=$(_haproxy_dir)
    local pid_f;  pid_f=$(_haproxy_pid)
    local sock_f; sock_f=$(_haproxy_sock)
    mkdir -p "${lb_dir}"

    python3 - "${lb_dir}" "${pid_f}" "${sock_f}" > "$(_haproxy_conf)" 2>/dev/null << 'PYEOF'
import json, os, sys

lb_dir   = sys.argv[1]
pid_file = sys.argv[2]
sock     = sys.argv[3]

rules = []
if os.path.isdir(lb_dir):
    for fn in sorted(os.listdir(lb_dir)):
        if fn.endswith('.json'):
            try:
                with open(os.path.join(lb_dir, fn)) as f:
                    r = json.load(f)
                if not r.get('revoke', False):
                    rules.append(r)
            except Exception:
                pass

lines = [
    "global",
    "    daemon",
    "    maxconn 4096",
    "    log /dev/log local0",
    f"    stats socket {sock} mode 660 level admin",
    f"    pidfile {pid_file}",
    "",
    "defaults",
    "    mode tcp",
    "    timeout connect 5s",
    "    timeout client  50s",
    "    timeout server  50s",
    "    log global",
    "",
]

ALG_MAP = {
    'roundrobin': 'roundrobin', 'leastconn': 'leastconn',
    'source': 'source', 'static-rr': 'static-rr',
    'least_conn': 'leastconn',
}

for rule in rules:
    rid      = rule['id']
    pub_ip   = rule.get('publicIp', '')
    pub_port = rule.get('publicPort', 0)
    alg      = ALG_MAP.get(rule.get('algorithm', '').lower(), 'roundrobin')
    backends = [b for b in rule.get('backends', []) if not b.get('revoked', False)]
    if not backends:
        continue
    lines += [
        f"frontend cs_lb_{rid}_front",
        f"    bind {pub_ip}:{pub_port}",
        f"    default_backend cs_lb_{rid}_back",
        "",
        f"backend cs_lb_{rid}_back",
        f"    balance {alg}",
    ]
    for i, b in enumerate(backends):
        bip   = b.get('ip', '')
        bport = b.get('port', pub_port)
        lines.append(f"    server backend_{rid}_{i} {bip}:{bport} check")
    lines.append("")

print('\n'.join(lines))
PYEOF
    log "haproxy: wrote config $(_haproxy_conf)"
}

_svc_reload_haproxy() {
    local conf_f; conf_f=$(_haproxy_conf)
    local pid_f;  pid_f=$(_haproxy_pid)

    if [ -f "${pid_f}" ] && kill -0 "$(cat "${pid_f}")" 2>/dev/null; then
        log "haproxy: reloading"
        if ! ip netns exec "${NAMESPACE}" haproxy -f "${conf_f}" -p "${pid_f}" \
                -sf "$(cat "${pid_f}")" 2>/dev/null; then
            log "WARNING: haproxy reload failed; attempting fresh start"
            rm -f "${pid_f}" 2>/dev/null || true
            if ! ip netns exec "${NAMESPACE}" haproxy -f "${conf_f}" -p "${pid_f}" 2>/dev/null; then
                log "WARNING: haproxy start failed — is haproxy installed on this host?"
            fi
        fi
    else
        log "haproxy: starting in namespace ${NAMESPACE}"
        if ! ip netns exec "${NAMESPACE}" haproxy -f "${conf_f}" -p "${pid_f}" 2>/dev/null; then
            log "WARNING: haproxy start failed — is haproxy installed on this host?"
        fi
    fi
}

_svc_stop_haproxy() {
    local pid_f; pid_f=$(_haproxy_pid)
    if [ -f "${pid_f}" ]; then
        local pid; pid=$(cat "${pid_f}")
        ip netns exec "${NAMESPACE}" kill "${pid}" 2>/dev/null || kill "${pid}" 2>/dev/null || true
        rm -f "${pid_f}"
        log "haproxy: stopped (pid=${pid})"
    fi
}

##############################################################################
# Helpers: apache2  (userdata / metadata HTTP service)
#
# apache2 runs inside the namespace, listening on <EXTENSION_IP>:80.
# EXTENSION_IP equals the network gateway when SourceNat/Gateway is enabled,
# or a dedicated placeholder IP otherwise.  Falls back to GATEWAY when absent.
#
# Files served:
#   ${STATE_DIR}/<NETWORK_ID>/metadata/<VM_IP>/latest/user-data
#   ${STATE_DIR}/<NETWORK_ID>/metadata/<VM_IP>/latest/meta-data/public-keys
#   ${STATE_DIR}/<NETWORK_ID>/metadata/<VM_IP>/latest/meta-data/hypervisor-hostname
#   ${STATE_DIR}/<NETWORK_ID>/metadata/<VM_IP>/latest/meta-data/local-hostname
#
# Apache2 uses a CGI script to dispatch requests to the per-IP subtree.
##############################################################################

_write_apache2_conf() {
    local dir;  dir=$(_apache2_dir)
    local www;  www=$(_metadata_dir)
    local cgi;  cgi=$(_apache2_cgi)
    local mods; mods=$(_find_apache2_modules_dir)
    local apuser; apuser=$(_apache2_user)
    mkdir -p "${dir}" "${www}"

    # ---- CGI dispatcher script ----
    cat > "${cgi}" << 'CGISCRIPT'
#!/bin/bash
# Metadata/userdata CGI dispatcher – EC2-compatible directory listing support.
# Requests are identified by REMOTE_ADDR (the VM's IP on this network).
CLIENT="${REMOTE_ADDR}"
BASEDIR="$(dirname "$0")/../metadata"
REQ="${PATH_INFO:-${REQUEST_URI}}"
# Strip query string if present
REQ="${REQ%%\?*}"
# Remove leading slash
REQ="${REQ#/}"
# Resolve path, stripping any trailing slash for filesystem lookup
TARGET="${BASEDIR}/${CLIENT}/${REQ%/}"

if [ -f "${TARGET}" ]; then
    # Regular file – serve contents
    printf 'Content-Type: text/plain\r\n\r\n'
    cat "${TARGET}"
elif [ -d "${TARGET}" ]; then
    # Directory – return a newline-delimited list of entries (EC2 API style).
    # Sub-directories are listed with a trailing '/'.
    printf 'Content-Type: text/plain\r\n\r\n'
    for item in "${TARGET}/"*; do
        [ -e "${item}" ] || continue          # skip empty glob
        name=$(basename "${item}")
        if [ -d "${item}" ]; then
            printf '%s/\n' "${name}"
        else
            printf '%s\n' "${name}"
        fi
    done
else
    printf 'Status: 404 Not Found\r\nContent-Type: text/plain\r\n\r\nNot found\n'
fi
CGISCRIPT
    chmod +x "${cgi}"

    # ---- Detect MPM module ----
    local mpm_mod="mpm_event_module"
    local mpm_so="mod_mpm_event.so"
    if [ ! -f "${mods}/${mpm_so}" ] && [ -f "${mods}/mod_mpm_prefork.so" ]; then
        mpm_mod="mpm_prefork_module"; mpm_so="mod_mpm_prefork.so"
    fi

    # ---- Check for authz_core (required in apache2 >= 2.4) ----
    local authz_line=""
    [ -f "${mods}/mod_authz_core.so" ] && \
        authz_line="LoadModule authz_core_module ${mods}/mod_authz_core.so"

    local unixd_line=""
    [ -f "${mods}/mod_unixd.so" ] && \
        unixd_line="LoadModule unixd_module ${mods}/mod_unixd.so"

    local require_line="Allow from all"
    [ -f "${mods}/mod_authz_core.so" ] && require_line="Require all granted"

    # Use EXTENSION_IP as the listen address; fall back to GATEWAY when absent.
    local listen_ip; listen_ip="${EXTENSION_IP:-${GATEWAY}}"

    cat > "$(_apache2_conf)" << EOF
# Auto-generated by network-namespace-wrapper.sh — do not edit
ServerRoot /tmp
PidFile $(_apache2_pid)
ServerName metadata-${NETWORK_ID}
Listen ${listen_ip}:80
#User ${apuser}
#Group ${apuser}

LoadModule ${mpm_mod} ${mods}/${mpm_so}
LoadModule cgi_module ${mods}/mod_cgi.so
LoadModule alias_module ${mods}/mod_alias.so
${unixd_line}
${authz_line}

DocumentRoot ${www}
ErrorLog /var/log/cloudstack/network-namespace-apache2-${NETWORK_ID}.log

<VirtualHost ${listen_ip}:80>
    ServerName metadata
    ScriptAlias / ${cgi}/
    <Directory ${dir}>
        Options +ExecCGI
        AllowOverride None
        ${require_line}
    </Directory>
</VirtualHost>
EOF
    log "apache2: wrote config $(_apache2_conf) (listen=${listen_ip}:80)"
}

_svc_start_or_reload_apache2() {
    local bin; bin=$(_find_apache2_bin)
    local pid_f; pid_f=$(_apache2_pid)

    if [ -f "${pid_f}" ] && kill -0 "$(cat "${pid_f}")" 2>/dev/null; then
        log "apache2: graceful restart (pid=$(cat "${pid_f}"))"
        ip netns exec "${NAMESPACE}" "${bin}" -f "$(_apache2_conf)" -k graceful 2>/dev/null || \
            log "WARNING: apache2 graceful restart failed"
    else
        log "apache2: starting in namespace ${NAMESPACE}"
        if ! ip netns exec "${NAMESPACE}" "${bin}" -f "$(_apache2_conf)" -k start 2>/dev/null; then
            log "WARNING: apache2 start failed — is apache2/httpd installed on this host?"
        fi
    fi

    # Allow metadata traffic inbound to the namespace (INPUT) from guest subnet only.
    if [ -n "${CIDR}" ]; then
        ip netns exec "${NAMESPACE}" iptables -t filter \
            -C INPUT -p tcp -s "${CIDR}" --dport 80 -j ACCEPT 2>/dev/null || \
        ip netns exec "${NAMESPACE}" iptables -t filter \
            -A INPUT -p tcp -s "${CIDR}" --dport 80 -j ACCEPT
    fi
}

_svc_stop_apache2() {
    local bin; bin=$(_find_apache2_bin)
    local pid_f; pid_f=$(_apache2_pid)

    if [ -f "${pid_f}" ] && kill -0 "$(cat "${pid_f}")" 2>/dev/null; then
        local pid; pid=$(cat "${pid_f}")
        ip netns exec "${NAMESPACE}" "${bin}" -f "$(_apache2_conf)" -k stop 2>/dev/null || \
            kill "${pid}" 2>/dev/null || true
        rm -f "${pid_f}"
        log "apache2: stopped (pid=${pid})"
    fi
}

##############################################################################
# Helpers: passwd-server  (CloudStack VR-compatible password service)
#
# Listens on <EXTENSION_IP>:8080 inside the namespace.
# EXTENSION_IP equals the network gateway when SourceNat/Gateway is enabled,
# or a dedicated placeholder IP otherwise.  Falls back to GATEWAY when absent.
# Protocol (identical to VR passwd_server_ip.py):
#   GET DomU_Request: send_my_password  → return password for REMOTE_ADDR
#   GET DomU_Request: saved_password    → remove password + ack
#
# Passwords are stored in ${STATE_DIR}/<NETWORK_ID>/passwords as ip=password lines.
##############################################################################

_svc_start_or_reload_passwd_server() {
    local script_f; script_f=$(_passwd_server_script)
    local pid_f;    pid_f=$(_passwd_server_pid)
    local passwd_f; passwd_f=$(_passwd_file)
    local log_f;    log_f="/var/log/cloudstack/network-namespace-passwd-${NETWORK_ID}.log"

    mkdir -p "$(dirname "${script_f}")"
    touch "${passwd_f}"

    # Write the embedded Python password server (same protocol as VR passwd_server_ip.py)
    cat > "${script_f}" << 'PYEOF'
#!/usr/bin/env python3
import os, sys, threading, syslog
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

gateway     = sys.argv[1] if len(sys.argv) > 1 else '0.0.0.0'
passwd_file = sys.argv[2] if len(sys.argv) > 2 else '/tmp/passwords'
pid_file    = sys.argv[3] if len(sys.argv) > 3 else '/tmp/passwd-server.pid'

lock = threading.RLock()

# Write PID so the shell wrapper can manage us
with open(pid_file, 'w') as _f:
    _f.write(str(os.getpid()))

def get_password(ip):
    """Read password for ip from the passwords file (re-read on every call)."""
    try:
        with open(passwd_file) as f:
            for line in f:
                line = line.strip()
                if '=' in line:
                    k, v = line.split('=', 1)
                    if k == ip:
                        return v
    except Exception:
        pass
    return None

def remove_password(ip):
    """Remove the password entry for ip from the passwords file."""
    with lock:
        try:
            lines = []
            with open(passwd_file) as f:
                for line in f:
                    if '=' not in line or line.strip().split('=', 1)[0] != ip:
                        lines.append(line)
            with open(passwd_file, 'w') as f:
                f.writelines(lines)
        except Exception:
            pass

class PasswordRequestHandler(BaseHTTPRequestHandler):
    server_version = 'CloudStack Password Server'
    sys_version    = '4.x'

    def do_GET(self):
        req_type = self.headers.get('DomU_Request', '')
        client_ip = self.client_address[0]
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.end_headers()
        if req_type == 'send_my_password':
            pw = get_password(client_ip)
            if pw:
                self.wfile.write(pw.encode())
                syslog.syslog(f'passwd-server: password sent to {client_ip}')
            else:
                self.wfile.write(b'saved_password')
                syslog.syslog(f'passwd-server: no password for {client_ip}')
        elif req_type == 'saved_password':
            remove_password(client_ip)
            self.wfile.write(b'saved_password')
            syslog.syslog(f'passwd-server: saved_password ack from {client_ip}')
        else:
            self.wfile.write(b'bad_request')

    def log_message(self, fmt, *args):
        pass  # silence access log; syslog used above

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    allow_reuse_address = True

server = ThreadedHTTPServer((gateway, 8080), PasswordRequestHandler)
syslog.syslog(f'passwd-server: listening on {gateway}:8080 (pid={os.getpid()})')
server.serve_forever()
PYEOF
    chmod +x "${script_f}"

    # Only start if not already running; the iptables rule is (re-)applied regardless
    # so that it is always present in the current namespace after a cleanup restart.
    if [ -f "${pid_f}" ] && kill -0 "$(cat "${pid_f}")" 2>/dev/null; then
        log "passwd-server: already running (pid=$(cat "${pid_f}"))"
    else
        # Use EXTENSION_IP as the listen address; fall back to GATEWAY when absent.
        local listen_ip; listen_ip="${EXTENSION_IP:-${GATEWAY}}"
        log "passwd-server: starting in namespace ${NAMESPACE} on ${listen_ip}:8080"
        ip netns exec "${NAMESPACE}" python3 "${script_f}" \
            "${listen_ip}" "${passwd_f}" "${pid_f}" \
            >> "${log_f}" 2>&1 &
        # Brief pause to let the server write its PID
        sleep 0.3
    fi

    # Always ensure the iptables INPUT rule is present (idempotent).
    if [ -n "${CIDR}" ]; then
        ip netns exec "${NAMESPACE}" iptables -t filter \
            -C INPUT -p tcp -s "${CIDR}" --dport 8080 -j ACCEPT 2>/dev/null || \
        ip netns exec "${NAMESPACE}" iptables -t filter \
            -A INPUT -p tcp -s "${CIDR}" --dport 8080 -j ACCEPT
    fi
}

_svc_stop_passwd_server() {
    local pid_f; pid_f=$(_passwd_server_pid)
    if [ -f "${pid_f}" ]; then
        local pid; pid=$(cat "${pid_f}")
        kill "${pid}" 2>/dev/null || true
        rm -f "${pid_f}"
        log "passwd-server: stopped (pid=${pid})"
    fi
    # Kill any orphaned instance for this network
    pkill -f "python3.*passwd-server.*${NETWORK_ID}" 2>/dev/null || true
}

##############################################################################
# Command: config-dhcp-subnet
# Configure dnsmasq for DHCP (DNS disabled at port 53).
##############################################################################

cmd_config_dhcp_subnet() {
    parse_args "$@"
    _load_state
    acquire_lock "${NETWORK_ID}"
    log "config-dhcp-subnet: network=${NETWORK_ID} ns=${NAMESPACE} gw=${GATEWAY} cidr=${CIDR}"
    [ -z "${GATEWAY}" ] && die "config-dhcp-subnet: missing --gateway"
    [ -z "${CIDR}" ]    && die "config-dhcp-subnet: missing --cidr"
    _write_dnsmasq_conf false
    _svc_start_or_reload_dnsmasq
    release_lock
    log "config-dhcp-subnet: done network=${NETWORK_ID}"
}

##############################################################################
# Command: config-dns-subnet
# Configure dnsmasq for DNS (also enables DHCP; DNS on port 53).
##############################################################################

cmd_config_dns_subnet() {
    parse_args "$@"
    _load_state
    acquire_lock "${NETWORK_ID}"
    log "config-dns-subnet: network=${NETWORK_ID} ns=${NAMESPACE} gw=${GATEWAY} cidr=${CIDR}"
    [ -z "${GATEWAY}" ] && die "config-dns-subnet: missing --gateway"
    [ -z "${CIDR}" ]    && die "config-dns-subnet: missing --cidr"
    # Ensure the per-network hosts file contains an entry for the namespace
    # extension IP named 'data-server' (idempotent).
    # Use EXTENSION_IP when provided; fall back to GATEWAY.
    local data_server_ip; data_server_ip="${EXTENSION_IP:-${GATEWAY}}"
    local hosts_f; hosts_f=$(_dnsmasq_hosts)
    mkdir -p "$(dirname "${hosts_f}")"
    touch "${hosts_f}"
    # Remove any existing data-server lines, then append the desired mapping
    grep -v -E "\sdata-server(\s|$)" "${hosts_f}" > "${hosts_f}.tmp" 2>/dev/null || true
    mv "${hosts_f}.tmp" "${hosts_f}"
    # Add the mapping: <extension-ip>  data-server
    echo "${data_server_ip} data-server" >> "${hosts_f}"

    _write_dnsmasq_conf true
    _svc_start_or_reload_dnsmasq
    release_lock
    log "config-dns-subnet: done network=${NETWORK_ID}"
}

##############################################################################
# Command: remove-dhcp-subnet
# Tear down dnsmasq DHCP for this network.
##############################################################################

cmd_remove_dhcp_subnet() {
    parse_args "$@"
    _load_state
    acquire_lock "${NETWORK_ID}"
    log "remove-dhcp-subnet: network=${NETWORK_ID}"
    _svc_stop_dnsmasq
    rm -rf "$(_dnsmasq_dir)"
    release_lock
    log "remove-dhcp-subnet: done network=${NETWORK_ID}"
}

##############################################################################
# Command: remove-dns-subnet
# Disable DNS (port 53) but keep DHCP running if configured.
##############################################################################

cmd_remove_dns_subnet() {
    parse_args "$@"
    _load_state
    acquire_lock "${NETWORK_ID}"
    log "remove-dns-subnet: network=${NETWORK_ID}"
    if [ -f "$(_dnsmasq_conf)" ]; then
        _write_dnsmasq_conf false
        _svc_start_or_reload_dnsmasq
    fi
    release_lock
    log "remove-dns-subnet: done network=${NETWORK_ID}"
}

##############################################################################
# Command: add-dhcp-entry
# Add a static DHCP host entry (mac→ip) to dnsmasq.
##############################################################################

cmd_add_dhcp_entry() {
    parse_args "$@"
    _load_state
    acquire_lock "${NETWORK_ID}"
    log "add-dhcp-entry: network=${NETWORK_ID} mac=${MAC} ip=${VM_IP} hostname=${HOSTNAME}"
    [ -z "${MAC}" ]   && die "add-dhcp-entry: missing --mac"
    [ -z "${VM_IP}" ] && die "add-dhcp-entry: missing --ip"

    local dhcp_hosts; dhcp_hosts=$(_dnsmasq_dhcp_hosts)
    mkdir -p "$(_dnsmasq_dir)"
    touch "${dhcp_hosts}"

    # Normalize MAC for use as a dnsmasq tag (colons → underscores, lowercase)
    local mac_tag; mac_tag=$(echo "${MAC}" | tr ':' '_' | tr '[:upper:]' '[:lower:]')

    # Remove any existing entry for this MAC (with or without a tag prefix)
    grep -v "${MAC}" "${dhcp_hosts}" > "${dhcp_hosts}.tmp" 2>/dev/null || true
    mv "${dhcp_hosts}.tmp" "${dhcp_hosts}"

    if [ "${DEFAULT_NIC}" = "false" ]; then
        # Non-default NIC: tag the host so we can suppress the gateway option.
        # dnsmasq set:<tag> in dhcp-hosts assigns the tag for this MAC.
        if [ -n "${HOSTNAME}" ]; then
            echo "set:norouter_${mac_tag},${MAC},${VM_IP},${HOSTNAME},infinite" >> "${dhcp_hosts}"
        else
            echo "set:norouter_${mac_tag},${MAC},${VM_IP},infinite" >> "${dhcp_hosts}"
        fi
        # Suppress option 3 (default gateway) for this specific MAC so the VM
        # does not get a competing default route via this secondary NIC.
        local dhcp_opts; dhcp_opts=$(_dnsmasq_dhcp_opts)
        touch "${dhcp_opts}"
        grep -v "tag:norouter_${mac_tag}" "${dhcp_opts}" > "${dhcp_opts}.tmp" 2>/dev/null || true
        mv "${dhcp_opts}.tmp" "${dhcp_opts}"
        echo "dhcp-option=tag:norouter_${mac_tag},option:router,0.0.0.0" >> "${dhcp_opts}"
        log "add-dhcp-entry: non-default NIC ${MAC} (${VM_IP}) — gateway suppressed for this NIC"
    else
        if [ -n "${HOSTNAME}" ]; then
            echo "${MAC},${VM_IP},${HOSTNAME},infinite" >> "${dhcp_hosts}"
        else
            echo "${MAC},${VM_IP},infinite" >> "${dhcp_hosts}"
        fi
    fi

    _svc_start_or_reload_dnsmasq
    release_lock
    log "add-dhcp-entry: done mac=${MAC} ip=${VM_IP}"
}

##############################################################################
# Command: remove-dhcp-entry
# Remove a static DHCP host entry from dnsmasq.
##############################################################################

cmd_remove_dhcp_entry() {
    parse_args "$@"
    _load_state
    acquire_lock "${NETWORK_ID}"
    log "remove-dhcp-entry: network=${NETWORK_ID} mac=${MAC}"
    [ -z "${MAC}" ] && die "remove-dhcp-entry: missing --mac"

    local dhcp_hosts; dhcp_hosts=$(_dnsmasq_dhcp_hosts)
    if [ -f "${dhcp_hosts}" ]; then
        grep -v "${MAC}" "${dhcp_hosts}" > "${dhcp_hosts}.tmp" 2>/dev/null || true
        mv "${dhcp_hosts}.tmp" "${dhcp_hosts}"
        # Also remove any per-MAC gateway-suppression option
        local mac_tag; mac_tag=$(echo "${MAC}" | tr ':' '_' | tr '[:upper:]' '[:lower:]')
        local dhcp_opts; dhcp_opts=$(_dnsmasq_dhcp_opts)
        if [ -f "${dhcp_opts}" ]; then
            grep -v "tag:norouter_${mac_tag}" "${dhcp_opts}" > "${dhcp_opts}.tmp" 2>/dev/null || true
            mv "${dhcp_opts}.tmp" "${dhcp_opts}"
        fi
        _svc_start_or_reload_dnsmasq
    fi
    release_lock
    log "remove-dhcp-entry: done mac=${MAC}"
}

##############################################################################
# Command: set-dhcp-options
# Set extra DHCP options for a NIC (by NIC ID as dnsmasq tag).
##############################################################################

cmd_set_dhcp_options() {
    parse_args "$@"
    _load_state
    acquire_lock "${NETWORK_ID}"
    log "set-dhcp-options: network=${NETWORK_ID} nic=${NIC_ID}"

    local dhcp_opts; dhcp_opts=$(_dnsmasq_dhcp_opts)
    mkdir -p "$(_dnsmasq_dir)"
    touch "${dhcp_opts}"

    # Parse JSON options with Python3 and write to opts file
    python3 - "${NIC_ID}" "${DHCP_OPTIONS_JSON}" "${dhcp_opts}" << 'PYEOF'
import json, sys, os

nic_id   = sys.argv[1]
opts_str = sys.argv[2]
optsfile = sys.argv[3]

try:
    opts = json.loads(opts_str)
except Exception:
    opts = {}

# Read existing lines; drop any previously set for this nic
try:
    with open(optsfile) as f:
        lines = f.readlines()
except FileNotFoundError:
    lines = []

marker = f"# nic:{nic_id}:"
lines = [l for l in lines if not l.startswith(marker)]

for code, value in opts.items():
    lines.append(f"{marker}\ndhcp-option=tag:{nic_id},{code},{value}\n")

with open(optsfile, 'w') as f:
    f.writelines(lines)
PYEOF

    _svc_start_or_reload_dnsmasq
    release_lock
    log "set-dhcp-options: done nic=${NIC_ID}"
}

##############################################################################
# Command: add-dns-entry
# Add a hostname→IP mapping to dnsmasq.
##############################################################################

cmd_add_dns_entry() {
    parse_args "$@"
    _load_state
    acquire_lock "${NETWORK_ID}"
    log "add-dns-entry: network=${NETWORK_ID} hostname=${HOSTNAME} ip=${VM_IP}"
    [ -z "${VM_IP}" ]    && die "add-dns-entry: missing --ip"
    [ -z "${HOSTNAME}" ] && die "add-dns-entry: missing --hostname"

    local hosts; hosts=$(_dnsmasq_hosts)
    mkdir -p "$(_dnsmasq_dir)"
    touch "${hosts}"

    # Remove existing entry for this IP then append fresh
    grep -v "^${VM_IP}[[:space:]]" "${hosts}" > "${hosts}.tmp" 2>/dev/null || true
    mv "${hosts}.tmp" "${hosts}"
    echo "${VM_IP} ${HOSTNAME}" >> "${hosts}"

    _svc_start_or_reload_dnsmasq
    release_lock
    log "add-dns-entry: done ${VM_IP} ${HOSTNAME}"
}

##############################################################################
# Command: remove-dns-entry
# Remove a hostname→IP mapping from dnsmasq.
##############################################################################

cmd_remove_dns_entry() {
    parse_args "$@"
    _load_state
    acquire_lock "${NETWORK_ID}"
    log "remove-dns-entry: network=${NETWORK_ID} ip=${VM_IP}"
    [ -z "${VM_IP}" ] && die "remove-dns-entry: missing --ip"

    local hosts; hosts=$(_dnsmasq_hosts)
    if [ -f "${hosts}" ]; then
        grep -v "^${VM_IP}[[:space:]]" "${hosts}" > "${hosts}.tmp" 2>/dev/null || true
        mv "${hosts}.tmp" "${hosts}"
        _svc_start_or_reload_dnsmasq
    fi
    release_lock
    log "remove-dns-entry: done ${VM_IP}"
}

##############################################################################
# Command: save-userdata
# Write base64-decoded user-data for a VM; start/reload apache2.
##############################################################################

cmd_save_userdata() {
    parse_args "$@"
    _load_state
    acquire_lock "${NETWORK_ID}"
    log "save-userdata: network=${NETWORK_ID} ip=${VM_IP}"
    [ -z "${VM_IP}" ] && die "save-userdata: missing --ip"

    local vm_dir; vm_dir="$(_metadata_dir)/${VM_IP}/latest"
    mkdir -p "${vm_dir}"

    if [ -n "${USERDATA}" ]; then
        printf '%s' "${USERDATA}" | base64 -d > "${vm_dir}/user-data" 2>/dev/null || \
            printf '%s' "${USERDATA}" > "${vm_dir}/user-data"
    else
        # Create empty user-data file if USERDATA is empty
        rm -rf "${vm_dir}/user-data" && touch "${vm_dir}/user-data"
    fi

    _write_apache2_conf
    _svc_start_or_reload_apache2
    release_lock
    log "save-userdata: done ${VM_IP}"
}

##############################################################################
# Command: save-password
# Write a VM password served via the metadata HTTP service.
##############################################################################

cmd_save_password() {
    parse_args "$@"
    _load_state
    acquire_lock "${NETWORK_ID}"
    log "save-password: network=${NETWORK_ID} ip=${VM_IP}"
    [ -z "${VM_IP}" ] && die "save-password: missing --ip"

    # Write to the passwords file for the VR-compatible password server only.
    # Format: ip=password  (same as /var/cache/cloud/passwords-<gw> on VR)
    local passwd_f; passwd_f=$(_passwd_file)
    if [ -n "${PASSWORD}" ]; then
        touch "${passwd_f}"
        grep -v "^${VM_IP}=" "${passwd_f}" > "${passwd_f}.tmp" 2>/dev/null || true
        mv "${passwd_f}.tmp" "${passwd_f}"
        echo "${VM_IP}=${PASSWORD}" >> "${passwd_f}"
    fi

    _write_apache2_conf
    _svc_start_or_reload_apache2
    _svc_start_or_reload_passwd_server
    release_lock
    log "save-password: done ${VM_IP}"
}

##############################################################################
# Command: save-sshkey
# Write a base64-encoded SSH public key for a VM.
##############################################################################

cmd_save_sshkey() {
    parse_args "$@"
    _load_state
    acquire_lock "${NETWORK_ID}"
    log "save-sshkey: network=${NETWORK_ID} ip=${VM_IP}"
    [ -z "${VM_IP}" ] && die "save-sshkey: missing --ip"

    local meta_dir; meta_dir="$(_metadata_dir)/${VM_IP}/latest/meta-data"
    mkdir -p "${meta_dir}"
    # SSH_KEY is base64-encoded by the Java caller.
    # All public keys for the VM are stored together in a single flat file
    # (one key per line) at latest/meta-data/public-keys.
    printf '%s' "${SSH_KEY}" | base64 -d > "${meta_dir}/public-keys" 2>/dev/null || \
        printf '%s' "${SSH_KEY}" > "${meta_dir}/public-keys"

    _write_apache2_conf
    _svc_start_or_reload_apache2
    release_lock
    log "save-sshkey: done ${VM_IP}"
}

##############################################################################
# Command: save-hypervisor-hostname
# Write the hypervisor hostname into the VM's meta-data.
##############################################################################

cmd_save_hypervisor_hostname() {
    parse_args "$@"
    _load_state
    acquire_lock "${NETWORK_ID}"
    log "save-hypervisor-hostname: network=${NETWORK_ID} ip=${VM_IP} host=${HYPERVISOR_HOSTNAME}"
    [ -z "${VM_IP}" ] && die "save-hypervisor-hostname: missing --ip"

    local meta_dir; meta_dir="$(_metadata_dir)/${VM_IP}/latest/meta-data"
    mkdir -p "${meta_dir}"
    printf '%s' "${HYPERVISOR_HOSTNAME}" > "${meta_dir}/hypervisor-hostname"

    _write_apache2_conf
    _svc_start_or_reload_apache2
    release_lock
    log "save-hypervisor-hostname: done ${VM_IP}"
}

##############################################################################
# Command: save-vm-data
# Write the full VM metadata/userdata/password set in one call.
# --ip      <vm_ip>      IP address of the VM on this network
# --vm-data <base64>     Base64-encoded JSON array of {dir,file,content} entries.
#                        Each 'content' value is itself Base64-encoded bytes.
#
# Path mapping from generateVmData() output:
#   [userdata, user_data,   <bytes>]  → latest/user-data
#   [metadata, public-keys, <bytes>]  → latest/meta-data/public-keys  (flat file, one key per line)
#   [metadata, <file>,      <bytes>]  → latest/meta-data/<file>
#   [password, vm_password, <bytes>]  → passwords file (VR-compat passwd-server only)
#   [password, vm-password-md5checksum, <bytes>] → latest/meta-data/password-checksum
#
# After writing all files the apache2 metadata server and the VR-compatible
# password server on port 8080 are both started / reloaded.
##############################################################################

cmd_save_vm_data() {
    parse_args "$@"
    _load_state
    acquire_lock "${NETWORK_ID}"
    log "save-vm-data: network=${NETWORK_ID} ip=${VM_IP}"
    [ -z "${VM_IP}" ]   && die "save-vm-data: missing --ip"
    [ -z "${VM_DATA}" ] && die "save-vm-data: missing --vm-data"

    local meta_dir; meta_dir=$(_metadata_dir)
    local passwd_f; passwd_f=$(_passwd_file)
    mkdir -p "${meta_dir}" "$(dirname "${passwd_f}")"
    touch "${passwd_f}"

    python3 - "${VM_IP}" "${meta_dir}" "${passwd_f}" "${VM_DATA}" << 'PYEOF'
import base64, json, os, sys

vm_ip      = sys.argv[1]
meta_dir   = sys.argv[2]
passwd_f   = sys.argv[3]
data_b64   = sys.argv[4]

# Decode the outer base64 wrapper, then parse the JSON array
try:
    entries = json.loads(base64.b64decode(data_b64).decode('utf-8'))
except Exception as e:
    print(f"save-vm-data: failed to decode vm-data: {e}", file=sys.stderr)
    sys.exit(1)

password_written = None
pub_keys = []  # accumulate all public-key entries; written as one flat file after the loop

for entry in entries:
    d    = entry.get('dir', '')
    f    = entry.get('file', '')
    c_b64 = entry.get('content', '')
    if not c_b64:
        continue
    # Each content value is base64-encoded actual bytes
    try:
        content = base64.b64decode(c_b64)
    except Exception:
        content = c_b64.encode('utf-8') if isinstance(c_b64, str) else b''

    if not content:
        continue

    # ---- path mapping ----
    if d == 'userdata' and f == 'user_data':
        path = os.path.join(meta_dir, vm_ip, 'latest', 'user-data')
    elif d == 'metadata' and f == 'public-keys':
        # All public keys are collected and written together as a single
        # flat file (one key per line) after the loop.
        pub_keys.append(content.rstrip(b'\n') + b'\n')
        continue
    elif d == 'metadata':
        path = os.path.join(meta_dir, vm_ip, 'latest', 'meta-data', f)
    elif d == 'password' and f == 'vm_password':
        # Only write to the VR-compatible passwords file; do NOT save to
        # latest/password inside the metadata tree.
        password_written = content.decode('utf-8', errors='replace').strip()
        continue
    elif d == 'password' and f == 'vm-password-md5checksum':
        path = os.path.join(meta_dir, vm_ip, 'latest', 'meta-data', 'password-checksum')
    else:
        # Fallback: store under latest/<dir>/<file>
        path = os.path.join(meta_dir, vm_ip, 'latest', d, f)

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as fp:
        fp.write(content if isinstance(content, bytes) else content.encode('utf-8'))

# Write all collected public keys into a single flat file.
if pub_keys:
    pk_path = os.path.join(meta_dir, vm_ip, 'latest', 'meta-data', 'public-keys')
    os.makedirs(os.path.dirname(pk_path), exist_ok=True)
    with open(pk_path, 'wb') as fp:
        fp.writelines(pub_keys)

# Update the passwords file (ip=password format, same as VR)
if password_written:
    try:
        lines = []
        try:
            with open(passwd_f) as pf:
                lines = [l for l in pf if l.strip() and not l.startswith(vm_ip + '=')]
        except FileNotFoundError:
            pass
        lines.append(f'{vm_ip}={password_written}\n')
        with open(passwd_f, 'w') as pf:
            pf.writelines(lines)
    except Exception as e:
        print(f"save-vm-data: could not update passwords file: {e}", file=sys.stderr)

print(f"save-vm-data: wrote {len(entries)} entries for {vm_ip}")
PYEOF

    _write_apache2_conf
    _svc_start_or_reload_apache2
    _svc_start_or_reload_passwd_server
    release_lock
    log "save-vm-data: done network=${NETWORK_ID} ip=${VM_IP}"
}


##############################################################################
# Command: apply-fw-rules
#
# Rebuilds the per-network firewall chain CS_EXTNET_FWRULES_<networkId> from
# scratch using a Base64-encoded JSON payload supplied via --fw-rules.
#
# JSON payload structure (base64-decoded):
# {
#   "default_egress_allow": true|false,
#   "cidr": "10.0.0.0/24",
#   "rules": [
#     {
#       "id": 1,
#       "type": "ingress"|"egress",
#       "protocol": "tcp"|"udp"|"icmp"|"all",
#       "portStart": <int>,          // optional
#       "portEnd":   <int>,          // optional
#       "icmpType":  <int>,          // optional
#       "icmpCode":  <int>,          // optional
#       "publicIp":  "1.2.3.4",     // ingress only
#       "sourceCidrs": ["0.0.0.0/0", ...],
#       "destCidrs":   ["0.0.0.0/0", ...]  // egress only, optional
#     }, ...
#   ]
# }
#
# iptables design (two-part, mirroring the VR FIREWALL_<pubIP> pattern)
# ----------------------------------------------------------------------
#
# PART 1 – Ingress: mangle table, PREROUTING hook (BEFORE nat DNAT)
#
#   Per-public-IP chains CS_EXTNET_FWI_<pubIp> in the mangle table:
#   -A PREROUTING -d <pubIp>/32 -j CS_EXTNET_FWI_<pubIp>
#   -A CS_EXTNET_FWI_<pubIp>  [explicit allow rules]  -j RETURN
#   -A CS_EXTNET_FWI_<pubIp>  -m state --state RELATED,ESTABLISHED  -j RETURN
#   -A CS_EXTNET_FWI_<pubIp>  -j DROP
#
#   Checking in PREROUTING mangle (before DNAT) lets us match directly on the
#   public destination IP — works for static-NAT, port-forwarding, and LB alike.
#
# PART 2 – Egress: filter table, FORWARD hook (CS_EXTNET_FWRULES_<N>)
#
#   CS_EXTNET_FWD_<networkId>                    (existing "fchain")
#     └─[pos 1]─> CS_EXTNET_FWRULES_<networkId>  (fw_chain, egress only)
#                   1. RELATED,ESTABLISHED  → ACCEPT
#                   2. explicit egress rules (-i <veth_n> ... -j ACCEPT|DROP)
#                   3. default egress policy (-i <veth_n> ... -j ACCEPT|DROP)
#                   4. -j RETURN
#
# Default egress policy:
#   default_egress_allow=true  → ALLOW by default; explicit egress rules are DROP
#   default_egress_allow=false → DENY  by default; explicit egress rules are ACCEPT
##############################################################################

cmd_apply_fw_rules() {
    parse_args "$@"
    _load_state
    acquire_lock "${NETWORK_ID}"
    log "apply-fw-rules: network=${NETWORK_ID} ns=${NAMESPACE}"

    local veth_n fchain fw_chain
    veth_n=$(veth_ns_name "${VLAN}" "${CHOSEN_ID}")
    fchain=$(filter_chain "${NETWORK_ID}")
    fw_chain=$(firewall_chain "${NETWORK_ID}")

    # ---- 1. Remove existing jump from fchain to fw_chain (idempotent) ----
    ip netns exec "${NAMESPACE}" iptables -t filter \
        -D "${fchain}" -j "${fw_chain}" 2>/dev/null || true

    # ---- 2. Flush and delete old fw chain ----
    ip netns exec "${NAMESPACE}" iptables -t filter -F "${fw_chain}" 2>/dev/null || true
    ip netns exec "${NAMESPACE}" iptables -t filter -X "${fw_chain}" 2>/dev/null || true

    # ---- 3. Create fresh fw chain ----
    ip netns exec "${NAMESPACE}" iptables -t filter -N "${fw_chain}"

    # ---- 4. Build iptables rules via Python ----
    python3 - "${NAMESPACE}" "${FW_RULES_JSON:-}" "${veth_n}" \
              "${fw_chain}" << 'PYEOF'
import base64, json, re, subprocess, sys

namespace = sys.argv[1]
rules_b64 = sys.argv[2]
veth_n    = sys.argv[3]
fw_chain  = sys.argv[4]   # filter table egress chain (CS_EXTNET_FWRULES_<N>)

# Prefix for per-public-IP ingress chains in the mangle table.
# e.g. CS_EXTNET_FWI_10.0.56.20
FW_INGRESS_PREFIX = 'CS_EXTNET_FWI_'

def _run(table, *args):
    cmd = ['ip', 'netns', 'exec', namespace, 'iptables', '-t', table] + list(args)
    r = subprocess.run(cmd, capture_output=True)
    if r.returncode != 0:
        print(f"iptables ({table}): {r.stderr.decode().strip()}", file=sys.stderr)
    return r

def iptf(*args):
    """iptables filter table."""
    _run('filter', *args)

def iptm(*args):
    """iptables mangle table."""
    _run('mangle', *args)

# ---------------------------------------------------------------------------
# Decode payload
# ---------------------------------------------------------------------------
if rules_b64:
    try:
        data = json.loads(base64.b64decode(rules_b64).decode('utf-8'))
    except Exception as e:
        print(f"apply-fw-rules: failed to decode --fw-rules: {e}", file=sys.stderr)
        sys.exit(1)
else:
    data = {}

default_egress_allow = data.get('default_egress_allow', True)
rules = data.get('rules', [])

ingress_rules = [r for r in rules if r.get('type') == 'ingress']
egress_rules  = [r for r in rules if r.get('type') == 'egress']

# ---------------------------------------------------------------------------
# PART 1 – Egress rules in filter table (CS_EXTNET_FWRULES_<N>)
#
# Handles only outbound guest-VM traffic (-i <veth_n>).
# ---------------------------------------------------------------------------

# Allow established/related first so ongoing sessions are never interrupted.
iptf('-A', fw_chain, '-m', 'state', '--state', 'RELATED,ESTABLISHED', '-j', 'ACCEPT')

# Explicit egress rules.
# default_egress_allow=true  → explicit rules are DROP  (deny specific traffic)
# default_egress_allow=false → explicit rules are ACCEPT (allow specific traffic)
rule_target = 'DROP' if default_egress_allow else 'ACCEPT'

for rule in egress_rules:
    protocol   = (rule.get('protocol') or 'all').lower()
    port_start = rule.get('portStart')
    port_end   = rule.get('portEnd')
    icmp_type  = rule.get('icmpType')
    icmp_code  = rule.get('icmpCode')
    src_cidrs  = rule.get('sourceCidrs') or ['0.0.0.0/0']
    dest_cidrs = rule.get('destCidrs') or []

    for src_cidr in src_cidrs:
        a = ['-i', veth_n]
        if src_cidr and src_cidr not in ('0.0.0.0/0', '::/0', ''):
            a += ['-s', src_cidr]
        if protocol not in ('all', ''):
            a += ['-p', protocol]
            if protocol in ('tcp', 'udp') and port_start is not None:
                port_spec = str(port_start)
                if port_end is not None and port_end != port_start:
                    port_spec = f"{port_start}:{port_end}"
                a += ['--dport', port_spec]
            elif protocol == 'icmp' and icmp_type is not None and icmp_type != -1:
                icmp_spec = str(icmp_type)
                if icmp_code is not None and icmp_code != -1:
                    icmp_spec += f"/{icmp_code}"
                a += ['--icmp-type', icmp_spec]

        if dest_cidrs:
            for dest_cidr in dest_cidrs:
                if dest_cidr and dest_cidr not in ('0.0.0.0/0', '::/0', ''):
                    iptf('-A', fw_chain, *a, '-d', dest_cidr, '-j', rule_target)
                else:
                    iptf('-A', fw_chain, *a, '-j', rule_target)
        else:
            iptf('-A', fw_chain, *a, '-j', rule_target)

# Default egress policy (NEW connections only — RELATED/ESTABLISHED already ACCEPTed).
if not default_egress_allow:
    iptf('-A', fw_chain, '-i', veth_n, '-m', 'state', '--state', 'NEW', '-j', 'DROP')
else:
    iptf('-A', fw_chain, '-i', veth_n, '-j', 'ACCEPT')

# RETURN so that fchain catch-all rules (static-NAT, PF, etc.) remain active
# for any non-VM traffic that reaches this chain.
iptf('-A', fw_chain, '-j', 'RETURN')

# ---------------------------------------------------------------------------
# PART 2 – Ingress firewall in mangle table, PREROUTING hook (before DNAT)
#
# Mirrors the VR's FIREWALL_<pubIp> chains in the mangle table:
#   -A PREROUTING -d <pubIp>/32 -j CS_EXTNET_FWI_<pubIp>
#   -A CS_EXTNET_FWI_<pubIp>  [explicit allow rules]  -j RETURN
#   -A CS_EXTNET_FWI_<pubIp>  -m state --state RELATED,ESTABLISHED -j RETURN
#   -A CS_EXTNET_FWI_<pubIp>  -j DROP
#
# Running in PREROUTING mangle (before nat PREROUTING DNAT) means we match
# on the real public destination IP directly — no conntrack tricks needed.
# Works uniformly for static-NAT, port-forwarding, and LB public IPs.
# ---------------------------------------------------------------------------

# Step 1: discover and flush all existing CS_EXTNET_FWI_* chains (full rebuild).
ls_out = _run('mangle', '-n', '-L').stdout.decode('utf-8', errors='replace')
old_chains = re.findall(
    r'^Chain (' + re.escape(FW_INGRESS_PREFIX) + r'[\d.]+) ',
    ls_out, re.MULTILINE)
for old_chain in old_chains:
    old_ip = old_chain[len(FW_INGRESS_PREFIX):]
    iptm('-D', 'PREROUTING', '-d', f'{old_ip}/32', '-j', old_chain)
    iptm('-F', old_chain)
    iptm('-X', old_chain)

# Step 2: build a per-IP chain for every public IP that has ingress rules.
pub_ip_rules = {}
for rule in ingress_rules:
    pub_ip = rule.get('publicIp', '')
    if not pub_ip:
        continue
    pub_ip_rules.setdefault(pub_ip, []).append(rule)

for pub_ip, ip_rules in pub_ip_rules.items():
    chain_name = FW_INGRESS_PREFIX + pub_ip   # e.g. CS_EXTNET_FWI_10.0.56.20

    # Create chain and register it in mangle PREROUTING.
    iptm('-N', chain_name)
    iptm('-A', 'PREROUTING', '-d', f'{pub_ip}/32', '-j', chain_name)

    # Explicit ALLOW rules — RETURN lets the packet proceed to DNAT and FORWARD.
    for rule in ip_rules:
        protocol   = (rule.get('protocol') or 'all').lower()
        port_start = rule.get('portStart')
        port_end   = rule.get('portEnd')
        icmp_type  = rule.get('icmpType')
        icmp_code  = rule.get('icmpCode')
        src_cidrs  = rule.get('sourceCidrs') or ['0.0.0.0/0']

        for src_cidr in src_cidrs:
            a = ['-A', chain_name]
            if src_cidr and src_cidr not in ('0.0.0.0/0', '::/0', ''):
                a += ['-s', src_cidr]
            if protocol not in ('all', ''):
                a += ['-p', protocol]
                if protocol in ('tcp', 'udp') and port_start is not None:
                    port_spec = str(port_start)
                    if port_end is not None and port_end != port_start:
                        port_spec = f"{port_start}:{port_end}"
                    a += ['--dport', port_spec]
                elif protocol == 'icmp' and icmp_type is not None and icmp_type != -1:
                    icmp_spec = str(icmp_type)
                    if icmp_code is not None and icmp_code != -1:
                        icmp_spec += f"/{icmp_code}"
                    a += ['--icmp-type', icmp_spec]
            a += ['-j', 'RETURN']
            iptm(*a)

    # Always allow packets belonging to an already-established session.
    iptm('-A', chain_name, '-m', 'state', '--state', 'RELATED,ESTABLISHED', '-j', 'RETURN')
    # Default: drop new connections not matched by any explicit rule above.
    iptm('-A', chain_name, '-j', 'DROP')

n_in  = sum(len(v) for v in pub_ip_rules.values())
n_eg  = len(egress_rules)
policy = 'ALLOW' if default_egress_allow else 'DENY'
print(f"apply-fw-rules: built {n_in} ingress rule(s) across {len(pub_ip_rules)} public IP(s), "
      f"{n_eg} egress rule(s), default_egress={policy}")
PYEOF

    local py_exit=$?
    if [ ${py_exit} -ne 0 ]; then
        # Python script failed — leave chain empty but continue so that the
        # fchain catch-all rules remain effective (fail-open for existing traffic).
        log "apply-fw-rules: Python rule builder exited ${py_exit}; firewall chain may be incomplete"
    fi

    # ---- 5. Insert jump from fchain to fw_chain at position 1 ----
    # Runs fw_chain BEFORE the fchain catch-all ACCEPT rules so the firewall
    # policy takes precedence.  Skipped when fchain does not exist yet (i.e.
    # implement has not been called — the jump will be inserted on next
    # apply-fw-rules invocation after implement).
    if ip netns exec "${NAMESPACE}" iptables -t filter -n -L "${fchain}" >/dev/null 2>&1; then
        ip netns exec "${NAMESPACE}" iptables -t filter \
            -I "${fchain}" 1 -j "${fw_chain}" 2>/dev/null || true
        log "apply-fw-rules: jump ${fchain} -> ${fw_chain} inserted at position 1"
    else
        log "apply-fw-rules: WARNING — ${fchain} not found; jump will be inserted on next implement"
    fi

    _dump_iptables "${NAMESPACE}"
    release_lock
    log "apply-fw-rules: done network=${NETWORK_ID}"
}

##############################################################################
# Command: apply-lb-rules
# Apply/revoke load balancing rules via haproxy inside the namespace.
# --lb-rules <json-array>  — array of LB rule objects (see Java side for schema)
##############################################################################

cmd_apply_lb_rules() {
    parse_args "$@"
    _load_state
    acquire_lock "${NETWORK_ID}"
    log "apply-lb-rules: network=${NETWORK_ID} ns=${NAMESPACE}"

    # Normalise empty input
    [ -z "${LB_RULES_JSON}" ] && LB_RULES_JSON="[]"

    local lb_dir; lb_dir=$(_haproxy_dir)
    mkdir -p "${lb_dir}"

    # Persist/remove per-rule state files
    python3 - "${lb_dir}" "${LB_RULES_JSON}" << 'PYEOF'
import json, os, sys

lb_dir = sys.argv[1]
rules  = json.loads(sys.argv[2])

for rule in rules:
    rid = str(rule['id'])
    fn  = os.path.join(lb_dir, f"{rid}.json")
    if rule.get('revoke', False):
        try:
            os.remove(fn)
        except FileNotFoundError:
            pass
    else:
        with open(fn, 'w') as f:
            json.dump(rule, f)
PYEOF

    # Regenerate haproxy config
    _write_haproxy_conf

    # Count active rules (json files in lb_dir, excluding haproxy.cfg / haproxy.pid / etc.)
    local active_rules
    active_rules=$(find "${lb_dir}" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)

    if [ "${active_rules}" -gt 0 ]; then
        _svc_reload_haproxy
    else
        log "apply-lb-rules: no active rules; stopping haproxy"
        _svc_stop_haproxy
    fi

    _dump_iptables "${NAMESPACE}"
    release_lock
    log "apply-lb-rules: done network=${NETWORK_ID}"
}

##############################################################################
# Command: custom-action

cmd_custom_action() {
    NETWORK_ID=""
    VPC_ID=""
    ACTION_NAME=""
    ACTION_PARAMS_JSON="{}"
    while [ $# -gt 0 ]; do
        case "$1" in
            --network-id)    NETWORK_ID="$2";               shift 2 ;;
            --vpc-id)        VPC_ID="$2";                   shift 2 ;;
            --action)        ACTION_NAME="$2";               shift 2 ;;
            --action-params) ACTION_PARAMS_JSON="${2:-{}}";  shift 2 ;;
            --physical-network-extension-details|--network-extension-details)
                             shift 2 ;;
            *)               shift ;;
        esac
    done
    [ -z "${NETWORK_ID}" ]  && die "custom-action: missing --network-id"
    [ -z "${ACTION_NAME}" ] && die "custom-action: missing --action"

    # Set NAMESPACE/CHOSEN_ID similar to parse_args
    if [ -z "${NAMESPACE}" ]; then
        if [ -n "${VPC_ID}" ]; then
            NAMESPACE="cs-vpc-${VPC_ID}"
        else
            local NS_FROM_DETAILS
            NS_FROM_DETAILS=$(_json_get "${EXTENSION_DETAILS}" "namespace")
            NAMESPACE="${NS_FROM_DETAILS:-cs-net-${NETWORK_ID}}"
        fi
    fi
    CHOSEN_ID="${VPC_ID:-${NETWORK_ID}}"

    _load_state

    log "custom-action: network=${NETWORK_ID} ns=${NAMESPACE} action=${ACTION_NAME} params=${ACTION_PARAMS_JSON}"

    case "${ACTION_NAME}" in
        reboot-device)
            local veth_h veth_n
            veth_h=$(veth_host_name "${VLAN}" "${CHOSEN_ID}")
            veth_n=$(veth_ns_name   "${VLAN}" "${CHOSEN_ID}")
            ip link set "${veth_h}" down 2>/dev/null || true
            ip netns exec "${NAMESPACE}" ip link set "${veth_n}" down 2>/dev/null || true
            sleep 1
            ip link set "${veth_h}" up 2>/dev/null || true
            ip netns exec "${NAMESPACE}" ip link set "${veth_n}" up 2>/dev/null || true
            echo "reboot-device: OK (namespace=${NAMESPACE})"
            ;;
        dump-config)
            echo "=== Namespace: ${NAMESPACE} ==="
            ip netns exec "${NAMESPACE}" ip addr 2>/dev/null || echo "(no namespace)"
            echo "=== Host bridge: $(host_bridge_name "${GUEST_ETH}" "${VLAN}") ==="
            ip link show "$(host_bridge_name "${GUEST_ETH}" "${VLAN}")" 2>/dev/null || echo "(not found)"
            echo "=== NAT table ==="
            ip netns exec "${NAMESPACE}" iptables -t nat    -L -n -v 2>/dev/null || echo "(unavailable)"
            echo "=== FILTER table ==="
            ip netns exec "${NAMESPACE}" iptables -t filter -L -n -v 2>/dev/null || echo "(unavailable)"
            echo "=== Per-network state ($(_net_state_dir)) ==="
            ls -la "$(_net_state_dir)/" 2>/dev/null || echo "(no network state)"
            echo "=== VPC/shared state ($(_vpc_state_dir)) ==="
            ls -la "$(_vpc_state_dir)/" 2>/dev/null || echo "(no vpc state)"
            ;;
        *)
            local hook="${STATE_DIR}/hooks/custom-action-${ACTION_NAME}.sh"
            if [ -x "${hook}" ]; then
                exec "${hook}" --network-id "${NETWORK_ID}" --action "${ACTION_NAME}" \
                     --action-params "${ACTION_PARAMS_JSON}"
            else
                die "Unknown action '${ACTION_NAME}'. Built-ins: reboot-device, dump-config"
            fi
            ;;
    esac
}

##############################################################################
# Command: restore-network
# Batch-restore DHCP/DNS/metadata for all VMs on a network in a single call.
# Called by AggregatedCommandExecutor.completeAggregatedExecution() on network
# restart so that we rebuild all state in one shot instead of N per-VM calls.
#
# Required arguments:
#   --network-id   <id>
#   --restore-data <base64-json>   JSON: see buildRestoreNetworkData() in Java
#
# Optional (for dnsmasq reconfiguration):
#   --gateway <gw>  --cidr <cidr>  --dns <dns>  --domain <dom>  --extension-ip <ip>
##############################################################################

cmd_restore_network() {
    parse_args "$@"
    _load_state
    acquire_lock "${NETWORK_ID}"
    log "restore-network: network=${NETWORK_ID} ns=${NAMESPACE}"
    [ -z "${RESTORE_DATA}" ] && die "restore-network: missing --restore-data"

    local dhcp_hosts; dhcp_hosts=$(_dnsmasq_dhcp_hosts)
    local dhcp_opts;  dhcp_opts=$(_dnsmasq_dhcp_opts)
    local dns_hosts;  dns_hosts=$(_dnsmasq_hosts)
    local meta_dir;   meta_dir=$(_metadata_dir)
    local passwd_f;   passwd_f=$(_passwd_file)

    mkdir -p "$(_dnsmasq_dir)" "${meta_dir}" "$(dirname "${passwd_f}")"
    touch "${dhcp_hosts}" "${dhcp_opts}" "${dns_hosts}" "${passwd_f}"

    python3 - \
        "${RESTORE_DATA}" \
        "${dhcp_hosts}" "${dhcp_opts}" "${dns_hosts}" \
        "${meta_dir}" "${passwd_f}" \
        << 'PYEOF'
import base64, json, os, sys

restore_b64  = sys.argv[1]
dhcp_hosts_f = sys.argv[2]
dhcp_opts_f  = sys.argv[3]
dns_hosts_f  = sys.argv[4]
meta_dir     = sys.argv[5]
passwd_f     = sys.argv[6]

# ---- Decode the outer base64, then parse JSON ----
try:
    data = json.loads(base64.b64decode(restore_b64).decode('utf-8'))
except Exception as e:
    print(f"restore-network: failed to decode restore-data: {e}", file=sys.stderr)
    sys.exit(1)

dhcp_enabled     = data.get('dhcp_enabled', False)
dns_enabled      = data.get('dns_enabled',  False)
userdata_enabled = data.get('userdata_enabled', False)
vms              = data.get('vms', [])

print(f"restore-network: dhcp={dhcp_enabled} dns={dns_enabled} "
      f"userdata={userdata_enabled} vms={len(vms)}")

# ---- Rebuild DHCP hosts file ----
if dhcp_enabled:
    new_hosts_lines = []
    new_opts_lines  = []
    # Keep existing custom dhcp-option lines not managed by us
    try:
        with open(dhcp_opts_f) as f:
            existing_opts = [l for l in f if not l.startswith('set:norouter_') and
                             'norouter_' not in l]
    except FileNotFoundError:
        existing_opts = []

    for vm in vms:
        ip          = vm.get('ip', '')
        mac         = vm.get('mac', '')
        hostname    = vm.get('hostname', '')
        default_nic = str(vm.get('default_nic', True)).lower() not in ('false', '0', 'no')
        if not ip or not mac:
            continue
        mac_tag = mac.replace(':', '_').lower()
        if not default_nic:
            if hostname:
                new_hosts_lines.append(f"set:norouter_{mac_tag},{mac},{ip},{hostname},infinite\n")
            else:
                new_hosts_lines.append(f"set:norouter_{mac_tag},{mac},{ip},infinite\n")
            new_opts_lines.append(f"dhcp-option=tag:norouter_{mac_tag},option:router,0.0.0.0\n")
        else:
            if hostname:
                new_hosts_lines.append(f"{mac},{ip},{hostname},infinite\n")
            else:
                new_hosts_lines.append(f"{mac},{ip},infinite\n")

    with open(dhcp_hosts_f, 'w') as f:
        f.writelines(new_hosts_lines)
    with open(dhcp_opts_f, 'w') as f:
        f.writelines(existing_opts + new_opts_lines)
    print(f"restore-network: wrote {len(new_hosts_lines)} DHCP entries")

# ---- Rebuild DNS hosts file ----
if dns_enabled:
    new_dns_lines = []
    for vm in vms:
        ip       = vm.get('ip', '')
        hostname = vm.get('hostname', '')
        if not ip or not hostname:
            continue
        new_dns_lines.append(f"{ip} {hostname}\n")
    with open(dns_hosts_f, 'w') as f:
        f.writelines(new_dns_lines)
    print(f"restore-network: wrote {len(new_dns_lines)} DNS entries")

# ---- Restore per-VM metadata / userdata ----
if userdata_enabled:
    passwords = {}
    # Load existing passwords to preserve non-restored entries
    try:
        with open(passwd_f) as pf:
            for line in pf:
                line = line.strip()
                if '=' in line:
                    k, v = line.split('=', 1)
                    passwords[k] = v
    except FileNotFoundError:
        pass

    vm_count = 0
    for vm in vms:
        vm_ip   = vm.get('ip', '')
        vm_data = vm.get('vm_data', [])
        if not vm_ip or not vm_data:
            continue
        vm_count += 1
        pub_keys = []  # accumulate public keys; written as a single flat file after inner loop
        for entry in vm_data:
            d     = entry.get('dir', '')
            f_    = entry.get('file', '')
            c_b64 = entry.get('content', '')
            if not c_b64:
                continue
            try:
                content = base64.b64decode(c_b64)
            except Exception:
                content = c_b64.encode('utf-8') if isinstance(c_b64, str) else b''

            if not content:
                continue
            # ---- path mapping (same as cmd_save_vm_data) ----
            if d == 'userdata' and f_ == 'user_data':
                path = os.path.join(meta_dir, vm_ip, 'latest', 'user-data')
            elif d == 'metadata' and f_ == 'public-keys':
                # Accumulate; written as a single flat file after the inner loop.
                pub_keys.append(content.rstrip(b'\n') + b'\n')
                continue
            elif d == 'metadata':
                path = os.path.join(meta_dir, vm_ip, 'latest', 'meta-data', f_)
            elif d == 'password' and f_ == 'vm_password':
                # Only write to the VR-compatible passwords file; do NOT save
                # to latest/password inside the metadata tree.
                passwords[vm_ip] = content.decode('utf-8', errors='replace').strip()
                continue
            elif d == 'password' and f_ == 'vm-password-md5checksum':
                path = os.path.join(meta_dir, vm_ip, 'latest', 'meta-data', 'password-checksum')
            else:
                path = os.path.join(meta_dir, vm_ip, 'latest', d, f_)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'wb') as fp:
                fp.write(content if isinstance(content, bytes)
                         else content.encode('utf-8'))

        # Write all collected public keys as a single flat file.
        if pub_keys:
            pk_path = os.path.join(meta_dir, vm_ip, 'latest', 'meta-data', 'public-keys')
            os.makedirs(os.path.dirname(pk_path), exist_ok=True)
            with open(pk_path, 'wb') as fp:
                fp.writelines(pub_keys)

    # Rewrite the passwords file atomically
    try:
        with open(passwd_f, 'w') as pf:
            for k, v in passwords.items():
                pf.write(f'{k}={v}\n')
    except Exception as e:
        print(f"restore-network: could not write passwords file: {e}", file=sys.stderr)

    print(f"restore-network: restored metadata for {vm_count} VMs")

print("restore-network: done")
PYEOF

    # ------------------------------------------------------------------
    # Decode dhcp_enabled / dns_enabled from RESTORE_DATA so we can
    # reconfigure dnsmasq correctly even when the namespace (and therefore
    # dnsmasq.conf) was deleted and recreated.  RESTORE_DATA is passed as
    # a positional argument to avoid shell-quoting issues with base64 data.
    # ------------------------------------------------------------------
    local _r_flags
    _r_flags=$(python3 - "${RESTORE_DATA}" 2>/dev/null << 'PYFLAGSEOF'
import base64, json, sys
try:
    d = json.loads(base64.b64decode(sys.argv[1]).decode('utf-8'))
    dhcp = 'true' if d.get('dhcp_enabled', False) else 'false'
    dns  = 'true' if d.get('dns_enabled',  False) else 'false'
    print(dhcp + ' ' + dns)
except Exception:
    print('false false')
PYFLAGSEOF
)
    local _r_dhcp _r_dns
    _r_dhcp="${_r_flags%% *}"; _r_dhcp="${_r_dhcp:-false}"
    _r_dns="${_r_flags##* }";  _r_dns="${_r_dns:-false}"

    # Re-add the data-server → extension-IP mapping when DNS is enabled.
    # This entry is normally written by cmd_config_dns_subnet; we must
    # reproduce it here so DNS resolution for the metadata/userdata service
    # keeps working after a namespace restart with cleanup.
    if [ "${_r_dns}" = "true" ]; then
        local _ds_ip; _ds_ip="${EXTENSION_IP:-${GATEWAY}}"
        grep -v -E "\sdata-server(\s|$)" "${dns_hosts}" > "${dns_hosts}.tmp" 2>/dev/null || true
        mv "${dns_hosts}.tmp" "${dns_hosts}"
        echo "${_ds_ip} data-server" >> "${dns_hosts}"
        log "restore-network: added data-server (${_ds_ip}) to DNS hosts"
    fi

    # Re-write dnsmasq.conf.  The conf file is NOT part of the persisted
    # state directory, so it is lost whenever the namespace is deleted.
    # Without this call _svc_start_or_reload_dnsmasq has nothing to read
    # and dnsmasq fails to start.
    if [ "${_r_dhcp}" = "true" ] || [ "${_r_dns}" = "true" ]; then
        _write_dnsmasq_conf "${_r_dns}"
    fi

    # Reload services once for the whole batch
    _svc_start_or_reload_dnsmasq
    _write_apache2_conf
    _svc_start_or_reload_apache2
    _svc_start_or_reload_passwd_server

    release_lock
    log "restore-network: done network=${NETWORK_ID}"
}

##############################################################################
# Main dispatcher
##############################################################################

ensure_dirs

COMMAND="${1:-}"
shift || true

case "${COMMAND}" in
    implement)                cmd_implement                "$@" ;;
    shutdown)                 cmd_shutdown                 "$@" ;;
    destroy)                  cmd_destroy                  "$@" ;;
    assign-ip)                cmd_assign_ip                "$@" ;;
    release-ip)               cmd_release_ip               "$@" ;;
    add-static-nat)           cmd_add_static_nat           "$@" ;;
    delete-static-nat)        cmd_delete_static_nat        "$@" ;;
    add-port-forward)         cmd_add_port_forward         "$@" ;;
    delete-port-forward)      cmd_delete_port_forward      "$@" ;;
    # DHCP / DNS (dnsmasq)
    config-dhcp-subnet)       cmd_config_dhcp_subnet       "$@" ;;
    remove-dhcp-subnet)       cmd_remove_dhcp_subnet       "$@" ;;
    add-dhcp-entry)           cmd_add_dhcp_entry           "$@" ;;
    remove-dhcp-entry)        cmd_remove_dhcp_entry        "$@" ;;
    set-dhcp-options)         cmd_set_dhcp_options         "$@" ;;
    config-dns-subnet)        cmd_config_dns_subnet        "$@" ;;
    remove-dns-subnet)        cmd_remove_dns_subnet        "$@" ;;
    add-dns-entry)            cmd_add_dns_entry            "$@" ;;
    remove-dns-entry)         cmd_remove_dns_entry         "$@" ;;
    # UserData / metadata (apache2)
    save-userdata)            cmd_save_userdata            "$@" ;;
    save-password)            cmd_save_password            "$@" ;;
    save-sshkey)              cmd_save_sshkey              "$@" ;;
    save-hypervisor-hostname) cmd_save_hypervisor_hostname "$@" ;;
    save-vm-data)             cmd_save_vm_data             "$@" ;;
    restore-network)          cmd_restore_network          "$@" ;;
    # Load balancing (haproxy)
    apply-fw-rules)           cmd_apply_fw_rules           "$@" ;;
    apply-lb-rules)           cmd_apply_lb_rules           "$@" ;;
    # Custom actions
    custom-action)            cmd_custom_action            "$@" ;;
    "")
        echo "Usage: $0 {implement|shutdown|destroy|assign-ip|release-ip|" \
             "add-static-nat|delete-static-nat|add-port-forward|delete-port-forward|" \
             "config-dhcp-subnet|remove-dhcp-subnet|add-dhcp-entry|remove-dhcp-entry|set-dhcp-options|" \
             "config-dns-subnet|remove-dns-subnet|add-dns-entry|remove-dns-entry|" \
             "save-userdata|save-password|save-sshkey|save-hypervisor-hostname|save-vm-data|restore-network|" \
             "apply-fw-rules|apply-lb-rules|custom-action} [options]" >&2
        exit 1 ;;
    *)
        echo "Unknown command: ${COMMAND}" >&2
        exit 1 ;;
esac

exit 0

