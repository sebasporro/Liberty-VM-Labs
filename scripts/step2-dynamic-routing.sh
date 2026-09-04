#!/bin/bash
# =============================================================================
# step2-dynamic-routing.sh
# Enables Liberty Dynamic Routing on the Collective Controller and updates
# plugin-cfg.xml so the controller handles all routing decisions automatically.
#
# Architecture after this step:
#   Browser → IHS:8080 → WAS plugin → controller:9080 (dynamicRouting-1.0)
#                                           ↓  routes dynamically
#                                    member1 / member2 / memberN
#
# What this script does:
#   1. Adds dynamicRouting-1.0 feature to the controller via configDropins
#   2. Restarts the controller and waits for it to be ready
#   3. Rewrites plugin-cfg.xml to point at the controller as dynamic router
#   4. Updates WebSpherePluginConfig in httpd.conf to the new file
#   5. Restarts IHS
#   6. Verifies end-to-end routing
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/IBM/HTTPServer}"
HTTPD_CONF="${IHS_ROOT}/conf/httpd.conf"
PLUGIN_CFG="${IHS_ROOT}/conf/plugin-cfg.xml"
APACHECTL="${IHS_ROOT}/bin/apachectl"

CONTROLLER_DIR="${WORKSPACE_ROOT}/installs/controller"
SERVER_DIR="${CONTROLLER_DIR}/wlp/usr/servers/controller"
WLP_BIN="${CONTROLLER_DIR}/wlp/bin/server"
OVERRIDES_DIR="${SERVER_DIR}/configDropins/overrides"
MESSAGES_LOG="${SERVER_DIR}/logs/messages.log"

CONTROLLER_HTTP=9080

echo ""
echo "=== Step 2: Enable Liberty Dynamic Routing ==="
echo ""

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
echo "[0/6] Pre-flight checks..."

if [[ ! -x "${WLP_BIN}" ]]; then
    echo "ERROR: Controller not installed at ${CONTROLLER_DIR}"
    exit 1
fi

if ! ss -tlnp 2>/dev/null | grep -q ":${CONTROLLER_HTTP} "; then
    echo "ERROR: Controller is not running on port ${CONTROLLER_HTTP}."
    echo "       Start it: ${WLP_BIN} start controller"
    exit 1
fi
echo "      Controller: running on port ${CONTROLLER_HTTP}"

RUNNING_MEMBERS=0
for member_dir in "${WORKSPACE_ROOT}/installs"/member*/; do
    member_name=$(basename "${member_dir}")
    member_bin="${member_dir}/wlp/bin/server"
    if [[ -x "${member_bin}" ]]; then
        STATUS=$("${member_bin}" status "${member_name}" 2>/dev/null)
        echo "${STATUS}" | grep -q "is running" && (( RUNNING_MEMBERS++ ))
    fi
done

if [[ ${RUNNING_MEMBERS} -eq 0 ]]; then
    echo "ERROR: No Liberty member servers are running."
    exit 1
fi
echo "      Members running: ${RUNNING_MEMBERS}"
echo ""

# ---------------------------------------------------------------------------
# 1. Add dynamicRouting-1.0 feature override to the controller
# ---------------------------------------------------------------------------
echo "[1/6] Adding dynamicRouting-1.0 to controller..."
mkdir -p "${OVERRIDES_DIR}"

DYNAMIC_ROUTING_XML="${OVERRIDES_DIR}/dynamic-routing.xml"

if [[ -f "${DYNAMIC_ROUTING_XML}" ]]; then
    echo "      Already present — skipped"
else
    cat > "${DYNAMIC_ROUTING_XML}" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<server description="Dynamic Routing feature override">
    <featureManager>
        <feature>dynamicRouting-1.0</feature>
    </featureManager>
</server>
EOF
    echo "      Written: ${DYNAMIC_ROUTING_XML}"
fi
echo ""

# ---------------------------------------------------------------------------
# 2. Restart controller to load the new feature
# ---------------------------------------------------------------------------
echo "[2/6] Restarting controller to load dynamicRouting-1.0..."
"${WLP_BIN}" stop controller 2>/dev/null
sleep 3
"${WLP_BIN}" start controller

echo "      Waiting for controller ready (up to 60s)..."
WAITED=0
while [[ ${WAITED} -lt 60 ]]; do
    grep -q "server is ready" "${MESSAGES_LOG}" 2>/dev/null && break
    sleep 2; (( WAITED += 2 ))
done

if [[ ${WAITED} -ge 60 ]]; then
    echo "WARNING: Timeout waiting for controller. Check: ${MESSAGES_LOG}"
fi

if grep -q "dynamicRouting-1.0" "${MESSAGES_LOG}" 2>/dev/null; then
    echo "      dynamicRouting-1.0: loaded ✓"
else
    echo "WARNING: dynamicRouting-1.0 may not have loaded. Check: ${MESSAGES_LOG}"
fi
echo ""

# ---------------------------------------------------------------------------
# 3. Rewrite plugin-cfg.xml — controller as dynamic router (HTTP only)
# ---------------------------------------------------------------------------
echo "[3/6] Writing plugin-cfg.xml (controller as dynamic router)..."

cat > "${PLUGIN_CFG}" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!--
  Liberty WAS Plugin — dynamic routing
  All requests go to the controller (${CONTROLLER_HTTP}).
  dynamicRouting-1.0 on the controller forwards to available members.
