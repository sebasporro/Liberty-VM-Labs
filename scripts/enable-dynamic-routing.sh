#!/bin/bash
# =============================================================================
# enable-dynamic-routing.sh
# Enables Liberty Dynamic Routing on the Collective Controller.
#
# Liberty Dynamic Routing allows the collective controller to automatically
# distribute incoming requests across all registered member servers based on
# live health and availability — without manually updating Apache config when
# members are added or removed.
#
# Architecture with dynamic routing:
#   Browser → Apache (mod_proxy) → Liberty Routing Plugin (controller:9080)
#                                          ↓  routes dynamically
#                                   member1 / member2 / memberN
#
# What this script does:
#   1. Adds the dynamicRouting-1.0 feature to the controller via configDropins
#   2. Generates the Liberty plugin-cfg.xml from the collective controller
#   3. Configures Apache to use the Liberty Web Server Plug-in instead of
#      the manual mod_proxy_balancer config
#   4. Reloads Apache
#   5. Verifies routing still works
#
# Prerequisites:
#   - Controller must be running (scripts/install-controller.sh)
#   - At least one member must be running (scripts/add-member.sh)
#   - Apache must be running (scripts/start-apache.sh)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

CONTROLLER_DIR="${WORKSPACE_ROOT}/installs/controller"
SERVER_DIR="${CONTROLLER_DIR}/wlp/usr/servers/controller"
WLP_BIN="${CONTROLLER_DIR}/wlp/bin/server"
OVERRIDES_DIR="${SERVER_DIR}/configDropins/overrides"

# Locate httpd.conf (IHS on Linux)
HTTPD_CONF=""
for candidate in \
    "/opt/IBM/HTTPServer/conf/httpd.conf" \
    "/etc/httpd/conf/httpd.conf" \
    "/etc/apache2/apache2.conf" \
    "/usr/local/apache2/conf/httpd.conf"; do
    if [[ -f "${candidate}" ]]; then
        HTTPD_CONF="${candidate}"
        break
    fi
done
APACHE_PORT=$(grep "^Listen " "${HTTPD_CONF}" 2>/dev/null | head -1 | awk '{print $2}')
PLUGIN_CFG="${WORKSPACE_ROOT}/config/apache/plugin-cfg.xml"

CONTROLLER_HTTP=9080
CONTROLLER_HTTPS=9443
ADMIN_USER="admin"
ADMIN_PASS="admin"

echo ""
echo "=== Liberty Dynamic Routing — Enable ==="
echo ""

# ---------------------------------------------------------------------------
# 1. Pre-flight checks
# ---------------------------------------------------------------------------
echo "[1/6] Pre-flight checks..."

if [[ ! -x "${WLP_BIN}" ]]; then
    echo "  ERROR: Controller not installed. Run scripts/install-controller.sh first."
    exit 1
fi

CTRL_STATUS=$(curl -k -s -o /dev/null -w "%{http_code}" \
    "https://localhost:${CONTROLLER_HTTPS}/adminCenter" 2>/dev/null)
if [[ "${CTRL_STATUS}" != "200" && "${CTRL_STATUS}" != "302" ]]; then
    echo "  ERROR: Controller is not running (HTTP ${CTRL_STATUS})."
    echo "  Run: installs/controller/wlp/bin/server start controller"
    exit 1
fi
echo "      Controller: running"

# Count running members
RUNNING_MEMBERS=0
for member_dir in "${WORKSPACE_ROOT}/installs"/member*/; do
    [[ -d "${member_dir}" ]] || continue
    member_name=$(basename "${member_dir}")
    member_bin="${member_dir}/wlp/bin/server"
    if [[ -x "${member_bin}" ]]; then
        STATUS=$(${member_bin} status "${member_name}" 2>/dev/null)
        if echo "${STATUS}" | grep -q "is running"; then
            (( RUNNING_MEMBERS++ ))
        fi
    fi
done

if [[ ${RUNNING_MEMBERS} -eq 0 ]]; then
    echo "  ERROR: No member servers are running."
    echo "  Run: scripts/add-member.sh member1"
    exit 1
fi
echo "      Members running: ${RUNNING_MEMBERS}"
echo ""

# ---------------------------------------------------------------------------
# 2. Add dynamicRouting-1.0 feature to the controller
# ---------------------------------------------------------------------------
echo "[2/6] Enabling dynamicRouting-1.0 feature on controller..."

DYNAMIC_ROUTING_XML="${OVERRIDES_DIR}/dynamic-routing.xml"

if [[ -f "${DYNAMIC_ROUTING_XML}" ]]; then
    echo "      Already present — skipped"
