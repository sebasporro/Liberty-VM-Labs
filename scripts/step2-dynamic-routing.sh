#!/bin/bash
# =============================================================================
# step2-dynamic-routing.sh
# Enables Liberty Dynamic Routing (Intelligent Management) for a Liberty
# collective. Follows the IBM documentation procedure:
#   https://www.ibm.com/docs/en/was-liberty/nd?topic=collectives-setting-up-dynamic-routing-single-liberty-collective
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/usr/IBM/IHS}"
CONTROLLER_BIN="${WORKSPACE_ROOT}/installs/controller/wlp/bin"

echo "=== Enabling Dynamic Routing ==="

# 1. Run dynamicRouting setup — used ONLY to generate the keystore files.
#    We discard its plugin-cfg.xml and write our own (see step 2) because the
#    generated file uses <IntelligentManagement>/<ConnectorCluster> which does
#    not support IgnoreAffinityRequests, causing the plugin to pin all browser
#    sessions to the first member via JSESSIONID affinity.
cd "${CONTROLLER_BIN}"
./dynamicRouting setup \
  --host=localhost \
  --port=9443 \
  --user=admin \
  --password=admin \
  --keystorePassword="Liberty26ctrl!" \
  --pluginInstallRoot="${IHS_ROOT}/plugin" \
  --webServerNames=webserver1 \
  --autoAcceptCertificates 2>&1

# 2. Stage keystore files; discard the generated plugin-cfg.xml
mkdir -p ~/temp/dynamicRouting
mv "${CONTROLLER_BIN}/plugin-key.p12" ~/temp/dynamicRouting/
rm -f "${CONTROLLER_BIN}/plugin-cfg.xml"

# 3. Write a correct plugin-cfg.xml with:
#    - <ServerCluster> pointing at the controller (dynamic routing format)
#    - IgnoreAffinityRequests="true"  → no session pinning
#    - No AffinityCookie / AffinityURLIdentifier on <Uri>  → true round-robin
PLUGIN_CFG="${IHS_ROOT}/plugin/config/webserver1/plugin-cfg.xml"
KDB="${IHS_ROOT}/plugin/config/webserver1/plugin-key.kdb"
STH="${IHS_ROOT}/plugin/config/webserver1/plugin-key.sth"

cat > "${PLUGIN_CFG}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<Config ASDisableNagle="false" AcceptAllContent="false"
        AppServerPortPreference="HostHeader" ChunkedResponse="false"
        FIPSEnable="false" IISDisableNagle="false" IISPluginPriority="High"
        IgnoreDNSFailures="false" RefreshInterval="60" ResponseChunkSize="64"
        SSLConsolidatedConfig="false" TrustedProxyEnable="false"
        VHostMatchingCompat="false">

    <Log LogLevel="Error" Name="${IHS_ROOT}/plugin/logs/webserver1/http_plugin.log"/>

    <Property Name="ESIEnable"                   Value="false"/>
    <Property Name="ESIMaxCacheSize"             Value="1024"/>
    <Property Name="ESIInvalidationMonitor"      Value="false"/>
    <Property Name="ESIEnableRecursiveInclude"   Value="false"/>
    <Property Name="ESIMaxRecursiveIncludeDepth" Value="10"/>
    <Property Name="Keyfile"                     Value="${KDB}"/>
    <Property Name="Stashfile"                   Value="${STH}"/>

    <ServerCluster CloneSeparatorChange="false" GetDWLMTable="false"
                   IgnoreAffinityRequests="true" LoadBalance="Round Robin"
                   Name="defaultCollective" PostSizeLimit="-1"
                   RemoveSpecialHeaders="true" RetryInterval="60">
        <Server CloneID="controller" ConnectTimeout="5" ExtendedHandshake="false"
                MaxConnections="-1" Name="controller_9443"
                ServerIOTimeout="900" WaitForContinue="false">
            <Transport Hostname="localhost" Port="9443" Protocol="https">
                <Property Name="keyring"   Value="${KDB}"/>
                <Property Name="stashfile" Value="${STH}"/>
            </Transport>
        </Server>
        <PrimaryServers>
            <Server Name="controller_9443"/>
        </PrimaryServers>
    </ServerCluster>

    <UriGroup Name="defaultCollective_URIs">
        <Uri Name="/*"/>
    </UriGroup>

    <VirtualHostGroup Name="defaultCollective_Hosts">
        <VirtualHost Name="*:1080"/>
    </VirtualHostGroup>

    <Route ServerCluster="defaultCollective"
           UriGroup="defaultCollective_URIs"
           VirtualHostGroup="defaultCollective_Hosts"/>

</Config>
EOF
echo "plugin-cfg.xml written with IgnoreAffinityRequests=true and no affinity cookie."

# 4. Convert keystore and set default certificate
"${IHS_ROOT}/bin/gskcapicmd" -keydb -convert \
  -pw "Liberty26ctrl!" \
  -db ~/temp/dynamicRouting/plugin-key.p12 \
  -old_format pkcs12 \
  -target ~/temp/dynamicRouting/plugin-key.kdb \
  -new_format cms \
  -stash

"${IHS_ROOT}/bin/gskcapicmd" -cert -setdefault \
  -pw "Liberty26ctrl!" \
  -db ~/temp/dynamicRouting/plugin-key.kdb \
  -label default

# 5. Copy certificates to the plugin config directory
cp ~/temp/dynamicRouting/plugin-key.kdb "${IHS_ROOT}/plugin/config/webserver1/"
cp ~/temp/dynamicRouting/plugin-key.sth "${IHS_ROOT}/plugin/config/webserver1/"

ls -lrt "${IHS_ROOT}/plugin/config/webserver1/"
cat "${IHS_ROOT}/plugin/config/webserver1/plugin-cfg.xml"

# 5. Restart IHS
"${IHS_ROOT}/bin/apachectl" stop
# Wait until port 1080 is released before starting again
for i in $(seq 10); do
  if ! ss -tlnp 2>/dev/null | grep -q ':1080 ' && \
     ! netstat -tlnp 2>/dev/null | grep -q ':1080 '; then
    break
  fi
  echo "Waiting for port 1080 to be released... ($i/10)"
  sleep 2
done
"${IHS_ROOT}/bin/apachectl" start
cat "${IHS_ROOT}/plugin/logs/webserver1/http_plugin.log"

echo "Dynamic routing configured!"
echo ""
echo "=== Verify round-robin ==="
echo "IMPORTANT: use curl (not a browser) to test round-robin."
echo "Browsers send JSESSIONID cookies which cause the plugin to stick to one server."
echo "Hit the api/health JSON endpoint and print the port (all members share the same hostname):"
echo ""
echo "  for i in \$(seq 8); do curl -s -c /dev/null http://localhost:1080/server-info/api/health | python3 -c \"import sys,json; d=json.load(sys.stdin); print(d['server']['port'])\"; done"
echo ""
echo "You should see the port alternating between 9081 (member1) and 9082 (member2)."
echo ""
echo "=== Verify failover ==="
echo "1. Stop member1:"
echo "   ${WORKSPACE_ROOT}/installs/member1/wlp/bin/server stop member1"
echo "2. Re-run the curl loop above — all responses should come from member2."
echo "3. Restart member1:"
echo "   ${WORKSPACE_ROOT}/installs/member1/wlp/bin/server start member1"