-->
<Config ASDisableNagle="false" AcceptAllContent="false"
        AppServerPortPreference="HostHeader" ChunkedResponse="false"
        FIPSEnable="false" IISDisableNagle="false" IISPluginPriority="High"
        IgnoreDNSFailures="false" RefreshInterval="60" ResponseChunkSize="64"
        SSLConsolidatedConfig="false" TrustedProxyEnable="false"
        VHostMatchingCompat="false">

    <Log LogLevel="Error" Name="${IHS_ROOT}/logs/plugin.log"/>

    <Property Name="ESIEnable"                   Value="false"/>
    <Property Name="ESIMaxCacheSize"              Value="1024"/>
    <Property Name="ESIInvalidationMonitor"       Value="false"/>
    <Property Name="ESIEnableRecursiveInclude"    Value="false"/>
    <Property Name="ESIMaxRecursiveIncludeDepth"  Value="10"/>

    <ServerCluster CloneSeparatorChange="false" GetDWLMTable="false"
                   IgnoreAffinityRequests="true" LoadBalance="Round Robin"
                   Name="LibertyCluster" PostSizeLimit="-1"
                   RemoveSpecialHeaders="true" RetryInterval="60">

        <Server CloneID="controller" ConnectTimeout="5" ExtendedHandshake="false"
                MaxConnections="-1" Name="controller_${CONTROLLER_HTTP}"
                ServerIOTimeout="900" WaitForContinue="false">
            <Transport Hostname="localhost" Port="${CONTROLLER_HTTP}" Protocol="http"/>
        </Server>

        <PrimaryServers>
            <Server Name="controller_${CONTROLLER_HTTP}"/>
        </PrimaryServers>

    </ServerCluster>

    <UriGroup Name="LibertyCluster_URIs">
        <Uri AffinityCookie="JSESSIONID" AffinityURLIdentifier="jsessionid" Name="/*"/>
    </UriGroup>

    <VirtualHostGroup Name="LibertyHosts">
        <VirtualHost Name="*:8080"/>
    </VirtualHostGroup>

    <Route ServerCluster="LibertyCluster"
           UriGroup="LibertyCluster_URIs"
           VirtualHostGroup="LibertyHosts"/>

</Config>
EOF

echo "      Written: ${PLUGIN_CFG}"

# ---------------------------------------------------------------------------
# 4. Ensure WebSpherePluginConfig in httpd.conf points to the right file
# ---------------------------------------------------------------------------
echo "[4/6] Ensuring WebSpherePluginConfig in httpd.conf..."

if grep -q "^WebSpherePluginConfig" "${HTTPD_CONF}"; then
    sed -i "s|^WebSpherePluginConfig .*|WebSpherePluginConfig ${PLUGIN_CFG}|" "${HTTPD_CONF}"
    echo "      WebSpherePluginConfig: updated"
else
    echo "" >> "${HTTPD_CONF}"
    echo "# WAS plugin routing — added by step2-dynamic-routing.sh" >> "${HTTPD_CONF}"
    echo "WebSpherePluginConfig ${PLUGIN_CFG}" >> "${HTTPD_CONF}"
    echo "      WebSpherePluginConfig: added"
fi
echo ""

# ---------------------------------------------------------------------------
# 5. Config test + restart IHS
# ---------------------------------------------------------------------------
echo "[5/6] Restarting IHS..."
RESULT=$("${APACHECTL}" configtest 2>&1)
if ! echo "${RESULT}" | grep -q "Syntax OK"; then
    echo "ERROR: httpd.conf syntax error:"
    echo "${RESULT}"
    exit 1
fi
echo "      Syntax OK"

if ss -tlnp 2>/dev/null | grep -q ":8080 "; then
    "${APACHECTL}" stop && sleep 2
fi
"${APACHECTL}" start
sleep 1

if ! ss -tlnp 2>/dev/null | grep -q ":8080 "; then
    echo "ERROR: IHS failed to start. Check: ${IHS_ROOT}/logs/error_log"
    tail -20 "${IHS_ROOT}/logs/error_log"
    exit 1
fi
echo "      IHS running on port 8080"
echo ""

# ---------------------------------------------------------------------------
# 6. Verify end-to-end routing
# ---------------------------------------------------------------------------
echo "[6/6] Verifying routing..."
sleep 2

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/server-info/ 2>/dev/null)
echo "      GET /server-info/ via IHS: HTTP ${HTTP_CODE}"

if [[ "${HTTP_CODE}" == "200" ]]; then
    echo ""
    echo "=== Step 2 complete — Dynamic routing is active ==="
else
    echo ""
    echo "  HTTP ${HTTP_CODE} — check logs:"
    echo "    tail -30 ${IHS_ROOT}/logs/error_log"
    echo "    tail -30 ${IHS_ROOT}/logs/plugin.log"
    echo "    tail -30 ${MESSAGES_LOG}"
fi

echo ""
echo "  Controller: http://localhost:${CONTROLLER_HTTP}/server-info/"
echo "  Admin Center: https://localhost:9443/adminCenter  (admin / admin)"
echo "  Plugin log: ${IHS_ROOT}/logs/plugin.log"
echo ""
echo "  Members joining the collective are now routed automatically."
echo ""
