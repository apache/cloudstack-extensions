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
# network-namespace.sh  (network-namespace)
#
# Proxy script for the network-namespace CloudStack extension.
# Runs on the CloudStack management server.
#
# Two modes of operation:
#
#  1. ensure-network-device  (local, no SSH)
#     Called by NetworkExtensionElement before every network operation.
#     Selects or re-validates the network device for the given network ID.
#     Reads the candidate host list from --physical-network-extension-details["hosts"]
#     (comma-separated).
#     If the previously selected host (from --current-details JSON) is still
#     reachable it is kept; otherwise a new host is chosen from the list.
#     Prints a single-line JSON object to stdout, e.g.:
#       {"host":"192.168.1.10","namespace":"cs-net-42"}
#     The caller (NetworkExtensionElement) stores this in network_details and
#     forwards it to all future calls as --network-extension-details.
#
#  2. All other commands  (forwarded to the target host via SSH)
#     The target host is taken from --network-extension-details["host"].
#     The remote script (network-namespace-wrapper.sh) is called with all
#     arguments including both --physical-network-extension-details and
#     --network-extension-details.
#
# ---- CLI arguments injected by NetworkExtensionElement ----
#
#   --physical-network-extension-details <json>
#       JSON object with all extension_resource_map_details registered for this
#       extension on the physical network.  No pre-defined keys — the user and
#       the script agree on the schema.  Typical keys for a KVM-namespace backend:
#         hosts     – comma-separated list of host IPs for HA/selection
#         port      – SSH port (default 22)
#         username  – SSH user (default root)
#         password  – SSH password  (sensitive, not logged)
#         sshkey    – PEM-encoded SSH private key  (sensitive, not logged)
#
#   --network-extension-details <json>
#       Per-network opaque JSON blob (from network_details key ext.details).
#       '{}' on the first ensure-network-device call.
#       This script is the sole owner — CloudStack stores and forwards it verbatim.
#         host      – previously selected host IP
#         namespace – Linux network namespace name (cs-net-<networkId>)
#
# ---- SSH authentication priority ----
#   1. sshkey  field in --physical-network-extension-details → PEM key
#   2. password field                                        → sshpass(1)
#   3. No credentials → relies on SSH agent / host keys on mgmt server
#
# Exit codes:
#   0  – success
#   1  – usage / configuration error
#   2  – SSH connection / authentication error
#   3  – remote command returned non-zero
##############################################################################

set -euo pipefail

DEFAULT_SSH_PORT=22
DEFAULT_SSH_USER=root

# ---------------------------------------------------------------------------
# Resolve this entry-point's absolute path so we can derive both the KVM
# wrapper path and the log file name from the extension directory name.
#
# Layout:
#   management server:  /usr/share/cloudstack-management/extensions/<name>/<name>.sh
#   KVM host (wrapper): /etc/cloudstack/extensions/<name>/<name>-wrapper.sh
#
# _EXT_DIR_NAME is the basename of the directory containing this script,
# which equals the extension name assigned by CloudStack (e.g.
# "extnet-isolated-gk3yys").  Both the wrapper path and the log file are
# derived from it so that renamed deployments work automatically.
#
# Callers may still override the remote path via CS_NET_SCRIPT_PATH:
#   CS_NET_SCRIPT_PATH=/custom/path/wrapper.sh network-namespace.sh <cmd> ...
# ---------------------------------------------------------------------------
_SELF="$(readlink -f "$0" 2>/dev/null \
         || realpath "$0" 2>/dev/null \
         || echo "$0")"
_SCRIPT_BASENAME="$(basename "${_SELF}" .sh)"
_EXT_DIR_NAME="$(basename "$(dirname "${_SELF}")")"

# Remote wrapper path on each KVM host.
DEFAULT_SCRIPT_PATH="/etc/cloudstack/extensions/${_EXT_DIR_NAME}/${_SCRIPT_BASENAME}-wrapper.sh"

# Log file — under /var/log/cloudstack/extensions/ named after the extension.
LOG_FILE="/var/log/cloudstack/extensions/${_EXT_DIR_NAME}.log"
mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
TMPDIR_BASE=/tmp

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] %s\n' "${ts}" "$*" >> "${LOG_FILE}" 2>/dev/null || true
}

