#########################
#  demo-applyRoutingRules.sh
#########################

# assign the arguets entered into a string for processing
str1=$@
#echo "str1" $str1

#  -s [appServer1 | appServer2 | all 


if [[ "$#" -lt 2 ]]; then
  echo "Missing command parameters, check usage"
  echo "---------------------------------------"
  echo "Usage:" 
  echo "-s The server(s) the routing rule should send requests [ appServer1 | appServer2 | all ]"
  echo ""
  echo "example: applyRoutingRules.sh -s appServer1"
  echo ""
  echo "---------------------------------------"
  exit 1
fi

IHS_HOME=/opt/IBM/HTTPServer

#iterate over the keys that are passed in, until all are processed
numKeys=0
while [[ $# -gt 1 ]]

do
key="$1"
#echo "key is: $key"
case $key in
    -s|--command)
    APP_SERVER="$2"
    let "numKeys+=1" 
    shift # past argument
    ;;
  esac
shift # past argument or value
#echo "numKeys: $numKeys"
done

#Make sure all of the required keys were passed in (-s)
if [[ $numKeys != 1 ]]; then
  echo "Missing command parameters, check usage"
  echo "---------------------------------------"
  echo "Usage:" 
  echo "-s The server(s) the routing rule should send requests [ appServer1 | appServer2 | all ]"
  echo ""
  echo "example: applyRoutingRules.sh -s appServer1"
  echo ""
  echo "---------------------------------------"
  exit 1
fi


#Ensure the -s flag matches appServer1 | appServer2 | all | for this lab environment

echo "The '-s $APP_SERVER' flag was specified for the script"

 if [[ "$APP_SERVER" = "appServer1" ]] || [[ "$APP_SERVER" = "appServer2" ]]  || [[ "$APP_SERVER" = "all" ]]; then
     echo "The command input is: $APP_SERVER"
else 
     echo "The -s flag specified contains an invalid appServer parameter."
     echo "   specify 'appServer1' to route request to only appServer1"
     echo "   specify 'appServer2' to route request to only appServer2"
     echo "   specify 'all' to route requests to appServer1 and appServer2"
     exit 1      
fi

#if APP_SERVER is set to "all", then update the variable to "appServer1,appServer2*"
 if [[ "$APP_SERVER" = "all" ]]; then 
    echo "setting APP_SERVER to appServer1,appServer2"
    APP_SERVER="appServer1,appServer2"
 fi

#Lab environment variable
LAB_HOME=/home/techzone
WORK_DIR=$LAB_HOME/lab-work
LAB_FILES=$LAB_HOME/liberty_admin_pot
SCRIPT_ARTIFACTS=$LAB_FILES/lab-scripts/scriptArtifacts
LOGS=$WORK_DIR/logs
SAVE_COMMAND="applyRoutingRules.sh -s $APP_SERVER"


LIBERTY_ROOT=$WORK_DIR/liberty-staging
WLP_HOME="$LIBERTY_ROOT/$LIBERTY_VERSION-$SERVER_NAME/wlp"  #this needs to be the liberty home for the verion of Liberty unzipped

LOG=$LOGS/sessiondb-overrides-$LIBERTY_VERSION-$SERVER_NAME.log

#Controller variables
CONTROLLER_NAME="CollectiveController"
CONTROLLER_ROOT_DIR="$WORK_DIR/liberty-controller"
CONTROLLER_HTTPS_PORT=9491
CONTROLLER_HOSTNAME=`hostname`
CONTROLLER_WLP_HOME="$CONTROLLER_ROOT_DIR/wlp"


#Remote member variables
KNOWN_REMOTE_HOST1="server1.gym.lan"



echo "#----------------------------------" 
echo "# Now running applyRoutingRules.sh" 
echo "#----------------------------------" 

sleep 3

process-overrides()
{

  OVERRIDE_FILE="demo-dynamicRoutingRules.xml"
  
 
   if [ -d "$CONTROLLER_WLP_HOME/usr/servers/$CONTROLLER_NAME/configDropins/overrides" ]; then
       
      echo "# cp command: cp $SCRIPT_ARTIFACTS/$OVERRIDE_FILE $CONTROLLER_WLP_HOME/usr/servers/$CONTROLLER_NAME/configDropins/overrides"

      cp $SCRIPT_ARTIFACTS/$OVERRIDE_FILE $CONTROLLER_WLP_HOME/usr/servers/$CONTROLLER_NAME/configDropins/overrides
      rc=$?
    fi
    
 if [[ $rc = 0 ]]; then  
 
#   sed -i 's/appServer1/'$APP_SERVER'/g' $CONTROLLER_WLP_HOME/usr/servers/$CONTROLLER_NAME/configDropins/overrides/$OVERRIDE_FILE 



#  echo ""
#  echo "Routing Rule is now set to send requests to '$APP_SERVER' Liberty server(s)" 
#  echo ""
   sleep 1
   #echo "restarting http server"
   $IHS_HOME/bin/apachectl -k restart
   sleep 3
    echo ""
    echo "============================================================="
    echo ""
    echo "Routing Rule is now set to send requests to '$APP_SERVER' Liberty server(s)" 
    echo ""
    echo "SUCCESS: Routing Rules Applied."
    echo ""
    echo "============================================================="
    echo ""  
  else  
    echo ""
    echo "============================================================="
    echo ""
    echo "ERROR: Could not apply the routing rule for the controller: $CONTROLLER_NAME"
    echo ""
    echo "---> Verify the Controller exists."
    echo ""
    echo "============================================================="
    exit 1
  fi  

} 
#############
#Main PROGRAM 
#############


process-overrides
        