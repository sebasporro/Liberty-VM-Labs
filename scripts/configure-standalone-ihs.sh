#!/bin/bash
# =============================================================================
# configure-standalone-ihs.sh
#
# Configures IBM HTTP Server (IHS) and the WebSphere Application Server (WAS)
# plugin to route requests to the standalone Liberty server (port 9080).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/usr/IBM/IHS}"
IHS_ZIP="${IHS_ARCHIVE:-/home/itzuser/software/IHS/WAS/9.0.5-WS-IHS-ARCHIVE-linux-x86_64-FP025.zip}"

echo "================================================================="
echo " Configuring IHS & WAS Plugin for Standalone Liberty"
echo "================================================================="

# 1. Install / extract IHS if not already present
if [[ ! -d "${IHS_ROOT}" ]]; then
  echo "==> [1/6] Extracting IHS to ${IHS_ROOT}..."
  mkdir -p "$(dirname "${IHS_ROOT}")"
  unzip -q "${IHS_ZIP}" -d "$(dirname "${IHS_ROOT}")"
  (cd "${IHS_ROOT}" && ./postinstall.sh)
else
  echo "==> [1/6] IHS already installed at ${IHS_ROOT}."
fi

# 2. Configure listen port 1080 (non-root)
echo "==> [2/6] Configuring listen port 1080 in httpd.conf..."
sed -i 's/Listen 80/Listen 1080/g' "${IHS_ROOT}/conf/httpd.conf"

# 3. Create static test page
echo "==> [3/6] Creating static index.html in htdocs..."
mkdir -p "${IHS_ROOT}/htdocs"
echo '<html><body><h1>IBM HTTP Server is running!</h1></body></html>' > "${IHS_ROOT}/htdocs/index.html"

# 4. Create WAS plugin directories and generate plugin-cfg.xml
echo "==> [4/6] Creating plugin directories and writing plugin-cfg.xml..."
mkdir -p "${IHS_ROOT}/plugin/config/webserver1"
mkdir -p "${IHS_ROOT}/plugin/logs/webserver1"

cat > "${IHS_ROOT}/plugin/config/webserver1/plugin-cfg.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<Config ASDisableNagle="false" AcceptAllContent="false"
        AppServerPortPreference="HostHeader" ChunkedResponse="false"
        FIPSEnable="false" IgnoreDNSFailures="false"
        RefreshInterval="60" ResponseChunkSize="64"
        TrustedProxyEnable="false" VHostMatchingCompat="false">

    <!-- Plugin log file -->
    <Log LogLevel="Error"
         Name="/home/itzuser/usr/IBM/IHS/plugin/logs/webserver1/http_plugin.log"/>

    <!-- Single-server cluster pointing at the standalone Liberty server -->
    <ServerCluster Name="standaloneCluster" LoadBalance="Round Robin"
                   CloneSeparatorChange="false" GetDWLMTable="false"
                   IgnoreAffinityRequests="true" PostSizeLimit="-1"
                   RemoveSpecialHeaders="true" RetryInterval="60">
        <Server CloneID="myServer" Name="myServer_9080"
                ConnectTimeout="5" ExtendedHandshake="false"
                MaxConnections="-1" ServerIOTimeout="900"
                WaitForContinue="false">
            <Transport Hostname="localhost" Port="9080" Protocol="http"/>
        </Server>
        <PrimaryServers>
            <Server Name="myServer_9080"/>
        </PrimaryServers>
    </ServerCluster>

    <!-- Route /server-info/* through the plugin -->
    <UriGroup Name="standaloneCluster_URIs">
        <Uri AffinityCookie="JSESSIONID" AffinityURLIdentifier="jsessionid"
             Name="/server-info/*"/>
    </UriGroup>

    <!-- Respond to requests on IHS port 1080 -->
    <VirtualHostGroup Name="standaloneCluster_Hosts">
        <VirtualHost Name="*:1080"/>
    </VirtualHostGroup>

    <Route ServerCluster="standaloneCluster"
           UriGroup="standaloneCluster_URIs"
           VirtualHostGroup="standaloneCluster_Hosts"/>

</Config>
EOF

# 5. Configure httpd.conf to load the WAS plugin module and reference plugin-cfg.xml
echo "==> [5/6] Updating httpd.conf with WAS plugin directives..."
if ! grep -q "mod_was_ap24_http.so" "${IHS_ROOT}/conf/httpd.conf"; then
  if [[ -f "${IHS_ROOT}/plugin/bin/64bits/mod_was_ap24_http.so" ]]; then
    echo "LoadModule was_ap24_module ${IHS_ROOT}/plugin/bin/64bits/mod_was_ap24_http.so" >> "${IHS_ROOT}/conf/httpd.conf"
  else
    echo "LoadModule was_ap24_module modules/mod_was_ap24_http.so" >> "${IHS_ROOT}/conf/httpd.conf"
  fi
fi

if grep -q "^WebSpherePluginConfig" "${IHS_ROOT}/conf/httpd.conf"; then
  sed -i "s|^WebSpherePluginConfig .*|WebSpherePluginConfig ${IHS_ROOT}/plugin/config/webserver1/plugin-cfg.xml|" "${IHS_ROOT}/conf/httpd.conf"
else
  echo "WebSpherePluginConfig ${IHS_ROOT}/plugin/config/webserver1/plugin-cfg.xml" >> "${IHS_ROOT}/conf/httpd.conf"
fi

# 6. Restart IHS and verify
echo "==> [6/6] Restarting IHS..."
"${IHS_ROOT}/bin/apachectl" stop 2>/dev/null || true
"${IHS_ROOT}/bin/apachectl" start

echo ""
echo "Testing static response:"
curl -s http://localhost:1080/
echo ""
echo ""
echo "Testing plugin routing to Liberty (/server-info/):"
curl -s http://localhost:1080/server-info/ | head -n 15 || true
echo ""
echo "=== IHS configuration complete ==="
