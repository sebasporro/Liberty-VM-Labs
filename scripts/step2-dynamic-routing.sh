#!/bin/bash
# =============================================================================
# step2-dynamic-routing.sh
# Enables Liberty Intelligent Management dynamic routing.
#
# Prerequisites (Step 3a must be complete and working):
#   - scripts/install-controller.sh  (controller on HTTPS 9443)
#   - scripts/add-member-26.sh       (at least one member joined)
#   - scripts/step1-was-plugin.sh    (static routing confirmed on port 8080)
#
# What this script does:
#   1. Stops IHS and removes stale plugin keystore files
#   2. Runs dynamicRouting setup — merges <IntelligentManagement> into the
#      existing plugin-cfg.xml and generates plugin-key.p12
#   3. Converts plugin-key.p12 (PKCS12) → plugin-key.kdb (CMS)
#   4. Installs the merged plugin-cfg.xml and keystore, starts IHS
#   5. Verifies ODR routing is active (up to 60s)
#
# dynamicRouting-1.0 and restConnector-2.0 are already declared in
# config/controller/role-override.xml — no controller restart is needed.
# =============================================================================
set -euo pipefail

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

if [[ ! -f "${IHS_ROOT}/conf/plugin-cfg.xml" ]]; then
    echo "ERROR: ${IHS_ROOT}/conf/plugin-cfg.xml not found."
    echo "       Run scripts/step1-was-plugin.sh first."
    exit 1
fi

