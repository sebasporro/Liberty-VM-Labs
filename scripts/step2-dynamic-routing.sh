#!/bin/bash
# step2-dynamic-routing.sh — Enable Liberty Intelligent Management dynamic routing.
# Prerequisites: install-controller.sh, add-member-26.sh, step1-was-plugin.sh

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
echo "=== Step 2: Enable Dynamic Routing ==="
echo ""

# --- Pre-flight ---
[[ ! -x "${WLP_BIN}/dynamicRouting" ]] && { echo "ERROR: dynamicRouting not found. Run install-controller.sh first."; exit 1; }
[[ ! -x "${GSKCAPICMD}" ]]             && { echo "ERROR: gskcapicmd not found. Run install-ihs.sh first."; exit 1; }
[[ ! -f "${IHS_ROOT}/conf/plugin-cfg.xml" ]] && { echo "ERROR: conf/plugin-cfg.xml missing. Run step1-was-plugin.sh first."; exit 1; }

CTRL=$(curl -k -s -o /dev/null -w "%{http_code}" https://localhost:9443/adminCenter 2>/dev/null)
[[ "${CTRL}" != "200" && "${CTRL}" != "302" ]] && { echo "ERROR: Controller not responding (HTTP ${CTRL}). Run install-controller.sh first."; exit 1; }

mkdir -p "${PLUGIN_DIR}" "${WORK_DIR}"

# --- 1. Stop IHS, clean stale files ---
echo "[1/4] Stopping IHS and cleaning stale plugin files..."
"${APACHECTL}" stop 2>/dev/null; sleep 2
pkill -9 -f "${IHS_ROOT}/bin/httpd" 2>/dev/null; sleep 1

for ext in kdb rdb sth crl p12; do rm -f "${PLUGIN_DIR}/plugin-key.${ext}" 2>/dev/null; done
rm -f "${PLUGIN_DIR}/plugin-cfg.xml" 2>/dev/null

# Seed merge base — dynamicRouting setup reads config/webserver1/plugin-cfg.xml
cp "${IHS_ROOT}/conf/plugin-cfg.xml" "${PLUGIN_DIR}/plugin-cfg.xml"
echo "      Done"
echo ""

# --- 2. Run dynamicRouting setup ---
echo "[2/4] Running dynamicRouting setup..."

_HELP=$("${WLP_BIN}/dynamicRouting" setup --help 2>&1 || true)
if echo "$_HELP" | grep -q -- "--webServerName[^s]"; then
    WS_FLAG="--webServerName=webserver1"
else
    WS_FLAG="--webServerNames=webserver1"
fi

"${WLP_BIN}/dynamicRouting" setup \
    --host=localhost --port=9443 \
    --user=admin --password=admin \
    --keystorePassword="${KEYSTORE_PASS}" \
    --pluginInstallRoot="${IHS_ROOT}" \
    "${WS_FLAG}" \
    --targetPath="${WORK_DIR}" \
    --autoAcceptCertificates || { echo "ERROR: dynamicRouting setup failed"; rm -rf "${WORK_DIR}"; exit 1; }

[[ ! -f "${WORK_DIR}/plugin-cfg.xml" ]] && { echo "ERROR: plugin-cfg.xml not produced"; rm -rf "${WORK_DIR}"; exit 1; }
[[ ! -f "${WORK_DIR}/plugin-key.p12" ]] && { echo "ERROR: plugin-key.p12 not produced"; rm -rf "${WORK_DIR}"; exit 1; }
echo "      Done"
echo ""

# --- 3. Convert keystore PKCS12 → CMS ---
echo "[3/4] Converting keystore..."
"${GSKCAPICMD}" -keydb -convert \
    -pw "${KEYSTORE_PASS}" \
    -db "${WORK_DIR}/plugin-key.p12" \
    -old_format pkcs12 \
    -target "${WORK_DIR}/plugin-key.kdb" \
    -new_format cms -stash || { echo "ERROR: gskcapicmd conversion failed"; rm -rf "${WORK_DIR}"; exit 1; }

LABEL=$("${GSKCAPICMD}" -cert -list -pw "${KEYSTORE_PASS}" \
    -db "${WORK_DIR}/plugin-key.kdb" 2>/dev/null \
    | grep "^-[[:space:]]" | head -1 | sed 's/^-[[:space:]]*//')
[[ -n "${LABEL}" ]] && "${GSKCAPICMD}" -cert -setdefault \
    -pw "${KEYSTORE_PASS}" -db "${WORK_DIR}/plugin-key.kdb" -label "${LABEL}"
echo "      Done"
echo ""

# --- 4. Inject missing static stanzas, install files, update httpd.conf ---
echo "[4/4] Installing plugin files and starting IHS..."

# dynamicRouting setup strips ServerCluster/VirtualHostGroup/UriGroup/Route.
# The WAS plugin parser requires them even in ODR mode.
if ! grep -q "<ServerCluster" "${WORK_DIR}/plugin-cfg.xml"; then
    python3 -c "
import sys
path = sys.argv[1]
content = open(path).read()
stanzas = '''<ServerCluster Name=\"defaultCollective\" LoadBalance=\"Round Robin\"
    CloneSeparatorChange=\"false\" GetDWLMTable=\"false\"
    IgnoreAffinityRequests=\"true\" PostSizeLimit=\"-1\"
    RemoveSpecialHeaders=\"true\" RetryInterval=\"60\">
  <Server Name=\"placeholder\" CloneID=\"placeholder\" ConnectTimeout=\"5\"
      ExtendedHandshake=\"false\" MaxConnections=\"-1\"
      ServerIOTimeout=\"900\" WaitForContinue=\"false\">
    <Transport Hostname=\"localhost\" Port=\"9081\" Protocol=\"http\"/>
  </Server>
  <PrimaryServers><Server Name=\"placeholder\"/></PrimaryServers>
</ServerCluster>
<VirtualHostGroup Name=\"defaultCollective_Hosts\">
  <VirtualHost Name=\"*:8080\"/>
</VirtualHostGroup>
<UriGroup Name=\"defaultCollective_URIs\">
  <Uri Name=\"/*\" AffinityCookie=\"JSESSIONID\" AffinityURLIdentifier=\"jsessionid\"/>
</UriGroup>
<Route ServerCluster=\"defaultCollective\" UriGroup=\"defaultCollective_URIs\" VirtualHostGroup=\"defaultCollective_Hosts\"/>
'''
open(path,'w').write(content.replace('</Config>', stanzas + '</Config>'))
" "${WORK_DIR}/plugin-cfg.xml"
fi

cp "${WORK_DIR}/plugin-cfg.xml" "${PLUGIN_DIR}/plugin-cfg.xml"
cp "${WORK_DIR}/plugin-key.kdb" "${PLUGIN_DIR}/plugin-key.kdb"
cp "${WORK_DIR}/plugin-key.sth" "${PLUGIN_DIR}/plugin-key.sth"
[[ -f "${WORK_DIR}/plugin-key.rdb" ]] && cp "${WORK_DIR}/plugin-key.rdb" "${PLUGIN_DIR}/plugin-key.rdb"
rm -rf "${WORK_DIR}"

# Point WebSpherePluginConfig at config/webserver1/plugin-cfg.xml
python3 -c "
import sys
path, new = sys.argv[1], sys.argv[2]
lines = open(path).readlines()
out = [new+'\n' if l.strip().lower().startswith('webspherepluginconfig') else l for l in lines]
if out == lines: out.append('\n'+new+'\n')
open(path,'w').writelines(out)
print('      httpd.conf → ' + new)
" "${HTTPD_CONF}" "WebSpherePluginConfig ${PLUGIN_DIR}/plugin-cfg.xml"

"${APACHECTL}" configtest || { echo "ERROR: httpd.conf syntax check failed"; exit 1; }
"${APACHECTL}" start; sleep 3

ss -tlnp 2>/dev/null | grep -q ":8080 " || { echo "ERROR: IHS failed to start"; exit 1; }
echo "      IHS running on port 8080"
echo ""

# --- 5. Wait for ODR routing (up to 90s) ---
echo "[5/5] Waiting for ODR routing (up to 90s)..."
CODE="000"
for t in $(seq 0 5 90); do
    [[ $t -gt 0 ]] && { sleep 5; printf "      %ss...\n" "${t}"; }
    CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/server-info/ 2>/dev/null)
    [[ "${CODE}" == "200" ]] && break
done

if [[ "${CODE}" == "200" ]]; then
    echo ""
    echo "=== Dynamic Routing enabled ==="
    echo "  for i in \$(seq 6); do curl -s http://localhost:8080/server-info/ | grep -o 'member[0-9]*'; done"
    echo ""
else
    echo ""
    echo "  HTTP ${CODE} after 90s — run: bash scripts/check-dynamic-routing.sh"
    exit 1
fi