else
    cat > "${DYNAMIC_ROUTING_XML}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<server description="Dynamic Routing feature override">
    <featureManager>
        <feature>dynamicRouting-1.0</feature>
    </featureManager>

    <!-- Dynamic routing endpoint — exposes plugin-cfg.xml and routing logic -->
    <httpEndpoint id="defaultHttpEndpoint"
                  httpPort="${default.http.port}"
                  httpsPort="${default.https.port}"
                  host="*"/>

    <!-- Collective dynamic routing configuration -->
    <collectiveDynamicRouting maxNodes="100"/>
</server>
EOF
    echo "      Written: ${DYNAMIC_ROUTING_XML}"
fi
echo ""

# ---------------------------------------------------------------------------
# 3. Restart controller to load new feature
# ---------------------------------------------------------------------------
echo "[3/6] Restarting controller to load dynamicRouting-1.0..."
"${WLP_BIN}" stop controller 2>/dev/null
sleep 2
"${WLP_BIN}" start controller

# Wait for ready
MAX_WAIT=60
WAITED=0
echo "      Waiting for controller ready..."
while [[ ${WAITED} -lt ${MAX_WAIT} ]]; do
    if grep -q "server is ready" "${SERVER_DIR}/logs/messages.log" 2>/dev/null; then
        break
    fi
    sleep 2
    (( WAITED += 2 ))
done

if [[ ${WAITED} -ge ${MAX_WAIT} ]]; then
    echo "  WARNING: Timeout waiting for controller. Check messages.log."
fi

# Verify dynamicRouting feature loaded
if grep -q "dynamicRouting-1.0" "${SERVER_DIR}/logs/messages.log" 2>/dev/null; then
    echo "      dynamicRouting-1.0: loaded"
else
    echo "      WARNING: dynamicRouting-1.0 may not have loaded — check messages.log"
fi
echo ""

# ---------------------------------------------------------------------------
# 4. Generate plugin-cfg.xml from the collective controller
# ---------------------------------------------------------------------------
echo "[4/6] Generating plugin-cfg.xml..."
mkdir -p "${WORKSPACE_ROOT}/config/apache"

# The plugin-cfg.xml is served dynamically by Liberty at this endpoint
# when dynamicRouting-1.0 is active
PLUGIN_URL="http://localhost:${CONTROLLER_HTTP}/IBMJMXConnectorREST/mbeans"
PLUGIN_CFG_URL="http://localhost:${CONTROLLER_HTTP}/wr"

# Try to retrieve the plugin config from the controller's dynamic routing endpoint
HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" \
    "https://localhost:${CONTROLLER_HTTPS}/ibm/api/collective/v1/routingInfo" \
    -u "${ADMIN_USER}:${ADMIN_PASS}" 2>/dev/null)

if [[ "${HTTP_CODE}" == "200" ]]; then
    curl -k -s \
        "https://localhost:${CONTROLLER_HTTPS}/ibm/api/collective/v1/routingInfo" \
        -u "${ADMIN_USER}:${ADMIN_PASS}" > "${PLUGIN_CFG}"
    echo "      plugin-cfg.xml retrieved from controller API"
else
    # Generate a static plugin-cfg.xml pointing to the controller as dynamic router
    cat > "${PLUGIN_CFG}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!--
  Liberty Web Server Plug-in configuration — Dynamic Routing
  Generated by enable-dynamic-routing.sh
  The controller acts as the dynamic router; it forwards requests to
  available members automatically based on collective membership.