CTRL_STATUS=$(curl -k -s -o /dev/null -w "%{http_code}" \
    https://localhost:9443/adminCenter 2>/dev/null)
if [[ ! "${CTRL_STATUS}" =~ ^(200|302)$ ]]; then
    echo "ERROR: Controller is not responding on HTTPS 9443 (got HTTP ${CTRL_STATUS})."
    echo "       Run scripts/install-controller.sh first."
    exit 1
fi

mkdir -p "${PLUGIN_DIR}" "${WORK_DIR}"

# ---------------------------------------------------------------------------
# 1. Stop IHS and clean stale keystore files
#    IHS must be stopped before dynamicRouting setup so the plugin does not
#    hold plugin-cfg.xml or plugin-key.kdb open when setup reads/writes them.
#    Stale CMS keystores must be removed — gskcapicmd will not overwrite them.
# ---------------------------------------------------------------------------
echo "[1/4] Stopping IHS and removing stale plugin files..."
"${APACHECTL}" stop 2>/dev/null || true
sleep 2
pkill -9 -f "${IHS_ROOT}/bin/httpd" 2>/dev/null || true
sleep 1
echo "      IHS stopped"

for ext in kdb rdb sth crl p12; do
    f="${PLUGIN_DIR}/plugin-key.${ext}"
    [[ -e "${f}" ]] && rm -f "${f}" && echo "      Removed: ${f}"
done
[[ -e "${PLUGIN_DIR}/plugin-cfg.xml" ]] && rm -f "${PLUGIN_DIR}/plugin-cfg.xml" \
    && echo "      Removed: ${PLUGIN_DIR}/plugin-cfg.xml"

# Seed plugin-cfg.xml from the static config written by step1-was-plugin.sh.
# dynamicRouting setup reads $pluginInstallRoot/config/webserver1/plugin-cfg.xml
# as its merge base — without a complete base file (ServerCluster, UriGroup,
# VirtualHostGroup, Route) the merged output is missing those elements and the
# WAS plugin parser fails on startup.
cp "${IHS_ROOT}/conf/plugin-cfg.xml" "${PLUGIN_DIR}/plugin-cfg.xml"
echo "      Seeded ${PLUGIN_DIR}/plugin-cfg.xml from step1 static config"
echo ""

# ---------------------------------------------------------------------------
# 2. Run dynamicRouting setup
#    Reads $pluginInstallRoot/config/webserver1/plugin-cfg.xml as merge base.
#    Writes merged plugin-cfg.xml and plugin-key.p12 to --targetPath.
# ---------------------------------------------------------------------------
echo "[2/4] Running dynamicRouting setup..."

# Liberty 26+ uses --webServerName (singular); older builds use --webServerNames.
_DR_HELP=$("${WLP_BIN}/dynamicRouting" setup --help 2>&1 || true)
if echo "$_DR_HELP" | grep -q -- "--webServerName[^s]"; then
    WS_FLAG="--webServerName=webserver1"
else
    WS_FLAG="--webServerNames=webserver1"
fi

"${WLP_BIN}/dynamicRouting" setup \
    --host=localhost \
    --port=9443 \
    --user=admin \
    --password=admin \
    --keystorePassword="${KEYSTORE_PASS}" \
    --pluginInstallRoot="${IHS_ROOT}" \
    "${WS_FLAG}" \
    --targetPath="${WORK_DIR}" \
    --autoAcceptCertificates

echo ""
echo "      Files produced by dynamicRouting setup in ${WORK_DIR}:"
ls -la "${WORK_DIR}/" 2>/dev/null | sed 's/^/        /'

if [[ ! -f "${WORK_DIR}/plugin-cfg.xml" || ! -f "${WORK_DIR}/plugin-key.p12" ]]; then
    echo "ERROR: dynamicRouting setup did not produce expected output files in ${WORK_DIR}"
    rm -rf "${WORK_DIR}"
    exit 1
fi
echo "      plugin-cfg.xml and plugin-key.p12 generated"
echo ""

# ---------------------------------------------------------------------------
# 3. Convert plugin-key.p12 (PKCS12) → plugin-key.kdb (CMS)
#    CMS is the only keystore format the WAS plugin accepts.
# ---------------------------------------------------------------------------
echo "[3/4] Converting plugin keystore (PKCS12 → CMS)..."
"${GSKCAPICMD}" -keydb -convert \
    -pw "${KEYSTORE_PASS}" \
    -db "${WORK_DIR}/plugin-key.p12" \
    -old_format pkcs12 \
    -target "${WORK_DIR}/plugin-key.kdb" \
    -new_format cms \
    -stash

# Set the first available personal cert as default (label varies by build).
FIRST_LABEL=$("${GSKCAPICMD}" -cert -list \
    -pw "${KEYSTORE_PASS}" \
    -db "${WORK_DIR}/plugin-key.kdb" 2>/dev/null \
    | grep "^-[[:space:]]" | head -1 | sed 's/^-[[:space:]]*//')
if [[ -n "${FIRST_LABEL}" ]]; then
    "${GSKCAPICMD}" -cert -setdefault \
        -pw "${KEYSTORE_PASS}" \
        -db "${WORK_DIR}/plugin-key.kdb" \
        -label "${FIRST_LABEL}"
fi
echo "      Keystore conversion complete"
echo ""

# ---------------------------------------------------------------------------
# 4. Patch plugin-cfg.xml — inject required static stanzas if missing
#
# dynamicRouting setup outputs ONLY the <IntelligentManagement> stanza plus
# global <Property> elements — it does NOT preserve the <ServerCluster>,
# <UriGroup>, <VirtualHostGroup>, or <Route> from the merge base.
# The WAS plugin parser requires all four to be present in the static XML
# even in ODR (dynamic routing) mode; without them every request returns 404.
# ---------------------------------------------------------------------------
if ! grep -q "<ServerCluster" "${WORK_DIR}/plugin-cfg.xml"; then
    echo "      Injecting required static stanzas into plugin-cfg.xml..."
    python3 - "${WORK_DIR}/plugin-cfg.xml" <<'PYEOF'
import sys, re

path = sys.argv[1]
with open(path) as f:
    content = f.read()

stanzas = """\
<ServerCluster CloneSeparatorChange="false" GetDWLMTable="false"
               IgnoreAffinityRequests="true" LoadBalance="Round Robin"
               Name="defaultCollective" PostSizeLimit="-1"
               RemoveSpecialHeaders="true" RetryInterval="60">
    <Server CloneID="placeholder" ConnectTimeout="5" ExtendedHandshake="false"
            MaxConnections="-1" Name="placeholder" ServerIOTimeout="900"
            WaitForContinue="false">
        <Transport Hostname="localhost" Port="9081" Protocol="http"/>
    </Server>
    <PrimaryServers>
        <Server Name="placeholder"/>
    </PrimaryServers>
</ServerCluster>
<VirtualHostGroup Name="defaultCollective_Hosts">
    <VirtualHost Name="*:8080"/>
</VirtualHostGroup>
<UriGroup Name="defaultCollective_URIs">
    <Uri AffinityCookie="JSESSIONID" AffinityURLIdentifier="jsessionid" Name="/*"/>
</UriGroup>
<Route ServerCluster="defaultCollective"
       UriGroup="defaultCollective_URIs"
       VirtualHostGroup="defaultCollective_Hosts"/>
"""

patched = content.replace('</Config>', stanzas + '</Config>')
with open(path, 'w') as f:
    f.write(patched)
print("      Static stanzas injected (ServerCluster/VirtualHostGroup/UriGroup/Route)")
PYEOF
fi

# ---------------------------------------------------------------------------
# 4. Install plugin files and start IHS
# ---------------------------------------------------------------------------
echo "[4/4] Installing plugin files and starting IHS..."
cp "${WORK_DIR}/plugin-cfg.xml"  "${PLUGIN_DIR}/plugin-cfg.xml"
cp "${WORK_DIR}/plugin-key.kdb"  "${PLUGIN_DIR}/plugin-key.kdb"
cp "${WORK_DIR}/plugin-key.sth"  "${PLUGIN_DIR}/plugin-key.sth"
[[ -f "${WORK_DIR}/plugin-key.rdb" ]] && cp "${WORK_DIR}/plugin-key.rdb" "${PLUGIN_DIR}/plugin-key.rdb"
[[ -f "${WORK_DIR}/odr-trace.xml" ]] && cp "${WORK_DIR}/odr-trace.xml" "${IHS_ROOT}/odr-trace.xml" \
    && echo "      odr-trace.xml → ${IHS_ROOT}/odr-trace.xml"

rm -rf "${WORK_DIR}"

# Update WebSpherePluginConfig to point at the dynamic plugin-cfg.xml.
# Use sed with a case-insensitive, whitespace-tolerant match so it works
# regardless of how step1 wrote the directive. The || true guards against
# set -e killing the script if grep finds no match.
PLUGIN_CFG_LINE="WebSpherePluginConfig ${PLUGIN_DIR}/plugin-cfg.xml"
if grep -qi "WebSpherePluginConfig" "${HTTPD_CONF}" 2>/dev/null; then
    sed -i "s|[Ww]eb[Ss]phere[Pp]lugin[Cc]onfig.*|${PLUGIN_CFG_LINE}|" "${HTTPD_CONF}"
    echo "      WebSpherePluginConfig updated in httpd.conf"
else
    printf '\n# Dynamic routing — added by step2-dynamic-routing.sh\n%s\n' \
        "${PLUGIN_CFG_LINE}" >> "${HTTPD_CONF}"
    echo "      WebSpherePluginConfig added to httpd.conf"
fi

echo ""
echo "  --- Diagnostic: WebSpherePluginConfig in httpd.conf ---"
grep -i "WebSpherePluginConfig" "${HTTPD_CONF}" || echo "  (not found)"
echo ""

echo "  --- Diagnostic: installed plugin-cfg.xml ---"
cat "${PLUGIN_DIR}/plugin-cfg.xml"
echo "  --- End plugin-cfg.xml ---"
echo ""

echo "  --- Diagnostic: members reachable directly ---"
for p in 9081 9082 9083 9084; do
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        "http://localhost:${p}/server-info/" 2>/dev/null)
    [[ "${code}" != "000" ]] && echo "      port ${p}: HTTP ${code}"
done
echo ""

"${APACHECTL}" configtest
"${APACHECTL}" start
sleep 3

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
    echo ""
else
    echo "  --- Diagnostic: plugin log (last 40 lines) ---"
    tail -40 "${IHS_ROOT}/logs/webserver1/http_plugin.log" 2>/dev/null \
        | sed 's/^/  /' \
        || echo "  (plugin log not found)"
    echo ""
    echo "  --- Diagnostic: IHS error log (last 10 lines) ---"
    tail -10 "${IHS_ROOT}/logs/error_log" 2>/dev/null | sed 's/^/  /'
    echo ""
    echo "  ERROR: ODR did not start routing within 60s."
    exit 1
fi
