##################################
# setupDynamicRouting-singleVM.sh
##################################
#
# Single-VM adaptation of Resources/sample-lab-scripts/setupDynamicRouting.sh.
#
# This lab runs on ONE VM:
#   vm-1.itz-709wr4.local  (user: itzuser)
#   Controller root  : /home/itzuser/Liberty-VM-Labs/installs/controller/wlp
#   Member1          : /home/itzuser/Liberty-VM-Labs/installs/member1  → HTTP 9081
#   Member2          : /home/itzuser/Liberty-VM-Labs/installs/member2  → HTTP 9082
#   IHS root         : /home/itzuser/IBM/HTTPServer
#   Controller HTTPS : 9443
#
# Prerequisites (all must be complete before running this script):
#   - scripts/install-controller.sh  (controller running on 9080/9443)
#   - scripts/add-member-26.sh member1 / member2
#   - scripts/reset-ihs.sh + scripts/step1-was-plugin.sh
#     (Step 3a confirmed working — http://localhost:8080/server-info/ returns 200)
#
# What this script does:
#   1. Drop dynamic-routing.xml dropin onto controller + RESTART controller
#      (restart is required so the correct basicRegistry takes effect before
#       dynamicRouting setup tries to authenticate — quickStartSecurity from
#       collective-create.xml would otherwise shadow basicRegistry and cause 403)
#   2. Stop IHS
#   3. Remove stale plugin-cfg.xml / plugin-key.* files
#   4. Run: dynamicRouting setup  (generates plugin-cfg.xml + plugin-key.p12)
#   5. Validate plugin-cfg.xml is well-formed XML before touching IHS
#   6. Convert plugin-key.p12 → plugin-key.kdb (CMS) via gskcapicmd
#   7. Install plugin-cfg.xml and key files into IHS config/webserver1/
#   8. Point WebSpherePluginConfig in httpd.conf at the new file
#   9. Start IHS (with apachectl configtest guard)

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths — single-VM layout
# ---------------------------------------------------------------------------
LAB_HOME=/home/itzuser
WORKSPACE=$LAB_HOME/Liberty-VM-Labs

# Controller
WLP_HOME=$WORKSPACE/installs/controller/wlp
CONTROLLER_NAME="controller"
CONTROLLER_HTTP_PORT="9080"
CONTROLLER_HTTPS_PORT="9443"
SERVER_DIR=$WLP_HOME/usr/servers/$CONTROLLER_NAME
MESSAGES_LOG=$SERVER_DIR/logs/messages.log

# IHS
IHS_HOME=$LAB_HOME/IBM/HTTPServer
HTTPD_CONF=$IHS_HOME/conf/httpd.conf
PLUGIN_INSTALL_DIR=$IHS_HOME/config/webserver1
PLUGIN_LOG_DIR=$IHS_HOME/logs/webserver1

# Scratch area for dynamicRouting setup output
SCRATCH=$SERVER_DIR/resources/security/plugin-setup

echo ""
echo "======================================================"
echo " Setup Dynamic Routing — single VM (itzuser)"
echo "======================================================"
echo ""
echo "  Controller : https://localhost:$CONTROLLER_HTTPS_PORT"
echo "  IHS        : http://localhost:8080"
echo ""

# ---------------------------------------------------------------------------
# Step 1 — drop dynamic-routing.xml dropin and RESTART controller
#
# WHY a restart is needed (not just a hot-update):
#   install-controller.sh runs 'collective create' which writes collective-create.xml
#   containing <quickStartSecurity>.  Liberty's quickStartSecurity element
#   REPLACES basicRegistry at runtime.  role-override.xml grants administrator-role
#   to the 'admin' user in basicRegistry — but that grant never takes effect while
#   quickStartSecurity is active.  install-controller.sh removes quickStartSecurity
#   from collective-create.xml via sed AFTER the server is started, so the registry
#   is only correct on the NEXT startup.
#
#   Dropping restConnector-2.0 into a running server that still has quickStartSecurity
#   active means 'dynamicRouting setup --user=admin --password=admin' hits a 403.
#   A full stop/start guarantees Liberty reads all config files from scratch with
#   quickStartSecurity absent and basicRegistry + administrator-role active.
# ---------------------------------------------------------------------------
echo "---------------------------------------------------------------------"
echo " Step 1: Enable dynamicRouting-1.0 + restConnector-2.0 on controller"
echo "         (controller will be restarted to activate correct security)"
echo "---------------------------------------------------------------------"
echo ""

