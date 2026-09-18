#!/bin/bash
# =============================================================================
# step2-dynamic-routing.sh
# Enables Liberty Dynamic Routing (Intelligent Management) for a Liberty
# collective. Follows the IBM documentation procedure:
#   https://www.ibm.com/docs/en/was-liberty/nd?topic=collectives-setting-up-dynamic-routing-single-liberty-collective
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/usr/IBM/IHS}"
CONTROLLER_BIN="${WORKSPACE_ROOT}/installs/controller/wlp/bin"
SCRATCH=~/temp/dynamicRouting
PLUGIN_DIR="${IHS_ROOT}/plugin/config/webserver1"

echo "=== Enabling Dynamic Routing ==="

# 1. Stop IHS before touching any plugin files so there is no hot-reload window
#    where the new plugin-cfg.xml is in place but the keystore has not been
#    converted yet.
echo "Stopping IHS..."
"${IHS_ROOT}/bin/apachectl" stop 2>/dev/null || true
for i in $(seq 15); do
  if ! ss -tlnp 2>/dev/null | grep -q ':1080 ' && \
     ! netstat -tlnp 2>/dev/null | grep -q ':1080 '; then
    break
  fi
  echo "Waiting for port 1080 to be released... ($i/15)"
  sleep 2
done

# 2. Run dynamicRouting setup
rm -rf "${SCRATCH}"
mkdir -p "${SCRATCH}"
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

# Verify the setup produced the expected files
if [[ ! -f "${CONTROLLER_BIN}/plugin-cfg.xml" || ! -f "${CONTROLLER_BIN}/plugin-key.p12" ]]; then
  echo "ERROR: dynamicRouting setup did not produce plugin-cfg.xml / plugin-key.p12 in ${CONTROLLER_BIN}" >&2
  exit 1
fi

mv "${CONTROLLER_BIN}/plugin-cfg.xml" "${SCRATCH}/"
mv "${CONTROLLER_BIN}/plugin-key.p12" "${SCRATCH}/"

# 3. Patch the generated plugin-cfg.xml:
#    a) Add LoadBalance and IgnoreAffinityRequests to ConnectorCluster so the
#       ODR does not honour JSESSIONID session affinity — required for visible
#       round-robin in curl tests and for pin rules to work from fresh sessions.
#    b) Lower RefreshInterval from 60 s (default) to 10 s so routing changes
#       propagate quickly during demos without waiting a full minute.
sed -i 's|<ConnectorCluster \(enabled="true"[^>]*\)>|<ConnectorCluster \1 LoadBalance="RoundRobin" IgnoreAffinityRequests="true">|' \
  "${SCRATCH}/plugin-cfg.xml"
sed -i 's|RefreshInterval="60"|RefreshInterval="10"|' \
  "${SCRATCH}/plugin-cfg.xml"

# 4. Convert keystore and set default certificate
"${IHS_ROOT}/bin/gskcapicmd" -keydb -convert \
  -pw "Liberty26ctrl!" \
  -db "${SCRATCH}/plugin-key.p12" \
  -old_format pkcs12 \
  -target "${SCRATCH}/plugin-key.kdb" \
  -new_format cms \
  -stash

"${IHS_ROOT}/bin/gskcapicmd" -cert -setdefault \
  -pw "Liberty26ctrl!" \
  -db "${SCRATCH}/plugin-key.kdb" \
  -label default

# 5. Install all files atomically (IHS is already down)
cp "${SCRATCH}/plugin-cfg.xml" "${PLUGIN_DIR}/"
cp "${SCRATCH}/plugin-key.kdb" "${PLUGIN_DIR}/"
cp "${SCRATCH}/plugin-key.sth" "${PLUGIN_DIR}/"

ls -lrt "${PLUGIN_DIR}/"
cat "${PLUGIN_DIR}/plugin-cfg.xml"

# 6. Start IHS
"${IHS_ROOT}/bin/apachectl" start
sleep 3
cat "${IHS_ROOT}/plugin/logs/webserver1/http_plugin.log"

echo "Dynamic routing configured!"
echo ""
echo "=== Verify round-robin ==="
echo "IMPORTANT: use curl (not a browser) to test round-robin."
echo "Browsers send JSESSIONID cookies which cause the plugin to stick to one server."
echo "Use curl with -c /dev/null to discard cookies between requests:"
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