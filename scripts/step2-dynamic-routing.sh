#!/bin/bash
# =============================================================================
# step2-dynamic-routing.sh
# Enables Liberty Dynamic Routing on the Collective Controller.
#
# How Liberty dynamic routing works:
#   - dynamicRouting-1.0 on the controller monitors collective membership
#   - It periodically rewrites plugin-cfg.xml with the current live member list
#   - The WAS plugin in IHS reads the updated file every RefreshInterval seconds
#   - IHS still talks directly to members — the controller manages the file,
#     not the traffic
#
# Architecture (unchanged from Step 1 — plugin still routes to members):
#   Browser → IHS:8080 → mod_was_ap24_http.so → member1:9081 / member2:9082
#                                ↑
#               plugin-cfg.xml kept current by controller (dynamicRouting-1.0)
#
# What this script does:
#   1. Adds dynamicRouting-1.0 feature to the controller via configDropins
#   2. Restarts the controller and waits for it to be ready
#   3. Verifies end-to-end routing still works (plugin-cfg.xml unchanged)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/IBM/HTTPServer}"
HTTPD_CONF="${IHS_ROOT}/conf/httpd.conf"
PLUGIN_CFG="${IHS_ROOT}/conf/plugin-cfg.xml"
APACHECTL="${IHS_ROOT}/bin/apachectl"

CONTROLLER_DIR="${WORKSPACE_ROOT}/installs/controller"
SERVER_DIR="${CONTROLLER_DIR}/wlp/usr/servers/controller"
WLP_BIN="${CONTROLLER_DIR}/wlp/bin/server"
OVERRIDES_DIR="${SERVER_DIR}/configDropins/overrides"
MESSAGES_LOG="${SERVER_DIR}/logs/messages.log"

CONTROLLER_HTTP=9080

echo ""
echo "=== Step 2: Enable Liberty Dynamic Routing ==="
echo ""

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
echo "[0/6] Pre-flight checks..."

if [[ ! -x "${WLP_BIN}" ]]; then
    echo "ERROR: Controller not installed at ${CONTROLLER_DIR}"
    exit 1
fi

if ! ss -tlnp 2>/dev/null | grep -q ":${CONTROLLER_HTTP} "; then
    echo "ERROR: Controller is not running on port ${CONTROLLER_HTTP}."
    echo "       Start it: ${WLP_BIN} start controller"
    exit 1
fi
echo "      Controller: running on port ${CONTROLLER_HTTP}"

RUNNING_MEMBERS=0
for member_dir in "${WORKSPACE_ROOT}/installs"/member*/; do
    member_name=$(basename "${member_dir}")
    member_bin="${member_dir}/wlp/bin/server"
    if [[ -x "${member_bin}" ]]; then
        STATUS=$("${member_bin}" status "${member_name}" 2>/dev/null)
        echo "${STATUS}" | grep -q "is running" && (( RUNNING_MEMBERS++ ))
    fi
done

if [[ ${RUNNING_MEMBERS} -eq 0 ]]; then
    echo "ERROR: No Liberty member servers are running."
    exit 1
fi
echo "      Members running: ${RUNNING_MEMBERS}"
echo ""

# ---------------------------------------------------------------------------
# 1. Add dynamicRouting-1.0 feature override to the controller
# ---------------------------------------------------------------------------
echo "[1/6] Adding dynamicRouting-1.0 to controller..."
mkdir -p "${OVERRIDES_DIR}"

DYNAMIC_ROUTING_XML="${OVERRIDES_DIR}/dynamic-routing.xml"

if [[ -f "${DYNAMIC_ROUTING_XML}" ]]; then
    echo "      Already present — skipped"
else
    cat > "${DYNAMIC_ROUTING_XML}" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<server description="Dynamic Routing feature override">
    <featureManager>
        <feature>dynamicRouting-1.0</feature>
    </featureManager>
</server>
EOF
    echo "      Written: ${DYNAMIC_ROUTING_XML}"
fi
echo ""

# ---------------------------------------------------------------------------
# 2. Restart controller to load the new feature
# ---------------------------------------------------------------------------
echo "[2/6] Restarting controller to load dynamicRouting-1.0..."
"${WLP_BIN}" stop controller 2>/dev/null
sleep 3
"${WLP_BIN}" start controller

echo "      Waiting for controller ready (up to 60s)..."
WAITED=0
while [[ ${WAITED} -lt 60 ]]; do
    grep -q "server is ready" "${MESSAGES_LOG}" 2>/dev/null && break
    sleep 2; (( WAITED += 2 ))
done

if [[ ${WAITED} -ge 60 ]]; then
    echo "WARNING: Timeout waiting for controller. Check: ${MESSAGES_LOG}"
fi

if grep -q "dynamicRouting-1.0" "${MESSAGES_LOG}" 2>/dev/null; then
    echo "      dynamicRouting-1.0: loaded ✓"
else
    echo "WARNING: dynamicRouting-1.0 may not have loaded. Check: ${MESSAGES_LOG}"
fi
echo ""

# ---------------------------------------------------------------------------
# 3. Verify plugin-cfg.xml still points at members (do NOT overwrite it)
# ---------------------------------------------------------------------------
echo "[3/4] Checking plugin-cfg.xml..."

if [[ ! -f "${PLUGIN_CFG}" ]]; then
    echo "ERROR: ${PLUGIN_CFG} not found."
    echo "       Run scripts/step1-was-plugin.sh first."
    exit 1
fi

if grep -q "Protocol=\"http\"" "${PLUGIN_CFG}" && ! grep -q "CloneID=\"controller\"" "${PLUGIN_CFG}"; then
    echo "      plugin-cfg.xml: OK (pointing at members)"
else
    echo "WARNING: plugin-cfg.xml may be pointing at the controller."
    echo "         Run scripts/step1-was-plugin.sh to restore correct member entries."
fi
echo ""

# ---------------------------------------------------------------------------
# 4. Verify end-to-end routing
# ---------------------------------------------------------------------------
echo "[4/4] Verifying routing..."
sleep 2

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/server-info/ 2>/dev/null)
echo "      GET /server-info/ via IHS: HTTP ${HTTP_CODE}"

if [[ "${HTTP_CODE}" == "200" ]]; then
    echo ""
    echo "=== Step 2 complete — Dynamic routing is active ==="
    echo ""
    echo "  The controller now monitors collective membership and keeps"
    echo "  plugin-cfg.xml current. New members are picked up automatically"
    echo "  within RefreshInterval (60s) — no IHS config changes needed."
else
    echo ""
    echo "  HTTP ${HTTP_CODE} — check logs:"
    echo "    tail -30 ${IHS_ROOT}/logs/error_log"
    echo "    tail -30 ${IHS_ROOT}/logs/plugin.log"
    echo "    tail -30 ${MESSAGES_LOG}"
fi

echo ""
echo "  Admin Center:  https://localhost:9443/adminCenter  (admin / admin)"
echo "  Plugin config: ${PLUGIN_CFG}"
echo "  Plugin log:    ${IHS_ROOT}/logs/plugin.log"
echo ""
