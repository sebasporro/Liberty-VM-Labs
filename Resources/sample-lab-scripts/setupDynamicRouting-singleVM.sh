##################################
# setupDynamicRouting-singleVM.sh
##################################
#
# Single-VM adaptation of Resources/sample-lab-scripts/setupDynamicRouting.sh.
#
# The reference lab (setupDynamicRouting.sh) runs across TWO VMs:
#   server0.gym.lan  — controller + IHS  (Liberty root: /home/techzone/lab-work/liberty-controller)
#   server1.gym.lan  — collective member  (Liberty root: /opt/IBM/wlp)
#   IHS root         : /opt/IBM/HTTPServer
#   Plugin root      : /opt/IBM/WebSphere/Plugins
#   Controller HTTPS : 9491
#
# This lab runs on ONE VM:
#   vm-1.itz-709wr4.local  (user: itzuser)
#   Controller root  : /home/itzuser/Liberty-VM-Labs/installs/controller/wlp
#   Member1          : /home/itzuser/Liberty-VM-Labs/installs/member1  → HTTP 9081
#   Member2          : /home/itzuser/Liberty-VM-Labs/installs/member2  → HTTP 9082
#   IHS root         : /home/itzuser/IBM/HTTPServer
#   Plugin root (IHS): /home/itzuser/IBM/HTTPServer
#   Controller HTTPS : 9443
#
# Prerequisites (all must be complete before running this script):
#   - scripts/install-controller.sh  (controller running on 9080/9443)
#   - scripts/add-member-26.sh member1  (member1 running on 9081)
#   - scripts/add-member-26.sh member2  (member2 running on 9082)
#   - scripts/reset-ihs.sh + scripts/step1-was-plugin.sh  (Step 3a done — static
#     round-robin confirmed working via IHS:8080)
#
# What this script does (mirrors setupDynamicRouting.sh step by step):
#   1. Drop dynamicRouting.xml into controller configDropins/overrides
#   2. Restart IHS (stop before dynamicRouting setup, same as reference lab)
#   3. Remove any stale plugin-cfg.xml and plugin-key.* files
#   4. Run: dynamicRouting setup  → generates plugin-cfg.xml + plugin-key.p12
#   5. Convert plugin-key.p12 → plugin-key.kdb (CMS) via gskcapicmd
#   6. Install plugin-key.kdb/.rdb/.sth + plugin-cfg.xml into IHS config/webserver1/
#   7. Add WebSpherePluginConfig directive to httpd.conf
#   8. Start IHS

HOSTNAME=$(hostname)
echo $HOSTNAME

# ---------------------------------------------------------------------------
# Paths — single-VM layout
# ---------------------------------------------------------------------------
LAB_HOME=/home/itzuser
WORKSPACE=$LAB_HOME/Liberty-VM-Labs

# Controller
WLP_HOME=$WORKSPACE/installs/controller/wlp
CONTROLLER_NAME="controller"
CONTROLLER_HTTPS_PORT="9443"

# Script artifacts (XML dropins live alongside the sample scripts)
SCRIPTS_DIR=$WORKSPACE/Resources/sample-lab-scripts/scriptArtifacts

# IHS — single VM: IHS root is also the plugin install root
IHS_HOME=$LAB_HOME/IBM/HTTPServer
PluginRoot=$IHS_HOME

# Plugin key output directory (where IHS reads it at runtime)
PLUGIN_INSTALL_DIR=$IHS_HOME/config/webserver1

# ---------------------------------------------------------------------------
# Step 1 — enable dynamicRouting-1.0 on the controller
#           (reference: setupDynamicRouting.sh line 20)
#
# The reference lab drops dynamicRouting.xml into the controller overrides.
# That file only adds the dynamicRouting-1.0 feature — security (administrator-role
# and basicRegistry) is already present in the controller's role-override.xml.
# Same pattern here: role-override.xml already has:
#   appSecurity-5.0 + basicRegistry(admin) + administrator-role(admin)
# so we only need to add the two dynamic routing features.
# ---------------------------------------------------------------------------
echo ""
echo "---------------------------------------------------------------------"
echo " Step 1: Enable dynamicRouting-1.0 + restConnector-2.0 on controller"
echo "---------------------------------------------------------------------"
echo ""

mkdir -p $WLP_HOME/usr/servers/$CONTROLLER_NAME/configDropins/overrides

# Use dynamicRouting-26.xml (adds restConnector-2.0 needed by Liberty 26 CLI).
# The original dynamicRouting.xml from the reference lab only has dynamicRouting-1.0
# which was sufficient for Liberty 22 but the setup CLI in Liberty 26 also needs
# restConnector-2.0 to reach the DynamicRouting MBean.
cp $SCRIPTS_DIR/dynamicRouting-26.xml \
   $WLP_HOME/usr/servers/$CONTROLLER_NAME/configDropins/overrides/dynamicRouting.xml

echo "dynamicRouting.xml dropped into controller configDropins/overrides"

# Give Liberty a moment to pick up the new dropin (hot update)
sleep 5