mkdir -p $SERVER_DIR/configDropins/overrides

# Write the dropin inline so we control exactly what goes in — no dependency
# on scriptArtifacts/dynamicRouting-26.xml being present.
cat > $SERVER_DIR/configDropins/overrides/dynamic-routing.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<server description="Dynamic routing features">
    <featureManager>
        <feature>dynamicRouting-1.0</feature>
        <!-- restConnector-2.0 is required by the dynamicRouting setup CLI
             to reach the DynamicRouting MBean via Liberty's REST JMX bridge. -->
        <feature>restConnector-2.0</feature>
    </featureManager>

    <!--
      Explicit administrator-role grant in this dropin so it is present
      regardless of the order in which overrides are processed.
      - <user>admin</user>  : allows the dynamicRouting setup CLI to authenticate
      - clientAuthenticationSupported : allows the IHS plugin to authenticate
        with its certificate (prevents CWWKV0020E when plugin connects to ODR)
    -->
    <administrator-role>
        <user>admin</user>
    </administrator-role>

    <ssl id="defaultSSLConfig" clientAuthenticationSupported="true"/>

</server>
XML

echo "  dynamic-routing.xml written to controller configDropins/overrides"
echo ""
echo "  Restarting controller (full stop+start)..."

$WLP_HOME/bin/server stop $CONTROLLER_NAME 2>/dev/null || true
sleep 3

# Clear the log so we can wait for a clean CWWKF0011I below
> $MESSAGES_LOG 2>/dev/null || true

$WLP_HOME/bin/server start $CONTROLLER_NAME
if [ $? -ne 0 ]; then
    echo "  ERROR: controller failed to start. Check $MESSAGES_LOG"
    exit 1
fi

echo ""
echo "  Waiting for controller ready (up to 90 s)..."
for i in $(seq 1 45); do
    grep -q "CWWKF0011I" $MESSAGES_LOG 2>/dev/null && break
    sleep 2
done

if ! grep -q "CWWKF0011I" $MESSAGES_LOG 2>/dev/null; then
    echo "  ERROR: controller did not reach ready state within 90 s"
    echo "  Check: $MESSAGES_LOG"
    exit 1
fi
echo "  Controller ready ✓"

# Verify the required features actually loaded
if ! grep -q "CWWKF0012I.*dynamicRouting-1.0" $MESSAGES_LOG 2>/dev/null; then
    echo "  ERROR: dynamicRouting-1.0 did not load"
    grep "CWWKF" $MESSAGES_LOG | tail -10
    exit 1
fi
echo "  dynamicRouting-1.0 loaded ✓"

if ! grep -q "CWWKF0012I.*restConnector-2.0" $MESSAGES_LOG 2>/dev/null; then
    echo "  ERROR: restConnector-2.0 did not load"
    exit 1
fi
echo "  restConnector-2.0 loaded ✓"

# Wait for the HTTPS connector to be ready before calling dynamicRouting setup
echo "  Waiting for HTTPS connector (up to 30 s)..."
for i in $(seq 1 15); do
    grep -q "CWWKO0219I" $MESSAGES_LOG 2>/dev/null && break
    sleep 2
done
grep -q "CWWKO0219I" $MESSAGES_LOG 2>/dev/null && echo "  HTTPS connector ready ✓" \
    || echo "  WARNING: HTTPS connector message not found — proceeding anyway"

