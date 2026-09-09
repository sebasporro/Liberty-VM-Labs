#!/bin/bash
# =============================================================================
# apply-routing-rules.sh  —  Liberty Collective Dynamic Routing Rules (Part 6)
#
# Applies (or clears) routing rules on the collective controller so that
# requests for /server-info/* are pinned to a specific member, or distributed
# across all members (default round-robin).
#
# Usage:
#   scripts/apply-routing-rules.sh -s member1
#   scripts/apply-routing-rules.sh -s member2
#   scripts/apply-routing-rules.sh -s all        # removes pin → round-robin
#
# What it does:
#   1. Writes (or removes) routing-rules.xml in the controller's
#      configDropins/overrides/ directory.
#   2. Liberty picks up the dropin change dynamically — no controller restart.
#   3. Restarts IHS so the plugin picks up the updated routing table.
#
# Reference:
#   https://www.ibm.com/docs/en/was-liberty/nd?topic=SSAW57_liberty/com.ibm.websphere.wlp.zseries.doc/ae/twlp_wve_routing_rules.htm
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
if [[ "$#" -lt 2 ]]; then
    echo ""
    echo "  Usage: $0 -s <member1 | member2 | all>"
    echo ""
    echo "  Examples:"
    echo "    $0 -s member1   # route /server-info/* only to member1"
    echo "    $0 -s member2   # route /server-info/* only to member2"
    echo "    $0 -s all       # remove pin — round-robin across all members"
    echo ""
    exit 1
fi

TARGET_SERVER=""
while [[ $# -gt 1 ]]; do
    case "$1" in
        -s|--server) TARGET_SERVER="$2"; shift ;;
    esac
    shift
done

if [[ -z "${TARGET_SERVER}" ]]; then
    echo "  ERROR: -s flag is required."
    exit 1
fi

if [[ "${TARGET_SERVER}" != "member1" && \
      "${TARGET_SERVER}" != "member2" && \
      "${TARGET_SERVER}" != "all" ]]; then
    echo "  ERROR: Invalid value '${TARGET_SERVER}' for -s."
    echo "         Must be: member1 | member2 | all"
    exit 1
fi

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
CTRL_OVERRIDES="${WORKSPACE_ROOT}/installs/controller/wlp/usr/servers/controller/configDropins/overrides"
RULES_FILE="${CTRL_OVERRIDES}/routing-rules.xml"
IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/usr/IBM/IHS}"
APACHECTL="${IHS_ROOT}/bin/apachectl"

echo ""
echo "=== Apply Routing Rules ==="
echo ""

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
[[ -d "${CTRL_OVERRIDES}" ]] \
    || { echo "  ERROR: Controller overrides directory not found: ${CTRL_OVERRIDES}"; echo "  Run scripts/install-controller.sh first."; exit 1; }

# ---------------------------------------------------------------------------
# Write or remove the routing-rules dropin
# ---------------------------------------------------------------------------
if [[ "${TARGET_SERVER}" == "all" ]]; then
    # Remove the pin — Liberty will revert to default round-robin
    if [[ -f "${RULES_FILE}" ]]; then
        rm -f "${RULES_FILE}"
        echo "  Routing rule removed — Liberty will load-balance across all members."
    else
        echo "  No routing rule was active — already using round-robin."
    fi
else
    # Pin /server-info/* to the requested member
    cat > "${RULES_FILE}" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<server description="Dynamic Routing Rules">
    <featureManager>
        <feature>dynamicRouting-1.0</feature>
    </featureManager>

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
    echo "  Routing rule written: all /server-info/* → ${TARGET_SERVER}"
fi

echo ""
echo "  Liberty picks up dropin changes dynamically — no controller restart needed."
echo ""

# ---------------------------------------------------------------------------
# Restart IHS so the plugin refreshes its routing table from the controller
# ---------------------------------------------------------------------------
echo "  Restarting IHS to refresh routing table..."
"${APACHECTL}" stop 2>/dev/null; sleep 2
"${APACHECTL}" start; sleep 2
echo ""

echo "============================================================="
echo ""
echo "  Routing rule now active: -s ${TARGET_SERVER}"
echo ""
echo "  Verify:"
echo "    for i in \$(seq 6); do curl -s http://localhost:1080/server-info/ | grep -o 'member[0-9]*'; done"
echo ""
echo "============================================================="
echo ""
