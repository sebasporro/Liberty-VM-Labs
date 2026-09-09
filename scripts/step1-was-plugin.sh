#!/bin/bash
# =============================================================================
# step1-was-plugin.sh (Minimalist Version)
# Configures the IHS WAS plugin to statically load-balance across member1 and member2.
# =============================================================================

IHS_ROOT="/home/itzuser/usr/IBM/IHS"
PLUGIN_CFG="${IHS_ROOT}/plugin/config/webserver1/plugin-cfg.xml"
HTTPD_CONF="${IHS_ROOT}/conf/httpd.conf"

echo "Configuring static routing to member1 (9081) and member2 (9082)..."

# 1. Write the static plugin-cfg.xml
cat > "${PLUGIN_CFG}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<Config ASDisableNagle="false" AcceptAllContent="false" AppServerPortPreference="HostHeader" ChunkedResponse="false" FIPSEnable="false" IISDisableNagle="false" IISPluginPriority="High" IgnoreDNSFailures="false" RefreshInterval="60" ResponseChunkSize="64" SSLConsolidatedConfig="false" TrustedProxyEnable="false" VHostMatchingCompat="false">
    <Log LogLevel="Error" Name="/home/itzuser/usr/IBM/IHS/plugin/logs/webserver1/http_plugin.log"/>

    <ServerCluster Name="defaultCollective" LoadBalance="Round Robin">
        <Server CloneID="member1" Name="member1_9081">
            <Transport Hostname="localhost" Port="9081" Protocol="http"/>
        </Server>
        <Server CloneID="member2" Name="member2_9082">
            <Transport Hostname="localhost" Port="9082" Protocol="http"/>
        </Server>
        <PrimaryServers>
            <Server Name="member1_9081"/>
            <Server Name="member2_9082"/>
        </PrimaryServers>
    </ServerCluster>

    <UriGroup Name="defaultCollective_URIs">
        <Uri Name="/*"/>
    </UriGroup>

    <VirtualHostGroup Name="defaultCollective_Hosts">
        <VirtualHost Name="*:1080"/>
    </VirtualHostGroup>

    <Route ServerCluster="defaultCollective" UriGroup="defaultCollective_URIs" VirtualHostGroup="defaultCollective_Hosts"/>
</Config>
EOF

echo "Written configuration to ${PLUGIN_CFG}"

# 2. Add WebSpherePluginConfig directive to httpd.conf if not already present
if ! grep -q "^WebSpherePluginConfig" "${HTTPD_CONF}"; then
    echo "Adding WebSpherePluginConfig to httpd.conf..."
    echo "WebSpherePluginConfig ${PLUGIN_CFG}" >> "${HTTPD_CONF}"
fi

# 3. Restart IHS
echo "Restarting IBM HTTP Server..."
"${IHS_ROOT}/bin/apachectl" stop 2>/dev/null || true
sleep 1
"${IHS_ROOT}/bin/apachectl" start

echo "Static routing configured! Verify at http://localhost:1080/server-info/"
