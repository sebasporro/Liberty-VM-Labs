#!/bin/bash
# =============================================================================
# step2-dynamic-routing.sh
# Enables Liberty Dynamic Routing on the Collective.
#
# Reference:
#   https://www.ibm.com/docs/en/was-liberty/nd?topic=collectives-setting-up-dynamic-routing-liberty
#
# How Liberty dynamic routing works:
#   1. The controller runs the dynamicRouting-1.0 feature which activates a
#      /wr (WebSphere Routing) endpoint on the controller HTTP port (9080).
#   2. The dynamicRouting setup command connects to the controller and
#      generates a plugin-cfg.xml that points the IHS plugin at the /wr
#      endpoint — NOT at individual member servers.
#   3. mod_was_ap24_http.so polls /wr every RefreshInterval seconds.
#      The controller returns the live routing table of all healthy collective
#      members; the plugin routes requests accordingly.
#   4. Members joining/leaving/stopping/starting are reflected automatically
#      within one RefreshInterval — no manual plugin-cfg.xml regeneration needed.
#
# Architecture after this script:
#   Browser → IHS:8080 ──(mod_was_ap24_http.so)──► controller:9080/wr
#                                                        │
#                                         live route table (all members)
#                                                        │
#                         ┌──────────────┬──────────────┼──────────────┐
#                         ▼              ▼              ▼              ▼
#                    member1:9081  member2:9082  member3:9083  member4:9084
#
# Prerequisites:
#   - IHS installed with mod_was_ap24_http.so     (scripts/install-ihs.sh)
#   - Controller running on HTTP 9080 / HTTPS 9443 (scripts/install-controller.sh)
#   - At least one member joined to the collective  (scripts/add-member-26.sh)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
CONTROLLER_DIR="${WORKSPACE_ROOT}/installs/controller"
CTRL_WLP="${CONTROLLER_DIR}/wlp"
SERVER_DIR="${CTRL_WLP}/usr/servers/controller"
WLP_BIN="${CTRL_WLP}/bin/server"
DYNAMIC_ROUTING_BIN="${CTRL_WLP}/bin/dynamicRouting"
OVERRIDES_DIR="${SERVER_DIR}/configDropins/overrides"
MESSAGES_LOG="${SERVER_DIR}/logs/messages.log"

# dynamicRouting setup writes output here
SETUP_OUTPUT_DIR="${SERVER_DIR}/resources/security/plugin-setup"

IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/IBM/HTTPServer}"
HTTPD_CONF="${IHS_ROOT}/conf/httpd.conf"
APACHECTL="${IHS_ROOT}/bin/apachectl"
PLUGIN_CFG="${IHS_ROOT}/conf/plugin-cfg.xml"

# Controller coordinates
# NOTE: dynamicRouting setup connects on the HTTP port (9080), not HTTPS.
# The /wr endpoint is served over plain HTTP on the controller HTTP port.
CONTROLLER_HOST="localhost"
CONTROLLER_HTTP=9080
CONTROLLER_HTTPS=9443
ADMIN_USER="admin"
ADMIN_PASS="admin"
KEYSTORE_PASS="Liberty26ctrl!"   # must match keystore.password in bootstrap.properties
WEB_SERVER_NAME="webserver1"     # name registered with the collective controller

echo ""
echo "=== Step 3b: Liberty Dynamic Routing ==="
echo ""

# ---------------------------------------------------------------------------
# 1. Pre-flight checks
# ---------------------------------------------------------------------------
echo "[1/5] Pre-flight checks..."

if [[ ! -x "${WLP_BIN}" ]]; then
    echo "  ERROR: Controller WLP not found at ${CONTROLLER_DIR}"
    echo "         Run scripts/install-controller.sh first."
    exit 1
fi

if [[ ! -x "${DYNAMIC_ROUTING_BIN}" ]]; then
    echo "  ERROR: dynamicRouting binary not found at ${DYNAMIC_ROUTING_BIN}"
    echo "         The collectiveController-1.0 feature must be installed."
    exit 1
fi
echo "  dynamicRouting  : ${DYNAMIC_ROUTING_BIN}"

if [[ ! -f "${HTTPD_CONF}" ]]; then
    echo "  ERROR: httpd.conf not found at ${HTTPD_CONF}"
    echo "         Run scripts/install-ihs.sh first."
    exit 1
