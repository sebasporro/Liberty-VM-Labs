#########################
#  applyOverrides.sh
#########################
numParms=$#
numOverrides=$(($numParms-6))

IHS_HOME=/opt/IBM/HTTPServer

#echo "numOverrides $numOverrides"
# assign the arguets entered into a string for processing
str1=$@
#echo "str1" $str1


if [[ "$#" -lt 7 ]]; then
  echo "Missing command parameters, check usage"
  echo "---------------------------------------"
  echo "Usage:" 
  echo "-n Liberty member name"
  echo "-v Verion of Liberty to install <22.0.0.8 | 22.0.0.12>"
  echo "-h Liberty member hostname" 
  echo "   specify 'server0.gym.lan' for creating a local collective member"
  echo "   specify 'server1.gym.lan' for creating a remote collective member"
  echo "Overrides: Instruct which overrides to apply" 
  echo "   specify 'SESSIONDB' for overriding server for sesion persistance"
  echo "   specify 'MONITOR' for enabling monitor-1.0"
  echo "   specify 'TIMING' for enabling requestTiming-1.0"
  echo ""
  echo "example-local:  applyOverrides.sh -n serverName-v 22.0.0.8 -h server0.gym.lan SESSIONDB"
  echo ""
   echo "---------------------------------------"
  exit 1
fi




#iterate over the keys that are passed in, until all are processed. Make sure all flags are included
numKeys=0
while [[ $# -gt 1 ]]

do
key="$1"
#echo "key is: $key"
case $key in
    -n|--serverName)
    SERVER_NAME="$2"
    let "numKeys+=1" 
    shift # past argument
    ;;
    -v|--version)
    LIBERTY_VERSION="$2"
     let "numKeys+=1"
    shift # past argument
    ;;
    -h|--hostName)
    MEMBER_HOSTNAME="$2"
     let "numKeys+=1"
    shift # past argument
    ;;
   esac
shift # past argument or value
#echo "numKeys: $numKeys"
done

#Make sure all of the required keys were passed in (-n -w -h)
if [[ $numKeys != 3 ]]; then
  echo "---------------------------------------"
  echo "Usage:" 
  echo "-n Liberty member name"
  echo "-v Verion of Liberty to install <22.0.0.8 | 22.0.0.12>"
  echo "-h Liberty member hostname" 
  echo "   specify 'server0.gym.lan' for creating a local collective member"
  echo "   specify 'server1.gym.lan' for creating a remote collective member"
  echo "Overrides: Instruct which overrides to apply" 
  echo "   specify 'SESSIONDB' for overriding server for sesion persistance"
  echo "   specify 'MONITOR' for enabling monitor-1.0"
  echo "   specify 'TIMING' for enabling requestTiming-1.0"
  echo ""
  echo "example-local:  applyOverrides.sh -n serverName-v 22.0.0.8 -h server0.gym.lan SESSIONDB"
  echo ""
   echo "---------------------------------------"
  exit 1
fi




#Lab environment variable
LAB_HOME=/home/techzone
WORK_DIR=$LAB_HOME/lab-work
LAB_FILES=$LAB_HOME/liberty_admin_pot
SCRIPT_ARTIFACTS=$LAB_FILES/lab-scripts/scriptArtifacts
LOGS=$WORK_DIR/logs
SAVE_COMMAND="applyOverride.sh -n $SERVER_NAME -v $LIBERTY_VERSION -h $MEMBER_HOSTNAME"

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


#Ensure the -h flag contains a valid hostname for this lab environment

 if [[ "$MEMBER_HOSTNAME" = "$CONTROLLER_HOSTNAME" ]] || [[ "$MEMBER_HOSTNAME" = "$KNOWN_REMOTE_HOST1" ]]; then
      echo " "
else 
     echo "The -h flag specified contains an invalid member hostName parameter."
      echo "   specify 'server0.gym.lan' for creating a local collective member"
      echo "   specify 'server1.gym.lan' for creating a remote collective member"
     exit 1      
fi

# Is this a remote or local member being registered
if [[ "$MEMBER_HOSTNAME" = "$CONTROLLER_HOSTNAME" ]] ; then
  MEMBER_TYPE="local"
else 
  MEMBER_TYPE="remote"  
  WLP_HOME_REMOTE="/opt/IBM/liberty-staging"
fi


echo "#----------------------------------" 
echo "# Now running applyOverrides.sh" 
echo "#----------------------------------" 

sleep 5




# List the variables used in the script
echo " "  
echo "#-------------------------------------------------------------" 
echo "# Applying server configuration overrides for $MEMBER_TYPE Liberty server: $SERVER_NAME" 
echo "#-------------------------------------------------------------" 
echo " "  
echo "# Command entered: $SAVE_COMMAND" 
echo "" 




