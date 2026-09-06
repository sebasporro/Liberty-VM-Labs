#!/bin/bash
# =============================================================================
# step2-dynamic-routing.sh  —  Liberty Collective Dynamic Routing (Step 3b)
#
# Reference:
#   https://www.ibm.com/docs/en/was-liberty/nd?topic=collectives-setting-up-dynamic-routing-liberty
#
# What this script does — exactly following IBM documentation:
#   1. Adds dynamicRouting-1.0 + restConnector-2.0 to the controller
#   2. Runs: dynamicRouting setup  (generates plugin-cfg.xml + plugin-key.p12)
#   3. Converts plugin-key.p12 → plugin-key.kdb (CMS) via gskcapicmd
#   4. Installs plugin-cfg.xml + key files to IHS config/webserver1/, sets WebSpherePluginConfig, restarts IHS
#
# Prerequisites:
#   - scripts/install-controller.sh completed (controller running on 9080/9443)
#   - scripts/add-member-26.sh member1 ... member4 completed (members running)
#   - scripts/install-ihs.sh completed (IHS + mod_was_ap24_http.so present)
#   - scripts/reset-ihs.sh run to give a clean httpd.conf baseline
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
CONTROLLER_DIR="${WORKSPACE_ROOT}/installs/controller"
CTRL_WLP="${CONTROLLER_DIR}/wlp"
CTRL_SERVER_DIR="${CTRL_WLP}/usr/servers/controller"
WLP_SERVER="${CTRL_WLP}/bin/server"
DR_BIN="${CTRL_WLP}/bin/dynamicRouting"
CTRL_OVERRIDES="${CTRL_SERVER_DIR}/configDropins/overrides"
MESSAGES_LOG="${CTRL_SERVER_DIR}/logs/messages.log"

IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/IBM/HTTPServer}"
HTTPD_CONF="${IHS_ROOT}/conf/httpd.conf"
APACHECTL="${IHS_ROOT}/bin/apachectl"
PLUGIN_KEY_DIR="${IHS_ROOT}/config/webserver1"
PLUGIN_CFG="${PLUGIN_KEY_DIR}/plugin-cfg.xml"
PLUGIN_LOG_DIR="${IHS_ROOT}/logs/webserver1"
GSKCAPICMD="${IHS_ROOT}/bin/gskcapicmd"
SCRATCH="${CTRL_SERVER_DIR}/resources/security/plugin-setup"

CTRL_HOST="localhost"
CTRL_HTTPS=9443
CTRL_HTTP=9080
ADMIN_USER="admin"
ADMIN_PASS="admin"
KS_PASS="Liberty26ctrl!"
WEB_SERVER_NAME="webserver1"

echo ""
echo "=== Step 3b: Liberty Collective Dynamic Routing ==="
echo ""

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
echo "[1/4] Pre-flight checks..."

[[ -x "${WLP_SERVER}" ]] \
    || { echo "  ERROR: controller not installed — run scripts/install-controller.sh"; exit 1; }

[[ -x "${DR_BIN}" ]] \
    || { echo "  ERROR: dynamicRouting binary missing at ${DR_BIN}"; exit 1; }
echo "  dynamicRouting : OK"

[[ -f "${IHS_ROOT}/modules/mod_was_ap24_http.so" ]] \
    || { echo "  ERROR: mod_was_ap24_http.so missing — run scripts/install-ihs.sh"; exit 1; }
echo "  WAS plugin     : OK"

[[ -x "${GSKCAPICMD}" ]] && "${GSKCAPICMD}" -version &>/dev/null \
    || { echo "  ERROR: gskcapicmd not functional at ${GSKCAPICMD}"; exit 1; }
echo "  gskcapicmd     : OK"

[[ -f "${HTTPD_CONF}" ]] \
    || { echo "  ERROR: httpd.conf missing — run scripts/reset-ihs.sh first"; exit 1; }

ss -tlnp 2>/dev/null | grep -q ":${CTRL_HTTP} " \
    || { echo "  ERROR: controller not running — run: ${WLP_SERVER} start controller"; exit 1; }
echo "  Controller     : running"

# Remove stale collective-join.xml from controller — it loads collectiveMember-1.0
# which conflicts with collectiveController-1.0 and blocks the DynamicRouting MBean
[[ -f "${CTRL_OVERRIDES}/collective-join.xml" ]] \
    && { rm -f "${CTRL_OVERRIDES}/collective-join.xml"; echo "  Removed stale collective-join.xml from controller"; }

