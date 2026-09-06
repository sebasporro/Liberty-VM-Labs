#!/bin/bash
# =============================================================================
# step2-dynamic-routing.sh
# Enables Liberty Intelligent Management (IM) Dynamic Routing.
#
# How Liberty IM routing works:
#   1. Controller runs dynamicRouting-1.0 → exposes /ibm/api/dynamicRouting
#   2. Each member has a <virtualHost> element associating it with webserver1
#      → the controller knows which apps/VHosts to advertise per web server
#   3. IHS plugin reads <IntelligentManagement> in plugin-cfg.xml, connects
#      to controller:9443/ibm/api/dynamicRouting, and receives a live routing
#      table that updates automatically as members join/leave/start/stop
#
# What this script does:
#   1. Pre-flight: verify controller, IHS, gskcapicmd, members running
#   2. Inject virtualHost dropin into every running member so the controller
#      knows to advertise them to webserver1
#   3. Enable dynamicRouting-1.0 + restConnector-2.0 on the controller
#   4. Run dynamicRouting setup → generates plugin-cfg.xml + plugin-key.p12
#   5. Convert plugin-key.p12 → plugin-key.kdb (CMS) via gskcapicmd
#   6. Install plugin-cfg.xml, patch Log path, create log dir, restart IHS
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

# ---------------------------------------------------------------------------
# Paths — controller
# ---------------------------------------------------------------------------
CONTROLLER_DIR="${WORKSPACE_ROOT}/installs/controller"
CTRL_WLP="${CONTROLLER_DIR}/wlp"
SERVER_DIR="${CTRL_WLP}/usr/servers/controller"
WLP_BIN="${CTRL_WLP}/bin/server"
DYNAMIC_ROUTING_BIN="${CTRL_WLP}/bin/dynamicRouting"
OVERRIDES_DIR="${SERVER_DIR}/configDropins/overrides"
MESSAGES_LOG="${SERVER_DIR}/logs/messages.log"

# ---------------------------------------------------------------------------
# Paths — IHS
# ---------------------------------------------------------------------------
IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/IBM/HTTPServer}"
HTTPD_CONF="${IHS_ROOT}/conf/httpd.conf"
APACHECTL="${IHS_ROOT}/bin/apachectl"
PLUGIN_CFG="${IHS_ROOT}/conf/plugin-cfg.xml"
PLUGIN_KEYSTORE_DIR="${IHS_ROOT}/config/webserver1"
PLUGIN_KEY_KDB="${PLUGIN_KEYSTORE_DIR}/plugin-key.kdb"
GSKCAPICMD="${IHS_ROOT}/bin/gskcapicmd"
# The IM plugin writes its log here — must match the Log Name in plugin-cfg.xml
PLUGIN_LOG_DIR="${IHS_ROOT}/logs/webserver1"
PLUGIN_LOG="${PLUGIN_LOG_DIR}/http_plugin.log"

# Scratch directory for dynamicRouting setup output
SETUP_OUTPUT_DIR="${SERVER_DIR}/resources/security/plugin-setup"

# ---------------------------------------------------------------------------
# Controller coordinates
# ---------------------------------------------------------------------------
CONTROLLER_HOST="localhost"
CONTROLLER_HTTPS=9443
CONTROLLER_HTTP=9080
ADMIN_USER="admin"
ADMIN_PASS="admin"
KEYSTORE_PASS="Liberty26ctrl!"
WEB_SERVER_NAME="webserver1"
IHS_HTTP_PORT=8080

echo ""
echo "=== Step 3b: Liberty Dynamic Routing (Intelligent Management) ==="
echo ""

# ---------------------------------------------------------------------------
# 1. Pre-flight checks
# ---------------------------------------------------------------------------
echo "[1/6] Pre-flight checks..."

if [[ ! -x "${WLP_BIN}" ]]; then
    echo "  ERROR: Controller WLP not found. Run scripts/install-controller.sh first."
    exit 1