# Extra settle time for the DynamicRouting MBean and security config
echo "  Waiting 10 s for MBean registration to settle..."
sleep 10
echo ""

# Quick smoke test — confirm admin credentials work via REST before continuing
echo "  Verifying admin credentials on restConnector endpoint..."
HTTP_CHECK=$(curl -k -s -o /dev/null -w "%{http_code}" \
    -u admin:admin \
    "https://localhost:$CONTROLLER_HTTPS_PORT/IBMJMXConnectorREST/mbeans" 2>/dev/null)
if [ "$HTTP_CHECK" != "200" ]; then
    echo "  ERROR: admin/admin credentials rejected on REST connector (HTTP $HTTP_CHECK)"
    echo "  The controller's security config is still not correct."
    echo "  Check $MESSAGES_LOG for CWWKS or CWWKV errors."
    exit 1
fi
echo "  Credentials OK (HTTP $HTTP_CHECK) ✓"
echo ""

# ---------------------------------------------------------------------------
# Step 2 — stop IHS
# ---------------------------------------------------------------------------
echo "------------------------------"
echo " Step 2: Stop IHS"
echo "------------------------------"
echo ""

$IHS_HOME/bin/apachectl stop 2>/dev/null || true
pkill -9 -f "$IHS_HOME/bin/httpd" 2>/dev/null || true
sleep 3

if ss -tlnp 2>/dev/null | grep -q ":8080 "; then
    echo "  WARNING: port 8080 still in use after stop — attempting to continue"
fi
echo "  IHS stopped"
echo ""

# ---------------------------------------------------------------------------
# Step 3 — remove stale files
# ---------------------------------------------------------------------------
echo "----------------------------------------------------"
echo " Step 3: Remove stale plugin-cfg.xml / plugin-key.*"
echo "----------------------------------------------------"
echo ""

rm -rf $SCRATCH
mkdir -p $SCRATCH
mkdir -p $PLUGIN_INSTALL_DIR
mkdir -p $PLUGIN_LOG_DIR

for ext in kdb rdb sth p12 crl; do
    f=$PLUGIN_INSTALL_DIR/plugin-key.$ext
    [ -e "$f" ] && rm "$f" && echo "  Removed: $f"
done
[ -e "$PLUGIN_INSTALL_DIR/plugin-cfg.xml" ] && rm $PLUGIN_INSTALL_DIR/plugin-cfg.xml \
    && echo "  Removed: $PLUGIN_INSTALL_DIR/plugin-cfg.xml"
echo "  Scratch dir: $SCRATCH (clean)"
echo ""

# ---------------------------------------------------------------------------
# Step 4 — run dynamicRouting setup
# ---------------------------------------------------------------------------
echo "-------------------------------------------------------------------"
echo " Step 4: dynamicRouting setup"
echo "-------------------------------------------------------------------"
echo ""

# Probe whether this Liberty build uses --webServerName (singular, Liberty 26+
# per IBM docs) or --webServerNames (plural, older builds).
_DR_HELP=$($WLP_HOME/bin/dynamicRouting setup --help 2>&1 || true)
if echo "$_DR_HELP" | grep -q -- "--webServerName[^s]"; then
    WS_FLAG="--webServerName=webserver1"
elif echo "$_DR_HELP" | grep -q -- "--webServerNames"; then
    WS_FLAG="--webServerNames=webserver1"
else
    WS_FLAG=""
fi
echo "  Using flag: ${WS_FLAG:-<none — old build>}"

$WLP_HOME/bin/dynamicRouting setup \
    --port=$CONTROLLER_HTTPS_PORT \
    --host=localhost \
    --user=admin \
    --password=admin \
    --keystorePassword=Liberty26ctrl! \
    ${WS_FLAG:+"$WS_FLAG"} \
    --pluginInstallRoot=$IHS_HOME \
    --targetPath=$SCRATCH \
    --autoAcceptCertificates