echo "  Members up:"
for i in 1 2 3 4 5 6 7 8 9; do
    ss -tlnp 2>/dev/null | grep -q ":$(( 9080 + i )) " && echo "    member${i} :$(( 9080 + i ))"
done
echo ""

# ---------------------------------------------------------------------------
# Step 1 (IBM doc): Enable dynamicRouting-1.0 and restConnector-2.0
#
# dynamicRouting-1.0  — exposes /ibm/api/dynamicRouting on the controller;
#                       the plugin connects here to receive the live routing table
# restConnector-2.0   — required by dynamicRouting setup CLI to reach the
#                       DynamicRouting MBean via Liberty's REST JMX bridge
# ---------------------------------------------------------------------------
echo "[2/4] Enabling dynamicRouting-1.0 + restConnector-2.0 on controller..."

# The dynamicRouting REST service (/ibm/api/dynamicRouting) requires the
# connecting client (the IHS plugin) to authenticate with a certificate that
# maps to the administrator-role (CWWKV0020E if missing).
# Grant the administrator-role to all certificate-authenticated clients so the
# plugin cert accepted by the collective PKI is also accepted by the REST service.
mkdir -p "${CTRL_OVERRIDES}"
cat > "${CTRL_OVERRIDES}/dynamic-routing.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<server description="Dynamic routing features">
    <featureManager>
        <feature>dynamicRouting-1.0</feature>
        <feature>restConnector-2.0</feature>
    </featureManager>

    <!-- Grant administrator-role to certificate-authenticated clients.
         Required so the IHS plugin cert is accepted by /ibm/api/dynamicRouting.
         Without this the controller logs CWWKV0020E and the plugin gets HTTP 403/500. -->
    <administrator-role>
        <user>admin</user>
        <certificate>
            <cn>*</cn>
        </certificate>
    </administrator-role>
</server>
XML

# Restart controller so features activate; clear log for clean matching
> "${MESSAGES_LOG}" 2>/dev/null || true
"${WLP_SERVER}" stop controller 2>/dev/null || true
sleep 3
"${WLP_SERVER}" start controller

echo "  Waiting for controller ready (up to 90 s)..."
for (( w=0; w<90; w+=2 )); do
    grep -q "CWWKF0011I" "${MESSAGES_LOG}" 2>/dev/null && break
    sleep 2
done
grep -q "CWWKF0011I" "${MESSAGES_LOG}" 2>/dev/null \
    || { echo "  ERROR: controller did not reach ready state"; echo "  Check: ${MESSAGES_LOG}"; exit 1; }

grep -q "CWWKF0012I.*dynamicRouting-1.0" "${MESSAGES_LOG}" 2>/dev/null \
    && echo "  dynamicRouting-1.0 : active ✓" \
    || { echo "  ERROR: dynamicRouting-1.0 did not load"; grep "CWWKF" "${MESSAGES_LOG}" | tail -5; exit 1; }

grep -q "CWWKF0012I.*restConnector-2.0" "${MESSAGES_LOG}" 2>/dev/null \
    && echo "  restConnector-2.0  : active ✓" \
    || { echo "  ERROR: restConnector-2.0 did not load"; exit 1; }

echo "  Pausing 10 s for DynamicRouting MBean to register..."
sleep 10
echo ""

# ---------------------------------------------------------------------------
# Step 2 (IBM doc): Run dynamicRouting setup
#
# This command connects to the controller via HTTPS and generates:
#   plugin-cfg.xml   — routing config with <IntelligentManagement> stanza
#   plugin-key.p12   — PKCS12 keystore (controller cert + plugin key pair)
#
# IBM doc flags used:
#   --host / --port            controller HTTPS coordinates
#   --user / --password        collective admin user
#   --keystorePassword         password for the generated plugin-key.p12
#   --webServerName            logical name of this IHS instance in the collective
#   --pluginInstallRoot        IHS root — Liberty embeds the Keyfile path from this
#   --targetPath               where to write the output files
#   --autoAcceptCertificates   trust the controller's self-signed cert
# ---------------------------------------------------------------------------
echo "[3/4] Running dynamicRouting setup..."

