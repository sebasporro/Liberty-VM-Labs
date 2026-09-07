#!/bin/bash
# =============================================================================
# step2-dynamic-routing.sh  —  Step 3b: Enable Dynamic Routing
#
# Enables Liberty Collective Dynamic Routing by:
#   1. Adding dynamicRouting-1.0 to the controller (already in role-override.xml)
#   2. Writing plugin-cfg.xml with <IntelligentManagement> pointing to the
#      controller's /ibm/api/dynamicRouting endpoint on HTTP:9080
#   3. Restarting IHS with the new plugin-cfg.xml
#
# This approach builds plugin-cfg.xml directly instead of using
# 'dynamicRouting setup', which requires GSKit certificate trust between
# the plugin keystore and the collective PKI — not available in this
# single-VM archive-based install.
#
# Prerequisites:
#   - scripts/install-controller.sh completed
#   - scripts/add-member-26.sh member1/member2 completed
#   - scripts/reset-ihs.sh + scripts/step1-was-plugin.sh completed (3a working)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/IBM/HTTPServer}"
HTTPD_CONF="${IHS_ROOT}/conf/httpd.conf"
APACHECTL="${IHS_ROOT}/bin/apachectl"
PLUGIN_CFG="${IHS_ROOT}/config/webserver1/plugin-cfg.xml"
PLUGIN_LOG_DIR="${IHS_ROOT}/logs/webserver1"

CTRL_HOST="localhost"
CTRL_HTTP=9080
CTRL_HTTPS=9443
WEB_SERVER_NAME="webserver1"

echo ""
echo "=== Step 3b: Liberty Collective Dynamic Routing ==="
echo ""

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
echo "[1/3] Pre-flight checks..."

# Controller must be running
ss -tlnp 2>/dev/null | grep -q ":${CTRL_HTTP} " \
    || { echo "  ERROR: controller not running on port ${CTRL_HTTP}"; exit 1; }
echo "  Controller : running ✓"

# IHS must have a httpd.conf
[[ -f "${HTTPD_CONF}" ]] \
    || { echo "  ERROR: httpd.conf missing — run scripts/reset-ihs.sh first"; exit 1; }

# Discover running members
MEMBER_PORTS=()
MEMBER_NAMES=()
for i in 1 2 3 4 5 6 7 8 9; do
    port=$(( 9080 + i ))
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        MEMBER_PORTS+=("${port}")
        MEMBER_NAMES+=("member${i}")
        echo "  member${i} : port ${port} ✓"
    fi
done

