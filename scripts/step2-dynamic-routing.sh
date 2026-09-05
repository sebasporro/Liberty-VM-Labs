#!/bin/bash
# =============================================================================
# step2-dynamic-routing.sh
# Enables native Liberty Intelligent Management Dynamic Routing.
#
# IBM Documentation:
#   Setting up dynamic routing for a single Liberty collective:
#   https://www.ibm.com/docs/en/was-liberty/nd?topic=collectives-setting-up-dynamic-routing-single-liberty-collective
#
#   Dynamic routing command reference:
#   https://www.ibm.com/docs/en/was-liberty/nd?topic=collectives-dynamic-routing-command
#
# How Liberty dynamic routing works:
#   1. The controller runs dynamicRouting-1.0, which activates the Dynamic
#      Routing service at /ibm/api/dynamicRouting (HTTPS, port 9443).
#   2. dynamicRouting setup connects to the controller via HTTPS and generates:
#        plugin-cfg.xml   — contains <IntelligentManagement> stanza
#        plugin-key.p12   — PKCS12 keystore for plugin ↔ controller TLS
#   3. gskcapicmd (ships with IHS) converts plugin-key.p12 → CMS plugin-key.kdb
#      The CMS keystore is placed at pluginInstallRoot/config/webServerName/.
#   4. plugin-cfg.xml is placed where WebSpherePluginConfig points in httpd.conf.
#   5. mod_was_ap24_http.so reads <IntelligentManagement>, connects to the
#      controller's /ibm/api/dynamicRouting endpoint, and continuously receives
#      the live routing table — members joining/leaving are reflected
#      automatically within the RetryInterval (default 60 s).
#
# Architecture after this script:
#   Browser → IHS:8080 ──(mod_was_ap24_http.so)──► controller:9443/ibm/api/dynamicRouting
#                                                        │
#                                          live route table (all members)
#                                                        │
#                          ┌──────────────┬─────────────┼─────────────┐
#                          ▼              ▼             ▼             ▼
#                     member1:9081  member2:9082  member3:9083  member4:9084
#
# Prerequisites:
#   - IHS with WAS Plugins (full install) — scripts/install-ihs.sh
#     The IHS ZIP must include a working gskcapicmd and the Intelligent
#     Management-capable mod_was_ap24_http.so from the WAS Plugins product.
#   - Controller running on HTTPS 9443  — scripts/install-controller.sh
#   - At least one member in collective — scripts/add-member-26.sh
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
# plugin-cfg.xml is placed here; WebSpherePluginConfig in httpd.conf points at it
PLUGIN_CFG="${IHS_ROOT}/conf/plugin-cfg.xml"

# The CMS keystore must live at pluginInstallRoot/config/webServerName/
# Liberty embeds this path as the Keyfile stanza in plugin-cfg.xml.
PLUGIN_KEYSTORE_DIR="${IHS_ROOT}/config/webserver1"
PLUGIN_KEY_KDB="${PLUGIN_KEYSTORE_DIR}/plugin-key.kdb"

# gskcapicmd — ships with a proper IHS install (full package, not stub ZIP)
GSKCAPICMD="${IHS_ROOT}/bin/gskcapicmd"

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
KEYSTORE_PASS="Liberty26ctrl!"   # must match keystore.password in bootstrap.properties
WEB_SERVER_NAME="webserver1"

echo ""
echo "=== Step 3b: Liberty Dynamic Routing (Intelligent Management) ==="
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
    echo "         Ensure Liberty ND with collectiveController-1.0 is installed."
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

# Verify gskcapicmd is functional (not an unpatched stub)
if [[ ! -x "${GSKCAPICMD}" ]]; then
    echo "  ERROR: gskcapicmd not found at ${GSKCAPICMD}"
    echo "         The IHS install must include the full WAS Plugins package."
    echo "         A ZIP-extracted IHS stub will not work — use the proper IHS installer."
    exit 1