fi

if [[ ! -f "${IHS_ROOT}/modules/mod_was_ap24_http.so" ]]; then
    echo "  ERROR: mod_was_ap24_http.so not found in ${IHS_ROOT}/modules/"
    echo "         Run scripts/install-ihs.sh first."
    exit 1
fi
echo "  WAS plugin      : present"

if ! ss -tlnp 2>/dev/null | grep -q ":${CONTROLLER_HTTP} "; then
    echo "  ERROR: Controller is not running on HTTP port ${CONTROLLER_HTTP}."
    echo "         Run: ${WLP_BIN} start controller"
    exit 1
fi
echo "  Controller HTTP : running on ${CONTROLLER_HTTP}"

# Report which members are up
MEMBERS_UP=0
for port in 9081 9082 9083 9084; do
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        echo "  Member :${port}     : up"
        (( MEMBERS_UP++ ))
    fi
done
if [[ ${MEMBERS_UP} -eq 0 ]]; then
    echo "  ERROR: No collective members running on ports 9081-9084."
    exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# 2. Add dynamicRouting-1.0 feature to the controller (idempotent)
# ---------------------------------------------------------------------------
echo "[2/5] Enabling dynamicRouting-1.0 on controller..."
mkdir -p "${OVERRIDES_DIR}"
DYNAMIC_XML="${OVERRIDES_DIR}/dynamic-routing.xml"

if [[ -f "${DYNAMIC_XML}" ]]; then
    echo "  Already present — skipped"
else
    cat > "${DYNAMIC_XML}" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<server description="Dynamic routing feature">
    <featureManager>
        <feature>dynamicRouting-1.0</feature>
    </featureManager>
</server>
XML
    echo "  Written: ${DYNAMIC_XML}"
fi

# ---------------------------------------------------------------------------
# 3. Restart controller and wait for dynamicRouting-1.0 to load
# ---------------------------------------------------------------------------
echo "[3/5] Restarting controller to activate dynamicRouting-1.0..."

> "${MESSAGES_LOG}" 2>/dev/null || true
"${WLP_BIN}" stop controller 2>/dev/null || true
sleep 3
"${WLP_BIN}" start controller

echo "  Waiting for server ready (CWWKF0011I) — up to 90 s..."
WAITED=0
while [[ ${WAITED} -lt 90 ]]; do
    grep -q "CWWKF0011I" "${MESSAGES_LOG}" 2>/dev/null && break
    sleep 2; (( WAITED += 2 ))
done
[[ ${WAITED} -ge 90 ]] && echo "  WARNING: Timeout — check ${MESSAGES_LOG}"

if grep -q "dynamicRouting-1.0" "${MESSAGES_LOG}" 2>/dev/null; then
    echo "  dynamicRouting-1.0 : active ✓"
else
    echo "  WARNING: dynamicRouting-1.0 not confirmed in messages.log — continuing."
fi
echo ""

# ---------------------------------------------------------------------------
# 4. Run  dynamicRouting setup
#
#   Connects to the controller HTTP port and generates:
#     plugin-cfg.xml  — points at controller:9080/wr (NOT individual members)
#
#   After this, the plugin reads /wr on every RefreshInterval and gets the
#   live member list from the collective. No static member entries needed.
# ---------------------------------------------------------------------------
echo "[4/5] Running dynamicRouting setup..."

rm -rf "${SETUP_OUTPUT_DIR}"
mkdir -p "${SETUP_OUTPUT_DIR}"

"${DYNAMIC_ROUTING_BIN}" setup \
    --host="${CONTROLLER_HOST}" \
    --port="${CONTROLLER_HTTP}" \
    --user="${ADMIN_USER}" \
    --password="${ADMIN_PASS}" \
    --keystorePassword="${KEYSTORE_PASS}" \
    --webServerNames="${WEB_SERVER_NAME}" \
    --pluginInstallRoot="${SETUP_OUTPUT_DIR}" \
    --autoAcceptCertificates

SETUP_RC=$?
if [[ ${SETUP_RC} -ne 0 ]]; then
    echo "  ERROR: dynamicRouting setup failed (exit ${SETUP_RC})"
    echo "         Check: ${MESSAGES_LOG}"
    exit 1
fi

