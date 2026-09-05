#!/bin/bash
# =============================================================================
# step2-dynamic-routing.sh
# Enables Liberty Dynamic Routing on the Collective.
#
# Reference:
#   https://www.ibm.com/docs/en/was-liberty/nd?topic=collectives-setting-up-dynamic-routing-liberty
#
# How Liberty dynamic routing works in this lab:
#   1. The controller runs the dynamicRouting-1.0 feature.
#   2. This script discovers all running collective members and generates a
#      <ServerCluster> plugin-cfg.xml covering all of them.
#   3. mod_was_ap24_http.so reads plugin-cfg.xml and round-robins across all
#      listed members.
#
# NOTE on Intelligent Management mode:
#   The IBM docs describe a mode where mod_was_ap24_http.so polls /wr on the
#   controller and dynamically updates its routing table (<IntelligentManagement>
#   stanza in plugin-cfg.xml). That mode requires the full "Web Server Plug-ins
#   for WebSphere Application Server 9.0.0.3+" product installed via Installation
#   Manager. This lab uses a standalone mod_was_ap24_http.so extracted from a ZIP
#   archive — that binary supports standard <ServerCluster> routing only.
#   Re-run this script whenever members are added or removed to regenerate the
#   plugin-cfg.xml with the updated member list.
#
# Architecture after this script:
#   Browser → IHS:8080 ──(mod_was_ap24_http.so)──► member1:9081
#                                                 ► member2:9082
#                                                 ► member3:9083  (if running)
#                                                 ► member4:9084  (if running)
#
# Prerequisites:
#   - IHS installed with mod_was_ap24_http.so     (scripts/install-ihs.sh)
#   - Controller running on HTTP 9080 / HTTPS 9443 (scripts/install-controller.sh)
#   - At least one member joined to the collective  (scripts/add-member-26.sh)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
CONTROLLER_DIR="${WORKSPACE_ROOT}/installs/controller"
CTRL_WLP="${CONTROLLER_DIR}/wlp"
SERVER_DIR="${CTRL_WLP}/usr/servers/controller"
WLP_BIN="${CTRL_WLP}/bin/server"
OVERRIDES_DIR="${SERVER_DIR}/configDropins/overrides"
MESSAGES_LOG="${SERVER_DIR}/logs/messages.log"

IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/IBM/HTTPServer}"
HTTPD_CONF="${IHS_ROOT}/conf/httpd.conf"
APACHECTL="${IHS_ROOT}/bin/apachectl"
PLUGIN_CFG="${IHS_ROOT}/conf/plugin-cfg.xml"
PLUGIN_LOG="${IHS_ROOT}/logs/plugin.log"

CONTROLLER_HTTP=9080
CONTROLLER_HTTPS=9443

echo ""
echo "=== Step 3b: Liberty Dynamic Routing ==="
echo ""

# ---------------------------------------------------------------------------
# 1. Pre-flight checks
# ---------------------------------------------------------------------------
echo "[1/4] Pre-flight checks..."

if [[ ! -x "${WLP_BIN}" ]]; then
    echo "  ERROR: Controller WLP not found at ${CONTROLLER_DIR}"
    echo "         Run scripts/install-controller.sh first."
    exit 1
fi

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

if ! ss -tlnp 2>/dev/null | grep -q ":${CONTROLLER_HTTP} "; then
    echo "  ERROR: Controller is not running on HTTP port ${CONTROLLER_HTTP}."
    echo "         Run: ${WLP_BIN} start controller"
    exit 1
fi
echo "  Controller HTTP : running on ${CONTROLLER_HTTP}"

# Guard: the controller must NOT have a collective-join.xml dropin.
STALE_JOIN="${OVERRIDES_DIR}/collective-join.xml"
if [[ -f "${STALE_JOIN}" ]]; then
    echo "  WARNING: Found collective-join.xml on the controller — removing it."
    rm -f "${STALE_JOIN}"
    echo "  Removed: ${STALE_JOIN}"
fi

# Discover all running members on the standard ports 9081-9084
MEMBER_PORTS=()
MEMBER_NAMES=()
for i in 1 2 3 4; do
    port=$(( 9080 + i ))
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        MEMBER_PORTS+=("${port}")
        MEMBER_NAMES+=("member${i}")
        echo "  Member :${port}     : up  → member${i}"
    fi
done

