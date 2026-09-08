#!/bin/bash
# step2-dynamic-routing.sh — Enable Liberty Intelligent Management dynamic routing.
# Prerequisites: install-controller.sh, add-member-26.sh, step1-was-plugin.sh
#
# What this script does:
#   1. Ensures the controller is running HTTP/1.1 (restarts if still on HTTP/2)
#   2. Neutralises any conflicting dynamic-routing.xml dropin on the controller
#   3. Stops IHS; cleans stale plugin keystore files
#   4. Runs `dynamicRouting setup` to generate plugin-key.p12 and register
#      the webserver with the collective
#   5. Retrieves the authoritative plugin-cfg.xml from the controller's own
#      generated copy (not from the WORK_DIR — that file lacks the AcceptType
#      property and often has stanzas stripped by setup)
#   6. Injects <Property name="AcceptType" value="application/json"/> so that
#      libodr.so sends the Accept header Liberty 26 requires
#   7. Converts plugin-key.p12 → plugin-key.kdb (CMS) via gskcapicmd
#   8. Installs files to IHS config/webserver1/, updates httpd.conf, restarts IHS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/IBM/HTTPServer}"
CONTROLLER_DIR="${WORKSPACE_ROOT}/installs/controller"
WLP_BIN="${CONTROLLER_DIR}/wlp/bin"
CTRL_SERVER_DIR="${WORKSPACE_ROOT}/installs/controller/wlp/usr/servers/controller"
CTRL_OVERRIDES="${CTRL_SERVER_DIR}/configDropins/overrides"
# The controller writes its authoritative plugin-cfg.xml here on every start/setup:
CTRL_PLUGIN_CFG="${CTRL_SERVER_DIR}/plugin-cfg.xml"
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

