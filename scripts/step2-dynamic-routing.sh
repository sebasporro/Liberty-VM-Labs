#!/bin/bash
# step2-dynamic-routing.sh — Enable Liberty Intelligent Management dynamic routing.
# Prerequisites: install-controller.sh, add-member-26.sh, step1-was-plugin.sh
#
# What this script does:
#   1. Verifies the controller has dynamicRouting-1.0 active (auto-copies override if not)
#   2. Stops IHS and cleans stale plugin keystore files
#   3. Runs `dynamicRouting setup` (Liberty CLI) → generates plugin-cfg.xml + plugin-key.p12
#   4. Converts plugin-key.p12 (PKCS12) → plugin-key.kdb (CMS) via gskcapicmd
#   5. Injects required routing stanzas (ServerCluster/VirtualHostGroup/UriGroup/Route)
#      that dynamicRouting setup strips from the file
#   6. Installs files to IHS config/webserver1/, restarts IHS
#   7. Waits up to 90s for the plugin to connect to /ibm/api/dynamicRouting

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/IBM/HTTPServer}"
CONTROLLER_DIR="${WORKSPACE_ROOT}/installs/controller"
WLP_BIN="${CONTROLLER_DIR}/wlp/bin"
CTRL_OVERRIDES="${WORKSPACE_ROOT}/installs/controller/wlp/usr/servers/controller/configDropins/overrides"
PLUGIN_DIR="${IHS_ROOT}/config/webserver1"
HTTPD_CONF="${IHS_ROOT}/conf/httpd.conf"
APACHECTL="${IHS_ROOT}/bin/apachectl"
GSKCAPICMD="${IHS_ROOT}/bin/gskcapicmd"
KEYSTORE_PASS="Liberty26ctrl!"
WORK_DIR="/tmp/liberty-dr-$$"

echo ""
echo "=== Step 2: Enable Dynamic Routing ==="
echo ""

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
[[ ! -x "${WLP_BIN}/dynamicRouting" ]] && {
    echo "ERROR: dynamicRouting binary not found at ${WLP_BIN}/dynamicRouting"
    echo "       Run install-controller.sh first."
    exit 1
}
[[ ! -x "${GSKCAPICMD}" ]] && {
    echo "ERROR: gskcapicmd not found at ${GSKCAPICMD}"
    echo "       Run install-ihs.sh first."
    exit 1
}
[[ ! -f "${IHS_ROOT}/conf/plugin-cfg.xml" ]] && {
    echo "ERROR: ${IHS_ROOT}/conf/plugin-cfg.xml missing."
    echo "       Run step1-was-plugin.sh first."
    exit 1
}