die() {
    log "ERROR: $*"
    exit "${2:-1}"
}

# ---------------------------------------------------------------------------
# JSON helpers (no jq dependency)
# ---------------------------------------------------------------------------

json_get() {
    # json_get <json> <key>  →  unquoted string value or empty
    printf '%s' "$1" | grep -o "\"$2\":\"[^\"]*\"" | cut -d'"' -f4 || true
}

# ---------------------------------------------------------------------------
# Validate input and parse command
# ---------------------------------------------------------------------------

if [ $# -lt 1 ]; then
    die "Usage: network-namespace.sh <command> [arguments...]" 1
fi

COMMAND="$1"
shift

# ---------------------------------------------------------------------------
# Parse CLI arguments: extract known flags, collect the rest as FORWARD_ARGS
# ---------------------------------------------------------------------------

PHYS_DETAILS="{}"
EXTENSION_DETAILS="{}"
NETWORK_ID=""
CURRENT_DETAILS="{}"
VPC_ID=""
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
            FORWARD_ARGS+=("$1" "$2")
            shift 2 ;;
        --vpc-id)
            VPC_ID="${2:-}"
            FORWARD_ARGS+=("$1" "$2")
            shift 2 ;;
        --current-details)
            CURRENT_DETAILS="${2:-{}}"
            shift 2 ;;
        *)
            FORWARD_ARGS+=("$1")
            shift ;;
    esac
done

REMOTE_SCRIPT="${CS_NET_SCRIPT_PATH:-${DEFAULT_SCRIPT_PATH}}"

REMOTE_PORT=$(json_get "${PHYS_DETAILS}" "port")
REMOTE_USER=$(json_get "${PHYS_DETAILS}" "username")
REMOTE_PASS=$(json_get "${PHYS_DETAILS}" "password")
REMOTE_SSHKEY=$(json_get "${PHYS_DETAILS}" "sshkey")
HOSTS_CSV=$(json_get "${PHYS_DETAILS}" "hosts")
SINGLE_HOST=$(json_get "${PHYS_DETAILS}" "host")

REMOTE_PORT="${REMOTE_PORT:-${DEFAULT_SSH_PORT}}"
REMOTE_USER="${REMOTE_USER:-${DEFAULT_SSH_USER}}"

# Build the candidate host list
if [ -n "${HOSTS_CSV}" ]; then
    IFS=',' read -ra HOST_LIST <<< "${HOSTS_CSV}"
elif [ -n "${SINGLE_HOST}" ]; then
    HOST_LIST=("${SINGLE_HOST}")
else
    HOST_LIST=()
fi

# ---------------------------------------------------------------------------
# SSH helpers
# ---------------------------------------------------------------------------

KEY_TMPFILE=""
KEY_TMPDIR=""

cleanup() {
    local rc=$?
    if [ -n "${KEY_TMPDIR}" ] && [ -d "${KEY_TMPDIR}" ]; then
        rm -rf "${KEY_TMPDIR}" 2>/dev/null || true
    fi
    exit ${rc}
}
trap cleanup EXIT INT TERM

setup_ssh_key() {
    if [ -n "${REMOTE_SSHKEY}" ] && [ -z "${KEY_TMPFILE}" ]; then
        KEY_TMPDIR=$(mktemp -d "${TMPDIR_BASE}/.cs-extnet-key-XXXXXX")
        chmod 700 "${KEY_TMPDIR}"
        KEY_TMPFILE="${KEY_TMPDIR}/id_extnet"
        printf '%s\n' "${REMOTE_SSHKEY}" > "${KEY_TMPFILE}"
        chmod 600 "${KEY_TMPFILE}"
    fi
}

