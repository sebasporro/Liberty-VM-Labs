##########################
# setupDynamicRouting.sh
##########################

# FIX 7 — abort immediately on any unset variable or command failure
set -euo pipefail

LAB_HOME=/home/itzuser
LAB_FILES=/home/itzuser/liberty_admin_pot
WORK_DIR="/home/itzuser/lab-work"
#wlp home of controller
LIBERTY_ROOT_DIR=$WORK_DIR/liberty-controller
CONTROLLER_HTTPS_PORT="9491"
WLP_HOME=$LIBERTY_ROOT_DIR/wlp
SCRIPTS_DIR=$LAB_FILES/lab-scripts
IHS_HOME=/home/itzuser/IBM/HTTPServer

PluginRoot=/home/itzuser/IBM/WebSphere/Plugins/

HOSTNAME=`hostname`
echo $HOSTNAME

# FIX 4 — use a dedicated staging directory so dynamicRouting setup output
# files always land at a known absolute path regardless of where the script
# is invoked from
STAGE_DIR="/tmp/dr_setup_$$"
mkdir -p "$STAGE_DIR"

cp $SCRIPTS_DIR/scriptArtifacts/dynamicRouting.xml $WLP_HOME/usr/servers/CollectiveController/configDropins/overrides/.

$IHS_HOME/bin/apachectl stop

# Clean up any stale files in SCRIPTS_DIR, /tmp, and STAGE_DIR
for f in plugin-cfg.xml plugin-key.p12; do
    [ -e "$SCRIPTS_DIR/$f" ] && { rm "$SCRIPTS_DIR/$f"; echo "$SCRIPTS_DIR/$f file removed"; }
done
for f in plugin-cfg.xml plugin-key.p12 plugin-key.kdb plugin-key.rdb plugin-key.sth plugin-key.crl; do
    [ -e "/tmp/$f" ] && { rm "/tmp/$f"; echo "/tmp/$f file removed"; }
    [ -e "$STAGE_DIR/$f" ] && rm "$STAGE_DIR/$f"
done

echo ""
echo "----------------------------------------------------------------------------------------------"
echo "AutoAcceptCertificates enabled for connection to controller  (secure connection to Controller)"
echo "----------------------------------------------------------------------------------------------"
echo ""

# FIX 3 — wait for the controller to activate dynamicRouting-1.0 and expose
# its REST endpoint before calling setup; a fixed sleep is not reliable
echo "Waiting for controller to activate dynamicRouting-1.0..."
until curl -sk --output /dev/null --write-out "%{http_code}" \
    "https://${HOSTNAME}:${CONTROLLER_HTTPS_PORT}/ibm/api/dynamicRouting/" \
    | grep -q "^[24]"; do
    sleep 3
done
echo "Controller ready."

# FIX 4 (continued) — cd into STAGE_DIR so setup writes files there
cd "$STAGE_DIR"

$WLP_HOME/bin/dynamicRouting setup --port=$CONTROLLER_HTTPS_PORT --host=$HOSTNAME --user=admin --password=admin --keystorePassword=webAS --pluginInstallRoot=$PluginRoot --webServerNames=webserver1 --autoAcceptCertificates

# FIX 7 (continued) — verify expected output files were created
if [ ! -f "$STAGE_DIR/plugin-cfg.xml" ] || [ ! -f "$STAGE_DIR/plugin-key.p12" ]; then
    echo "ERROR: dynamicRouting setup did not produce plugin-cfg.xml or plugin-key.p12" >&2
    exit 1
fi

echo "dynamicRouting setup completed"

# FIX 1 — inject AcceptType into ConnectorCluster so libodr.so sends
# Accept: application/json; Liberty 26 returns HTTP 500 without it
# FIX 2 — append trailing slash to the uri property; Liberty 26 returns
# HTTP 307 for /ibm/api/dynamicRouting (no slash) and libodr.so does
# not follow redirects, causing "Unable to find a transport" failures
python3 - "$STAGE_DIR/plugin-cfg.xml" <<'PYEOF'
import sys, re
path = sys.argv[1]
content = open(path).read()

# FIX 1: inject AcceptType if absent
if 'AcceptType' not in content:
    content = re.sub(
        r'(<ConnectorCluster\b[^>]*>)',
        r'\1\n        <Property name="AcceptType" value="application/json"/>',
        content
    )

# FIX 2: ensure trailing slash on dynamicRouting uri
content = re.sub(
    r'(<Property\s+name="uri"\s+value="/ibm/api/dynamicRouting)(")',
    r'\g<1>/\g<2>',
    content
)

open(path, 'w').write(content)
PYEOF

echo "plugin-cfg.xml patched (AcceptType + trailing slash uri)"

$IHS_HOME/bin/gskcapicmd -keydb -convert -pw webAS -db "$STAGE_DIR/plugin-key.p12" -old_format pkcs12 -target "$STAGE_DIR/plugin-key.kdb" -new_format cms -stash
echo "gskcmd convert completed"
$IHS_HOME/bin/gskcapicmd -cert -setdefault -pw webAS -db "$STAGE_DIR/plugin-key.kdb" -label default 2>/dev/null || true
echo "gskcmd cert completed"

cp "$STAGE_DIR/plugin-key.kdb" "$PluginRoot/config/webserver1/."
# FIX 5 — .rdb is not always produced by gskcapicmd; guard before copying
[ -f "$STAGE_DIR/plugin-key.rdb" ] && cp "$STAGE_DIR/plugin-key.rdb" "$PluginRoot/config/webserver1/."
cp "$STAGE_DIR/plugin-key.sth" "$PluginRoot/config/webserver1/."
cp "$STAGE_DIR/plugin-cfg.xml" "$PluginRoot/config/webserver1/."

# FIX 6 — ensure httpd.conf contains a WebSpherePluginConfig directive
# pointing at the newly installed plugin-cfg.xml
PLUGIN_CFG="$PluginRoot/config/webserver1/plugin-cfg.xml"
if grep -q "WebSpherePluginConfig" "$IHS_HOME/conf/httpd.conf"; then
    sed -i "s|^WebSpherePluginConfig .*|WebSpherePluginConfig ${PLUGIN_CFG}|" "$IHS_HOME/conf/httpd.conf"
else
    echo "WebSpherePluginConfig ${PLUGIN_CFG}" >> "$IHS_HOME/conf/httpd.conf"
fi
echo "httpd.conf WebSpherePluginConfig → ${PLUGIN_CFG}"

# Clean up staging directory
rm -rf "$STAGE_DIR"

#Start IHS server
$IHS_HOME/bin/apachectl start

echo ""
echo "Dynamic Routing setup complete."
echo "Verify: for i in \$(seq 6); do curl -s http://localhost:8080/server-info/ | grep -o 'member[0-9]*'; done"