process-overrides() 
{ 
 
  if [[ "$MEMBER_TYPE" = "remote" ]]; then 
    remote-overrides
  else 
    local-overrides
  fi

}



remote-overrides()
{

echo "# scp command: scp $OVERRIDE_FILE techzone@$MEMBER_HOSTNAME:$WLP_HOME_REMOTE/$LIBERTY_VERSION-$SERVER_NAME/wlp/usr/servers/$SERVER_NAME/configDropins/overrides"

sshpass -p "IBMDem0s!" scp $OVERRIDE_FILE techzone@$MEMBER_HOSTNAME:$WLP_HOME_REMOTE/$LIBERTY_VERSION-$SERVER_NAME/wlp/usr/servers/$SERVER_NAME/configDropins/overrides
rc=$?

if [[ $rc = 0 ]]; then  
  echo ""
  echo "============================================================="
  echo ""
  echo "SUCCESS: Applying the $override_value  overides file was successful."
  echo ""
  echo "============================================================="
  echo ""
else  
  echo ""
  echo "============================================================="
  echo ""
  echo "ERROR: Could not copy the $override_value  overrides file to the server $SERVER_NAME on host $MEMBER_HOSTNAME"
  echo ""
  echo "---> Verify the server exists on the specified HOST."
  echo "---> Verify the input paramters on the script are corect and be sure you have specified the correct servername, hostname, and version."
  echo ""
  echo "============================================================="
  exit 1
fi  

}




local-overrides()
{
 
    #echo "path: $WLP_HOME/usr/servers/$SERVER_NAME/configDropins/overrides"
 
    if [ -d "$WLP_HOME/usr/servers/$SERVER_NAME/configDropins/overrides" ]; then
      #echo "The server $WLP_HOME/usr/servers/$SERVER_NAME/configDropins/overrides directory was not found"
      #exit 1
       
      echo "# cp command: cp $OVERRIDE_FILE $WLP_HOME/usr/servers/$SERVER_NAME/configDropins/overrides"

      cp $OVERRIDE_FILE $WLP_HOME/usr/servers/$SERVER_NAME/configDropins/overrides
      rc=$?
    fi
    
  if [[ $rc = 0 ]]; then  
    echo ""
    echo "============================================================="
    echo ""
    echo "SUCCESS: Applying the $override_value overides file was successful."
    echo ""
    echo "============================================================="
    echo ""  
  else  
    echo ""
    echo "============================================================="
    echo ""
    echo "ERROR: Could not copy the $override_value overrides file to the server $SERVER_NAME on host $MEMBER_HOSTNAME"
    echo ""
    echo "---> Verify the server exists on the specified HOST."
    echo "---> Verify the input paramters on the script are corect and be sure you have specified the correct servername, hostname, and version."
    echo ""
    echo "============================================================="
    exit 1
  fi  

} 
#############
#Main PROGRAM 
#############


PROCESS_OVERRIDE=""


# The oveerides parrms begin at parameter 7, after the flags.... 
for ((n=7; n<=$numParms; n++))
  do 
#get the nth paramter, starting at 7, which will be the override parms on the command
     override_value=`echo "$str1" | cut -d ' ' -f${n}`
      
#if overide parm is "SESSIONDB" then let it be know we found it      
     if [[ $override_value == "SESSIONDB" ]]; then
         PROCESS_OVERRIDE="SESSIONDB"
         echo "--------------------------"
         echo ""
         echo "Applying SESSIONDB override"
         echo ""
         echo "--------------------------"
         OVERRIDE_FILE=$SCRIPT_ARTIFACTS/httpSessionPersistence.xml
         process-overrides
         sleep 7
         #echo "restarting http server"
         $IHS_HOME/bin/apachectl -k restart
         
         
     elif [[ $override_value == "MONITOR" ]]; then
         PROCESS_OVERRIDE="MONITOR"
         echo "--------------------------"
         echo ""
         echo "Applying MONITOR override"
         echo ""
         echo "--------------------------"
         OVERRIDE_FILE=$SCRIPT_ARTIFACTS/monitor.xml
         process-overrides
     elif [[ $override_value == "TIMING" ]]; then
         PROCESS_OVERRIDE="TIMING"
         echo "--------------------------"
         echo ""
         echo "Applying TIMING override"
         echo ""
         echo "--------------------------"
         OVERRIDE_FILE=$SCRIPT_ARTIFACTS/requestTiming.xml
         process-overrides
     fi


#place holder for adding support of additinal overrides in the labs      
     if [[ $override_value == "DUMMY" ]]; then
         PROCESS_OVERRIDE="DUMMY"
         echo "--------------------------"
         echo ""
         echo "Applying DUMMY override"
         echo ""
         echo "--------------------------"
         OVERRIDE_FILE=$SCRIPT_ARTIFACTS/dummy.xml
         process-overrides
     fi      
  
done