ssh_opts() {
    local opts=(
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o LogLevel=ERROR
        -o ConnectTimeout=10
        -p "${REMOTE_PORT}"
    )
    if [ -n "${KEY_TMPFILE}" ]; then
        opts+=(-i "${KEY_TMPFILE}" -o IdentitiesOnly=yes -o BatchMode=yes)
    elif [ -n "${REMOTE_PASS}" ]; then
        # When using password-based auth we should not force an IdentityFile of /dev/null
        # because recent OpenSSH may attempt to parse it and emit libcrypto errors
        # (seen as: Load key "/dev/null": error in libcrypto). Just rely on sshpass
        # (SSHPASS) to provide the password if needed.
        opts+=(-o IdentitiesOnly=yes)
    fi
    printf '%s\n' "${opts[@]}"
}

host_reachable() {
    local host="$1"
    setup_ssh_key
    local opts
    mapfile -t opts < <(ssh_opts)
    if [ -n "${REMOTE_SSHKEY}" ]; then
        ssh "${opts[@]}" "${REMOTE_USER}@${host}" "echo ok" >/dev/null 2>&1
    elif [ -n "${REMOTE_PASS}" ]; then
        command -v sshpass >/dev/null 2>&1 || return 1
        SSHPASS="${REMOTE_PASS}" sshpass -e \
            ssh "${opts[@]}" "${REMOTE_USER}@${host}" "echo ok" >/dev/null 2>&1
    else
        ssh "${opts[@]}" "${REMOTE_USER}@${host}" "echo ok" >/dev/null 2>&1
    fi
}

ssh_exec() {
    local host="$1"
    local remote_cmd="$2"
    setup_ssh_key
    local opts
    mapfile -t opts < <(ssh_opts)
    if [ -n "${REMOTE_SSHKEY}" ]; then
        ssh "${opts[@]}" "${REMOTE_USER}@${host}" "${remote_cmd}"
    elif [ -n "${REMOTE_PASS}" ]; then
        command -v sshpass >/dev/null 2>&1 || \
            die "password set but sshpass not installed. Use sshkey instead." 2
        SSHPASS="${REMOTE_PASS}" sshpass -e \
            ssh "${opts[@]}" "${REMOTE_USER}@${host}" "${remote_cmd}"
    else
        ssh "${opts[@]}" "${REMOTE_USER}@${host}" "${remote_cmd}"
    fi
}

# ---------------------------------------------------------------------------
# ensure-network-device
# ---------------------------------------------------------------------------