# ---------------------------------------------------------------------------
# Step 2 — stop IHS before running dynamicRouting setup
#           (reference: setupDynamicRouting.sh line 22)
# ---------------------------------------------------------------------------
echo ""
echo "------------------------------"
echo " Step 2: Stop IHS"
echo "------------------------------"
echo ""

$IHS_HOME/bin/apachectl stop
sleep 3

# ---------------------------------------------------------------------------
# Step 3 — remove any stale plugin-cfg.xml and plugin-key.* files
#           (reference: setupDynamicRouting.sh lines 23-55)
#
# The reference lab cleans /tmp and $SCRIPTS_DIR.
# Here we clean the IHS config/webserver1/ directory and a local scratch area.
# ---------------------------------------------------------------------------
echo ""
echo "----------------------------------------------------"
echo " Step 3: Remove stale plugin-cfg.xml / plugin-key.*"
echo "----------------------------------------------------"
echo ""

SCRATCH=$WORKSPACE/installs/controller/wlp/usr/servers/$CONTROLLER_NAME/resources/security/plugin-setup
mkdir -p $SCRATCH

for f in $SCRATCH/plugin-cfg.xml $SCRATCH/plugin-key.p12; do
    if [ -e "$f" ]; then rm "$f"; echo "$f removed"; fi
done

for ext in kdb rdb sth p12; do
    f=$PLUGIN_INSTALL_DIR/plugin-key.$ext
    if [ -e "$f" ]; then rm "$f"; echo "$f removed"; fi
done

if [ -e "$PLUGIN_INSTALL_DIR/plugin-cfg.xml" ]; then
    rm $PLUGIN_INSTALL_DIR/plugin-cfg.xml
    echo "$PLUGIN_INSTALL_DIR/plugin-cfg.xml removed"
fi

# ---------------------------------------------------------------------------
# Step 4 — run dynamicRouting setup
#           (reference: setupDynamicRouting.sh line 65)
#
# Key differences from the reference:
#   --port        : 9443  (was 9491 in two-VM lab)
#   --host        : localhost  (was $HOSTNAME = server0.gym.lan)
#   --pluginInstallRoot : IHS root  (same role as /opt/IBM/WebSphere/Plugins in ref)
#   --targetPath  : writes output files here instead of the working directory
#   --webServerNames : webserver1  (same logical name)
#   --autoAcceptCertificates : same flag as reference lab
# ---------------------------------------------------------------------------
echo ""
echo "-------------------------------------------------------------------"
echo " AutoAcceptCertificates enabled for connection to controller"
echo " (secure connection to controller)"
echo "-------------------------------------------------------------------"
echo ""

sleep 2

mkdir -p $PLUGIN_INSTALL_DIR

$WLP_HOME/bin/dynamicRouting setup \
    --port=$CONTROLLER_HTTPS_PORT \
    --host=localhost \
    --user=admin \
    --password=admin \
    --keystorePassword=Liberty26ctrl! \
    --webServerNames=webserver1 \
    --pluginInstallRoot=$PluginRoot \
    --targetPath=$SCRATCH \
    --autoAcceptCertificates

sleep 2
echo "dynamicRouting setup completed"

# Locate the generated files in the scratch directory
GEN_CFG=$(find $SCRATCH -name "plugin-cfg.xml" 2>/dev/null | head -1)
GEN_KEY=$(find $SCRATCH -name "plugin-key.p12" 2>/dev/null | head -1)

if [ ! -f "$GEN_CFG" ]; then
    echo "ERROR: plugin-cfg.xml was not generated. Check the output above."
    exit 1
fi
if [ ! -f "$GEN_KEY" ]; then
    echo "ERROR: plugin-key.p12 was not generated. Check the output above."
    exit 1
fi

echo "Generated: $GEN_CFG"
echo "Generated: $GEN_KEY"

# ---------------------------------------------------------------------------
# Step 5 — convert plugin-key.p12 (PKCS12) → plugin-key.kdb (CMS)
#           (reference: setupDynamicRouting.sh lines 74-79)
#
# gskcapicmd is the GSKit command bundled with IHS.
# The WAS plugin requires the keystore in CMS (.kdb) format.
# ---------------------------------------------------------------------------
echo ""
echo "-----------------------------------------------------"
echo " Step 5: Convert plugin-key.p12 to plugin-key.kdb"
echo "-----------------------------------------------------"
echo ""

$IHS_HOME/bin/gskcapicmd -keydb -convert \
    -pw Liberty26ctrl! \
    -db $GEN_KEY \
    -old_format pkcs12 \
    -target $PLUGIN_INSTALL_DIR/plugin-key.kdb \
    -new_format cms \
    -stash

sleep 2
echo "gskcapicmd convert completed"

# Set the default certificate in the converted keystore
# The reference lab hard-codes the label "default"; we find the first personal cert.
FIRST_LABEL=$($IHS_HOME/bin/gskcapicmd -cert -list \
    -pw Liberty26ctrl! \
    -db $PLUGIN_INSTALL_DIR/plugin-key.kdb 2>/dev/null \
    | grep "^-[[:space:]]" | head -1 | sed 's/^-[[:space:]]*//')

