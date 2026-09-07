#!/bin/bash
# =============================================================================
# step2-dynamic-routing.sh
# Enables Liberty Intelligent Management dynamic routing.
#
# The controller already has dynamicRouting-1.0 + restConnector-2.0 declared
# in config/controller/role-override.xml — no dropin changes are needed.
#
# How dynamicRouting setup works:
#   - Writes plugin-cfg.xml and plugin-key.p12 into the CURRENT DIRECTORY
#   - plugin-cfg.xml must be copied to wherever WebSpherePluginConfig points
#   - plugin-key.p12 must be converted to CMS format via gskcapicmd, then
#     plugin-key.kdb/.sth copied to $IHS_ROOT/config/webserver1/
#
# Usage:  scripts/step2-dynamic-routing.sh
#
# Prerequisites:
#   - scripts/install-controller.sh completed (controller on HTTPS 9443)
#   - scripts/add-member-26.sh member1 completed (at least one member joined)
#   - scripts/install-ihs.sh completed (gskcapicmd functional)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/IBM/HTTPServer}"
CONTROLLER_DIR="${WORKSPACE_ROOT}/installs/controller"
WLP_BIN="${CONTROLLER_DIR}/wlp/bin"
PLUGIN_DIR="${IHS_ROOT}/config/webserver1"
HTTPD_CONF="${IHS_ROOT}/conf/httpd.conf"
APACHECTL="${IHS_ROOT}/bin/apachectl"
GSKCAPICMD="${IHS_ROOT}/bin/gskcapicmd"
KEYSTORE_PASS="Liberty26ctrl!"
WORK_DIR="/tmp/liberty-dr-$$"

echo ""
echo "=== Step 2: Enable Dynamic Routing (Intelligent Management) ==="
echo ""

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [[ ! -x "${WLP_BIN}/dynamicRouting" ]]; then
    echo "ERROR: dynamicRouting binary not found at ${WLP_BIN}/dynamicRouting"
    echo "       Run scripts/install-controller.sh first."
    exit 1
fi

if [[ ! -x "${GSKCAPICMD}" ]]; then
    echo "ERROR: gskcapicmd not found at ${GSKCAPICMD}"
    echo "       Run scripts/install-ihs.sh first."
    exit 1
fi

if ! curl -k -s -o /dev/null -w "%{http_code}" https://localhost:9443/adminCenter 2>/dev/null | grep -qE "^(200|302)$"; then
    echo "ERROR: Controller is not responding on HTTPS 9443."
    echo "       Run scripts/install-controller.sh first."
    exit 1
fi

mkdir -p "${PLUGIN_DIR}" "${WORK_DIR}"

# ---------------------------------------------------------------------------
# 1. Seed config/webserver1/plugin-cfg.xml from the static config written by
#    step1-was-plugin.sh. dynamicRouting setup merges <IntelligentManagement>
#    into whatever is already at $pluginInstallRoot/config/webserver1/plugin-cfg.xml.
#    Without a complete base file (ServerCluster, UriGroup, VirtualHostGroup,
#    Route) the merged output is missing those elements and the plugin parser fails.
# ---------------------------------------------------------------------------
STATIC_CFG="${IHS_ROOT}/conf/plugin-cfg.xml"
if [[ ! -f "${STATIC_CFG}" ]]; then
    echo "ERROR: ${STATIC_CFG} not found."
    echo "       Run scripts/step1-was-plugin.sh before this script."
    exit 1
fi
cp "${STATIC_CFG}" "${PLUGIN_DIR}/plugin-cfg.xml"
echo "      Seeded ${PLUGIN_DIR}/plugin-cfg.xml from step1 static config"

# ---------------------------------------------------------------------------
# 2. Run dynamicRouting setup
#    Reads $pluginInstallRoot/config/webserver1/plugin-cfg.xml as merge base.
#    Writes the merged plugin-cfg.xml and plugin-key.p12 to the current directory.
#    We run from WORK_DIR so the output files land there cleanly.
# ---------------------------------------------------------------------------
echo "[1/4] Running dynamicRouting setup..."
cd "${WORK_DIR}"
"${WLP_BIN}/dynamicRouting" setup \
    --host=localhost \
    --port=9443 \
    --user=admin \
    --password=admin \
    --keystorePassword="${KEYSTORE_PASS}" \
    --pluginInstallRoot="${IHS_ROOT}" \
    --webServerNames=webserver1 \
    --autoAcceptCertificates
DR_RC=$?
cd "${SCRIPT_DIR}"

if [[ ${DR_RC} -ne 0 ]]; then
    echo "ERROR: dynamicRouting setup exited with code ${DR_RC}."
    rm -rf "${WORK_DIR}"
    exit 1
fi
if [[ ! -f "${WORK_DIR}/plugin-cfg.xml" || ! -f "${WORK_DIR}/plugin-key.p12" ]]; then
    echo "ERROR: dynamicRouting setup did not produce expected output files in ${WORK_DIR}"
    ls -la "${WORK_DIR}/" 2>/dev/null
    rm -rf "${WORK_DIR}"
    exit 1