rm -rf "${SCRATCH}"
mkdir -p "${SCRATCH}"
mkdir -p "${PLUGIN_KEY_DIR}"

# Probe whether this build uses --webServerName (singular, per IBM docs)
# or --webServerNames (plural, older builds)
_HELP=$("${DR_BIN}" setup --help 2>&1 || true)
if   echo "${_HELP}" | grep -q -- "--webServerName[^s]"; then WS_FLAG="--webServerName=${WEB_SERVER_NAME}"
elif echo "${_HELP}" | grep -q -- "--webServerNames";    then WS_FLAG="--webServerNames=${WEB_SERVER_NAME}"
else                                                          WS_FLAG=""
fi

"${DR_BIN}" setup \
    --host="${CTRL_HOST}" \
    --port="${CTRL_HTTPS}" \
    --user="${ADMIN_USER}" \
    --password="${ADMIN_PASS}" \
    --keystorePassword="${KS_PASS}" \
    ${WS_FLAG:+"${WS_FLAG}"} \
    --pluginInstallRoot="${IHS_ROOT}" \
    --targetPath="${SCRATCH}" \
    --autoAcceptCertificates

DR_RC=$?
[[ ${DR_RC} -ne 0 ]] \
    && { echo "  ERROR: dynamicRouting setup exited ${DR_RC}"; echo "  Check: ${MESSAGES_LOG}"; exit 1; }

GEN_CFG=$(find "${SCRATCH}" -name "plugin-cfg.xml" 2>/dev/null | head -1)
GEN_KEY=$(find "${SCRATCH}" -name "plugin-key.p12" 2>/dev/null | head -1)

[[ -f "${GEN_CFG}" ]] || { echo "  ERROR: plugin-cfg.xml not generated"; find "${SCRATCH}" -type f; exit 1; }
[[ -f "${GEN_KEY}" ]] || { echo "  ERROR: plugin-key.p12 not generated"; exit 1; }
echo "  plugin-cfg.xml : ${GEN_CFG}"
echo "  plugin-key.p12 : ${GEN_KEY}"
echo ""

# ---------------------------------------------------------------------------
# Step 3 (IBM doc): Convert plugin-key.p12 (PKCS12) → plugin-key.kdb (CMS)
#
# The WAS plugin requires the keystore in GSKit CMS (.kdb) format.
# gskcapicmd -stash also writes plugin-key.sth (stash file) which the
# plugin uses to unlock the keystore at runtime without a passphrase prompt.
# The .kdb/.sth/.rdb files must live at: pluginInstallRoot/config/webServerName/
# (Liberty embeds this exact path as the Keyfile stanza in plugin-cfg.xml)
# ---------------------------------------------------------------------------
echo "[4/4] Converting keystore and installing plugin-cfg.xml..."

rm -f "${PLUGIN_KEY_DIR}/plugin-key.kdb" \
      "${PLUGIN_KEY_DIR}/plugin-key.sth" \
      "${PLUGIN_KEY_DIR}/plugin-key.rdb"

"${GSKCAPICMD}" -keydb -convert \
    -pw "${KS_PASS}" \
    -db "${GEN_KEY}" \
    -old_format pkcs12 \
    -target "${PLUGIN_KEY_DIR}/plugin-key.kdb" \
    -new_format cms \
    -stash
[[ $? -eq 0 ]] || { echo "  ERROR: gskcapicmd -keydb -convert failed"; exit 1; }

# List certs so we know the exact label to use for setdefault
echo "  Certs in plugin-key.kdb:"
"${GSKCAPICMD}" -cert -list \
    -pw "${KS_PASS}" \
    -db "${PLUGIN_KEY_DIR}/plugin-key.kdb" 2>&1 | sed 's/^/    /'

# Set the first personal cert (-) as default — skip the legend header line and
# trusted/secret-key certs. Personal certs are marked with "- " prefix.
FIRST_LABEL=$("${GSKCAPICMD}" -cert -list \
    -pw "${KS_PASS}" \
    -db "${PLUGIN_KEY_DIR}/plugin-key.kdb" 2>/dev/null \
    | grep "^-[[:space:]]" | head -1 | sed 's/^-[[:space:]]*//')