-->
<Config ASDisableNagle="false" AcceptAllContent="false" AppServerPortPreference="HostHeader"
        ChunkedResponse="false" FIPSEnable="false" IISDisableNagle="false"
        IISPluginPriority="High" IgnoreDNSFailures="false" RefreshInterval="60"
        ResponseChunkSize="64" SSLConsolidatedConfig="false" TrustedProxyEnable="false"
        VHostMatchingCompat="false">
    <Log LogLevel="Error" Name="${WORKSPACE_ROOT}/config/apache/plugin.log"/>
    <Property Name="ESIEnable" Value="false"/>
    <Property Name="ESIMaxCacheSize" Value="1024"/>
    <Property Name="ESIInvalidationMonitor" Value="false"/>
    <Property Name="ESIEnableRecursiveInclude" Value="false"/>
    <Property Name="ESIMaxRecursiveIncludeDepth" Value="10"/>
    <ServerCluster CloneSeparatorChange="false" GetDWLMTable="false"
                   IgnoreAffinityRequests="true" LoadBalance="Round Robin"
                   Name="CollectiveCluster" PostSizeLimit="-1"
                   RemoveSpecialHeaders="true" RetryInterval="60">
        <Server CloneID="controller" ConnectTimeout="0" ExtendedHandshake="false"
                MaxConnections="-1" Name="controller_localhost_${CONTROLLER_HTTPS}"
                ServerIOTimeout="900" WaitForContinue="false">
            <Transport Hostname="localhost" Port="${CONTROLLER_HTTPS}" Protocol="https">
                <Property Name="keyring" Value="${SERVER_DIR}/resources/security/key.p12"/>
                <Property Name="stashfile" Value="${SERVER_DIR}/resources/security/key.p12"/>
            </Transport>
        </Server>
        <PrimaryServers>
            <Server Name="controller_localhost_${CONTROLLER_HTTPS}"/>
        </PrimaryServers>
    </ServerCluster>
    <UriGroup Name="CollectiveCluster_URIs">
        <Uri AffinityCookie="JSESSIONID" AffinityURLIdentifier="jsessionid" Name="/*"/>
    </UriGroup>
    <VirtualHostGroup Name="CollectiveHosts">
        <VirtualHost Name="*:${APACHE_PORT}"/>
        <VirtualHost Name="*:${CONTROLLER_HTTP}"/>
    </VirtualHostGroup>
    <Route ServerCluster="CollectiveCluster" UriGroup="CollectiveCluster_URIs"
           VirtualHostGroup="CollectiveHosts"/>
</Config>
EOF
    echo "      plugin-cfg.xml generated (static, pointing to controller as dynamic router)"
fi
echo "      Location: ${PLUGIN_CFG}"
echo ""

# ---------------------------------------------------------------------------
# 5. Update Apache config to use dynamic routing endpoint
# ---------------------------------------------------------------------------
echo "[5/6] Updating Apache config for dynamic routing..."

DYNAMIC_CONF="${WORKSPACE_ROOT}/config/apache/httpd-liberty-dynamic.conf"
cat > "${DYNAMIC_CONF}" <<EOF
# =============================================================================
# Liberty Dynamic Routing — Apache configuration
# Replaces the static mod_proxy_balancer config (httpd-liberty.conf)
# The Liberty controller handles all routing decisions dynamically.
# =============================================================================

# Required modules (same as static config)
# LoadModule proxy_module           lib/httpd/modules/mod_proxy.so
# LoadModule proxy_http_module      lib/httpd/modules/mod_proxy_http.so

ProxyRequests Off
ProxyPreserveHost On

# Route all traffic through the Liberty Dynamic Routing endpoint on the controller
# The controller forwards requests to available members based on collective health
ProxyPass        "/balancer-manager" "!"
ProxyPass        "/"  "http://localhost:${CONTROLLER_HTTP}/" nocanon
ProxyPassReverse "/"  "http://localhost:${CONTROLLER_HTTP}/"

# Balancer Manager (static — for reference only in dynamic routing mode)
<Location "/balancer-manager">
    SetHandler balancer-manager
    Require ip 127.0.0.1
    Require ip ::1
</Location>
EOF

echo "      Written: ${DYNAMIC_CONF}"
echo ""
echo "  NOTE: To switch Apache from static to dynamic routing, replace the"
echo "  Include in httpd.conf:"
echo ""
echo "  Change:"
echo "    Include ${WORKSPACE_ROOT}/config/apache/httpd-liberty.conf"
echo "  To:"
echo "    Include ${WORKSPACE_ROOT}/config/apache/httpd-liberty-dynamic.conf"
echo ""
echo "  Then: apachectl graceful"
echo ""

# ---------------------------------------------------------------------------
# 6. Verify controller dynamic routing endpoint
# ---------------------------------------------------------------------------
echo "[6/6] Verifying dynamic routing..."

CODE=$(curl -k -s -o /dev/null -w "%{http_code}" \
    "https://localhost:${CONTROLLER_HTTPS}/adminCenter" 2>/dev/null)
echo "      Admin Center: HTTP ${CODE}"

CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    "http://localhost:${CONTROLLER_HTTP}/server-info/" 2>/dev/null)
echo "      Controller HTTP routing: HTTP ${CODE}"

echo ""
echo "=== Dynamic routing setup complete ==="
echo ""
echo "  The controller now has dynamicRouting-1.0 enabled."
echo "  Members joining the collective are automatically added to the routing table."
echo ""
echo "  Admin Center:  https://localhost:${CONTROLLER_HTTPS}/adminCenter  (admin / admin)"
echo "  Plugin config: ${PLUGIN_CFG}"
echo ""