fi
echo "      plugin-cfg.xml and plugin-key.p12 generated in ${WORK_DIR}"
echo ""

# ---------------------------------------------------------------------------
# 2. Convert plugin-key.p12 (PKCS12) → plugin-key.kdb (CMS)
#    CMS is the only keystore format the WAS plugin accepts.
# ---------------------------------------------------------------------------
echo "[2/4] Converting plugin keystore (PKCS12 → CMS)..."
"${GSKCAPICMD}" -keydb -convert \
    -pw "${KEYSTORE_PASS}" \
    -db "${WORK_DIR}/plugin-key.p12" \
    -old_format pkcs12 \
    -target "${WORK_DIR}/plugin-key.kdb" \
    -new_format cms \
    -stash

"${GSKCAPICMD}" -cert -setdefault \
    -pw "${KEYSTORE_PASS}" \
    -db "${WORK_DIR}/plugin-key.kdb" \
    -label default

echo "      Keystore conversion complete"
echo ""

# ---------------------------------------------------------------------------
# 3. Copy plugin files to their destinations
#    plugin-cfg.xml  → wherever WebSpherePluginConfig points in httpd.conf
#    plugin-key.kdb/.sth/.rdb → $IHS_ROOT/config/webserver1/
# ---------------------------------------------------------------------------
echo "[3/4] Installing plugin files..."
cp "${WORK_DIR}/plugin-cfg.xml"  "${PLUGIN_DIR}/plugin-cfg.xml"
cp "${WORK_DIR}/plugin-key.kdb"  "${PLUGIN_DIR}/plugin-key.kdb"
cp "${WORK_DIR}/plugin-key.sth"  "${PLUGIN_DIR}/plugin-key.sth"
[[ -f "${WORK_DIR}/plugin-key.rdb" ]] && cp "${WORK_DIR}/plugin-key.rdb" "${PLUGIN_DIR}/plugin-key.rdb"
rm -rf "${WORK_DIR}"
echo "      plugin-cfg.xml  → ${PLUGIN_DIR}/plugin-cfg.xml"
echo "      plugin-key.kdb  → ${PLUGIN_DIR}/plugin-key.kdb"
echo ""

# ---------------------------------------------------------------------------
# 4. Point WebSpherePluginConfig at the new plugin-cfg.xml and restart IHS
# ---------------------------------------------------------------------------
echo "[4/4] Updating httpd.conf and restarting IHS..."
PLUGIN_CFG_LINE="WebSpherePluginConfig ${PLUGIN_DIR}/plugin-cfg.xml"
if grep -q "^WebSpherePluginConfig" "${HTTPD_CONF}"; then
    sed -i "s|^WebSpherePluginConfig .*|${PLUGIN_CFG_LINE}|" "${HTTPD_CONF}"
    echo "      WebSpherePluginConfig: updated"
else
    printf '\n# Dynamic routing — added by step2-dynamic-routing.sh\n%s\n' \
        "${PLUGIN_CFG_LINE}" >> "${HTTPD_CONF}"
    echo "      WebSpherePluginConfig: added"
fi

"${APACHECTL}" stop 2>/dev/null; sleep 2
pkill -9 -f "${IHS_ROOT}/bin/httpd" 2>/dev/null; sleep 1
"${APACHECTL}" start; sleep 3

if ! ss -tlnp 2>/dev/null | grep -q ":8080 "; then
    echo "ERROR: IHS failed to start. Check: ${IHS_ROOT}/logs/error_log"
    exit 1
fi
echo "      IHS running on port 8080"
echo ""

# ---------------------------------------------------------------------------
# 5. Wait for ODR to connect and verify routing (up to 60s)
# ---------------------------------------------------------------------------
echo "[5/5] Waiting for ODR to connect to controller..."
HTTP_CODE="000"
for t in $(seq 0 5 60); do
    [[ $t -gt 0 ]] && { sleep 5; echo "      ${t}s — HTTP ${HTTP_CODE}..."; }
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        http://localhost:8080/server-info/ 2>/dev/null)
    [[ "${HTTP_CODE}" == "200" ]] && break
done

echo ""
echo "  GET http://localhost:8080/server-info/ → HTTP ${HTTP_CODE}"
echo ""

if [[ "${HTTP_CODE}" == "200" ]]; then
    echo "=== Step 2 complete: Dynamic Routing enabled ==="
    echo ""
    echo "  Verify round-robin across all members:"
    echo "    for i in \$(seq 6); do curl -s http://localhost:8080/server-info/ | grep -o 'member[0-9]*'; done"
    echo ""
    echo "  Next (optional) — pin requests to a specific member:"
    echo "    bash scripts/apply-routing-rules.sh -s member1"
else
    echo "  ERROR: ODR did not start routing within 60s."
    echo "  Plugin log:  tail -30 ${IHS_ROOT}/logs/webserver1/http_plugin.log"
    exit 1
fi
echo ""
