#!/bin/bash
# =============================================================================
# routing.sh
# Manage Liberty Collective dynamic routing rules via simple subcommands.
#
# Usage:
#   routing.sh list                 — list all collective members
#   routing.sh pin <member-name>    — route ALL traffic to one member
#   routing.sh roundrobin           — restore default round-robin routing
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

# ---------------------------------------------------------------------------
# Shared constants
# ---------------------------------------------------------------------------
CONTROLLER_DROPIN_DIR="${WORKSPACE_ROOT}/installs/controller/wlp/usr/servers/controller/configDropins/overrides"
ROUTING_RULES_FILE="${CONTROLLER_DROPIN_DIR}/routing-rules.xml"
INSTALLS_DIR="${WORKSPACE_ROOT}/installs"
CONTROLLER_BIN="${INSTALLS_DIR}/controller/wlp/bin/collective"
CONTROLLER_HTTPS=9443
CONTROLLER_USER="admin"
CONTROLLER_PASS="admin"

# ---------------------------------------------------------------------------
# usage
# ---------------------------------------------------------------------------
usage() {
  echo "Usage:"
  echo "  $0 list                  List all collective members and their status"
  echo "  $0 pin <member-name>     Route ALL traffic to <member-name>"
  echo "  $0 roundrobin            Restore default round-robin across all members"
}

