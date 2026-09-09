#!/bin/bash
# =============================================================================
# step2-dynamic-routing.sh
# Enables Liberty Dynamic Routing (Intelligent Management) for a Liberty
# collective. Follows the IBM documentation procedure:
#   https://www.ibm.com/docs/en/was-liberty/nd?topic=collectives-setting-up-dynamic-routing-single-liberty-collective
#
# Steps performed (single-VM variant — controller and IHS on the same host):
#
#   Step 1 — Enable dynamicRouting-1.0 on the controller
#             (pre-requisite: already declared in configDropins/overrides/role-override.xml)
#
#   Step 2 — Start / verify the controller is running
#             (pre-requisite: controller must be started before running this script)
#
#   Step 3 — Run 'dynamicRouting setup' on the controller to generate
#             plugin-key.p12 and plugin-cfg.xml
#
#   Step 4 — Copy generated files to a temporary directory on the web server host
#             (single-VM: TEMP_DIR serves as both source and staging area)
#
#   Step 5 — Run gskcapicmd to convert plugin-key.p12 (PKCS12) to CMS format
#             (.kdb / .sth) as required by the WebSphere plug-in
#
#   Step 6 — Set the personal certificate as default in the CMS keystore
#
#   Step 7 — Copy plugin-key.kdb, plugin-key.rdb, plugin-key.sth to
#             $IHS/config/webserver1/
#
#   Step 8 — Copy plugin-cfg.xml to the directory referenced by the
#             WebSpherePluginConfig directive in httpd.conf
#
#   Step 9 — Start the web server and begin routing to the collective
#
#   (Liberty 26 extras applied automatically after Step 3):
#     - Inject AcceptType=application/json into ConnectorCluster
#     - Ensure trailing slash on /ibm/api/dynamicRouting URI
#     - Patch Keyfile/Stashfile paths to final plugin target directory
#
# Prerequisites:
#   - Controller running on HTTPS 9443 with dynamicRouting-1.0 feature
#   - Collective members running
#   - IHS installed and mod_was_ap24_http.so present
# =============================================================================


cd ~/Liberty-VM-Labs/installs/controller/wlp/bin/
./dynamicRouting setup   --host=localhost --port=9443   --user=admin --password=admin   --keystorePassword="Liberty26ctrl!"   --pluginInstallRoot=/home/itzuser/usr/IBM/IHS/plugin  --webServerNames=webserver1   --autoAcceptCertificates 2>&1

mkdir -p ~/temp/dynamicRouting
mv ~/Liberty-VM-Labs/installs/controller/wlp/bin/plugin-cfg.xml ~/temp/dynamicRouting
mv ~/Liberty-VM-Labs/installs/controller/wlp/bin/plugin-key.p12 ~/temp/dynamicRouting
cp ~/temp/dynamicRouting/plugin-cfg.xml ~/usr/IBM/IHS/plugin/config/webserver1/

gskcapicmd -keydb -convert -pw "Liberty26ctrl!" -db ~/temp/dynamicRouting/plugin-key.p12 -old_format pkcs12 -target ~/temp/dynamicRouting/plugin-key.kdb -new_format cms -stash
gskcapicmd -cert -setdefault -pw "Liberty26ctrl!" -db ~/temp/dynamicRouting/plugin-key.kdb -label default
cp ~/temp/dynamicRouting/plugin-key.kdb /home/itzuser/usr/IBM/IHS/plugin/config/webserver1/
cp ~/temp/dynamicRouting/plugin-key.sth /home/itzuser/usr/IBM/IHS/plugin/config/webserver1/
ls -lrt /home/itzuser/usr/IBM/IHS/plugin/config/webserver1/
cat ~/usr/IBM/IHS/plugin/config/webserver1/plugin-cfg.xml

~/usr/IBM/IHS/bin/apachectl stop
~/usr/IBM/IHS/bin/apachectl start 
cat ~/usr/IBM/IHS/plugin/logs/webserver1/http_plugin.log

# Access the page url http://localhost:1080/server-info/
# Stop Liberty inatcen
/home/itzuser/Liberty-VM-Labs/installs/member1/wlp/bin/server stop member1

# Access the page url http://localhost:1080/server-info/
# Start Liberty inatcen
/home/itzuser/Liberty-VM-Labs/installs/member1/wlp/bin/server start member1