if [[ ${#MEMBER_PORTS[@]} -eq 0 ]]; then
    echo "  ERROR: No collective members running on ports 9081-9084."
    echo "         Run scripts/add-member-26.sh member1 first."
    exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# 2. Enable dynamicRouting-1.0 + restConnector-2.0 on the controller
#    (required by the lab — activates the feature even though we use
#     <ServerCluster> routing rather than <IntelligentManagement> mode)
# ---------------------------------------------------------------------------
echo "[2/4] Enabling dynamicRouting-1.0 on controller..."
mkdir -p "${OVERRIDES_DIR}"
DYNAMIC_XML="${OVERRIDES_DIR}/dynamic-routing.xml"

cat > "${DYNAMIC_XML}" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<server description="Dynamic routing feature">
    <featureManager>
        <feature>dynamicRouting-1.0</feature>
        <feature>restConnector-2.0</feature>
    </featureManager>
</server>
XML
echo "  Written: ${DYNAMIC_XML}"

# Restart controller to activate the feature
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
    echo "  WARNING: Could not confirm dynamicRouting-1.0 loaded — continuing."
fi
echo ""

# ---------------------------------------------------------------------------
# 3. Generate plugin-cfg.xml covering all discovered members
#
#    Uses standard <ServerCluster> format — compatible with the standalone
#    mod_was_ap24_http.so that ships with this IHS archive.
#    Round-robin load balancing across all running members.
# ---------------------------------------------------------------------------
echo "[3/4] Generating plugin-cfg.xml for ${#MEMBER_PORTS[@]} member(s)..."

# Build <Server> stanzas for every running member
SERVER_STANZAS=""
PRIMARY_SERVERS=""
for idx in "${!MEMBER_PORTS[@]}"; do
    port="${MEMBER_PORTS[$idx]}"
    name="${MEMBER_NAMES[$idx]}"
    SERVER_STANZAS+="
        <Server CloneID=\"${name}\" ConnectTimeout=\"5\" ExtendedHandshake=\"false\"
                MaxConnections=\"-1\" Name=\"${name}_${port}\"
                ServerIOTimeout=\"900\" WaitForContinue=\"false\">
            <Transport Hostname=\"localhost\" Port=\"${port}\" Protocol=\"http\"/>
        </Server>"
    PRIMARY_SERVERS+="
            <Server Name=\"${name}_${port}\"/>"
done

cat > "${PLUGIN_CFG}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!--
  Liberty WAS Plugin — dynamic routing (all collective members)
  Generated by step2-dynamic-routing.sh on $(date)
  Re-run this script to regenerate when members are added or removed.
-->
<Config ASDisableNagle="false" AcceptAllContent="false"
        AppServerPortPreference="HostHeader" ChunkedResponse="false"
        FIPSEnable="false" IISDisableNagle="false" IISPluginPriority="High"
        IgnoreDNSFailures="false" RefreshInterval="60" ResponseChunkSize="64"
        SSLConsolidatedConfig="false" TrustedProxyEnable="false"
        VHostMatchingCompat="false">

    <Log LogLevel="Error" Name="${PLUGIN_LOG}"/>

    <Property Name="ESIEnable"                   Value="false"/>
    <Property Name="ESIMaxCacheSize"              Value="1024"/>
    <Property Name="ESIInvalidationMonitor"       Value="false"/>
    <Property Name="ESIEnableRecursiveInclude"    Value="false"/>
    <Property Name="ESIMaxRecursiveIncludeDepth"  Value="10"/>

    <ServerCluster CloneSeparatorChange="false" GetDWLMTable="false"
                   IgnoreAffinityRequests="true" LoadBalance="Round Robin"
                   Name="LibertyCluster" PostSizeLimit="-1"
                   RemoveSpecialHeaders="true" RetryInterval="60">
${SERVER_STANZAS}

        <PrimaryServers>${PRIMARY_SERVERS}
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

echo "  Written: ${PLUGIN_CFG}"
echo "  Members in cluster:"
for idx in "${!MEMBER_PORTS[@]}"; do
    echo "    ${MEMBER_NAMES[$idx]} → localhost:${MEMBER_PORTS[$idx]}"
done
echo ""

# ---------------------------------------------------------------------------
# 4. Ensure WebSpherePluginConfig directive, validate and restart IHS
# ---------------------------------------------------------------------------
echo "[4/4] Installing config and restarting IHS..."

if grep -q "^WebSpherePluginConfig" "${HTTPD_CONF}"; then
    sed -i "s|^WebSpherePluginConfig .*|WebSpherePluginConfig ${PLUGIN_CFG}|" "${HTTPD_CONF}"
    echo "  WebSpherePluginConfig: updated"
else
    printf '\n# WAS plugin — dynamic routing\nWebSpherePluginConfig %s\n' \
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
    echo "  ERROR: IHS failed to start."
    tail -20 "${IHS_ROOT}/logs/error_log"
    exit 1
fi
echo "  IHS: running on port 8080"
echo ""

# Verify routing works
echo "  Verifying routing via IHS..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/server-info/ 2>/dev/null)
echo "  GET /server-info/ via IHS → HTTP ${HTTP_CODE}"
echo ""

if [[ "${HTTP_CODE}" == "200" ]]; then
    echo "=== Dynamic routing is active ==="
    echo ""
    echo "  IHS:8080 → round-robin across ${#MEMBER_PORTS[@]} collective member(s)"
    echo ""
    echo "  Members in rotation:"
    for idx in "${!MEMBER_PORTS[@]}"; do
        echo "    ${MEMBER_NAMES[$idx]}  http://localhost:${MEMBER_PORTS[$idx]}/server-info/"
    done
    echo ""
    echo "  Verify round-robin (run several times):"
    echo "    for i in \$(seq 6); do curl -s http://localhost:8080/server-info/ | grep -o 'member[0-9]*'; done"
    echo ""
    echo "  When you add more members, re-run this script to include them:"
    echo "    bash scripts/add-member-26.sh member3"
    echo "    bash scripts/step2-dynamic-routing.sh"
    echo ""
    echo "  Plugin log : tail -f ${PLUGIN_LOG}"
    echo "  Admin Center: https://localhost:${CONTROLLER_HTTPS}/adminCenter"
else
    echo "  ERROR: Routing check returned HTTP ${HTTP_CODE}"
    echo ""
    echo "  Diagnose:"
    echo "    tail -30 ${IHS_ROOT}/logs/error_log"
    echo "    tail -30 ${PLUGIN_LOG}"
    echo "    curl -v http://localhost:${MEMBER_PORTS[0]}/server-info/"
    exit 1
fi
echo ""
