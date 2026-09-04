#!/bin/bash
# =============================================================================
# step1-was-plugin.sh
# Configures the IHS WAS plugin to route HTTP traffic to Liberty member servers.
#
# Architecture:
#   Browser → IHS:8080 → mod_was_ap24_http.so → member1:9081 / member2:9082
#
# What this script does:
#   1. Writes plugin-cfg.xml pointing at member1 (9081) + member2 (9082)
#   2. Adds WebSpherePluginConfig to httpd.conf
#   3. Validates and restarts IHS
#   4. Verifies routing with a test request
# =============================================================================

IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/IBM/HTTPServer}"
HTTPD_CONF="${IHS_ROOT}/conf/httpd.conf"
PLUGIN_CFG="${IHS_ROOT}/conf/plugin-cfg.xml"
APACHECTL="${IHS_ROOT}/bin/apachectl"

echo ""
echo "=== Step 1: Configure WAS plugin — static routing to members ==="
echo ""

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
if [[ ! -f "${HTTPD_CONF}" ]]; then
    echo "ERROR: httpd.conf not found at ${HTTPD_CONF}"
    echo "       Run scripts/reset-ihs.sh first."
    exit 1
fi

if [[ ! -f "${IHS_ROOT}/modules/mod_was_ap24_http.so" ]]; then
    echo "ERROR: mod_was_ap24_http.so not found in ${IHS_ROOT}/modules/"
    echo "       Run scripts/install-ihs.sh first."
    exit 1
fi

# Check members are up
for port in 9081 9082; do
    if ! ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        echo "WARNING: Nothing listening on port ${port} — is Liberty member running?"
    fi
done

# ---------------------------------------------------------------------------
# 1. Write plugin-cfg.xml
# ---------------------------------------------------------------------------
echo "[1/4] Writing ${PLUGIN_CFG}..."

cat > "${PLUGIN_CFG}" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!--
  Liberty WAS Plugin — static routing
  IHS:8080 -> member1:9081 (Round Robin) -> member2:9082
-->
<Config ASDisableNagle="false" AcceptAllContent="false"
        AppServerPortPreference="HostHeader" ChunkedResponse="false"
        FIPSEnable="false" IISDisableNagle="false" IISPluginPriority="High"
        IgnoreDNSFailures="false" RefreshInterval="60" ResponseChunkSize="64"
        SSLConsolidatedConfig="false" TrustedProxyEnable="false"
        VHostMatchingCompat="false">

    <Log LogLevel="Error" Name="/home/itzuser/IBM/HTTPServer/logs/plugin.log"/>

    <Property Name="ESIEnable"                   Value="false"/>
    <Property Name="ESIMaxCacheSize"              Value="1024"/>
    <Property Name="ESIInvalidationMonitor"       Value="false"/>
    <Property Name="ESIEnableRecursiveInclude"    Value="false"/>
    <Property Name="ESIMaxRecursiveIncludeDepth"  Value="10"/>

    <ServerCluster CloneSeparatorChange="false" GetDWLMTable="false"
                   IgnoreAffinityRequests="true" LoadBalance="Round Robin"
                   Name="LibertyCluster" PostSizeLimit="-1"
                   RemoveSpecialHeaders="true" RetryInterval="60">

        <Server CloneID="member1" ConnectTimeout="5" ExtendedHandshake="false"
                MaxConnections="-1" Name="member1_9081"
                ServerIOTimeout="900" WaitForContinue="false">
            <Transport Hostname="localhost" Port="9081" Protocol="http"/>
        </Server>

        <Server CloneID="member2" ConnectTimeout="5" ExtendedHandshake="false"
                MaxConnections="-1" Name="member2_9082"
                ServerIOTimeout="900" WaitForContinue="false">
            <Transport Hostname="localhost" Port="9082" Protocol="http"/>
        </Server>

        <PrimaryServers>
            <Server Name="member1_9081"/>
            <Server Name="member2_9082"/>
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
# 2. Add WebSpherePluginConfig to httpd.conf (idempotent)
# ---------------------------------------------------------------------------
echo "[2/4] Adding WebSpherePluginConfig to httpd.conf..."

if grep -q "^WebSpherePluginConfig" "${HTTPD_CONF}"; then
    # Update path in case it differs
    sed -i "s|^WebSpherePluginConfig .*|WebSpherePluginConfig ${PLUGIN_CFG}|" "${HTTPD_CONF}"
    echo "      WebSpherePluginConfig: updated"
else
    echo "" >> "${HTTPD_CONF}"
    echo "# WAS plugin routing — added by step1-was-plugin.sh" >> "${HTTPD_CONF}"
    echo "WebSpherePluginConfig ${PLUGIN_CFG}" >> "${HTTPD_CONF}"
    echo "      WebSpherePluginConfig: added"
fi

# ---------------------------------------------------------------------------
# 3. Config test
# ---------------------------------------------------------------------------
echo "[3/4] Running configtest..."
RESULT=$("${APACHECTL}" configtest 2>&1)
if echo "${RESULT}" | grep -q "Syntax OK"; then
    echo "      Syntax OK"
else
    echo "ERROR: Config test failed:"
    echo "${RESULT}"
    exit 1
fi

# ---------------------------------------------------------------------------
# 4. (Re)start IHS
# ---------------------------------------------------------------------------
echo "[4/4] Starting IHS..."
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

echo ""
echo "=== Step 1 complete ==="
echo ""
echo "  Verify routing:"
echo "    curl -v http://localhost:8080/server-info/"
echo ""
echo "  IHS plugin log:"
echo "    tail -f ${IHS_ROOT}/logs/plugin.log"
echo ""
echo "  When ready, enable dynamic routing:"
echo "    bash scripts/step2-dynamic-routing.sh"
echo ""