if [ "${COMMAND}" = "ensure-network-device" ]; then
    [ -z "${NETWORK_ID}" ] && die "ensure-network-device: missing --network-id" 1

    if [ ${#HOST_LIST[@]} -eq 0 ]; then
        die "ensure-network-device: no hosts configured. Set 'hosts' in registerExtension details." 1
    fi

    # Namespace names must match those used by the wrapper on the KVM host.
    # VPC networks share one namespace per VPC (cs-vpc-<vpcId>);
    # standalone isolated networks get their own namespace (cs-net-<networkId>).
    if [ -n "${VPC_ID}" ]; then
        NAMESPACE="cs-vpc-${VPC_ID}"
    else
        NAMESPACE="cs-net-${NETWORK_ID}"
    fi

    # ---- Step 1: honour the previously selected host (sticky assignment) ----
    # This preserves the host–namespace binding across API calls once a network
    # has been implemented on a particular KVM host.
    CURRENT_HOST=$(json_get "${CURRENT_DETAILS}" "host")
    [ -z "${CURRENT_HOST}" ] && CURRENT_HOST=$(json_get "${EXTENSION_DETAILS}" "host")

    if [ -n "${CURRENT_HOST}" ]; then
        for h in "${HOST_LIST[@]}"; do
            h="${h// /}"
            if [ "${h}" = "${CURRENT_HOST}" ]; then
                if host_reachable "${CURRENT_HOST}"; then
                    log "ensure-network-device: network=${NETWORK_ID} keeping current host=${CURRENT_HOST}"
                    if [ -n "${VPC_ID}" ]; then
                        printf '{"host":"%s","namespace":"%s","vpc_id":"%s"}\n' \
                            "${CURRENT_HOST}" "${NAMESPACE}" "${VPC_ID}"
                    else
                        printf '{"host":"%s","namespace":"%s"}\n' \
                            "${CURRENT_HOST}" "${NAMESPACE}"
                    fi
                    exit 0
                else
                    log "ensure-network-device: current host ${CURRENT_HOST} not reachable — failover"
                fi
                break
            fi
        done
    fi

    # ---- Step 2: stable hash-based host selection for new / failed-over networks ----
    #
    # For VPC networks ALL tiers must land on the same KVM host (they share one
    # namespace).  Using VPC_ID as the hash key guarantees every tier in a VPC
    # hashes to the same preferred index even when its own details are not yet
    # stored.  For isolated networks the NETWORK_ID is used.
    #
    # Algorithm: CRC32 of the routing key (via cksum) modulo the host count
    # gives a stable preferred index.  We probe hosts starting from that index,
    # wrapping around, until a reachable one is found.  This distributes
    # different networks evenly across KVM hosts while remaining deterministic.
    _ROUTE_KEY="${VPC_ID:-${NETWORK_ID}}"
    _HOST_COUNT="${#HOST_LIST[@]}"
    _PREFERRED_IDX=$(printf '%s' "${_ROUTE_KEY}" | cksum | awk -v n="${_HOST_COUNT}" '{print ($1 % n)}')

    _SELECTED_HOST=""
    _PROBE=0
    while [ "${_PROBE}" -lt "${_HOST_COUNT}" ]; do
        _IDX=$(( (_PREFERRED_IDX + _PROBE) % _HOST_COUNT ))
        _H="${HOST_LIST[$_IDX]// /}"
        if host_reachable "${_H}"; then
            _SELECTED_HOST="${_H}"
            log "ensure-network-device: network=${NETWORK_ID} hash-selected host=${_SELECTED_HOST} (key=${_ROUTE_KEY}, idx=${_IDX})"
            break
        fi
        log "ensure-network-device: host ${_H} not reachable, trying next"
        _PROBE=$(( _PROBE + 1 ))
    done

    [ -z "${_SELECTED_HOST}" ] && \
        die "ensure-network-device: no reachable host found in list: ${HOSTS_CSV:-${SINGLE_HOST}}" 1

    if [ -n "${VPC_ID}" ]; then
        printf '{"host":"%s","namespace":"%s","vpc_id":"%s"}\n' \
            "${_SELECTED_HOST}" "${NAMESPACE}" "${VPC_ID}"
    else
        printf '{"host":"%s","namespace":"%s"}\n' "${_SELECTED_HOST}" "${NAMESPACE}"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# All other commands: forward via SSH to the selected network device
# ---------------------------------------------------------------------------

REMOTE_HOST=$(json_get "${EXTENSION_DETAILS}" "host")
if [ -z "${REMOTE_HOST}" ]; then
    REMOTE_HOST="${SINGLE_HOST:-}"
    [ -z "${REMOTE_HOST}" ] && [ ${#HOST_LIST[@]} -gt 0 ] && REMOTE_HOST="${HOST_LIST[0]// /}"
fi
[ -z "${REMOTE_HOST}" ] && die "No target host available. Run ensure-network-device first." 1

# Build the remote command — quote each argument and forward both JSON blobs
remote_args=()
for arg in "${FORWARD_ARGS[@]}"; do
    remote_args+=("'${arg//"'"/"'\\''"}'" )
done

PHYS_ESCAPED="${PHYS_DETAILS//\'/\'\\\'\'}"
EXT_ESCAPED="${EXTENSION_DETAILS//\'/\'\\\'\'}"
REMOTE_CMD="'${REMOTE_SCRIPT}' '${COMMAND}' ${remote_args[*]} --physical-network-extension-details '${PHYS_ESCAPED}' --network-extension-details '${EXT_ESCAPED}'"

log "Remote: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT} cmd=${COMMAND}"

RC=0
ssh_exec "${REMOTE_HOST}" "${REMOTE_CMD}" || RC=$?

if [ ${RC} -ne 0 ]; then
    if [ ${RC} -eq 255 ]; then
        log "SSH connection failed (rc=255): host=${REMOTE_HOST}:${REMOTE_PORT} user=${REMOTE_USER}"
        exit 2
    fi
    log "Remote script returned rc=${RC}"
    exit 3
fi

log "Command '${COMMAND}' completed successfully on ${REMOTE_HOST}"
exit 0