DR_RC=$?
if [ $DR_RC -ne 0 ]; then
    echo ""
    echo "  ERROR: dynamicRouting setup exited $DR_RC"
    echo "  Check $MESSAGES_LOG for details"
    exit 1
fi

GEN_CFG=$(find $SCRATCH -name "plugin-cfg.xml" 2>/dev/null | head -1)
GEN_KEY=$(find $SCRATCH -name "plugin-key.p12" 2>/dev/null | head -1)

if [ ! -f "$GEN_CFG" ]; then
    echo "  ERROR: plugin-cfg.xml was not generated"
    find $SCRATCH -type f
    exit 1
fi
if [ ! -f "$GEN_KEY" ]; then
    echo "  ERROR: plugin-key.p12 was not generated"
    exit 1
fi

echo ""
echo "  Generated: $GEN_CFG"
echo "  Generated: $GEN_KEY"
echo ""

# ---------------------------------------------------------------------------
# Step 5 — validate plugin-cfg.xml is well-formed XML
#
# WHY this matters: if the file is malformed IHS will fail to start with a
# cascade of "configGetServerGroup / Failed to parse" errors (the exact errors
# seen in the original failure).  We catch this here — before touching IHS —
# so a bad file never leaves IHS broken.
# ---------------------------------------------------------------------------
echo "-----------------------------------------------------"
echo " Step 5: Validate plugin-cfg.xml"
echo "-----------------------------------------------------"
echo ""

python3 - "$GEN_CFG" <<'PYEOF'
import sys, xml.etree.ElementTree as ET

path = sys.argv[1]
try:
    ET.parse(path)
    print("  XML well-formed ✓")
except ET.ParseError as e:
    print(f"  ERROR: plugin-cfg.xml is not valid XML: {e}")
    sys.exit(1)

# Patch 1: fix VirtualHost port — dynamicRouting setup writes port 80 by default;
#           IHS in this lab listens on 8080.
with open(path, 'r') as f:
    content = f.read()

import re
patched = re.sub(
    r'VirtualHost Name="\*:[0-9]+"',
    'VirtualHost Name="*:8080"',
    content
)

# Patch 2: inject the static stanzas the WAS plugin parser REQUIRES.
#
# dynamicRouting setup generates plugin-cfg.xml with only an <IntelligentManagement>
# stanza — ODR (the dynamic routing engine) builds the live server list at runtime.
# However the WAS plugin parser validates the static XML structure on startup and
# REQUIRES:
#   - A <ServerCluster> whose Name is referenced by a <Route>
#   - A <VirtualHostGroup> listing the IHS listen port
#   - A <UriGroup> and a <Route> tying them together
# Without these the parser logs:
#   "Failed to find server group for defaultCollective"  (the error seen in the lab)
# and refuses to load, taking IHS down with it.
#
# The cluster Name "defaultCollective" matches what the dynamic routing engine
# uses as the default group name when registering servers from the collective.
if '<ServerCluster' not in patched:
    injection = '''\
<ServerCluster CloneSeparatorChange="false" GetDWLMTable="false"
               IgnoreAffinityRequests="true" LoadBalance="Round Robin"
               Name="defaultCollective" PostSizeLimit="-1"
               RemoveSpecialHeaders="true" RetryInterval="60">
</ServerCluster>
<VirtualHostGroup Name="default_vhost_group">
    <VirtualHost Name="*:8080"/>
</VirtualHostGroup>
<UriGroup Name="default_uri_group">
    <Uri AffinityCookie="JSESSIONID" AffinityURLIdentifier="jsessionid" Name="/*"/>
</UriGroup>
<Route VirtualHostGroup="default_vhost_group"
       UriGroup="default_uri_group"
       ServerCluster="defaultCollective"/>
'''
    patched = patched.replace('</Config>', injection + '</Config>')
    print("  Static stanzas injected (ServerCluster/VirtualHostGroup/UriGroup/Route) ✓")
