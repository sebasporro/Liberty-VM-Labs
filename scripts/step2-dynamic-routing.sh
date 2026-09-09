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

# Patch plugin-cfg.xml to:
#  1. Ensure trailing slash on dynamicRouting uri (fixes HTTP 307 redirect issue)
#  2. Inject AcceptType under Connector (fixes HTTP 500 error on Liberty 26)
#  3. Inject RoutingPolicy under IntelligentManagement (forces strict RoundRobin load-balancing)
python3 - ~/temp/dynamicRouting/plugin-cfg.xml <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    content = f.read()

# 1. Ensure trailing slash on dynamicRouting uri
content = re.sub(
    r'(<Property\s+name="uri"\s+value="/ibm/api/dynamicRouting)(")',
    r'\g<1>/\g<2>',
    content
)

# 2. Inject AcceptType under Connector if absent
if 'AcceptType' not in content:
    content = re.sub(
        r'(<Connector\b[^>]*>)',
        r'\1\n            <Property name="AcceptType" value="application/json"/>',
        content
    )

# 3. Inject RoutingPolicy under IntelligentManagement if absent
if 'RoutingPolicy' not in content:
    content = re.sub(
        r'(<IntelligentManagement\b[^>]*>)',
        r'\1\n    <Property name="RoutingPolicy" value="RoundRobin"/>',
        content
    )

with open(path, 'w') as f:
    f.write(content)
PYEOF

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
"${IHS_ROOT}/bin/apachectl" start
cat "${IHS_ROOT}/plugin/logs/webserver1/http_plugin.log"

echo "Dynamic routing configured! Verify at http://localhost:1080/server-info/"

# -----------------------------------------------------------------------------
# Optional Manual Verification Steps:
# -----------------------------------------------------------------------------
# 1. Access http://localhost:1080/server-info/
# 2. Stop member1:
#    "${WORKSPACE_ROOT}/installs/member1/wlp/bin/server" stop member1
# 3. Access http://localhost:1080/server-info/ again (should route to member2)
# 4. Start member1:
#    "${WORKSPACE_ROOT}/installs/member1/wlp/bin/server" start member1
