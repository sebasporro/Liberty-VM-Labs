#!/bin/bash
# =============================================================================
# setup-dynamic-routing.sh
# Minimal, robust script to enable Liberty Dynamic Routing (Intelligent Management).
#
# Prerequisites:
#   - Controller running on HTTPS 9443 with dynamicRouting-1.0 feature
#   - Collective members running
#   - IHS installed and mod_was_ap24_http.so present
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

# Environment variables & paths
IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/IBM/HTTPServer}"
CONTROLLER_DIR="${WORKSPACE_ROOT}/installs/controller"
WLP_BIN="${CONTROLLER_DIR}/wlp/bin"
GSKCAPICMD="${IHS_ROOT}/bin/gskcapicmd"
APACHECTL="${IHS_ROOT}/bin/apachectl"
HTTPD_CONF="${IHS_ROOT}/conf/httpd.conf"
PLUGIN_TARGET_DIR="${IHS_ROOT}/config/webserver1"

CONTROLLER_HOST="localhost"
CONTROLLER_PORT="9443"
ADMIN_USER="admin"
ADMIN_PASS="admin"
KEYSTORE_PASS="Liberty26ctrl!"
WEBSERVER_NAME="webserver1"

TEMP_DIR="/tmp/dr_setup_$$"

echo ""
echo "=== Enabling Liberty Dynamic Routing ==="
echo ""

# 1. Pre-flight checks
if [[ ! -x "${WLP_BIN}/dynamicRouting" ]]; then
    echo "ERROR: dynamicRouting command not found at ${WLP_BIN}/dynamicRouting"
    exit 1
fi

if [[ ! -x "${GSKCAPICMD}" ]]; then
    echo "ERROR: gskcapicmd not found at ${GSKCAPICMD}"
    exit 1
fi

# 2. Stop IHS and clean up staging / old target files
echo "[1/5] Stopping IHS and preparing workspace..."
"${APACHECTL}" stop 2>/dev/null || true
pkill -9 -f "${IHS_ROOT}/bin/httpd" 2>/dev/null || true
sleep 2

rm -rf "${TEMP_DIR}"
mkdir -p "${TEMP_DIR}" "${PLUGIN_TARGET_DIR}"

# 3. Execute dynamicRouting setup
echo "[2/5] Running dynamicRouting setup against controller (${CONTROLLER_HOST}:${CONTROLLER_PORT})..."
cd "${TEMP_DIR}"

"${WLP_BIN}/dynamicRouting" setup \
    --host="${CONTROLLER_HOST}" \
    --port="${CONTROLLER_PORT}" \
    --user="${ADMIN_USER}" \
    --password="${ADMIN_PASS}" \
    --keystorePassword="${KEYSTORE_PASS}" \
    --pluginInstallRoot="${IHS_ROOT}" \
    --webServerNames="${WEBSERVER_NAME}" \
    --autoAcceptCertificates

if [[ ! -f "plugin-cfg.xml" || ! -f "plugin-key.p12" ]]; then
    echo "ERROR: dynamicRouting setup did not produce plugin-cfg.xml or plugin-key.p12"
    rm -rf "${TEMP_DIR}"
    exit 1
fi

echo "      dynamicRouting setup completed successfully."

# 4. Convert PKCS12 keystore to CMS (KDB/STH) for the WAS plug-in
echo "[3/5] Converting plugin keystore (PKCS12 -> CMS)..."
"${GSKCAPICMD}" -keydb -convert \
    -pw "${KEYSTORE_PASS}" \
    -db "${TEMP_DIR}/plugin-key.p12" \
    -old_format pkcs12 \
    -target "${TEMP_DIR}/plugin-key.kdb" \
    -new_format cms \
    -stash

"${GSKCAPICMD}" -cert -setdefault \
    -pw "${KEYSTORE_PASS}" \
    -db "${TEMP_DIR}/plugin-key.kdb" \
    -label default 2>/dev/null || true

# 5. Deploy plugin configuration and keystore files
echo "[4/5] Deploying plugin files to ${PLUGIN_TARGET_DIR}..."
cp "${TEMP_DIR}/plugin-cfg.xml" "${PLUGIN_TARGET_DIR}/plugin-cfg.xml"
cp "${TEMP_DIR}/plugin-key.kdb" "${PLUGIN_TARGET_DIR}/plugin-key.kdb"
cp "${TEMP_DIR}/plugin-key.sth" "${PLUGIN_TARGET_DIR}/plugin-key.sth"
[[ -f "${TEMP_DIR}/plugin-key.rdb" ]] && cp "${TEMP_DIR}/plugin-key.rdb" "${PLUGIN_TARGET_DIR}/plugin-key.rdb"

# Cleanup temp files
cd - >/dev/null
rm -rf "${TEMP_DIR}"

# Ensure httpd.conf points to webserver1/plugin-cfg.xml
sed -i "s|^WebSpherePluginConfig .*|WebSpherePluginConfig ${PLUGIN_TARGET_DIR}/plugin-cfg.xml|" "${HTTPD_CONF}"
if ! grep -q "WebSpherePluginConfig" "${HTTPD_CONF}"; then
    echo "WebSpherePluginConfig ${PLUGIN_TARGET_DIR}/plugin-cfg.xml" >> "${HTTPD_CONF}"
fi

# 6. Start IHS and test
echo "[5/5] Starting IHS..."
"${APACHECTL}" start
sleep 2

if ! ss -tlnp 2>/dev/null | grep -q ":8080 "; then
    echo "ERROR: IHS failed to start on port 8080. Check ${IHS_ROOT}/logs/error_log"
    exit 1
fi

echo ""
echo "=== Dynamic Routing Setup Complete ==="
echo "  IHS Status: Running on port 8080"
echo "  Plugin Config: ${PLUGIN_TARGET_DIR}/plugin-cfg.xml"
echo ""
echo "  Verify routing across members:"
echo "    for i in \$(seq 6); do curl -s http://localhost:8080/server-info/ | grep -o 'member[0-9]*'; done"
echo ""