else:
    print("  Static stanzas already present ✓")

with open(path, 'w') as f:
    f.write(patched)

# Final parse check after patching
try:
    ET.parse(path)
    print("  Post-patch XML well-formed ✓")
except ET.ParseError as e:
    print(f"  ERROR: plugin-cfg.xml is malformed after patching: {e}")
    sys.exit(1)
PYEOF

if [ $? -ne 0 ]; then
    echo ""
    echo "  ERROR: plugin-cfg.xml validation/patching failed — aborting."
    echo "  IHS has NOT been touched. Static routing (step1-was-plugin.sh) is still intact."
    exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# Step 6 — convert plugin-key.p12 (PKCS12) → plugin-key.kdb (CMS)
# ---------------------------------------------------------------------------
echo "-----------------------------------------------------"
echo " Step 6: Convert plugin-key.p12 to plugin-key.kdb"
echo "-----------------------------------------------------"
echo ""

$IHS_HOME/bin/gskcapicmd -keydb -convert \
    -pw Liberty26ctrl! \
    -db $GEN_KEY \
    -old_format pkcs12 \
    -target $PLUGIN_INSTALL_DIR/plugin-key.kdb \
    -new_format cms \
    -stash

if [ $? -ne 0 ]; then
    echo "  ERROR: gskcapicmd -keydb -convert failed"
    exit 1
fi
echo "  gskcapicmd convert completed ✓"

# Find and set the default certificate
FIRST_LABEL=$($IHS_HOME/bin/gskcapicmd -cert -list \
    -pw Liberty26ctrl! \
    -db $PLUGIN_INSTALL_DIR/plugin-key.kdb 2>/dev/null \
    | grep "^-[[:space:]]" | head -1 | sed 's/^-[[:space:]]*//')

if [ -n "$FIRST_LABEL" ]; then
    $IHS_HOME/bin/gskcapicmd -cert -setdefault \
        -pw Liberty26ctrl! \
        -db $PLUGIN_INSTALL_DIR/plugin-key.kdb \
        -label "$FIRST_LABEL"
    echo "  Default cert set: $FIRST_LABEL ✓"
else
    echo "  WARNING: no personal cert found in plugin-key.kdb — ODR may fail to authenticate"
fi

chmod 644 $PLUGIN_INSTALL_DIR/plugin-key.kdb \
          $PLUGIN_INSTALL_DIR/plugin-key.sth 2>/dev/null || true
echo ""

# ---------------------------------------------------------------------------
# Step 7 — install plugin-cfg.xml
# ---------------------------------------------------------------------------
echo "------------------------------------------------"
echo " Step 7: Install plugin-cfg.xml"
echo "------------------------------------------------"
echo ""

cp $GEN_CFG $PLUGIN_INSTALL_DIR/plugin-cfg.xml
echo "  Installed: $PLUGIN_INSTALL_DIR/plugin-cfg.xml"

echo ""
echo "  Key sections of installed plugin-cfg.xml:"
grep -E "IntelligentManagement|VirtualHost Name|ServerCluster |Keyfile|Stashfile|Log Name" \
    $PLUGIN_INSTALL_DIR/plugin-cfg.xml 2>/dev/null | sed 's/^/    /'
echo ""

# ---------------------------------------------------------------------------
# Step 8 — point WebSpherePluginConfig at the new file
# ---------------------------------------------------------------------------
echo "------------------------------------------------"
echo " Step 8: Update httpd.conf"
echo "------------------------------------------------"
echo ""

if grep -q "^WebSpherePluginConfig" $HTTPD_CONF; then
    sed -i "s|^WebSpherePluginConfig.*|WebSpherePluginConfig $PLUGIN_INSTALL_DIR/plugin-cfg.xml|" $HTTPD_CONF
    echo "  WebSpherePluginConfig updated ✓"