fi
# Quick smoke-test — a broken stub fails immediately
if ! "${GSKCAPICMD}" -version >/dev/null 2>&1; then
    echo "  ERROR: gskcapicmd at ${GSKCAPICMD} failed to run."
    echo "         The IHS install appears to be a stub (@@SERVERROOT@@ not substituted)."
    echo "         Re-install IHS using the full WAS Plugins-capable package."
    exit 1
fi
echo "  gskcapicmd      : functional"

if ! ss -tlnp 2>/dev/null | grep -q ":${CONTROLLER_HTTP} "; then
    echo "  ERROR: Controller is not running on port ${CONTROLLER_HTTP}."
    echo "         Run: ${WLP_BIN} start controller"
    exit 1
fi
echo "  Controller      : running on ${CONTROLLER_HTTP} / ${CONTROLLER_HTTPS}"

# Guard: controller must NOT have a collective-join.xml dropin
STALE_JOIN="${OVERRIDES_DIR}/collective-join.xml"
if [[ -f "${STALE_JOIN}" ]]; then
    echo "  WARNING: Found collective-join.xml on the controller — removing it."
    echo "           This dropin loads collectiveMember-1.0 on the controller, which"
    echo "           prevents the DynamicRouting MBean from registering (CWWKX0217E)."
    rm -f "${STALE_JOIN}"
    echo "  Removed: ${STALE_JOIN}"
fi

# Report running members (informational — dynamic routing discovers them automatically)
for i in 1 2 3 4; do
    port=$(( 9080 + i ))
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        echo "  Member :${port}     : up"
    fi
done
echo ""

# ---------------------------------------------------------------------------
# 2. Enable dynamicRouting-1.0 + restConnector-2.0 on the controller
#
#    dynamicRouting-1.0  — activates the /ibm/api/dynamicRouting endpoint
#    restConnector-2.0   — required by the dynamicRouting setup CLI to reach
#                          the DynamicRouting MBean via the Liberty REST JMX
#                          bridge; without it setup fails with CWWKX0217E
# ---------------------------------------------------------------------------
echo "[2/5] Enabling dynamicRouting-1.0 + restConnector-2.0 on controller..."
mkdir -p "${OVERRIDES_DIR}"
DYNAMIC_XML="${OVERRIDES_DIR}/dynamic-routing.xml"

cat > "${DYNAMIC_XML}" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<server description="Dynamic routing feature">
    <featureManager>
        <!-- Activates /ibm/api/dynamicRouting on the controller HTTPS port -->
        <feature>dynamicRouting-1.0</feature>
        <!-- Required by the dynamicRouting setup CLI (REST JMX bridge) -->
        <feature>restConnector-2.0</feature>
    </featureManager>
</server>
XML
echo "  Written: ${DYNAMIC_XML}"

# Restart controller — truncate log first so we only match this startup
mkdir -p "$(dirname "${MESSAGES_LOG}")"
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
if [[ ${WAITED} -ge 90 ]]; then
    echo "  ERROR: Timeout waiting for controller ready — check ${MESSAGES_LOG}"
    exit 1
fi

if grep -q "CWWKF0012I.*dynamicRouting-1.0" "${MESSAGES_LOG}" 2>/dev/null; then
    echo "  dynamicRouting-1.0  : active ✓"
elif grep -q "CWWKF0001E.*dynamicRouting" "${MESSAGES_LOG}" 2>/dev/null; then
    echo "  ERROR: dynamicRouting-1.0 not available in this Liberty edition."
    grep "CWWKF0001E\|CWWKF0002E\|dynamicRouting" "${MESSAGES_LOG}" 2>/dev/null | tail -5
    exit 1
else
    echo "  ERROR: dynamicRouting-1.0 did not load — check ${MESSAGES_LOG}"
    grep -iE "CWWKF|dynamicRouting|error" "${MESSAGES_LOG}" 2>/dev/null | tail -10
    exit 1