# Locate the generated plugin-cfg.xml
# dynamicRouting setup writes it to: <pluginInstallRoot>/config/webserver1/plugin-cfg.xml
GENERATED_CFG="${SETUP_OUTPUT_DIR}/config/webserver1/plugin-cfg.xml"
if [[ ! -f "${GENERATED_CFG}" ]]; then
    GENERATED_CFG=$(find "${SETUP_OUTPUT_DIR}" -name "plugin-cfg.xml" 2>/dev/null | head -1)
fi
if [[ -z "${GENERATED_CFG}" || ! -f "${GENERATED_CFG}" ]]; then
    echo "  ERROR: plugin-cfg.xml not found after dynamicRouting setup."
    echo "         Searched under: ${SETUP_OUTPUT_DIR}"
    exit 1
fi
echo "  Generated: ${GENERATED_CFG}"
echo ""

# ---------------------------------------------------------------------------
# 5. Install plugin-cfg.xml into IHS, set WebSpherePluginConfig, restart IHS
# ---------------------------------------------------------------------------
echo "[5/5] Installing plugin-cfg.xml and restarting IHS..."

# Install — always overwrite so any static config from step1 is replaced
cp "${GENERATED_CFG}" "${PLUGIN_CFG}"
echo "  Installed: ${PLUGIN_CFG}"

# Ensure WebSpherePluginConfig directive is in httpd.conf (idempotent)
if grep -q "^WebSpherePluginConfig" "${HTTPD_CONF}"; then
    sed -i "s|^WebSpherePluginConfig .*|WebSpherePluginConfig ${PLUGIN_CFG}|" "${HTTPD_CONF}"
    echo "  WebSpherePluginConfig: updated"
else
    printf '\n# WAS plugin — dynamic routing via Liberty controller /wr\nWebSpherePluginConfig %s\n' \
        "${PLUGIN_CFG}" >> "${HTTPD_CONF}"
    echo "  WebSpherePluginConfig: added"
fi

# Config test
RESULT=$("${APACHECTL}" configtest 2>&1)
if ! echo "${RESULT}" | grep -q "Syntax OK"; then
    echo "  ERROR: httpd.conf syntax check failed:"
    echo "${RESULT}"
    exit 1
fi
echo "  httpd.conf syntax: OK"

# (Re)start IHS
if ss -tlnp 2>/dev/null | grep -q ":8080 "; then
    "${APACHECTL}" stop && sleep 2
fi
"${APACHECTL}" start
sleep 2

if ! ss -tlnp 2>/dev/null | grep -q ":8080 "; then
    echo "  ERROR: IHS failed to start."
    echo "         tail -30 ${IHS_ROOT}/logs/error_log"
    tail -20 "${IHS_ROOT}/logs/error_log"
    exit 1
fi
echo "  IHS: running on port 8080"

# Wait for the plugin to fetch the first routing table from /wr
sleep 3

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/server-info/ 2>/dev/null)
echo "  GET /server-info/ via IHS → HTTP ${HTTP_CODE}"
echo ""

if [[ "${HTTP_CODE}" == "200" ]]; then
    echo "=== Dynamic routing is active ==="
    echo ""
    echo "  IHS:8080 → controller:${CONTROLLER_HTTP}/wr → all collective members"
    echo ""
    echo "  Members are routed dynamically — no script re-run needed when"
    echo "  members are added, removed, started, or stopped."
    echo ""
    echo "  Verify all members are being used (run several times):"
    echo "    curl http://localhost:8080/server-info/"
    echo ""
    echo "  Plugin log  : tail -f ${IHS_ROOT}/logs/plugin.log"
    echo "  Plugin config: ${PLUGIN_CFG}"
    echo "  Admin Center : https://localhost:${CONTROLLER_HTTPS}/adminCenter"
else
    echo "=== Setup complete but routing returned HTTP ${HTTP_CODE} ==="
    echo ""
    echo "  The plugin may still be fetching the first routing table from /wr."
    echo "  Wait 10–15 seconds and retry:"
    echo "    curl http://localhost:8080/server-info/"
    echo ""
    echo "  Diagnose:"
    echo "    tail -50 ${IHS_ROOT}/logs/plugin.log"
    echo "    tail -50 ${IHS_ROOT}/logs/error_log"
    echo "    tail -50 ${MESSAGES_LOG}"
fi
echo ""