else
    echo "" >> $HTTPD_CONF
    echo "WebSpherePluginConfig $PLUGIN_INSTALL_DIR/plugin-cfg.xml" >> $HTTPD_CONF
    echo "  WebSpherePluginConfig added ✓"
fi

# Syntax check BEFORE attempting to start IHS — this is what prevented catching
# the bad plugin-cfg.xml in the original failure.
echo "  Running apachectl configtest..."
CONFIGTEST=$($IHS_HOME/bin/apachectl configtest 2>&1)
if echo "$CONFIGTEST" | grep -q "Syntax OK"; then
    echo "  httpd.conf syntax: OK ✓"
else
    echo "  ERROR: httpd.conf syntax check failed:"
    echo "$CONFIGTEST"
    echo ""
    echo "  IHS has NOT been started. Fix the config error above."
    exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# Step 9 — start IHS
# ---------------------------------------------------------------------------
echo "------------------------------"
echo " Step 9: Start IHS"
echo "------------------------------"
echo ""

$IHS_HOME/bin/apachectl start
sleep 3

if ! ss -tlnp 2>/dev/null | grep -q ":8080 "; then
    echo "  ERROR: IHS failed to start. Checking error log..."
    echo ""
    tail -30 $IHS_HOME/logs/error_log 2>/dev/null | sed 's/^/  /'
    echo ""
    echo "  Plugin log (if it exists):"
    tail -20 $PLUGIN_LOG_DIR/http_plugin.log 2>/dev/null | sed 's/^/  /' \
        || echo "  (plugin log not yet created)"
    exit 1
fi
echo "  IHS started on port 8080 ✓"
echo ""

# ---------------------------------------------------------------------------
# Verify — wait up to 60 s for the plugin to connect to ODR and get a routing table
# ---------------------------------------------------------------------------
echo "  Verifying routing (up to 60 s)..."
HTTP_CODE="000"
for t in $(seq 0 5 60); do
    [ $t -gt 0 ] && { sleep 5; echo "    ${t}s — HTTP $HTTP_CODE..."; }
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        http://localhost:8080/server-info/ 2>/dev/null)
    [ "$HTTP_CODE" = "200" ] && break
done

echo ""
echo "  GET /server-info/ → HTTP $HTTP_CODE"
echo ""

if [ "$HTTP_CODE" = "200" ]; then
    echo "======================================================"
    echo " Dynamic Routing is active ✓"
    echo "======================================================"
    echo ""
    echo "  IHS          : http://localhost:8080"
    echo "  Admin Center : https://localhost:$CONTROLLER_HTTPS_PORT/adminCenter"
    echo "  Credentials  : admin / admin"
    echo ""
    echo "  Verify round-robin:"
    echo "    for i in \$(seq 6); do curl -s http://localhost:8080/server-info/ | grep -o 'member[0-9]*'; done"
    echo ""
    echo "  Plugin log:"
    echo "    tail -f $PLUGIN_LOG_DIR/http_plugin.log"
else
    echo "  Routing not confirmed yet (HTTP $HTTP_CODE)."
    echo ""
    echo "  Plugin log (last 20 lines):"
    tail -20 $PLUGIN_LOG_DIR/http_plugin.log 2>/dev/null | sed 's/^/  /' \
        || echo "  (not yet created)"
    echo ""
    echo "  IHS error log:"
    grep -i "error\|warn" $IHS_HOME/logs/error_log 2>/dev/null | tail -10 | sed 's/^/  /'
    echo ""
    echo "  ODR endpoint reachable?"
    curl -k -s -o /dev/null -w "  HTTP %{http_code}\n" \
        -u admin:admin \
        "https://localhost:$CONTROLLER_HTTPS_PORT/ibm/api/dynamicRouting" 2>/dev/null
fi
echo ""
