# Install IHS

unzip /home/itzuser/software/IHS/WAS/9.0.5-WS-IHS-ARCHIVE-linux-x86_64-FP025.zip -d ~/usr/IBM
cd ~/usr/IBM/IHS/
./postinstall.sh 
sed -i 's/Listen 80/Listen 1080/g' conf/httpd.conf

bin/apachectl -version

# Setup WAS Plugin configuration directory
mkdir -p /home/itzuser/IBM/HTTPServer/plugin/config/webserver1
mkdir -p /home/itzuser/IBM/HTTPServer/plugin/logs/webserver1

# Generate plugin-cfg.xml
cat > /home/itzuser/IBM/HTTPServer/plugin/config/webserver1/plugin-cfg.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<Config ASDisableNagle="false" AcceptAllContent="false" AppServerPortPreference="HostHeader" ChunkedResponse="false" FIPSEnable="false" IISDisableNagle="false" IISPluginPriority="High" IgnoreDNSFailures="false" RefreshInterval="60" ResponseChunkSize="64" SSLConsolidatedConfig="false" TrustedProxyEnable="false" VHostMatchingCompat="false">
    <Log LogLevel="Error" Name="/home/itzuser/IBM/HTTPServer/plugin/logs/webserver1/http_plugin.log"/>
    <Property Name="ESIEnable" Value="false"/>
    <Property Name="ESIMaxCacheSize" Value="1024"/>
    <Property Name="ESIInvalidationMonitor" Value="false"/>
    <Property Name="ESIEnableRecursiveInclude" Value="false"/>
    <Property Name="ESIMaxRecursiveIncludeDepth" Value="10"/>

    <ServerCluster CloneSeparatorChange="false" GetDWLMTable="false" IgnoreAffinityRequests="true" LoadBalance="Round Robin" Name="defaultCollective" PostSizeLimit="-1" RemoveSpecialHeaders="true" RetryInterval="60">
        <Server CloneID="member1" ConnectTimeout="5" ExtendedHandshake="false" MaxConnections="-1" Name="member1_9081" ServerIOTimeout="900" WaitForContinue="false">
            <Transport Hostname="localhost" Port="9081" Protocol="http"/>
        </Server>
        <Server CloneID="member2" ConnectTimeout="5" ExtendedHandshake="false" MaxConnections="-1" Name="member2_9082" ServerIOTimeout="900" WaitForContinue="false">
            <Transport Hostname="localhost" Port="9082" Protocol="http"/>
        </Server>
        <PrimaryServers>
            <Server Name="member1_9081"/>
            <Server Name="member2_9082"/>
        </PrimaryServers>
    </ServerCluster>

    <UriGroup Name="defaultCollective_URIs">
        <Uri AffinityCookie="JSESSIONID" AffinityURLIdentifier="jsessionid" Name="/*"/>
    </UriGroup>

    <VirtualHostGroup Name="defaultCollective_Hosts">
        <VirtualHost Name="*:1080"/>
        <VirtualHost Name="*:80"/>
    </VirtualHostGroup>

    <Route ServerCluster="defaultCollective" UriGroup="defaultCollective_URIs" VirtualHostGroup="defaultCollective_Hosts"/>
</Config>
EOF

# Ensure httpd.conf loads WAS plugin and references plugin-cfg.xml
if ! grep -q "mod_was_ap24_http.so" conf/httpd.conf; then
    echo "LoadModule was_ap24_module modules/mod_was_ap24_http.so" >> conf/httpd.conf
fi

if grep -q "^WebSpherePluginConfig" conf/httpd.conf; then
    sed -i 's|^WebSpherePluginConfig .*|WebSpherePluginConfig /home/itzuser/IBM/HTTPServer/plugin/config/webserver1/plugin-cfg.xml|' conf/httpd.conf
else
    echo "WebSpherePluginConfig /home/itzuser/IBM/HTTPServer/plugin/config/webserver1/plugin-cfg.xml" >> conf/httpd.conf
fi

# Start IHS
bin/apachectl start 

# Verify that round robin works
curl -s http://localhost:1080/server-info/
