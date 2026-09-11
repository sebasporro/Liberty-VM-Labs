#!/bin/bash
# =============================================================================
# apply-routing-rules.sh  —  Liberty Collective Dynamic Routing Rules
#
# Pins /server-info/* to a specific collective member, or restores round-robin
# across all members, by writing (or removing) a routing-rules.xml dropin into
# the controller's configDropins/overrides/ directory.
#
# In IntelligentManagement mode the WAS plug-in fetches its routing table from
# the controller's /ibm/api/dynamicRouting endpoint. Controller-side
# <routingRules> are the correct mechanism to influence that table — patching
# plugin-cfg.xml attributes has no effect in this mode.
#
# Usage:
#   scripts/apply-routing-rules.sh -s member1   # pin /server-info/* to member1
#   scripts/apply-routing-rules.sh -s member2   # pin /server-info/* to member2
#   scripts/apply-routing-rules.sh -s all       # remove pin → round-robin
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
TARGET_SERVER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--server) TARGET_SERVER="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ -z "${TARGET_SERVER}" ]]; then
    echo "Usage: $0 -s <member1 | member2 | all>"
    exit 1
fi

if [[ "${TARGET_SERVER}" != "member1" && \
      "${TARGET_SERVER}" != "member2" && \
      "${TARGET_SERVER}" != "all" ]]; then
    echo "ERROR: -s must be: member1 | member2 | all"
    exit 1
fi

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
CTRL_OVERRIDES="${WORKSPACE_ROOT}/installs/controller/wlp/usr/servers/controller/configDropins/overrides"
RULES_FILE="${CTRL_OVERRIDES}/routing-rules.xml"

[[ -d "${CTRL_OVERRIDES}" ]] \
    || { echo "ERROR: ${CTRL_OVERRIDES} not found. Run scripts/install-controller.sh first."; exit 1; }

echo ""
echo "=== Apply Routing Rules ==="
echo ""

# ---------------------------------------------------------------------------
# Write or remove the routing-rules dropin
# ---------------------------------------------------------------------------
if [[ "${TARGET_SERVER}" == "all" ]]; then
    if [[ -f "${RULES_FILE}" ]]; then
        rm -f "${RULES_FILE}"
        echo "  Routing rule removed — controller will round-robin across all members."
    else
        echo "  No routing rule active — already round-robin."
    fi
else
    cat > "${RULES_FILE}" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<server description="Dynamic Routing Rules">

    <!--
      Pins /server-info/* to ${TARGET_SERVER}.
      destination pattern: server=<collective>,<host>,<userdir>,<serverName>
      Wildcards (*) match any collective / host / userdir in this single-VM lab.
    -->
    <dynamicRouting>
        <routingRules webServers="webserver1">
            <routingRule order="100" matchExpression="URI LIKE '/server-info%'">
                <permitAction>
                    <loadBalanceEndPoints>
                        <endpoint destination="server=*,*,*,${TARGET_SERVER}"/>
                    </loadBalanceEndPoints>
                </permitAction>
            </routingRule>
        </routingRules>
    </dynamicRouting>

</server>
XML
    echo "  Routing rule written → /server-info/* pinned to ${TARGET_SERVER}"
    echo "  File: ${RULES_FILE}"
fi

echo ""
echo "  Liberty picks up the dropin dynamically — no controller restart needed."
echo "  The plug-in refreshes its routing table within RefreshInterval (60s)."
echo "  Force immediate pickup with: apachectl graceful"
echo ""
echo "  Verify:"
echo "    for i in \$(seq 6); do curl -s http://localhost:1080/server-info/ | grep -o 'member[0-9]*'; done"
echo ""
