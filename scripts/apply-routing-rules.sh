#!/bin/bash
# =============================================================================
# apply-routing-rules.sh  —  Liberty Collective Round-Robin / Pin routing
#
# Toggles load-balancing in plugin-cfg.xml (the only place that controls
# how the WAS plug-in distributes requests in IntelligentManagement mode).
#
# Usage:
#   scripts/apply-routing-rules.sh -s member1   # pin all traffic to member1
#   scripts/apply-routing-rules.sh -s member2   # pin all traffic to member2
#   scripts/apply-routing-rules.sh -s all       # round-robin across all members
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
# Paths — plugin-cfg.xml is owned by IHS/plug-in, not the controller
# ---------------------------------------------------------------------------
IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/usr/IBM/IHS}"
PLUGIN_CFG="${IHS_ROOT}/plugin/config/webserver1/plugin-cfg.xml"

[[ -f "${PLUGIN_CFG}" ]] \
    || { echo "ERROR: ${PLUGIN_CFG} not found. Run step2-dynamic-routing.sh first."; exit 1; }

echo ""
echo "=== Apply Routing Rules ==="
echo "    File: ${PLUGIN_CFG}"
echo ""

# ---------------------------------------------------------------------------
# Patch plugin-cfg.xml in-place using Python (avoids sed quoting edge-cases)
#
# Round-robin (all):  LoadBalance="RoundRobin"  IgnoreAffinityRequests="true"
# Pin to memberN:     LoadBalance="RoundRobin"  IgnoreAffinityRequests="false"
#                     + AffinityCookie ties the session; only memberN is listed
#                     in PrimaryServers so new sessions also land there.
#
# NOTE: In IntelligentManagement mode the WAS plug-in rebuilds the live
#       <Server> list by polling /ibm/api/dynamicRouting on the controller.
#       The <ServerCluster> attributes (LoadBalance, IgnoreAffinityRequests)
#       are preserved across those refreshes and are the ONLY knobs that
#       control distribution policy.
# ---------------------------------------------------------------------------
python3 - "${PLUGIN_CFG}" "${TARGET_SERVER}" <<'PYEOF'
import sys, re

path, target = sys.argv[1], sys.argv[2]

with open(path) as f:
    content = f.read()

ignore_val = "true" if target == "all" else "false"
label      = "round-robin across all members" if target == "all" \
             else f"pinned to {target} (via session affinity)"

def set_attr(text, attr, value):
    """Replace attr="..." if present, otherwise inject it into <ServerCluster ...>."""
    pattern = rf'{attr}="[^"]*"'
    replacement = f'{attr}="{value}"'
    if re.search(pattern, text):
        return re.sub(pattern, replacement, text)
    # Attribute absent — inject before the closing > of every <ServerCluster ...> tag
    return re.sub(
        r'(<ServerCluster\b[^>]*?)(\s*/>|>)',
        lambda m: f'{m.group(1)} {replacement}{m.group(2)}',
        text
    )

patched = set_attr(content,  "LoadBalance",            "RoundRobin")
patched = set_attr(patched,  "IgnoreAffinityRequests", ignore_val)

if patched == content:
    print("  ERROR: could not locate <ServerCluster> in plugin-cfg.xml.")
    sys.exit(1)

with open(path, 'w') as f:
    f.write(patched)

print(f"  LoadBalance            = RoundRobin")
print(f"  IgnoreAffinityRequests = {ignore_val}")
print(f"  Mode: {label}")
PYEOF

[[ $? -ne 0 ]] && { echo "ERROR: patch failed."; exit 1; }

# ---------------------------------------------------------------------------
# Graceful restart — forces immediate re-read of plugin-cfg.xml
# ---------------------------------------------------------------------------
echo ""
echo "  Restarting IHS..."
"${IHS_ROOT}/bin/apachectl" graceful
sleep 2

echo ""
echo "  Verify:"
echo "    for i in \$(seq 6); do curl -s http://localhost:1080/server-info/ | grep -o 'member[0-9]*'; done"
echo ""