fi

if grep -q "CWWKF0012I.*restConnector-2.0" "${MESSAGES_LOG}" 2>/dev/null; then
    echo "  restConnector-2.0   : active ✓"
elif grep -q "CWWKF0001E.*restConnector" "${MESSAGES_LOG}" 2>/dev/null; then
    echo "  ERROR: restConnector-2.0 not available — check Liberty edition."
    grep "CWWKF0001E.*restConnector" "${MESSAGES_LOG}" 2>/dev/null | tail -3
    exit 1
else
    echo "  ERROR: restConnector-2.0 did not load — check ${MESSAGES_LOG}"
    grep -iE "CWWKF|restConnector|error" "${MESSAGES_LOG}" 2>/dev/null | tail -10
    exit 1
fi

# Brief pause for the DynamicRouting MBean to register after server ready
echo "  Waiting 5 s for DynamicRouting MBean registration..."
sleep 5
echo ""

# ---------------------------------------------------------------------------
# 3. Run dynamicRouting setup
#
#    Connects to the controller via HTTPS and generates:
#      plugin-cfg.xml   — <IntelligentManagement> stanza pointing at the
#                         controller's /ibm/api/dynamicRouting endpoint
#      plugin-key.p12   — PKCS12 keystore for TLS between plugin and controller
#
#    --pluginInstallRoot  : the IHS plugin root — Liberty embeds this path as
#                           the Keyfile location in plugin-cfg.xml
#    --targetPath         : where the command writes its output files
#                           (defaults to $PWD without this flag)
#    --webServerName      : web server name registered with the controller
#                           IBM docs use singular; older builds accepted plural.
#                           We probe the binary and use whichever it accepts.
# ---------------------------------------------------------------------------
echo "[3/5] Running dynamicRouting setup..."

rm -rf "${SETUP_OUTPUT_DIR}"
mkdir -p "${SETUP_OUTPUT_DIR}"
mkdir -p "${PLUGIN_KEYSTORE_DIR}"

# Detect whether this build of dynamicRouting uses --webServerName (singular,
# per IBM docs) or --webServerNames (plural, accepted by some older builds).
# Fall back to no web-server flag at all if neither is advertised — the command
# still generates plugin-cfg.xml without it (uses a default name).
_DR_HELP=$("${DYNAMIC_ROUTING_BIN}" setup --help 2>&1 || true)
if echo "${_DR_HELP}" | grep -q -- "--webServerName[^s]"; then
    WS_NAME_FLAG="--webServerName=${WEB_SERVER_NAME}"
elif echo "${_DR_HELP}" | grep -q -- "--webServerNames"; then
    WS_NAME_FLAG="--webServerNames=${WEB_SERVER_NAME}"
else
    WS_NAME_FLAG=""
    echo "  NOTE: --webServerName[s] not advertised by this build — omitting flag"
fi
echo "  Web server flag : ${WS_NAME_FLAG:-<omitted>}"

"${DYNAMIC_ROUTING_BIN}" setup \
    --host="${CONTROLLER_HOST}" \
    --port="${CONTROLLER_HTTPS}" \
    --user="${ADMIN_USER}" \
    --password="${ADMIN_PASS}" \
    --keystorePassword="${KEYSTORE_PASS}" \
    ${WS_NAME_FLAG:+"${WS_NAME_FLAG}"} \
    --pluginInstallRoot="${IHS_ROOT}" \
    --targetPath="${SETUP_OUTPUT_DIR}" \
    --autoAcceptCertificates

SETUP_RC=$?
if [[ ${SETUP_RC} -ne 0 ]]; then
    echo "  ERROR: dynamicRouting setup failed (exit ${SETUP_RC})"
    echo "         Check: ${MESSAGES_LOG}"
    exit 1
fi