CTRL_HTTP=$(curl -k -s -o /dev/null -w "%{http_code}" https://localhost:9443/adminCenter 2>/dev/null)
[[ "${CTRL_HTTP}" != "200" && "${CTRL_HTTP}" != "302" ]] && {
    echo "ERROR: Controller not responding on https://localhost:9443 (HTTP ${CTRL_HTTP})"
    echo "       Run install-controller.sh first."
    exit 1
}

# ---------------------------------------------------------------------------
# [0/4] Ensure controller config dropins are correct before setup runs.
#
# collective-create.xml: strip clientAuthenticationSupported ssl element so
#   role-override.xml exclusively owns the SSL config.  Liberty merges same-id
#   elements across all dropins — even one dropin with clientAuthenticationSupported
#   causes unknown_ca for the WAS plugin (which never presents a client cert).
#
# dynamic-routing.xml: an unmanaged dropin may exist from a prior manual run.
#   If it contains <ssl> or <httpEndpoint> it conflicts with our overrides.
#
# ports-override.xml / role-override.xml: always sync from repo.
# Neither file changes ports, keystores, or collective PKI — collective and
# static routing are unaffected.
# ---------------------------------------------------------------------------
echo "[0/4] Verifying controller config..."

NEED_RESTART=false

# Sync role-override.xml
cp "${WORKSPACE_ROOT}/config/controller/role-override.xml" \
   "${CTRL_OVERRIDES}/role-override.xml"

# Sync ports-override.xml
cp "${WORKSPACE_ROOT}/config/controller/ports-override.xml" \
   "${CTRL_OVERRIDES}/ports-override.xml"

# Strip clientAuthenticationSupported from collective-create.xml if present
if grep -q 'clientAuthenticationSupported' "${CTRL_OVERRIDES}/collective-create.xml" 2>/dev/null; then
    echo "  Patching collective-create.xml: removing clientAuthenticationSupported..."
    python3 - "${CTRL_OVERRIDES}/collective-create.xml" <<'PYEOF'
import re, sys
content = open(sys.argv[1]).read()
content = re.sub(r'\n?\s*<!--\s*clientAuthenticationSupported[^>]*-->\s*\n?', '\n', content)
content = re.sub(r'\n?\s*<ssl\s[^/]*/>', '', content)
open(sys.argv[1], 'w').write(content)
PYEOF
    NEED_RESTART=true
fi

# Neutralise conflicting dynamic-routing.xml dropin if present
if [[ -f "${CTRL_OVERRIDES}/dynamic-routing.xml" ]]; then
    if grep -qE '<ssl\b|<httpEndpoint\b' "${CTRL_OVERRIDES}/dynamic-routing.xml" 2>/dev/null; then
        echo "  WARNING: dynamic-routing.xml contains conflicting <ssl>/<httpEndpoint> — replacing with stub."
        cp "${CTRL_OVERRIDES}/dynamic-routing.xml" \
           "${CTRL_OVERRIDES}/dynamic-routing.xml.bak"
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<server description="dynamic-routing placeholder — managed by step2"/>\n' \
            > "${CTRL_OVERRIDES}/dynamic-routing.xml"
        NEED_RESTART=true
    fi
fi

if [[ "${NEED_RESTART}" == "true" ]]; then
    echo "  Restarting controller..."
    "${WLP_BIN}/server" stop controller 2>/dev/null || true
    sleep 3
    "${WLP_BIN}/server" start controller
    printf "  Waiting for controller"
    for i in $(seq 1 30); do
        HC=$(curl -k -s -o /dev/null -w "%{http_code}" https://localhost:9443/adminCenter 2>/dev/null)
        [[ "${HC}" == "200" || "${HC}" == "302" ]] && break
        sleep 2; printf "."
    done; echo ""
    echo "  Controller ready."
else
    echo "  Controller OK."
fi
echo ""

mkdir -p "${PLUGIN_DIR}" "${WORK_DIR}"

# ---------------------------------------------------------------------------
# [1/4] Stop IHS and clean stale keystore files
# ---------------------------------------------------------------------------
echo "[1/4] Stopping IHS and cleaning stale plugin files..."
"${APACHECTL}" stop 2>/dev/null; sleep 2
pkill -9 -f "${IHS_ROOT}/bin/httpd" 2>/dev/null; sleep 1
for ext in kdb rdb sth crl p12; do rm -f "${PLUGIN_DIR}/plugin-key.${ext}" 2>/dev/null; done
echo "      Done"; echo ""

# ---------------------------------------------------------------------------
# [2/4] Run dynamicRouting setup
#
# Purpose: generate plugin-key.p12 and register webserver1 with the collective.
#
# --pluginInstallRoot is the IHS root.  The CLI looks for an existing
# config/webserver1/plugin-cfg.xml under that root as the merge base.
# Pre-seed it from the step1 static file so the CLI has valid XML to read.
#
# We do NOT use the plugin-cfg.xml that setup writes to WORK_DIR.
# Instead we use the authoritative copy the controller itself generates at
# CTRL_SERVER_DIR/plugin-cfg.xml — that file is current, has the correct
# member list, and has not been stripped of its routing stanzas.
# ---------------------------------------------------------------------------
echo "[2/4] Running dynamicRouting setup..."

# Pre-seed the merge base the CLI expects under pluginInstallRoot
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

[[ ! -f "${WORK_DIR}/plugin-key.p12" ]] && {
    echo "ERROR: plugin-key.p12 not produced by dynamicRouting setup"
    rm -rf "${WORK_DIR}"; exit 1
}
echo "      Done"; echo ""

# ---------------------------------------------------------------------------
# [3/4] Build the plugin-cfg.xml from the controller's authoritative copy
#
# The controller writes an up-to-date plugin-cfg.xml to its own server dir.
# This file already has:
#   - IntelligentManagement stanza with ConnectorCluster → localhost:9443
#   - ServerCluster, VirtualHostGroup, UriGroup, Route stanzas intact
#   - Correct Keyfile/Stashfile paths (we patch these below)
#
# The only thing it is missing is the AcceptType property inside
# ConnectorCluster — Liberty 26's DynamicRoutingRestService throws
# UnsupportedOperationException (HTTP 500) for any request without
# Accept: application/json.  The AcceptType property instructs libodr.so
# to send that header.
# ---------------------------------------------------------------------------
echo "[3/4] Building plugin-cfg.xml from controller's authoritative copy..."

# Wait up to 10s for the controller to (re)generate its plugin-cfg.xml
for i in $(seq 1 10); do
    [[ -f "${CTRL_PLUGIN_CFG}" ]] && break
    sleep 1
done
[[ ! -f "${CTRL_PLUGIN_CFG}" ]] && {
    echo "ERROR: Controller plugin-cfg.xml not found at ${CTRL_PLUGIN_CFG}"
    echo "       Trigger regeneration: restart controller or call dynamicRouting setup"
    rm -rf "${WORK_DIR}"; exit 1
}

cp "${CTRL_PLUGIN_CFG}" "${WORK_DIR}/plugin-cfg.xml"

python3 - "${WORK_DIR}/plugin-cfg.xml" "${PLUGIN_DIR}" <<'PYEOF'
import re, sys
path, plugin_dir = sys.argv[1], sys.argv[2]
content = open(path).read()

# 1. Fix Keyfile/Stashfile paths to point to the IHS plugin dir
content = re.sub(
    r'(<Property\s+Name="Keyfile"\s+Value=")[^"]*(")',
    r'\g<1>' + plugin_dir + '/plugin-key.kdb\g<2>',
    content
)
content = re.sub(
    r'(<Property\s+Name="Stashfile"\s+Value=")[^"]*(")',
    r'\g<1>' + plugin_dir + '/plugin-key.sth\g<2>',
    content
)

# 2. Fix keyring path inside Connector element
content = re.sub(
    r'(<Property\s+name="keyring"\s+value=")[^"]*(")',
    r'\g<1>' + plugin_dir + '/plugin-key.kdb\g<2>',
    content
)

# 3. Inject AcceptType into ConnectorCluster so libodr.so sends
#    Accept: application/json.  Liberty 26 rejects requests without it
#    with UnsupportedOperationException / HTTP 500.
#    Guard against double-injection on reruns.
if 'AcceptType' not in content:
    content = re.sub(
        r'(<ConnectorCluster\b[^>]*>)',
        r'\1\n    <Property name="AcceptType" value="application/json"/>',
        content,
        flags=re.DOTALL
    )

# 4. Ensure ServerCluster/VirtualHostGroup/UriGroup/Route stanzas are present.
#    The controller-generated file normally includes them, but guard anyway.
if '<ServerCluster' not in content:
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
    content = content.replace('</Config>', stanzas + '</Config>')

open(path, 'w').write(content)
PYEOF

grep -q 'AcceptType' "${WORK_DIR}/plugin-cfg.xml" || {
    echo "ERROR: AcceptType injection failed. ConnectorCluster tag in controller's plugin-cfg.xml:"
    grep -A3 'ConnectorCluster' "${WORK_DIR}/plugin-cfg.xml" || true
    cat "${WORK_DIR}/plugin-cfg.xml"
    rm -rf "${WORK_DIR}"; exit 1
}
echo "      AcceptType injected OK"; echo ""

# ---------------------------------------------------------------------------
# Convert keystore PKCS12 → CMS (required format for the WAS plugin)
# ---------------------------------------------------------------------------
echo "      Converting keystore (PKCS12 → CMS)..."
"${GSKCAPICMD}" -keydb -convert \
    -pw "${KEYSTORE_PASS}" \
    -db "${WORK_DIR}/plugin-key.p12" \
    -old_format pkcs12 \
    -target "${WORK_DIR}/plugin-key.kdb" \
    -new_format cms -stash || { echo "ERROR: gskcapicmd conversion failed"; rm -rf "${WORK_DIR}"; exit 1; }

LABEL=$("${GSKCAPICMD}" -cert -list -pw "${KEYSTORE_PASS}" \
    -db "${WORK_DIR}/plugin-key.kdb" 2>/dev/null \
    | grep "^-[[:space:]]" | head -1 | sed 's/^-[[:space:]]*//')
LABEL="${LABEL:-default}"
"${GSKCAPICMD}" -cert -setdefault \
    -pw "${KEYSTORE_PASS}" -db "${WORK_DIR}/plugin-key.kdb" -label "${LABEL}"
echo "      Keystore ready (label: ${LABEL})"; echo ""

# ---------------------------------------------------------------------------
# [4/4] Install files and start IHS
# ---------------------------------------------------------------------------
echo "[4/4] Installing plugin files and starting IHS..."

cp "${WORK_DIR}/plugin-cfg.xml"  "${PLUGIN_DIR}/plugin-cfg.xml"
cp "${WORK_DIR}/plugin-key.kdb"  "${PLUGIN_DIR}/plugin-key.kdb"
cp "${WORK_DIR}/plugin-key.sth"  "${PLUGIN_DIR}/plugin-key.sth"
[[ -f "${WORK_DIR}/plugin-key.rdb" ]] && cp "${WORK_DIR}/plugin-key.rdb" "${PLUGIN_DIR}/plugin-key.rdb"
rm -rf "${WORK_DIR}"

# Update WebSpherePluginConfig in httpd.conf (keep only one entry, no duplicates)
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
echo "      IHS running on port 8080"; echo ""

# ---------------------------------------------------------------------------
# [5/5] Inline diagnostics + wait for traffic
# ---------------------------------------------------------------------------
CTRL_LOG="${CTRL_SERVER_DIR}/logs/messages.log"

echo "[5/5] Diagnostics..."
echo ""

DR_NONE=$(curl -k -u admin:admin -s -o /dev/null -w "%{http_code}" \
    https://localhost:9443/ibm/api/dynamicRouting 2>/dev/null)
DR_JSON=$(curl -k -u admin:admin -H "Accept: application/json" \
    -s -w "%{http_code} body: %{size_download} bytes" -o /dev/null \
    https://localhost:9443/ibm/api/dynamicRouting 2>/dev/null)
echo "  Controller /ibm/api/dynamicRouting:"
echo "    no Accept header : HTTP ${DR_NONE}  (500=expected; libodr.so uses AcceptType property)"
echo "    Accept: app/json : HTTP ${DR_JSON}  (200=OK)"
echo ""

echo "  Plugin log (ODR / connect lines):"
grep -i "odrInit\|odrChild\|ODR enabled\|Intelligent\|9443\|abort\|NULL\|state change\|libodr" \
    "${IHS_ROOT}/logs/webserver1/http_plugin.log" 2>/dev/null | tail -8 | sed 's/^/    /'
echo ""

echo "  Controller errors since last start:"
LAST_LINE=$(grep -n "CWWKF0011I" "${CTRL_LOG}" 2>/dev/null | tail -1 | cut -d: -f1)
[[ -n "${LAST_LINE}" ]] && tail -n +"${LAST_LINE}" "${CTRL_LOG}" \
    | grep -E "CWWK[A-Z][0-9]+[EW]|Exception|FFDC" | tail -8 | sed 's/^/    /'
echo ""

echo "  Installed plugin-cfg.xml AcceptType check:"
grep -c 'AcceptType' "${PLUGIN_DIR}/plugin-cfg.xml" | \
    xargs -I{} echo "    {} AcceptType occurrence(s) found"
echo ""

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
    echo "  Verify round-robin across members:"
    echo "    for i in \$(seq 6); do curl -s http://localhost:8080/server-info/ | grep -o 'member[0-9]*'; done"
    echo ""
else
    echo ""
    echo "  FAILED — run full diagnostics:"
    echo "    bash ${SCRIPT_DIR}/collect-debug.sh && cat /tmp/liberty-debug-*.txt"
    exit 1
fi