fi
if [[ ! -x "${DYNAMIC_ROUTING_BIN}" ]]; then
    echo "  ERROR: dynamicRouting binary not found at ${DYNAMIC_ROUTING_BIN}"
    exit 1
fi
echo "  dynamicRouting  : ${DYNAMIC_ROUTING_BIN}"

if [[ ! -f "${IHS_ROOT}/modules/mod_was_ap24_http.so" ]]; then
    echo "  ERROR: mod_was_ap24_http.so not found. Run scripts/install-ihs.sh first."
    exit 1
fi
echo "  WAS plugin      : present"

if [[ ! -x "${GSKCAPICMD}" ]] || ! "${GSKCAPICMD}" -version >/dev/null 2>&1; then
    echo "  ERROR: gskcapicmd not functional at ${GSKCAPICMD}"
    exit 1
fi
echo "  gskcapicmd      : functional"

if ! ss -tlnp 2>/dev/null | grep -q ":${CONTROLLER_HTTP} "; then
    echo "  ERROR: Controller not running on port ${CONTROLLER_HTTP}."
    echo "         Run: ${WLP_BIN} start controller"
    exit 1
fi
echo "  Controller      : running on ${CONTROLLER_HTTP} / ${CONTROLLER_HTTPS}"

# Guard: controller must NOT have collective-join.xml (it would load collectiveMember-1.0
# which prevents the DynamicRouting MBean from registering)
STALE_JOIN="${OVERRIDES_DIR}/collective-join.xml"
if [[ -f "${STALE_JOIN}" ]]; then
    echo "  WARNING: Removing stale collective-join.xml from controller overrides."
    rm -f "${STALE_JOIN}"
fi

echo "  Running members:"
MEMBER_FOUND=0
for i in 1 2 3 4 5 6 7 8 9; do
    port=$(( 9080 + i ))
    ss -tlnp 2>/dev/null | grep -q ":${port} " && { echo "    member${i} :${port}"; (( MEMBER_FOUND++ )); }
done
if [[ ${MEMBER_FOUND} -eq 0 ]]; then
    echo "  ERROR: No members running. Start members before running this script."
    exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# 2. Inject <virtualHost> dropin into every running member
#
# The controller uses <virtualHost> elements to build the routing table it
# sends to the web server plugin. Without this, the plugin connects to the
# controller successfully but gets an empty server group (websphereFindServerGroup
# error) because no member has declared itself reachable via webserver1.
#
# Each member needs:
#   <virtualHost id="default_host" allowFromEndpointRef="defaultHttpEndpoint">
#       <hostAlias>*:IHS_PORT</hostAlias>
#   </virtualHost>
# ---------------------------------------------------------------------------
echo "[2/6] Injecting virtualHost dropin into running members and restarting them..."

for i in 1 2 3 4 5 6 7 8 9; do
    port=$(( 9080 + i ))
    member_name="member${i}"
    member_install="${WORKSPACE_ROOT}/installs/${member_name}"
    member_overrides="${member_install}/wlp/usr/servers/${member_name}/configDropins/overrides"
    member_bin="${member_install}/wlp/bin/server"

    if ! ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        continue
    fi

    if [[ ! -d "${member_overrides}" ]]; then
        echo "  WARNING: overrides dir not found for ${member_name} — skipping"
        continue
    fi

    cat > "${member_overrides}/dynamic-routing-vhost.xml" <<VHOSTXML
<?xml version="1.0" encoding="UTF-8"?>
<!--
  Virtual host declaration for Liberty IM Dynamic Routing.
  Tells the collective controller to advertise this member's applications
  to the IHS web server plugin under the *:${IHS_HTTP_PORT} virtual host.
  Injected by scripts/step2-dynamic-routing.sh
-->
<server>
    <virtualHost id="default_host" allowFromEndpointRef="defaultHttpEndpoint">
        <hostAlias>*:${IHS_HTTP_PORT}</hostAlias>
    </virtualHost>