if [[ -n "${FIRST_LABEL}" ]]; then
    "${GSKCAPICMD}" -cert -setdefault \
        -pw "${KS_PASS}" \
        -db "${PLUGIN_KEY_DIR}/plugin-key.kdb" \
        -label "${FIRST_LABEL}" 2>&1 \
        && echo "  Default cert set: ${FIRST_LABEL}" \
        || echo "  WARNING: setdefault failed for label '${FIRST_LABEL}' — continuing"
else
    echo "  WARNING: no certs found in plugin-key.kdb — ODR will fail to authenticate"
fi

echo "  plugin-key.kdb : ${PLUGIN_KEY_DIR}/plugin-key.kdb"
echo "  plugin-key.sth : ${PLUGIN_KEY_DIR}/plugin-key.sth"

# Permissions — IHS worker must be able to read the keystore files.
# chmod 644 ensures readability regardless of chown outcome.
chmod 644 \
    "${PLUGIN_KEY_DIR}/plugin-key.kdb" \
    "${PLUGIN_KEY_DIR}/plugin-key.sth" \
    "${PLUGIN_KEY_DIR}/plugin-key.rdb" 2>/dev/null || true

IHS_USER=$(awk '/^User /  {print $2}' "${HTTPD_CONF}" 2>/dev/null)
IHS_GRP=$(awk  '/^Group / {print $2}' "${HTTPD_CONF}" 2>/dev/null)
if [[ -n "${IHS_USER}" ]]; then
    chown "${IHS_USER}:${IHS_GRP:-${IHS_USER}}" \
        "${PLUGIN_KEY_DIR}/plugin-key.kdb" \
        "${PLUGIN_KEY_DIR}/plugin-key.sth" \
        "${PLUGIN_KEY_DIR}/plugin-key.rdb" 2>/dev/null \
        && echo "  Ownership set: ${IHS_USER}:${IHS_GRP:-${IHS_USER}}" \
        || echo "  WARNING: chown failed — files left as $(stat -c '%U' "${PLUGIN_KEY_DIR}/plugin-key.kdb" 2>/dev/null)"
fi

echo ""
echo "  Key file permissions:"
ls -la "${PLUGIN_KEY_DIR}/" | grep "plugin-key" | sed 's/^/    /'

# ---------------------------------------------------------------------------
# Install plugin-cfg.xml
#
# Three patches applied to the generated file:
#
#   (a) VirtualHost port — dynamicRouting setup defaults to port 80.
#       IHS in this lab listens on 8080. Patch every VirtualHost entry.
#
#   (b) Keyfile/Stashfile paths — Liberty embeds the path as
#         pluginInstallRoot/config/webServerName/plugin-key.kdb
#       Verify these point at the CMS files we just created.
#
#   (c) Log path — the IM plugin writes to
#         pluginInstallRoot/logs/webServerName/http_plugin.log
#       Create that directory so logs are visible.
# ---------------------------------------------------------------------------
mkdir -p "${PLUGIN_LOG_DIR}"
[[ -n "${IHS_USER}" ]] && chown "${IHS_USER}:${IHS_GRP:-${IHS_USER}}" "${PLUGIN_LOG_DIR}" 2>/dev/null || true

# Patch (a): fix VirtualHost port
sed -i "s|VirtualHost Name=\"\*:[0-9]*\"|VirtualHost Name=\"*:8080\"|g" "${GEN_CFG}"

# Show what we're installing
echo ""
echo "  --- plugin-cfg.xml (key sections) ---"
grep -E "IntelligentManagement|VirtualHost|Connector|Keyfile|Stashfile|Log Name" \
    "${GEN_CFG}" | sed 's/^/  /'
echo "  ---"
echo ""

cp "${GEN_CFG}" "${PLUGIN_CFG}"
echo "  Installed: ${PLUGIN_CFG}"

# WebSpherePluginConfig directive in httpd.conf (idempotent)
if grep -q "^WebSpherePluginConfig" "${HTTPD_CONF}"; then
    sed -i "s|^WebSpherePluginConfig.*|WebSpherePluginConfig ${PLUGIN_CFG}|" "${HTTPD_CONF}"
    echo "  WebSpherePluginConfig: updated"
else
    printf '\nWebSpherePluginConfig %s\n' "${PLUGIN_CFG}" >> "${HTTPD_CONF}"
    echo "  WebSpherePluginConfig: added"
fi

