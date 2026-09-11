#!/bin/bash
# Usage:
#   scripts/apply-routing-rules.sh on    # round-robin across all members
#   scripts/apply-routing-rules.sh off   # single member answers; failover if it goes down

TARGET="$1"
PLUGIN_CFG="/home/itzuser/usr/IBM/IHS/plugin/config/webserver1/plugin-cfg.xml"
KDB="/home/itzuser/usr/IBM/IHS/plugin/config/webserver1/plugin-key.kdb"
M1_BIN="/home/itzuser/Liberty-VM-Labs/installs/member1/wlp/bin/server"
M2_BIN="/home/itzuser/Liberty-VM-Labs/installs/member2/wlp/bin/server"
APACHECTL="/home/itzuser/usr/IBM/IHS/bin/apachectl"

if [[ "$TARGET" != "on" && "$TARGET" != "off" ]]; then
    echo "Usage: $0 <on | off>"
    exit 1
fi

# IgnoreAffinityRequests must be on <ConnectorCluster> — not a <Property> element.
# true  = plug-in ignores JSESSIONID cookie → every request rotates (round-robin)
# false = plug-in pins client to first member via cookie → single server
[[ "$TARGET" == "on" ]] && AFFINITY="true" || AFFINITY="false"

cat > "$PLUGIN_CFG" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<Config ASDisableNagle="false" AcceptAllContent="false"
        AppServerPortPreference="HostHeader" ChunkedResponse="false"
        FIPSEnable="false" IISDisableNagle="false" IISPluginPriority="High"
        IgnoreDNSFailures="false" RefreshInterval="60" ResponseChunkSize="64"
        SSLConsolidate="false" TrustedProxyEnable="false" VHostMatchingCompat="false">

    <Log LogLevel="Error" Name="/home/itzuser/usr/IBM/IHS/plugin/logs/webserver1/http_plugin.log"/>

    <Property Name="PluginInstallRoot" Value="/home/itzuser/usr/IBM/IHS/plugin/"/>
    <Property Name="Keyfile"   Value="${KDB}"/>
    <Property Name="Stashfile" Value="/home/itzuser/usr/IBM/IHS/plugin/config/webserver1/plugin-key.sth"/>

    <IntelligentManagement>
        <Property name="webserverName" value="webserver1"/>
        <ConnectorCluster enabled="true" maxRetries="-1" name="defaultCollective"
                          retryInterval="60"
                          LoadBalance="RoundRobin"
                          IgnoreAffinityRequests="${AFFINITY}">
            <Property name="uri" value="/ibm/api/dynamicRouting"/>
            <Connector host="localhost" port="9443" protocol="https">
                <Property name="keyring" value="${KDB}"/>
            </Connector>
        </ConnectorCluster>
        <Property name="RoutingRulesConnectorClusterName" value="defaultCollective"/>
    </IntelligentManagement>

</Config>
EOF

echo "plugin-cfg.xml rewritten — IgnoreAffinityRequests=${AFFINITY}, LoadBalance=RoundRobin"

case "$TARGET" in
    on)
        echo "Round-robin ON — starting all members..."
        "$M1_BIN" start member1 2>/dev/null
        "$M2_BIN" start member2 2>/dev/null
        ;;
    off)
        echo "Round-robin OFF — stopping member2, member1 answers all requests..."
        echo "(If member1 goes down, member2 will take over automatically)"
        "$M2_BIN" stop member2
        ;;
esac

"$APACHECTL" graceful
echo ""
echo "Test: for i in \$(seq 6); do curl -s http://localhost:1080/server-info/ | grep -o 'member[0-9]*'; done"