</server>
VHOSTXML
    echo "  Written dropin for ${member_name}"

    # Restart member so it re-registers the virtualHost with the collective
    if [[ -x "${member_bin}" ]]; then
        "${member_bin}" stop "${member_name}" 2>/dev/null || true
        sleep 2
        "${member_bin}" start "${member_name}"
        echo "  Restarted: ${member_name}"
    fi
done

echo "  Waiting 10 s for members to re-register with collective..."
sleep 10
echo ""

# ---------------------------------------------------------------------------
# 3. Enable dynamicRouting-1.0 + restConnector-2.0 on the controller
# ---------------------------------------------------------------------------
echo "[3/6] Enabling dynamicRouting-1.0 + restConnector-2.0 on controller..."
mkdir -p "${OVERRIDES_DIR}"

cat > "${OVERRIDES_DIR}/dynamic-routing.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<server description="Dynamic routing feature">
    <featureManager>
        <feature>dynamicRouting-1.0</feature>
        <feature>restConnector-2.0</feature>
    </featureManager>
</server>
XML
echo "  Written: ${OVERRIDES_DIR}/dynamic-routing.xml"

# Restart controller with clean log
> "${MESSAGES_LOG}" 2>/dev/null || true
"${WLP_BIN}" stop controller 2>/dev/null || true
sleep 3
"${WLP_BIN}" start controller

echo "  Waiting for controller ready (CWWKF0011I) — up to 90 s..."
WAITED=0
while [[ ${WAITED} -lt 90 ]]; do
    grep -q "CWWKF0011I" "${MESSAGES_LOG}" 2>/dev/null && break
    sleep 2; (( WAITED += 2 ))
done
[[ ${WAITED} -ge 90 ]] && { echo "  ERROR: Timeout — check ${MESSAGES_LOG}"; exit 1; }

grep -q "CWWKF0012I.*dynamicRouting-1.0" "${MESSAGES_LOG}" 2>/dev/null \
    && echo "  dynamicRouting-1.0  : active ✓" \
    || { echo "  ERROR: dynamicRouting-1.0 did not load"; grep -iE "CWWKF|dynamicRouting" "${MESSAGES_LOG}" | tail -5; exit 1; }

grep -q "CWWKF0012I.*restConnector-2.0" "${MESSAGES_LOG}" 2>/dev/null \
    && echo "  restConnector-2.0   : active ✓" \
    || { echo "  ERROR: restConnector-2.0 did not load"; exit 1; }

echo "  Waiting 10 s for DynamicRouting MBean registration..."
sleep 10

# Verify the controller has server groups (members registered with virtualHost)
echo "  Checking controller routing table..."
ROUTING_JSON=$(curl -k -s -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -H "Accept: application/json" \
    "https://${CONTROLLER_HOST}:${CONTROLLER_HTTPS}/ibm/api/dynamicRouting" \
    2>/dev/null)
if echo "${ROUTING_JSON}" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d else 1)" 2>/dev/null; then
    echo "  Routing table    : populated ✓"
else
    echo "  WARNING: Controller routing table is empty."
    echo "           Members may not have registered their virtualHost yet."
    echo "           dynamicRouting setup will still run — the plugin will"
    echo "           retry connecting to the controller every 60 s."
fi
echo ""

# ---------------------------------------------------------------------------
# 4. Run dynamicRouting setup
#    Generates plugin-cfg.xml (with <IntelligentManagement>) + plugin-key.p12
# ---------------------------------------------------------------------------
echo "[4/6] Running dynamicRouting setup..."

rm -rf "${SETUP_OUTPUT_DIR}"
mkdir -p "${SETUP_OUTPUT_DIR}"
mkdir -p "${PLUGIN_KEYSTORE_DIR}"

