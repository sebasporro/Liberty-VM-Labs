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

# 1. Run dynamicRouting setup on the controller
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

# 2. Stage files
mkdir -p ~/temp/dynamicRouting
mv "${CONTROLLER_BIN}/plugin-cfg.xml" ~/temp/dynamicRouting/
mv "${CONTROLLER_BIN}/plugin-key.p12" ~/temp/dynamicRouting/
cp ~/temp/dynamicRouting/plugin-cfg.xml "${IHS_ROOT}/plugin/config/webserver1/"

# 3. Convert keystore and set default certificate
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

# 4. Copy certificates to the plugin config directory
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
echo "Use curl with -c /dev/null to discard cookies between requests:"
echo ""
echo "  for i in \$(seq 8); do curl -s -c /dev/null http://localhost:1080/server-info/ | grep -o 'member[0-9]*'; done"
echo ""
echo "You should see responses alternating between member1 and member2."
echo ""
echo "=== Verify failover ==="
echo "1. Stop member1:"
echo "   ${WORKSPACE_ROOT}/installs/member1/wlp/bin/server stop member1"
echo "2. Re-run the curl loop above — all responses should come from member2."
echo "3. Restart member1:"
echo "   ${WORKSPACE_ROOT}/installs/member1/wlp/bin/server start member1"
