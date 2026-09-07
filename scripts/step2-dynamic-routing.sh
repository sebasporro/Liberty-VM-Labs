#!/bin/bash
# =============================================================================
# step2-dynamic-routing.sh
# Enables Liberty Intelligent Management dynamic routing.
#
# The controller already has dynamicRouting-1.0 + restConnector-2.0 declared
# in config/controller/role-override.xml — no dropin changes are needed.
#
# What this script does:
#   1. Runs 'dynamicRouting setup' against the controller (HTTPS 9443)
#      --autoAcceptCertificates installs the collective CA into plugin-key.p12
#      so the ODR library can authenticate to the controller over HTTPS.
#   2. Converts the generated plugin-key.p12 (PKCS12) → plugin-key.kdb (CMS)
#   3. Installs plugin-cfg.xml + key files into $IHS_ROOT/config/webserver1/
#   4. Wires WebSpherePluginConfig in httpd.conf, restarts IHS
#   5. Waits up to 60s for ODR to connect and verifies HTTP 200
#
# Usage:  scripts/step2-dynamic-routing.sh
#
# Prerequisites:
#   - scripts/install-controller.sh completed (controller on HTTPS 9443)
#   - scripts/add-member-26.sh member1 completed (at least one member joined)
#   - scripts/install-ihs.sh completed (gskcapicmd functional)
#   - scripts/step1-was-plugin.sh completed — REQUIRED: dynamicRouting setup
#     merges the IntelligentManagement stanza into the existing plugin-cfg.xml
#     written by step1. Without it the generated file is missing ServerCluster,
#     UriGroup, VirtualHostGroup, and Route elements and the plugin parser fails.
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

mkdir -p "${PLUGIN_DIR}"

# ---------------------------------------------------------------------------
# 1. Run dynamicRouting setup
#    Must run from $IHS_ROOT — setup reads the existing plugin-cfg.xml from
#    $pluginInstallRoot/config/webserver1/ (written by step1-was-plugin.sh)
#    and merges <IntelligentManagement> into it. It also writes plugin-key.p12
#    into the current directory, so we run from $IHS_ROOT to keep everything
#    under the plugin install root.
#    --autoAcceptCertificates accepts the collective self-signed CA and embeds
#    it in plugin-key.p12 so the ODR library can authenticate over HTTPS.
# ---------------------------------------------------------------------------
echo "[1/4] Running dynamicRouting setup..."

# step1-was-plugin.sh must have run first — its plugin-cfg.xml is the merge base
if [[ ! -f "${IHS_ROOT}/conf/plugin-cfg.xml" ]]; then
    echo "ERROR: ${IHS_ROOT}/conf/plugin-cfg.xml not found."
    echo "       Run scripts/step1-was-plugin.sh before this script."
    exit 1
fi

cd "${IHS_ROOT}"
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
    exit 1
fi
if [[ ! -f "${PLUGIN_DIR}/plugin-cfg.xml" ]]; then
    echo "ERROR: dynamicRouting setup did not produce ${PLUGIN_DIR}/plugin-cfg.xml"
    exit 1
fi
echo "      dynamicRouting setup complete"
echo ""

# ---------------------------------------------------------------------------
# 2. Convert plugin-key.p12 (PKCS12) → plugin-key.kdb (CMS)
#    setup writes plugin-key.p12 into $IHS_ROOT (the cwd during setup).
#    CMS is the only keystore format the WAS plugin accepts.
# ---------------------------------------------------------------------------
echo "[2/4] Converting plugin keystore (PKCS12 → CMS)..."
P12="${IHS_ROOT}/plugin-key.p12"
KDB="${PLUGIN_DIR}/plugin-key.kdb"

if [[ ! -f "${P12}" ]]; then
    echo "ERROR: plugin-key.p12 not found at ${P12}"
    exit 1
fi

"${GSKCAPICMD}" -keydb -convert \
    -pw "${KEYSTORE_PASS}" \
    -db "${P12}" \
    -old_format pkcs12 \
    -target "${KDB}" \
    -new_format cms \
    -stash

"${GSKCAPICMD}" -cert -setdefault \
    -pw "${KEYSTORE_PASS}" \
    -db "${KDB}" \
    -label default

# IBM docs: chown keystore files to IHS User:Group
IHS_USER=$(grep -E "^User "  "${HTTPD_CONF}" | awk '{print $2}')
IHS_GROUP=$(grep -E "^Group " "${HTTPD_CONF}" | awk '{print $2}')
if [[ -n "${IHS_USER}" && -n "${IHS_GROUP}" ]]; then
    chown "${IHS_USER}:${IHS_GROUP}" \
        "${PLUGIN_DIR}/plugin-key.kdb" \
        "${PLUGIN_DIR}/plugin-key.rdb" \
        "${PLUGIN_DIR}/plugin-key.sth" 2>/dev/null || true
fi

rm -f "${P12}"
echo "      Keystore conversion complete"
echo ""

# ---------------------------------------------------------------------------
# 3. plugin-cfg.xml is already in $PLUGIN_DIR — written by dynamicRouting setup
# ---------------------------------------------------------------------------
echo "[3/4] Plugin files in place at ${PLUGIN_DIR}"
echo "      plugin-cfg.xml  — merged static + IntelligentManagement"
echo "      plugin-key.kdb  — collective CA trusted keystore (CMS)"
echo ""

# ---------------------------------------------------------------------------
# 4. Wire WebSpherePluginConfig in httpd.conf and restart IHS
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
# 5. Wait for ODR to connect and verify routing
#    The ODR library connects to the controller HTTPS endpoint, retrieves
#    the live member table, and begins routing. Allow up to 60s.
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
    echo ""
    echo "  Diagnostics:"
    echo "    Plugin log:      tail -30 ${IHS_ROOT}/logs/webserver1/http_plugin.log"
    echo "    Controller log:  tail -30 ${WORKSPACE_ROOT}/installs/controller/wlp/usr/servers/controller/logs/messages.log"
    echo "    plugin-cfg.xml:  cat ${PLUGIN_DIR}/plugin-cfg.xml"
    exit 1
fi
echo ""