# Probe for --webServerName vs --webServerNames
_DR_HELP=$("${DYNAMIC_ROUTING_BIN}" setup --help 2>&1 || true)
if echo "${_DR_HELP}" | grep -q -- "--webServerName[^s]"; then
    WS_FLAG="--webServerName=${WEB_SERVER_NAME}"
elif echo "${_DR_HELP}" | grep -q -- "--webServerNames"; then
    WS_FLAG="--webServerNames=${WEB_SERVER_NAME}"
else
    WS_FLAG=""
fi
echo "  Web server flag: ${WS_FLAG:-<omitted>}"

"${DYNAMIC_ROUTING_BIN}" setup \
    --host="${CONTROLLER_HOST}" \
    --port="${CONTROLLER_HTTPS}" \
    --user="${ADMIN_USER}" \
    --password="${ADMIN_PASS}" \
    --keystorePassword="${KEYSTORE_PASS}" \
    ${WS_FLAG:+"${WS_FLAG}"} \
    --pluginInstallRoot="${IHS_ROOT}" \
    --targetPath="${SETUP_OUTPUT_DIR}" \
    --autoAcceptCertificates

SETUP_RC=$?
if [[ ${SETUP_RC} -ne 0 ]]; then
    echo "  ERROR: dynamicRouting setup failed (exit ${SETUP_RC})"
    echo "         Check: ${MESSAGES_LOG}"
    exit 1
fi

GENERATED_CFG=$(find "${SETUP_OUTPUT_DIR}" -name "plugin-cfg.xml" 2>/dev/null | head -1)
if [[ -z "${GENERATED_CFG}" ]]; then
    echo "  ERROR: plugin-cfg.xml not generated"
    find "${SETUP_OUTPUT_DIR}" -type f | sort | sed 's/^/    /'
    exit 1
fi
echo "  Generated: ${GENERATED_CFG}"

GENERATED_KEY=$(find "${SETUP_OUTPUT_DIR}" -name "plugin-key.p12" 2>/dev/null | head -1)
if [[ -z "${GENERATED_KEY}" ]]; then
    echo "  ERROR: plugin-key.p12 not generated"
    exit 1
fi
echo "  Keystore (PKCS12): ${GENERATED_KEY}"
echo ""

# ---------------------------------------------------------------------------
# 5. Convert plugin-key.p12 → plugin-key.kdb (CMS)
# ---------------------------------------------------------------------------
echo "[5/6] Converting keystore PKCS12 → CMS (gskcapicmd)..."

rm -f "${PLUGIN_KEYSTORE_DIR}/plugin-key.kdb" \
      "${PLUGIN_KEYSTORE_DIR}/plugin-key.sth" \
      "${PLUGIN_KEYSTORE_DIR}/plugin-key.rdb"

"${GSKCAPICMD}" -keydb -convert \
    -pw "${KEYSTORE_PASS}" \
    -db "${GENERATED_KEY}" \
    -old_format pkcs12 \
    -target "${PLUGIN_KEY_KDB}" \
    -new_format cms \
    -stash
[[ $? -ne 0 ]] && { echo "  ERROR: gskcapicmd -keydb -convert failed"; exit 1; }

"${GSKCAPICMD}" -cert -setdefault \
    -pw "${KEYSTORE_PASS}" \
    -db "${PLUGIN_KEY_KDB}" \
    -label default 2>/dev/null || true

echo "  CMS keystore : ${PLUGIN_KEY_KDB}"
echo "  Stash file   : ${PLUGIN_KEYSTORE_DIR}/plugin-key.sth"

IHS_USER=$(grep "^User " "${HTTPD_CONF}" 2>/dev/null | awk '{print $2}')
IHS_GROUP=$(grep "^Group " "${HTTPD_CONF}" 2>/dev/null | awk '{print $2}')
[[ -n "${IHS_USER}" && -n "${IHS_GROUP}" ]] && \
    chown "${IHS_USER}:${IHS_GROUP}" \
        "${PLUGIN_KEYSTORE_DIR}/plugin-key.kdb" \
        "${PLUGIN_KEYSTORE_DIR}/plugin-key.sth" \
        "${PLUGIN_KEYSTORE_DIR}/plugin-key.rdb" 2>/dev/null || true