"${APACHECTL}" configtest 2>&1 | grep -q "Syntax OK" \
    || { echo "  ERROR: httpd.conf syntax error"; "${APACHECTL}" configtest 2>&1; exit 1; }
echo "  httpd.conf syntax: OK"

# Reliable IHS restart
"${APACHECTL}" stop 2>/dev/null; sleep 2
pkill -9 -f "${IHS_ROOT}/bin/httpd" 2>/dev/null; sleep 1
ss -tlnp 2>/dev/null | grep -q ":8080 " \
    && { echo "  ERROR: port 8080 still in use after stop"; exit 1; }
"${APACHECTL}" start; sleep 3
ss -tlnp 2>/dev/null | grep -q ":8080 " \
    || { echo "  ERROR: IHS failed to start"; tail -20 "${IHS_ROOT}/logs/error_log"; exit 1; }
echo "  IHS: running on port 8080"
echo ""

# ---------------------------------------------------------------------------
# Verify — allow 90 s for the plugin to connect to /ibm/api/dynamicRouting
# and receive its first routing table update
# ---------------------------------------------------------------------------
echo "  Verifying routing (up to 90 s)..."
HTTP_CODE="000"
for (( t=0; t<=90; t+=5 )); do
    [[ ${t} -gt 0 ]] && { sleep 5; echo "    ${t}s — HTTP ${HTTP_CODE}..."; }
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        http://localhost:8080/server-info/ 2>/dev/null)
    [[ "${HTTP_CODE}" == "200" ]] && break
    # Surface ODR init failure early so user doesn't wait the full 90 s
    if grep -q "initializeODR.*Failed" "${PLUGIN_LOG_DIR}/http_plugin.log" 2>/dev/null; then
        echo "  ERROR: ODR failed to initialize — keystore or connectivity issue"
        echo "  Plugin log (last 20 lines):"
        tail -20 "${PLUGIN_LOG_DIR}/http_plugin.log" | sed 's/^/    /'
        echo ""
        echo "  Keyfile check:"
        KEYFILE=$(grep -o 'Keyfile="[^"]*"' "${PLUGIN_CFG}" 2>/dev/null | head -1)
        echo "    plugin-cfg.xml says: ${KEYFILE}"
        ls -la "${PLUGIN_KEY_DIR}/plugin-key.kdb" 2>/dev/null | sed 's/^/    /' \
            || echo "    plugin-key.kdb NOT FOUND at ${PLUGIN_KEY_DIR}/"
        echo ""
        echo "  Controller /ibm/api/dynamicRouting reachable?"
        curl -k -s -o /dev/null -w "    HTTP %{http_code}\n" \
            -u "${ADMIN_USER}:${ADMIN_PASS}" \
            "https://${CTRL_HOST}:${CTRL_HTTPS}/ibm/api/dynamicRouting" 2>/dev/null
        break
    fi
done

echo ""
echo "  GET /server-info/ via IHS → HTTP ${HTTP_CODE}"
echo ""

if [[ "${HTTP_CODE}" == "200" ]]; then
    echo "=== Dynamic Routing is active ==="
    echo ""
    echo "  IHS:8080 → /ibm/api/dynamicRouting → all collective members"
    echo "  Members joining/leaving/restarting are reflected automatically."
    echo ""
    echo "  Verify round-robin:"
    echo "    for i in \$(seq 8); do curl -s http://localhost:8080/server-info/ | grep -o 'member[0-9]*'; done"
    echo ""
    echo "  Plugin log : tail -f ${PLUGIN_LOG_DIR}/http_plugin.log"
    echo "  Admin Center: https://${CTRL_HOST}:${CTRL_HTTPS}/adminCenter"
else
    echo "  HTTP ${HTTP_CODE} — routing not yet working."
    echo ""
    echo "  Plugin log:"
    tail -30 "${PLUGIN_LOG_DIR}/http_plugin.log" 2>/dev/null \
        | sed 's/^/    /' || echo "    (not yet created)"
    echo ""
    echo "  IHS error log:"
    grep -i "error\|warn" "${IHS_ROOT}/logs/error_log" 2>/dev/null | tail -10 | sed 's/^/    /'
    echo ""
    echo "  Restore static routing: scripts/reset-ihs.sh && scripts/step1-was-plugin.sh"
fi
echo ""