CTRL_HTTP=$(curl -k -s -o /dev/null -w "%{http_code}" https://localhost:9443/adminCenter 2>/dev/null)
[[ "${CTRL_HTTP}" != "200" && "${CTRL_HTTP}" != "302" ]] && {
    echo "ERROR: Controller not responding on https://localhost:9443 (HTTP ${CTRL_HTTP})"
    echo "       Run install-controller.sh first."
    exit 1
}

# ---------------------------------------------------------------------------
# Fix controller config dropins:
#
# 1. role-override.xml — ensure dynamicRouting-1.0 is declared and
#    clientAuthentication="false" is set (not clientAuthenticationSupported="true").
#
# 2. collective-create.xml — Liberty's 'collective create' writes an
#    <ssl id="defaultSSLConfig" clientAuthenticationSupported="true"/> element.
#    Liberty MERGES same-id elements across dropins, so this attribute survives
#    even when role-override.xml sets clientAuthentication="false", causing
#    SSLHandshakeException: unknown_ca on every WAS plugin connection.
#    Strip the ssl element from collective-create.xml so role-override.xml owns it.
# ---------------------------------------------------------------------------
NEED_SLEEP=false

# Always update role-override.xml
if ! grep -q "dynamicRouting-1.0" "${CTRL_OVERRIDES}/role-override.xml" 2>/dev/null || \
   grep -q 'clientAuthenticationSupported="true"' "${CTRL_OVERRIDES}/role-override.xml" 2>/dev/null; then
    NEED_SLEEP=true
fi
cp "${WORKSPACE_ROOT}/config/controller/role-override.xml" \
   "${CTRL_OVERRIDES}/role-override.xml"
cp "${WORKSPACE_ROOT}/config/controller/ports-override.xml" \
   "${CTRL_OVERRIDES}/ports-override.xml"

# Strip clientAuthenticationSupported ssl element from collective-create.xml
if grep -q 'clientAuthenticationSupported' "${CTRL_OVERRIDES}/collective-create.xml" 2>/dev/null; then
    echo "  Patching collective-create.xml: removing clientAuthenticationSupported ssl element..."
    python3 - "${CTRL_OVERRIDES}/collective-create.xml" <<'PYEOF'
import re, sys
content = open(sys.argv[1]).read()
content = re.sub(r'\n?\s*<!--\s*clientAuthenticationSupported[^>]*-->\s*\n?', '\n', content)
content = re.sub(r'\n?\s*<ssl\s[^/]*/>', '', content)
open(sys.argv[1], 'w').write(content)
PYEOF
    NEED_SLEEP=true
fi

if [[ "${NEED_SLEEP}" == "true" ]]; then
    echo "  Controller config updated — waiting 15s for Liberty to reload..."
    sleep 15
fi

mkdir -p "${PLUGIN_DIR}" "${WORK_DIR}"

# ---------------------------------------------------------------------------
# [1/4] Stop IHS and remove stale keystore files
# ---------------------------------------------------------------------------
echo "[1/4] Stopping IHS and cleaning stale plugin files..."
"${APACHECTL}" stop 2>/dev/null
sleep 2
pkill -9 -f "${IHS_ROOT}/bin/httpd" 2>/dev/null
sleep 1
for ext in kdb rdb sth crl p12; do rm -f "${PLUGIN_DIR}/plugin-key.${ext}" 2>/dev/null; done
echo "      Done"
echo ""

# ---------------------------------------------------------------------------
# [2/4] Run dynamicRouting setup
# Seed config/webserver1/plugin-cfg.xml from the step1 static file so the
# CLI has a valid merge base to read from.
# Files land in WORK_DIR (cd before running — same pattern as reference lab).
# ---------------------------------------------------------------------------
echo "[2/4] Running dynamicRouting setup..."
cp "${IHS_ROOT}/conf/plugin-cfg.xml" "${PLUGIN_DIR}/plugin-cfg.xml"

cd "${WORK_DIR}"
"${WLP_BIN}/dynamicRouting" setup \
    --host=localhost --port=9443 \
    --user=admin --password=admin \
    --keystorePassword="${KEYSTORE_PASS}" \
    --pluginInstallRoot="${IHS_ROOT}" \
    --webServerNames=webserver1 \
    --autoAcceptCertificates || { echo "ERROR: dynamicRouting setup failed"; rm -rf "${WORK_DIR}"; exit 1; }
cd - > /dev/null

[[ ! -f "${WORK_DIR}/plugin-cfg.xml" ]] && { echo "ERROR: plugin-cfg.xml not produced by setup"; rm -rf "${WORK_DIR}"; exit 1; }
[[ ! -f "${WORK_DIR}/plugin-key.p12" ]] && { echo "ERROR: plugin-key.p12 not produced by setup"; rm -rf "${WORK_DIR}"; exit 1; }
echo "      Done"
echo ""

# ---------------------------------------------------------------------------
# [3/4] Convert keystore PKCS12 → CMS (required format for the WAS plugin)
# ---------------------------------------------------------------------------
echo "[3/4] Converting keystore (PKCS12 → CMS)..."
"${GSKCAPICMD}" -keydb -convert \
    -pw "${KEYSTORE_PASS}" \
    -db "${WORK_DIR}/plugin-key.p12" \
    -old_format pkcs12 \
    -target "${WORK_DIR}/plugin-key.kdb" \
    -new_format cms -stash || { echo "ERROR: gskcapicmd conversion failed"; rm -rf "${WORK_DIR}"; exit 1; }

# Set the default certificate — probe actual label; fall back to "default"
LABEL=$("${GSKCAPICMD}" -cert -list -pw "${KEYSTORE_PASS}" \
    -db "${WORK_DIR}/plugin-key.kdb" 2>/dev/null \
    | grep "^-[[:space:]]" | head -1 | sed 's/^-[[:space:]]*//')
LABEL="${LABEL:-default}"
"${GSKCAPICMD}" -cert -setdefault \
    -pw "${KEYSTORE_PASS}" -db "${WORK_DIR}/plugin-key.kdb" -label "${LABEL}"
echo "      Done (label: ${LABEL})"
echo ""

# ---------------------------------------------------------------------------
# [4/4] Install files and start IHS
# dynamicRouting setup strips ServerCluster/VirtualHostGroup/UriGroup/Route
# from the output plugin-cfg.xml. The WAS plugin parser requires those stanzas
# even in dynamic mode — the plugin replaces the server list at runtime by
# polling /ibm/api/dynamicRouting, but the routing structure must be present.
# ---------------------------------------------------------------------------
echo "[4/4] Installing plugin files and starting IHS..."

if ! grep -q "<ServerCluster" "${WORK_DIR}/plugin-cfg.xml"; then
    python3 - "${WORK_DIR}/plugin-cfg.xml" <<'PYEOF'
import sys
path = sys.argv[1]
content = open(path).read()
stanzas = (
    '<ServerCluster Name="defaultCollective" LoadBalance="Round Robin"\n'
    '    CloneSeparatorChange="false" GetDWLMTable="false"\n'
    '    IgnoreAffinityRequests="true" PostSizeLimit="-1"\n'
    '    RemoveSpecialHeaders="true" RetryInterval="60">\n'
    '  <Server Name="placeholder" CloneID="placeholder" ConnectTimeout="5"\n'
    '      ExtendedHandshake="false" MaxConnections="-1"\n'
    '      ServerIOTimeout="900" WaitForContinue="false">\n'
    '    <Transport Hostname="localhost" Port="9081" Protocol="http"/>\n'
    '  </Server>\n'
    '  <PrimaryServers><Server Name="placeholder"/></PrimaryServers>\n'
    '</ServerCluster>\n'
    '<VirtualHostGroup Name="defaultCollective_Hosts">\n'
    '  <VirtualHost Name="*:8080"/>\n'
    '</VirtualHostGroup>\n'
    '<UriGroup Name="defaultCollective_URIs">\n'
    '  <Uri Name="/*" AffinityCookie="JSESSIONID" AffinityURLIdentifier="jsessionid"/>\n'
    '</UriGroup>\n'
    '<Route ServerCluster="defaultCollective" UriGroup="defaultCollective_URIs"'
    ' VirtualHostGroup="defaultCollective_Hosts"/>\n'
)
open(path, 'w').write(content.replace('</Config>', stanzas + '</Config>'))
PYEOF
fi

cp "${WORK_DIR}/plugin-cfg.xml"  "${PLUGIN_DIR}/plugin-cfg.xml"
cp "${WORK_DIR}/plugin-key.kdb"  "${PLUGIN_DIR}/plugin-key.kdb"
cp "${WORK_DIR}/plugin-key.sth"  "${PLUGIN_DIR}/plugin-key.sth"
[[ -f "${WORK_DIR}/plugin-key.rdb" ]] && cp "${WORK_DIR}/plugin-key.rdb" "${PLUGIN_DIR}/plugin-key.rdb"
rm -rf "${WORK_DIR}"

# Update WebSpherePluginConfig in httpd.conf — replace all existing lines,
# keeping only one. The append fallback only runs if no line exists yet.
python3 - "${HTTPD_CONF}" "WebSpherePluginConfig ${PLUGIN_DIR}/plugin-cfg.xml" <<'PYEOF'
import sys
path, directive = sys.argv[1], sys.argv[2]
lines = open(path).readlines()
found = False
out = []
for l in lines:
    if l.strip().lower().startswith('webspherepluginconfig'):
        if not found:
            out.append(directive + '\n')
            found = True
        # skip duplicates
    else:
        out.append(l)
if not found:
    out.append('\n' + directive + '\n')
open(path, 'w').writelines(out)
print('      httpd.conf -> ' + directive)
PYEOF

"${APACHECTL}" configtest || { echo "ERROR: httpd.conf syntax check failed"; exit 1; }
"${APACHECTL}" start
sleep 3
ss -tlnp 2>/dev/null | grep -q ":8080 " || { echo "ERROR: IHS failed to start on port 8080"; exit 1; }
echo "      IHS running on port 8080"
echo ""

# ---------------------------------------------------------------------------
# [5/5] Inline diagnostics + wait for traffic
# ---------------------------------------------------------------------------
CTRL_LOG="${WORKSPACE_ROOT}/installs/controller/wlp/usr/servers/controller/logs/messages.log"

echo "[5/5] Inline diagnostics..."
echo ""

# Controller endpoint — actual status both with and without Accept header
DR_NONE=$(curl -k -u admin:admin -s -o /dev/null -w "%{http_code}" \
    https://localhost:9443/ibm/api/dynamicRouting 2>/dev/null)
DR_JSON=$(curl -k -u admin:admin -H "Accept: application/json" \
    -s -o /dev/null -w "%{http_code}" \
    https://localhost:9443/ibm/api/dynamicRouting 2>/dev/null)
DR_HDRS=$(curl -k -u admin:admin -H "Accept: application/json" \
    -s -D - -o /dev/null \
    https://localhost:9443/ibm/api/dynamicRouting 2>/dev/null | grep -E "^HTTP|^reason|^location" | head -3)
echo "  Controller /ibm/api/dynamicRouting:"
echo "    no Accept header : HTTP ${DR_NONE}"
echo "    Accept: app/json : HTTP ${DR_JSON}"
echo "    headers          : ${DR_HDRS}"
echo ""

# Plugin log — last odr/connect lines
echo "  Plugin log (last relevant):"
grep -i "odrInit\|odrChild\|ODR enabled\|Intelligent\|9443\|abort\|NULL\|state change" \
    "${IHS_ROOT}/logs/webserver1/http_plugin.log" 2>/dev/null | tail -8 | sed 's/^/    /'
echo ""

# Controller errors since last start
LAST_LINE=$(grep -n "CWWKF0011I" "${CTRL_LOG}" 2>/dev/null | tail -1 | cut -d: -f1)
echo "  Controller errors since last start:"
[[ -n "${LAST_LINE}" ]] && tail -n +"${LAST_LINE}" "${CTRL_LOG}" \
    | grep -E "CWWK[A-Z][0-9]+[EW]|Exception|FFDC" | tail -8 | sed 's/^/    /'
echo ""

# Wait for traffic — show both statuses on each tick
echo "  Waiting for traffic through IHS (up to 120s)..."
CODE="000"
for t in $(seq 0 5 120); do
    [[ $t -gt 0 ]] && {
        sleep 5
        CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/server-info/ 2>/dev/null)
        DR_NOW=$(curl -k -u admin:admin -s -o /dev/null -w "%{http_code}" \
            https://localhost:9443/ibm/api/dynamicRouting 2>/dev/null)
        printf "    %3ds  IHS:%s  controller:%s\n" "${t}" "${CODE}" "${DR_NOW}"
        [[ "${CODE}" == "200" ]] && break
    }
done
CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/server-info/ 2>/dev/null)

if [[ "${CODE}" == "200" ]]; then
    echo ""
    echo "=== Dynamic Routing enabled ==="
    echo ""
    echo "  Verify round-robin across all members:"
    echo "    for i in \$(seq 6); do curl -s http://localhost:8080/server-info/ | grep -o 'member[0-9]*'; done"
    echo ""
else
    echo ""
    echo "  FAILED — run full diagnostics:"
    echo "    bash ${SCRIPT_DIR}/collect-debug.sh && cat /tmp/liberty-debug-*.txt"
    exit 1
fi