echo ""

# ---------------------------------------------------------------------------
# 6. Patch plugin-cfg.xml, create log dir, install, restart IHS
#
# dynamicRouting setup writes the Log Name as:
#   pluginInstallRoot/logs/webServerName/http_plugin.log
# That directory must exist before IHS starts, otherwise the plugin silently
# uses /dev/null and all plugin activity is invisible.
#
# The generated VirtualHostGroup defaults to ports 80/443. Patch it to 8080.
# ---------------------------------------------------------------------------
echo "[6/6] Installing plugin-cfg.xml and restarting IHS..."

# Create the plugin log directory the IM plugin expects
mkdir -p "${PLUGIN_LOG_DIR}"
[[ -n "${IHS_USER}" ]] && chown "${IHS_USER}:${IHS_GROUP:-${IHS_USER}}" "${PLUGIN_LOG_DIR}" 2>/dev/null || true
echo "  Created log dir: ${PLUGIN_LOG_DIR}"

# Patch the generated plugin-cfg.xml:
#   1. Fix Connector: switch to HTTP port 9080, add stashfile, remove keyring
#      The plugin needs stashfile to unlock the CMS keystore for TLS. Since
#      we want HTTP (simpler, no cert trust required), switch protocol+port
#      and remove the keyring/stashfile properties entirely.
#   2. Fix VirtualHost: replace generated port (80/443) with IHS port 8080
#   3. Inject UriGroup+VirtualHostGroup+Route if missing
python3 - "${GENERATED_CFG}" "${IHS_HTTP_PORT}" "${CONTROLLER_HTTP}" <<'PYEOF'
import sys, re

path      = sys.argv[1]
ihs_port  = sys.argv[2]
ctrl_http = sys.argv[3]

with open(path) as f:
    xml = f.read()

# Fix <Connector>: switch to HTTP, remove keyring/stashfile
# Replace the entire Connector element inside IntelligentManagement
def fix_connector(m):
    c = m.group(0)
    # Switch to http and controller HTTP port
    c = re.sub(r'\bprotocol="https"', 'protocol="http"', c, flags=re.IGNORECASE)
    c = re.sub(r'\bport="\d+"', f'port="{ctrl_http}"', c)
    # Remove keyring and stashfile properties (not needed for HTTP)
    c = re.sub(r'\s*<Property\s+name="(?:keyring|stashfile)"[^>]*/>', '', c, flags=re.IGNORECASE)
    return c

xml = re.sub(r'<Connector\b[^>]*>.*?</Connector>', fix_connector, xml, flags=re.DOTALL)

# Fix VirtualHost port
xml = re.sub(r'(<VirtualHost\s+Name="\*:)\d+(")', rf'\g<1>{ihs_port}\2', xml)

# Inject routing footer if missing
if '<VirtualHostGroup' not in xml:
    footer = f"""
    <UriGroup Name="default_uris">
        <Uri AffinityCookie="JSESSIONID" AffinityURLIdentifier="jsessionid" Name="/*"/>
    </UriGroup>

    <VirtualHostGroup Name="default_vhosts">
        <VirtualHost Name="*:{ihs_port}"/>
    </VirtualHostGroup>

    <Route VirtualHostGroup="default_vhosts"
           UriGroup="default_uris"
           IntelligentManagement="true"/>

"""
    xml = xml.replace('</Config>', footer + '</Config>')

with open(path, 'w') as f:
    f.write(xml)

print(f"  Patched: Connector → http:{ctrl_http}, VirtualHost → *:{ihs_port}")
PYEOF
[[ $? -ne 0 ]] && { echo "  ERROR: Failed to patch plugin-cfg.xml"; exit 1; }

