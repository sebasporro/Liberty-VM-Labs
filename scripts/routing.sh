#!/bin/bash
# =============================================================================
# apply-routing-rules.sh
# Manage Liberty Collective dynamic routing rules via simple subcommands.
#
# Usage:
#   apply-routing-rules.sh list                 — list all collective members
#   apply-routing-rules.sh pin <member-name>    — route ALL traffic to one member
#   apply-routing-rules.sh roundrobin           — restore default round-robin routing
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
  printf "  %-12s  %-6s  %-8s  %s\n" "Member" "HTTP" "Status" "Server dir"
  printf "  %-12s  %-6s  %-8s  %s\n" "──────────" "────" "──────" "──────────"

  local found=0
  for member_dir in "${INSTALLS_DIR}"/*/; do
    local name
    name="$(basename "${member_dir}")"
    [[ "${name}" == "controller" ]] && continue

    # Derive HTTP port from member index (member1=9081, member2=9082, …)
    local idx="${name//[^0-9]/}"
    local port="?"
    if [[ -n "${idx}" ]]; then
      port=$(( 9080 + idx ))
    fi

    # Port up/down check
    local status="stopped"
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
      status="running"
    fi

    local server_dir="${member_dir}wlp/usr/servers/${name}"
    printf "  %-12s  %-6s  %-8s  %s\n" "${name}" "${port}" "${status}" "${server_dir}"
    (( found++ ))
  done

  if [[ "${found}" -eq 0 ]]; then
    echo "  (no members found under ${INSTALLS_DIR})"
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