if [ -n "$FIRST_LABEL" ]; then
    $IHS_HOME/bin/gskcapicmd -cert -setdefault \
        -pw Liberty26ctrl! \
        -db $PLUGIN_INSTALL_DIR/plugin-key.kdb \
        -label "$FIRST_LABEL"
    echo "Default cert set: $FIRST_LABEL"
fi

sleep 2
echo "gskcapicmd cert completed"

# ---------------------------------------------------------------------------
# Step 6 — install plugin-cfg.xml and key files into IHS config/webserver1/
#           (reference: setupDynamicRouting.sh lines 80-83)
#
# The reference lab copies to /opt/IBM/WebSphere/Plugins/config/webserver1/.
# Here the equivalent path is $IHS_HOME/config/webserver1/ (same structure).
#
# Also fix the VirtualHost port: dynamicRouting setup writes port 80 by default;
# IHS in this lab listens on 8080.
# ---------------------------------------------------------------------------
echo ""
echo "------------------------------------------------"
echo " Step 6: Install plugin-cfg.xml and key files"
echo "------------------------------------------------"
echo ""

# The dynamicRouting setup generates plugin-cfg.xml with only the
# <IntelligentManagement> stanza — no VirtualHostGroup/ServerCluster/Route.
# ODR builds the server list dynamically at runtime from the collective.
# However ODR still needs a <VirtualHostGroup> to know which incoming port
# to intercept. Without it, initializeODR fails.
# Inject a minimal VirtualHostGroup + UriGroup + Route block before </Config>.
sed -i "s|</Config>|<VirtualHostGroup Name=\"default_vhost_group\">\n\
    <VirtualHost Name=\"*:8080\"/>\n\
</VirtualHostGroup>\n\
<UriGroup Name=\"default_uri_group\">\n\
    <Uri AffinityCookie=\"JSESSIONID\" AffinityURLIdentifier=\"jsessionid\" Name=\"/*\"/>\n\
</UriGroup>\n\
<Route VirtualHostGroup=\"default_vhost_group\" UriGroup=\"default_uri_group\" ServerCluster=\"defaultCollective\"/>\n\
</Config>|" $GEN_CFG

# Install plugin-cfg.xml
cp $GEN_CFG $PLUGIN_INSTALL_DIR/plugin-cfg.xml
echo "$PLUGIN_INSTALL_DIR/plugin-cfg.xml installed"

# The .kdb/.sth/.rdb files were written directly into $PLUGIN_INSTALL_DIR
# by gskcapicmd above (--target already pointed there).
echo "$PLUGIN_INSTALL_DIR/plugin-key.kdb installed"
echo "$PLUGIN_INSTALL_DIR/plugin-key.sth installed"
[ -f $PLUGIN_INSTALL_DIR/plugin-key.rdb ] && echo "$PLUGIN_INSTALL_DIR/plugin-key.rdb installed"

# Ensure IHS worker can read the keystore files
chmod 644 $PLUGIN_INSTALL_DIR/plugin-key.kdb \
          $PLUGIN_INSTALL_DIR/plugin-key.sth 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 7 — add WebSpherePluginConfig directive to httpd.conf
#           (not explicit in reference lab — the plugin-cfg.xml path is
#           already baked into httpd.conf by the two-VM setup; here we ensure it)
# ---------------------------------------------------------------------------
HTTPD_CONF=$IHS_HOME/conf/httpd.conf

if grep -q "^WebSpherePluginConfig" $HTTPD_CONF; then
    sed -i "s|^WebSpherePluginConfig.*|WebSpherePluginConfig $PLUGIN_INSTALL_DIR/plugin-cfg.xml|" $HTTPD_CONF
    echo "WebSpherePluginConfig updated in httpd.conf"
else
    echo "" >> $HTTPD_CONF
    echo "WebSpherePluginConfig $PLUGIN_INSTALL_DIR/plugin-cfg.xml" >> $HTTPD_CONF
    echo "WebSpherePluginConfig added to httpd.conf"
fi

sleep 2

# ---------------------------------------------------------------------------
# Step 8 — start IHS
#           (reference: setupDynamicRouting.sh line 87)
# ---------------------------------------------------------------------------
echo ""
echo "------------------------------"
echo " Step 8: Start IHS"
echo "------------------------------"
echo ""

$IHS_HOME/bin/apachectl start

sleep 2
echo ""
echo "==========================="
echo " Dynamic Routing is active"
echo "==========================="
echo ""
echo "  IHS          : http://localhost:8080"
echo "  Admin Center : https://localhost:$CONTROLLER_HTTPS_PORT/adminCenter"
echo "  Credentials  : admin / admin"
echo ""
echo "  Verify round-robin across members:"
echo "    for i in \$(seq 6); do curl -s http://localhost:8080/server-info/ | grep -o 'member[0-9]*'; done"
echo ""
echo "  Plugin log:"
echo "    tail -f $IHS_HOME/logs/webserver1/http_plugin.log"
echo ""