# Locate generated plugin-cfg.xml
# With a single --webServerName entry the filename is plugin-cfg.xml
GENERATED_CFG="${SETUP_OUTPUT_DIR}/plugin-cfg.xml"
if [[ ! -f "${GENERATED_CFG}" ]]; then
    GENERATED_CFG=$(find "${SETUP_OUTPUT_DIR}" -name "plugin-cfg.xml" 2>/dev/null | head -1)
fi
if [[ -z "${GENERATED_CFG}" || ! -f "${GENERATED_CFG}" ]]; then
    echo "  ERROR: plugin-cfg.xml not found after dynamicRouting setup."
    echo "         All files under ${SETUP_OUTPUT_DIR}:"
    find "${SETUP_OUTPUT_DIR}" -type f 2>/dev/null | sort | sed 's/^/    /'
    exit 1
fi
echo "  Generated: ${GENERATED_CFG}"

# ---------------------------------------------------------------------------
# Critical check: the generated plugin-cfg.xml MUST contain an
# <IntelligentManagement> stanza. If it contains only a static <ServerCluster>
# it means the DynamicRouting MBean was not reachable when setup ran — the
# plugin will do plain round-robin across only the members alive at setup time
# and will NOT pick up new members automatically. That defeats the entire
# purpose of Step 3b.
#
# Root cause when this check fails:
#   - restConnector-2.0 did not load (check CWWKF0012I in messages.log)
#   - The DynamicRouting MBean had not finished registering (sleep was too short)
#   - The controller keystore password in --keystorePassword does not match
#     bootstrap.properties keystore.password on the controller
# ---------------------------------------------------------------------------
if ! grep -qi "IntelligentManagement" "${GENERATED_CFG}"; then
    echo ""
    echo "  ERROR: plugin-cfg.xml does NOT contain an <IntelligentManagement> stanza."
    echo "         The dynamicRouting setup command fell back to a static <ServerCluster>"
    echo "         — this means it could not contact the DynamicRouting MBean on the"
    echo "         controller. Routing will be limited to members alive at setup time"
    echo "         and will NOT update automatically when members join or leave."
    echo ""
    echo "  Diagnostics:"
    echo "    # Confirm restConnector-2.0 loaded:"
    echo "    grep 'restConnector-2.0' ${MESSAGES_LOG}"
    echo "    # Confirm DynamicRouting MBean registered:"
    echo "    grep -i 'dynamicRouting\|DynamicRouting' ${MESSAGES_LOG} | tail -20"
    echo ""
    echo "  First 40 lines of generated plugin-cfg.xml:"
    head -40 "${GENERATED_CFG}" | sed 's/^/    /'
    echo ""
    exit 1
fi
echo "  IntelligentManagement stanza : present ✓  (live routing active)"

# Locate generated plugin-key.p12
GENERATED_KEY=$(find "${SETUP_OUTPUT_DIR}" -name "plugin-key.p12" 2>/dev/null | head -1)
if [[ -z "${GENERATED_KEY}" || ! -f "${GENERATED_KEY}" ]]; then
    echo "  ERROR: plugin-key.p12 not found after dynamicRouting setup."
    find "${SETUP_OUTPUT_DIR}" -type f 2>/dev/null | sort | sed 's/^/    /'
    exit 1
fi
echo "  Keystore (PKCS12): ${GENERATED_KEY}"
echo ""

# ---------------------------------------------------------------------------
# 4. Convert plugin-key.p12 (PKCS12) → plugin-key.kdb (CMS)
#
#    The WAS plugin requires the keystore in CMS (.kdb) format.
#    gskcapicmd ships with a proper IHS install and performs the conversion.
#    The .kdb + .sth + .rdb files must reside at:
#      pluginInstallRoot/config/webServerName/
#    Liberty encodes that exact path as the Keyfile stanza in plugin-cfg.xml.
# ---------------------------------------------------------------------------
echo "[4/5] Converting keystore PKCS12 → CMS (gskcapicmd)..."