cp "${GENERATED_CFG}" "${PLUGIN_CFG}"
echo "  Installed: ${PLUGIN_CFG}"

# WebSpherePluginConfig in httpd.conf
if grep -q "^WebSpherePluginConfig" "${HTTPD_CONF}"; then
    sed -i "s|^WebSpherePluginConfig .*|WebSpherePluginConfig ${PLUGIN_CFG}|" "${HTTPD_CONF}"
    echo "  WebSpherePluginConfig: updated"
else
    printf '\n# WAS plugin — Liberty IM Dynamic Routing\nWebSpherePluginConfig %s\n' \
        "${PLUGIN_CFG}" >> "${HTTPD_CONF}"
    echo "  WebSpherePluginConfig: added"
fi

"${APACHECTL}" configtest 2>&1 | grep -q "Syntax OK" \
    || { echo "  ERROR: httpd.conf syntax check failed"; "${APACHECTL}" configtest; exit 1; }
echo "  httpd.conf syntax: OK"

# Reliable IHS restart
"${APACHECTL}" stop 2>/dev/null; sleep 2
pkill -9 -f "${IHS_ROOT}/bin/httpd" 2>/dev/null; sleep 1
ss -tlnp 2>/dev/null | grep -q ":8080 " && { echo "  ERROR: port 8080 still in use"; exit 1; }
"${APACHECTL}" start
sleep 3

ss -tlnp 2>/dev/null | grep -q ":8080 " \
    || { echo "  ERROR: IHS failed to start"; tail -20 "${IHS_ROOT}/logs/error_log"; exit 1; }
echo "  IHS: running on port 8080"
echo ""

# ---------------------------------------------------------------------------
# Verify — allow up to 60 s for IM plugin to connect and get routing table
# ---------------------------------------------------------------------------
echo "  Verifying routing via IHS (up to 60 s)..."
POLL_WAITED=0; HTTP_CODE="000"
while [[ ${POLL_WAITED} -lt 60 ]]; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/server-info/ 2>/dev/null)
    [[ "${HTTP_CODE}" == "200" ]] && break
    sleep 5; (( POLL_WAITED += 5 ))
    echo "    ${POLL_WAITED}s — HTTP ${HTTP_CODE}..."
done

echo ""
echo "  GET /server-info/ via IHS → HTTP ${HTTP_CODE}"
echo ""
echo "  Plugin log (IM writes here):"
tail -30 "${PLUGIN_LOG}" 2>/dev/null | sed 's/^/    /' || echo "    (${PLUGIN_LOG} not yet created)"
echo ""

if [[ "${HTTP_CODE}" == "200" ]]; then
    echo "=== Liberty Dynamic Routing (Intelligent Management) is active ==="
    echo ""
    echo "  IHS:8080 → controller:${CONTROLLER_HTTPS}/ibm/api/dynamicRouting"
    echo "           → all collective members (live routing table)"
    echo ""
    echo "  Members joining/leaving are reflected automatically."
    echo ""
    echo "  Verify round-robin:"
    echo "    for i in \$(seq 8); do curl -s http://localhost:8080/server-info/ | grep -o 'member[0-9]*'; done"
    echo ""
    echo "  Plugin log : tail -f ${PLUGIN_LOG}"
    echo "  Admin Center: https://localhost:${CONTROLLER_HTTPS}/adminCenter"
else
    echo "  WARNING: Routing returned HTTP ${HTTP_CODE} after 60 s."
    echo ""
    echo "  To restore working static routing immediately:"
    echo "    scripts/reset-ihs.sh && scripts/step1-was-plugin.sh"
    echo ""
    echo "  Diagnose:"
    echo "    tail -50 ${PLUGIN_LOG}"
    echo "    tail -30 ${IHS_ROOT}/logs/error_log"
    echo "    tail -30 ${MESSAGES_LOG}"
fi
echo ""