[[ ${#MEMBER_PORTS[@]} -gt 0 ]] \
    || { echo "  ERROR: no members running on ports 9081-9089"; exit 1; }
echo ""

# ---------------------------------------------------------------------------
# Step 1 — confirm dynamicRouting-1.0 is loaded on controller
#   (it is declared in config/controller/role-override.xml which is deployed
#    by install-controller.sh — no dropin needed)
# ---------------------------------------------------------------------------
echo "[2/3] Checking dynamicRouting-1.0 on controller..."

MESSAGES_LOG="${WORKSPACE_ROOT}/installs/controller/wlp/usr/servers/controller/logs/messages.log"
if grep -q "CWWKF0012I.*dynamicRouting-1.0" "${MESSAGES_LOG}" 2>/dev/null; then
    echo "  dynamicRouting-1.0 : active ✓"
else
    echo "  WARNING: dynamicRouting-1.0 not found in messages.log"
    echo "  Verify it is in config/controller/role-override.xml and controller is running"
fi

# Verify /ibm/api/dynamicRouting is reachable on HTTP
DR_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    "http://${CTRL_HOST}:${CTRL_HTTP}/ibm/api/dynamicRouting" 2>/dev/null)
if [[ "${DR_CODE}" == "200" || "${DR_CODE}" == "302" || "${DR_CODE}" == "401" || "${DR_CODE}" == "403" ]]; then
    echo "  /ibm/api/dynamicRouting : reachable (HTTP ${DR_CODE}) ✓"
else
    echo "  ERROR: /ibm/api/dynamicRouting not reachable (HTTP ${DR_CODE})"
    echo "  The dynamicRouting-1.0 feature may not be loaded on the controller"
    exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# Step 2 — write plugin-cfg.xml with IntelligentManagement
#
# Build the file directly — no 'dynamicRouting setup' needed.
# The <IntelligentManagement> block is what tells the WAS plugin to use ODR.
# The <ServerCluster> contains the real member servers as a fallback;
# ODR will dynamically manage routing once connected.
# ---------------------------------------------------------------------------
echo "[3/3] Writing plugin-cfg.xml and restarting IHS..."

mkdir -p "${IHS_ROOT}/config/${WEB_SERVER_NAME}"
mkdir -p "${PLUGIN_LOG_DIR}"

# Build Server blocks for all running members
SERVER_BLOCKS=""
PRIMARY_LIST=""
for idx in "${!MEMBER_NAMES[@]}"; do
    name="${MEMBER_NAMES[$idx]}"
    port="${MEMBER_PORTS[$idx]}"
    SERVER_BLOCKS+="
        <Server CloneID=\"${name}\" ConnectTimeout=\"5\" ExtendedHandshake=\"false\"
                MaxConnections=\"-1\" Name=\"${name}\" ServerIOTimeout=\"900\" WaitForContinue=\"false\">
            <Transport Hostname=\"localhost\" Port=\"${port}\" Protocol=\"http\"/>
        </Server>"
    PRIMARY_LIST+="            <Server Name=\"${name}\"/>\n"
done

cat > "${PLUGIN_CFG}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!--
  Liberty WAS Plugin — Dynamic Routing (ODR) mode
  Generated by step2-dynamic-routing.sh on $(date)
  ODR endpoint: http://${CTRL_HOST}:${CTRL_HTTP}/ibm/api/dynamicRouting
-->
<Config ASDisableNagle="false" AcceptAllContent="false"
        AppServerPortPreference="HostHeader" ChunkedResponse="false"
        FIPSEnable="false" IISDisableNagle="false" IISPluginPriority="High"
        IgnoreDNSFailures="false" RefreshInterval="60" ResponseChunkSize="64"
        SSLConsolidate="false" TrustedProxyEnable="false" VHostMatchingCompat="false">

    <Log LogLevel="Error" Name="${IHS_ROOT}/logs/${WEB_SERVER_NAME}/http_plugin.log"/>

    <Property Name="ESIEnable"              Value="false"/>
    <Property Name="ESIMaxCacheSize"         Value="1024"/>
    <Property Name="ESIInvalidationMonitor" Value="false"/>
    <Property Name="PluginInstallRoot"       Value="${IHS_ROOT}/"/>

    <IntelligentManagement>
        <Property name="webserverName" value="${WEB_SERVER_NAME}"/>
        <ConnectorCluster enabled="true" maxRetries="-1"
                          name="defaultCollective" retryInterval="60">
            <Property name="uri" value="/ibm/api/dynamicRouting"/>
            <Connector host="${CTRL_HOST}" port="${CTRL_HTTP}" protocol="http">
            </Connector>
        </ConnectorCluster>
        <Property name="RoutingRulesConnectorClusterName" value="defaultCollective"/>
    </IntelligentManagement>

    <ServerCluster CloneSeparatorChange="false" GetDWLMTable="false"
                   IgnoreAffinityRequests="true" LoadBalance="Round Robin"
                   Name="defaultCollective" PostSizeLimit="-1"
                   RemoveSpecialHeaders="true" RetryInterval="60">
${SERVER_BLOCKS}

        <PrimaryServers>
$(printf "${PRIMARY_LIST}")        </PrimaryServers>

    </ServerCluster>

    <UriGroup Name="default_uri_group">
        <Uri AffinityCookie="JSESSIONID" AffinityURLIdentifier="jsessionid" Name="/*"/>
    </UriGroup>

    <VirtualHostGroup Name="default_vhost_group">
        <VirtualHost Name="*:8080"/>
    </VirtualHostGroup>

    <Route ServerCluster="defaultCollective"
           UriGroup="default_uri_group"
           VirtualHostGroup="default_vhost_group"/>

</Config>
EOF

echo "  Written: ${PLUGIN_CFG}"

# Point httpd.conf at the new file (idempotent)
if grep -q "^WebSpherePluginConfig" "${HTTPD_CONF}"; then
    sed -i "s|^WebSpherePluginConfig.*|WebSpherePluginConfig ${PLUGIN_CFG}|" "${HTTPD_CONF}"
else
    printf '\nWebSpherePluginConfig %s\n' "${PLUGIN_CFG}" >> "${HTTPD_CONF}"
fi
echo "  WebSpherePluginConfig: ${PLUGIN_CFG}"

# Syntax check
"${APACHECTL}" configtest 2>&1 | grep -q "Syntax OK" \
    || { echo "  ERROR: httpd.conf syntax error"; "${APACHECTL}" configtest 2>&1; exit 1; }

# Restart IHS
"${APACHECTL}" stop 2>/dev/null; sleep 2
pkill -9 -f "${IHS_ROOT}/bin/httpd" 2>/dev/null; sleep 1
"${APACHECTL}" start; sleep 3

ss -tlnp 2>/dev/null | grep -q ":8080 " \
    || { echo "  ERROR: IHS failed to start"; tail -20 "${IHS_ROOT}/logs/error_log"; exit 1; }
echo "  IHS: running on port 8080 ✓"
echo ""

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
echo "  Verifying routing (up to 60 s)..."
HTTP_CODE="000"
for (( t=0; t<=60; t+=5 )); do
    [[ ${t} -gt 0 ]] && { sleep 5; echo "    ${t}s — HTTP ${HTTP_CODE}..."; }
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        http://localhost:8080/server-info/ 2>/dev/null)
    [[ "${HTTP_CODE}" == "200" ]] && break
done

echo ""
echo "  GET /server-info/ → HTTP ${HTTP_CODE}"
echo ""

if [[ "${HTTP_CODE}" == "200" ]]; then
    echo "=== Dynamic Routing is active ==="
    echo ""
    echo "  Verify round-robin:"
    echo "    for i in \$(seq 8); do curl -s http://localhost:8080/server-info/ | grep -o 'member[0-9]*'; done"
    echo ""
    echo "  Plugin log : tail -f ${PLUGIN_LOG_DIR}/http_plugin.log"
else
    echo "  Routing not confirmed (HTTP ${HTTP_CODE})"
    echo ""
    echo "  Plugin log:"
    tail -20 "${PLUGIN_LOG_DIR}/http_plugin.log" 2>/dev/null | sed 's/^/  /' \
        || echo "  (not yet created)"
    echo ""
    echo "  IHS error log:"
    grep -i "error\|warn" "${IHS_ROOT}/logs/error_log" 2>/dev/null | tail -5 | sed 's/^/  /'
fi
echo ""