# Remove any stale CMS files from a previous run
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

CONV_RC=$?
if [[ ${CONV_RC} -ne 0 ]]; then
    echo "  ERROR: gskcapicmd -keydb -convert failed (exit ${CONV_RC})"
    exit 1
fi

"${GSKCAPICMD}" -cert -setdefault \
    -pw "${KEYSTORE_PASS}" \
    -db "${PLUGIN_KEY_KDB}" \
    -label default

echo "  CMS keystore : ${PLUGIN_KEY_KDB}"
echo "  Stash file   : ${PLUGIN_KEYSTORE_DIR}/plugin-key.sth"

# Set ownership to match the User/Group in httpd.conf (IHS runs as itzuser)
IHS_USER=$(grep "^User " "${HTTPD_CONF}" 2>/dev/null | awk '{print $2}')
IHS_GROUP=$(grep "^Group " "${HTTPD_CONF}" 2>/dev/null | awk '{print $2}')
if [[ -n "${IHS_USER}" && -n "${IHS_GROUP}" ]]; then
    chown "${IHS_USER}:${IHS_GROUP}" \
        "${PLUGIN_KEYSTORE_DIR}/plugin-key.kdb" \
        "${PLUGIN_KEYSTORE_DIR}/plugin-key.sth" \
        "${PLUGIN_KEYSTORE_DIR}/plugin-key.rdb" 2>/dev/null || true
    echo "  Ownership    : ${IHS_USER}:${IHS_GROUP}"
fi
echo ""

# ---------------------------------------------------------------------------
# 5. Install plugin-cfg.xml, set WebSpherePluginConfig, restart IHS
#
# dynamicRouting setup generates plugin-cfg.xml without a <VirtualHostGroup>
# when the web server ports default to 80/443. IHS in this lab listens on
# 8080. Without a VirtualHostGroup for *:8080 the WAS plugin does not bind
# Intelligent Management routing to that port.
# Inject the missing stanza before </Config>.
# ---------------------------------------------------------------------------
echo "[5/5] Installing plugin-cfg.xml and restarting IHS..."

IHS_HTTP_PORT=8080

# Inject VirtualHostGroup + Route for port 8080 if not already present.
# IntelligentManagement-based configs omit VirtualHostGroup/Route by default
# (they use the IM stanza for routing) but they still need at least one
# VirtualHostGroup so that mod_was_ap24_http.so binds to the correct port.
# Without this, requests on :8080 are not matched and the plugin passes them
# through without dynamic routing.
if grep -q "VirtualHostGroup.*default_vhosts" "${GENERATED_CFG}" 2>/dev/null; then
    # Already present — make sure the port is correct
    if ! grep -q "VirtualHost Name=\"\*:${IHS_HTTP_PORT}\"" "${GENERATED_CFG}" 2>/dev/null; then
        sed -i "s|VirtualHostGroup Name=\"default_vhosts\"|VirtualHostGroup Name=\"default_vhosts\"><VirtualHost Name=\"*:${IHS_HTTP_PORT}\"/|" "${GENERATED_CFG}" 2>/dev/null || true
        echo "  Patched VirtualHostGroup to add *:${IHS_HTTP_PORT}"
    else
        echo "  VirtualHostGroup *:${IHS_HTTP_PORT} : already present"
    fi
elif ! grep -q "VirtualHostGroup" "${GENERATED_CFG}" 2>/dev/null; then
    sed -i "s|</Config>|<VirtualHostGroup Name=\"default_vhosts\">\n  <VirtualHost Name=\"*:${IHS_HTTP_PORT}\"/>\n</VirtualHostGroup>\n<Route VirtualHostGroup=\"default_vhosts\"/>\n</Config>|" "${GENERATED_CFG}"
    echo "  Injected VirtualHostGroup *:${IHS_HTTP_PORT} into plugin-cfg.xml"