# ---------------------------------------------------------------------------
# cmd_list — show collective members detected via filesystem + port check
# ---------------------------------------------------------------------------
cmd_list() {
  echo ""
  echo "Collective members"
  echo "────────────────────────────────────────────────────────"
  printf "  %-14s  %-10s  %-8s  %s\n" "Member" "Host" "State" "App (server-info)"
  printf "  %-14s  %-10s  %-8s  %s\n" "────────────" "──────────" "──────" "─────────────────"

  local found=0

  # Query the controller using the collective CLI — authoritative source for membership.
  # 'collective listMembers' talks directly to the controller over the JMX REST connector
  # and returns one "host/wlpUserDir/serverName" triplet per line.
  local raw_members=""
  if [[ -x "${CONTROLLER_BIN}" ]]; then
    raw_members=$(
      "${CONTROLLER_BIN}" listMembers \
        --host=localhost \
        --port="${CONTROLLER_HTTPS}" \
        --user="${CONTROLLER_USER}" \
        --password="${CONTROLLER_PASS}" \
        --disableHostnameVerification \
        --autoAcceptCertificates 2>/dev/null \
      | grep -v '^\s*$' \
      | grep -v '^Successfully\|^CWWKX\|^The\|^Members' \
      || true
    )
  fi

  if [[ -n "${raw_members}" ]]; then
    # Each line is:  host,/wlpUserDir/,serverName
    while IFS= read -r line; do
      # Extract the last comma-separated token as the server name
      local server_name
      server_name=$(echo "${line}" | awk -F',' '{print $NF}' | tr -d ' ')
      [[ -z "${server_name}" ]] && continue

      local host
      host=$(echo "${line}" | awk -F',' '{print $1}' | tr -d ' ')

      # Derive HTTP port from numeric suffix (member1→9081, member2→9082, …)
      local idx="${server_name//[^0-9]/}"
      local port="?"
      [[ -n "${idx}" ]] && port=$(( 9080 + idx ))

      # Is the member process actually listening?
      local state="stopped"
      ss -tlnp 2>/dev/null | grep -q ":${port} " && state="running"

      # Live HTTP check against the app
      local app_status="-"
      if [[ "${port}" != "?" ]]; then
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
          --max-time 2 "http://localhost:${port}/server-info/" 2>/dev/null || true)
        [[ "${http_code}" == "200" ]] && app_status="HTTP ${http_code}" || app_status="HTTP ${http_code:-err}"
      fi

      printf "  %-14s  %-10s  %-8s  %s\n" "${server_name}" "${host}" "${state}" "${app_status}"
      (( found++ ))
    done <<< "${raw_members}"
  else
    # Fallback: collective CLI unavailable — scan installs/ directory
    echo "  (collective CLI unavailable — falling back to filesystem scan)"
    echo ""
    for member_dir in "${INSTALLS_DIR}"/*/; do
      local name
      name="$(basename "${member_dir}")"
      [[ "${name}" == "controller" ]] && continue

      local idx="${name//[^0-9]/}"
      local port="?"
      [[ -n "${idx}" ]] && port=$(( 9080 + idx ))

      local state="stopped"
      ss -tlnp 2>/dev/null | grep -q ":${port} " && state="running"

      local app_status="-"
      if [[ "${port}" != "?" ]]; then
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
          --max-time 2 "http://localhost:${port}/server-info/" 2>/dev/null || true)
        [[ "${http_code}" == "200" ]] && app_status="HTTP ${http_code}" || app_status="HTTP ${http_code:-err}"
      fi

      printf "  %-14s  %-10s  %-8s  %s\n" "${name}" "localhost" "${state}" "${app_status}"
      (( found++ ))
    done
  fi

  if [[ "${found}" -eq 0 ]]; then
    echo "  (no members found)"
  fi

  echo ""
  # Show current routing mode
  if [[ -f "${ROUTING_RULES_FILE}" ]]; then
    local pinned
    pinned=$(grep -oP 'destination="server=\*,\*,\*,\K[^"]+' "${ROUTING_RULES_FILE}" 2>/dev/null || true)
    echo "  Current routing: PINNED to '${pinned:-unknown}'"
  else
    echo "  Current routing: ROUND-ROBIN (default)"
  fi
  echo ""
}

# ---------------------------------------------------------------------------
# cmd_pin — write a routing rule that sends all traffic to one member
# ---------------------------------------------------------------------------
cmd_pin() {
  local target="${1:-}"

  if [[ -z "${target}" ]]; then
    echo "ERROR: 'pin' requires a member name." >&2
    echo "  e.g. $0 pin member2" >&2
    exit 1
  fi

  # Validate that the member install directory exists
  if [[ ! -d "${INSTALLS_DIR}/${target}" ]]; then
    echo "ERROR: No install directory found for '${target}' under ${INSTALLS_DIR}." >&2
    echo "  Run: scripts/add-member-26.sh ${target}" >&2
    exit 1
  fi

  if [[ ! -d "${CONTROLLER_DROPIN_DIR}" ]]; then
    echo "ERROR: Controller overrides directory does not exist: ${CONTROLLER_DROPIN_DIR}" >&2
    exit 1
  fi

  cat > "${ROUTING_RULES_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<server description="Dynamic Routing Rules — pinned to ${target}">
    <dynamicRouting>
        <routingRules webServers="webserver1">
            <routingRule order="100" matchExpression="URI LIKE '/*'">
                <permitAction>
                    <loadBalanceEndPoints>
                        <endpoint destination="server=*,*,*,${target}"/>
                    </loadBalanceEndPoints>
                </permitAction>
            </routingRule>
        </routingRules>
    </dynamicRouting>
</server>
EOF

  echo "All traffic pinned to '${target}'."
  echo "Liberty applies routing-rule changes dynamically — no IHS or controller restart needed."
  echo ""
  echo "Verify:  curl -s -c /dev/null http://localhost:1080/server-info/api/health"
}

# ---------------------------------------------------------------------------
# cmd_roundrobin — remove the routing-rules file, restoring Liberty defaults
# ---------------------------------------------------------------------------
cmd_roundrobin() {
  if [[ ! -d "${CONTROLLER_DROPIN_DIR}" ]]; then
    echo "ERROR: Controller overrides directory does not exist: ${CONTROLLER_DROPIN_DIR}" >&2
    exit 1
  fi

  rm -f "${ROUTING_RULES_FILE}"
  echo "Routing rule removed — traffic is now distributed round-robin across all members."
  echo "Liberty applies the change dynamically — no IHS or controller restart needed."
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
CMD="${1:-}"
shift || true   # shift off CMD; remaining args passed to subcommands

case "${CMD}" in
  list)        cmd_list ;;
  pin)         cmd_pin "$@" ;;
  roundrobin)  cmd_roundrobin ;;
  "")
    usage
    exit 0
    ;;
  *)
    echo "ERROR: Unknown command '${CMD}'." >&2
    echo "" >&2
    usage >&2
    exit 1
    ;;
esac
