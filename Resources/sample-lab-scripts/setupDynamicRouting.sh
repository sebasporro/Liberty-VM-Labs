##########################
# setupDynamicRouting.sh
##########################

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

cp $SCRIPTS_DIR/scriptArtifacts/dynamicRouting.xml $WLP_HOME/usr/servers/CollectiveController/configDropins/overrides/.
sleep 5
$IHS_HOME/bin/apachectl stop
if [ -e "$SCRIPTS_DIR/plugin-cfg.xml" ]; then
     rm   $SCRIPTS_DIR/plugin-cfg.xml ;
     echo "$SCRIPTS_DIR/plugin-cfg.xml file removed"
fi
if [ -e "$SCRIPTS_DIR/plugin-key.p12" ]; then
     rm   $SCRIPTS_DIR/plugin-key.p12 ;
     echo "$SCRIPTS_DIR/plugin-key.p12 file removed"
fi
if [ -e "/tmp/plugin-cfg.xml" ]; then
     rm   /tmp/plugin-cfg.xml ;
     echo "/tmp/plugin-cfg.xml file removed"
fi
if [ -e "/tmp/plugin-key.p12" ]; then
     rm   /tmp/plugin-key.p12 ;
     echo "/tmp/plugin-key.p12 file removed"
fi
if [ -e "/tmp/plugin-key.kdb" ]; then
     rm   /tmp/plugin-key.kdb ;
     echo "/tmp/plugin-key.kdb file removed"
fi
if [ -e "/tmp/plugin-key.rdb" ]; then
     rm   /tmp/plugin-key.rdb ;
     echo "/tmp/plugin-key.rdb file removed"
fi
if [ -e "/tmp/plugin-key.sth" ]; then
     rm   /tmp/plugin-key.sth ;
     echo "/tmp/plugin-key.sth file removed"
fi

if [ -e "/tmp/plugin-key.crl" ]; then
     rm   /tmp/plugin-key.crl ;
     echo "/tmp/plugin-key.crl file removed"
fi

echo ""
echo "----------------------------------------------------------------------------------------------" 
echo "AutoAcceptCertificates enabled for connection to controller  (secure connection to Controller)" 
echo "----------------------------------------------------------------------------------------------" 
echo "" 

sleep 2

$WLP_HOME/bin/dynamicRouting setup --port=$CONTROLLER_HTTPS_PORT --host=$HOSTNAME --user=admin --password=admin --keystorePassword=webAS --pluginInstallRoot=$PluginRoot --webServerNames=webserver1 --autoAcceptCertificates

sleep 2
echo "dynamicRouting setup completed"

cp plugin-cfg.xml /tmp/.
cp plugin-key.p12 /tmp/.
sleep 2

$IHS_HOME/bin/gskcapicmd -keydb -convert -pw webAS -db /tmp/plugin-key.p12 -old_format pkcs12 -target /tmp/plugin-key.kdb -new_format cms -stash 
sleep 2
echo "gskcmd convert completed"
$IHS_HOME/bin/gskcapicmd -cert -setdefault -pw webAS -db /tmp/plugin-key.kdb -label default
sleep 2
echo "gskcmd cert completed"
cp /tmp/plugin-key.kdb  $PluginRoot/config/webserver1/.
cp /tmp/plugin-key.rdb  $PluginRoot/config/webserver1/.
cp /tmp/plugin-key.sth $PluginRoot/config/webserver1/.
cp /tmp/plugin-cfg.xml $PluginRoot/config/webserver1/.
sleep 2
#Start HIS server

$IHS_HOME/bin/apachectl start

sleep 2