fi

cp "${GENERATED_CFG}" "${PLUGIN_CFG}"
echo "  Installed: ${PLUGIN_CFG}"

# Ensure WebSpherePluginConfig directive is in httpd.conf (idempotent)
if grep -q "^WebSpherePluginConfig" "${HTTPD_CONF}"; then
    sed -i "s|^WebSpherePluginConfig .*|WebSpherePluginConfig ${PLUGIN_CFG}|" "${HTTPD_CONF}"
    echo "  WebSpherePluginConfig: updated"
else
    printf '\n# WAS plugin — Liberty dynamic routing (Intelligent Management)\nWebSpherePluginConfig %s\n' \
        "${PLUGIN_CFG}" >> "${HTTPD_CONF}"
    echo "  WebSpherePluginConfig: added"
fi

RESULT=$("${APACHECTL}" configtest 2>&1)
if ! echo "${RESULT}" | grep -q "Syntax OK"; then
    echo "  ERROR: httpd.conf syntax check failed:"
    echo "${RESULT}"
    exit 1
fi
echo "  httpd.conf syntax: OK"

if ss -tlnp 2>/dev/null | grep -q ":8080 "; then
    "${APACHECTL}" stop && sleep 2
fi
"${APACHECTL}" start
sleep 2

if ! ss -tlnp 2>/dev/null | grep -q ":8080 "; then
    echo "  ERROR: IHS failed to start — check ${IHS_ROOT}/logs/error_log"
    tail -20 "${IHS_ROOT}/logs/error_log"
    exit 1
fi
echo "  IHS: running on port 8080"
echo ""

# Verify end-to-end routing
# The plugin fetches the routing table from the controller on first request;
# allow up to 30 s for the initial connection to /ibm/api/dynamicRouting.
echo "  Verifying routing via IHS (up to 30 s)..."
POLL_WAITED=0
HTTP_CODE="000"
while [[ ${POLL_WAITED} -lt 30 ]]; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        http://localhost:8080/server-info/ 2>/dev/null)
    [[ "${HTTP_CODE}" == "200" ]] && break
    sleep 5; (( POLL_WAITED += 5 ))
    echo "    ${POLL_WAITED}s — HTTP ${HTTP_CODE}..."
done

echo "  GET /server-info/ via IHS → HTTP ${HTTP_CODE}"
echo ""

if [[ "${HTTP_CODE}" == "200" ]]; then
    echo "=== Liberty Dynamic Routing (Intelligent Management) is active ==="
    echo ""
    echo "  IHS:8080 → controller:${CONTROLLER_HTTPS}/ibm/api/dynamicRouting"
    echo "             → all healthy collective members (live routing table)"
    echo ""
    echo "  Members are discovered automatically — no script re-run needed"
    echo "  when members are added, removed, started, or stopped."
    echo ""
    echo "  Verify round-robin across members (run several times):"
    echo "    for i in \$(seq 6); do curl -s http://localhost:8080/server-info/ | grep -o 'member[0-9]*'; done"
    echo ""
    echo "  Plugin log  : tail -f ${IHS_ROOT}/logs/plugin.log"
    echo "  Plugin cfg  : ${PLUGIN_CFG}"
    echo "  Admin Center: https://localhost:${CONTROLLER_HTTPS}/adminCenter"
else
    echo "  WARNING: Routing returned HTTP ${HTTP_CODE} after 30 s."
    echo "           The plugin may still be connecting to /ibm/api/dynamicRouting."
    echo "           Wait 60 s and retry: curl http://localhost:8080/server-info/"
    echo ""
    echo "  Diagnose:"
    echo "    tail -50 ${IHS_ROOT}/logs/plugin.log"
    echo "    tail -30 ${IHS_ROOT}/logs/error_log"
    echo "    tail -30 ${MESSAGES_LOG}"
fi
echo ""
