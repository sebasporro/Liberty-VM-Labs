####################
#  addMember.sh
####################

numParms=$#

SKIP_P=$9
#echo "skip prompt: $SKIP_PROMPT"

if [[ "$#" -lt 8 ]]; then
  echo "Missing command parameters, check usage"
  echo "---------------------------------------"
   echo "Usage:" 
  echo "-n Liberty member name"
  echo "-v Verion of Liberty to install <22.0.0.8 | 22.0.0.12>"
  echo "-p HTTP:HTTPS port for Liberty server"
  echo "-h Liberty member hostname" 
  echo "   specify 'server0.gym.lan' for creating a local collective member"
  echo "   specify 'server1.gym.lan' for creating a remote collective member"
  echo ""
  echo "example: addMember.sh -n server1 -v 22.0.0.8 -p 9080:9443 -h server0.gym.lan"
  echo ""
   echo "---------------------------------------"
  exit 1
fi


#iterate over the keys that are passed in, until all are processed
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
    -v|--verion)
    LIBERTY_VERSION="$2"
     let "numKeys+=1"
    shift # past argument
    ;;
    -p|--ports)
    PORTS="$2"
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

#Make sure all of the required keys were passed in (-n -p -s -h)
if [[ $numKeys != 4 ]]; then
  echo "---------------------------------------"
  echo "Missing required FLAGS, check usage"
  echo "---------------------------------------"
  echo "Usage:" 
  echo "-n Liberty member name"
  echo "-v Verion of Liberty to install <22.0.0.8 | 22.0.0.12>"
  echo "-p HTTP:HTTPS port for Liberty server"
  echo "-h Liberty member hostname" 
  echo "   specify 'server0.gym.lan' for creating a local collective member"
  echo "   specify 'server1.gym.lan' for creating a remote collective member"
  echo ""
  echo "example: addMember.sh -n server1 -v 22.0.0.8 -p 9080:9443 -h server0.gym.lan"
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
SAVE_COMMAND="addMember.sh -n $SERVER_NAME -v $LIBERTY_VERSION -p $PORTS -h $MEMBER_HOSTNAME"

#Controller variables
CONTROLLER_NAME="CollectiveController"
CONTROLLER_ROOT_DIR=$WORK_DIR/liberty-controller
CONTROLLER_HTTPS_PORT=9491
CONTROLLER_HOSTNAME=`hostname`
CONTROLLER_WLP_HOME="$CONTROLLER_ROOT_DIR/wlp"


#Collective member variables
HTTP_PORT=$(echo $PORTS | cut -f1 -d:)
HTTPS_PORT=$(echo $PORTS | cut -f2 -d:)
echo "http port: $HTTP_PORT"
echo "https port: $HTTPS_PORT"

LIBERTY_ROOT=$WORK_DIR/liberty-staging
PACKAGED_PBW_SERVER_NAME="pbwServerX"
WLP_HOME="$LIBERTY_ROOT/$LIBERTY_VERSION-$SERVER_NAME/wlp"  #this needs to be the liberty home for the verion of Liberty unzipped

PACKAGED_SERVER_DIR=$WORK_DIR/packagedServers
PACKAGED_ARCHIVE_NAME=$LIBERTY_VERSION-$PACKAGED_PBW_SERVER_NAME.zip
FULL_PATH_PACKAGED_SERVER_PATH=$PACKAGED_SERVER_DIR/$LIBERTY_VERSION-$PACKAGED_PBW_SERVER_NAME
LOG=$LOGS/1_addMember-$LIBERTY_VERSION-$SERVER_NAME.log


#Remote member variables
KNOWN_REMOTE_HOST1="server1.gym.lan"
REMOTE_LOG=$LOGS/2_addRemoteMember-$LIBERTY_VERSION-$SERVER_NAME.log

# ports cannot be same value
if [  "$HTTP_PORT" == "$HTTPS_PORT" ]; then 
  echo "The HTTP and HTTPS ports were not specified correctly. Verify the ports paramter is in the format of 'http_port:https_port'and rerun the script"

  exit 1
fi


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
  WLP_HOME_REMOTE="/opt/IBM/wlp"
fi


echo "#----------------------------------" | tee $LOG
echo "# Now running addMember.sh" | tee -a $LOG
echo "#----------------------------------" | tee -a $LOG

sleep 3


#create the LOGS directory if it does not exist
if [ ! -d "$LOGS" ]; then
     mkdir $LOGS ;
     echo "Create Logs Directory: $LOGS"
fi

#Remove the old log if it exists
if [  -f "$LOG" ]; then
    rm $LOG ;
    echo "removed $LOG"
fi


#Ensure the Liberty $CONTROLLER_NAME server is running. 

$CONTROLLER_WLP_HOME/bin/server status $CONTROLLER_NAME 
rc=$?
echo "server status return code: $rc"

for n in {1..2};
do 
  if [[ "$rc" != "0" ]]; then
    echo "$CONTROLLER_NAME is not running, Attemting to start it now!"
    $CONTROLLER_WLP_HOME/bin/server start $CONTROLLER_NAME 
    rc=$?
    echo "server start return code" $rc
    sleep 2
  fi 
done

if [[ "$rc" != "0" ]]; then
  echo "Could not start the $CONTROLLER_NAME, exiting!"
  exit 1
fi  
  

# List the variables used in the script
echo " "  | tee -a $LOG
echo "#-------------------------------------------------------------" | tee -a  $LOG
echo "# Registering $MEMBER_TYPE Liberty server: $SERVER_NAME" | tee -a $LOG
echo "#-------------------------------------------------------------" | tee -a $LOG
echo " "  | tee -a $LOG

echo "# List the variables used in the script" | tee -a $LOG
echo "#-------------------------------------------------------------" | tee -a  $LOG
echo "# Command entered: $SAVE_COMMAND" | tee -a $LOG
echo "# Member Hostname: $MEMBER_HOSTNAME" | tee -a $LOG
echo "# Lab Home: $LAB_HOME" | tee -a $LOG
echo "# Lab Files Directory: $LAB_FILES" | tee -a $LOG
echo "# Script Artifacts Directory: $SCRIPT_ARTIFACTS" | tee -a $LOG
echo "# Liberty Home directory on Controllers Host: $WLP_HOME" | tee -a $LOG
if [[ "$MEMBER_TYPE" = "remote" ]]; then 
    echo "# Liberty Home directory on $MEMBER_HOSTNAME: $WLP_HOME_REMOTE" | tee -a $LOG
fi    
echo "# Controller Hostname: $CONTROLLER_HOSTNAME" | tee -a $LOG
echo "# Controller wlp Home: $CONTROLLER_WLP_HOME" | tee -a $LOG
echo "# Controller HTTPS Port: $CONTROLLER_HTTPS_PORT" | tee -a $LOG
echo "# Name of Liberty Server being registered: $SERVER_NAME" | tee -a $LOG
echo "# Collective member HTTP Port: $HTTP_PORT" | tee -a $LOG
echo "# Collective member HTTP Port: $HTTPS_PORT" | tee -a $LOG
echo "# Liberty Server Package to deploy: $PACKAGED_ARCHIVE_NAME" | tee -a $LOG
echo "# Liberty Server name in package: $PACKAGED_PBW_SERVER_NAME" | tee -a $LOG
echo "# Liberty Server Package location: $PACKAGED_SERVER_DIR" | tee -a $LOG
echo "# Full path to the Librty server package: $FULL_PATH_PACKAGED_SERVER_PATH" | tee -a $LOG
echo "#-------------------------------------------------------------" | tee -a $LOG
echo "" | tee -a $LOG

#sleep 5

#Look for the udocumneted parm 'SKIP_ACCEPT' to bypass the prompt to continue script. 
#This is used for higher level scripts to run without user input

#Have user reply "y" to continue the script, afer ensuring accuracy of the variables inout 
#if [[ $SKIP_P != "SKIP_PROMPT" ]]; then  
#
# read -p "Do you wish to continue with the parameters specified? (y/n)? " answer
#  case ${answer:0:1} in
#    y|Y )
#        echo continuing...
#    ;;
#    * )
#        exit 1
#    ;;
#  esac
#fi


verify_server_package_exists()
{
#verify the server package exists for adding the members to the collective

  if [ ! -f "$FULL_PATH_PACKAGED_SERVER_PATH.zip" ]; then
    echo "The Server Package could not be found: $FULL_PATH_PACKAGED_SERVER_PATH.zip" 
    echo ""
    echo "Ensure the server was packaged with the expected name."
    echo "" 
    echo "Exiting!"
  fi

}



join_Local_Member() 
{ 
  
#create the $LIBERTY_ROOT for the labs
  echo "Create the Liberty Root directory if it does not exist: $LIBERTY_ROOT"
  
  
  echo "" | tee -a $LOG
  echo "# Create the Liberty root directory, if it does not exist" | tee -a $LOG
  echo "mkdir $LIBERTY_ROOT" | tee -a $LOG
  echo "" | tee -a $LOG  
    
  
  if [ ! -d "$LIBERTY_ROOT" ]; then
     mkdir $LIBERTY_ROOT;
     echo "Liberty Root directory created: $LIBERTY_ROOT"
  fi 

#Unzip the server package for the specified version of Liberty. The server package must already be created by using the libetyBuildManager scripts. 
#Do not allow to unzip if the ServerName with ServerVersion already exists. 

  echo "" | tee -a $LOG
  echo "# Unzip the Liberty server package to the Liberty root directory" | tee -a $LOG
  echo " unzip -o $FULL_PATH_PACKAGED_SERVER_PATH.zip -d $LIBERTY_ROOT/$LIBERTY_VERSION-$SERVER_NAME" | tee -a $LOG
  echo "" | tee -a $LOG  


  if [ ! -d "$LIBERTY_ROOT/$LIBERTY_VERSION-$SERVER_NAME" ]; then
    echo "Unzip the server package"
    unzip -o $FULL_PATH_PACKAGED_SERVER_PATH.zip -d $LIBERTY_ROOT/$LIBERTY_VERSION-$SERVER_NAME
 
   echo "The Server package was extracted to: $LIBERTY_ROOT/$LIBERTY_VERSION-$SERVER_NAME"
   sleep 1
  else 
    echo "A server package already exists of name: $LIBERTY_VERSION-$SERVER_NAME, and therefore cannot be extracted to directory: $LIBERTY_ROOT/$LIBERTY_VERSION-$SERVER_NAME". 
    echo "A collective member of that server name may already exist in the collective. 
    echo "
    echo "Exiting!" 
    exit 1
  fi 


#Rename the pbwserverX server dir to $SERVER_NAME passed in

  echo "" | tee -a $LOG
  echo "# Rename the default packaged servername based on servername passed in on paramters" | tee -a $LOG
  echo "mv   $WLP_HOME/usr/servers/$PACKAGED_PBW_SERVER_NAME $WLP_HOME/usr/servers/$SERVER_NAME" | tee -a $LOG
  echo "" | tee -a $LOG  


  echo "Rename the default packaged server name $PACKAGED_PBW_SERVER_NAME to $SERVER_NAME"
  mv   $WLP_HOME/usr/servers/$PACKAGED_PBW_SERVER_NAME $WLP_HOME/usr/servers/$SERVER_NAME
  echo "The Server name is: $SERVER_NAME"
  sleep 1

 
#Update the Liberty server ports in the memberOverrides.xml with ports passed into script
  echo "" | tee -a $LOG
  echo "# Update the Liberty server ports in the memberOverrides.xml" | tee -a $LOG
  echo "sed -i 's/9084/'$HTTP_PORT'/g' $WLP_HOME/usr/servers/$SERVER_NAME/configDropins/overrides/memberOverride.xml" | tee -a $LOG
  echo "" | tee -a $LOG
  echo "sed -i 's/9446/'$HTTPS_PORT'/g' $WLP_HOME/usr/servers/$SERVER_NAME/configDropins/overrides/memberOverride.xml" | tee -a $LOG
  echo "" | tee -a $LOG
  
  
  sed -i 's/9084/'$HTTP_PORT'/g' $WLP_HOME/usr/servers/$SERVER_NAME/configDropins/overrides/memberOverride.xml 
  sed -i 's/9446/'$HTTPS_PORT'/g' $WLP_HOME/usr/servers/$SERVER_NAME/configDropins/overrides/memberOverride.xml 
  echo "HTTP port is now set to $HTTP_PORT in configOverrides" 
  echo "HTTPS port is now set to $HTTPS_PORT in configOverrides" 
  echo ""
  sleep 3

  echo "joining local member to collective...." 
#  sleep 3
   
  #join a local server to the collective
  
  echo "" | tee -a $LOG
  echo "# join local member to collective." | tee -a $LOG
  echo "" | tee -a $LOG

  echo "$WLP_HOME/bin/collective join $SERVER_NAME --host=$CONTROLLER_HOSTNAME --port=$CONTROLLER_HTTPS_PORT --user=admin --password=admin --keystorePassword=memberKSPassword --createConfigFile=$WLP_HOME/usr/servers/$SERVER_NAME/controller.xml"  | tee -a $LOG
  echo "" | tee -a $LOG

  echo "-----------------------------------------------------"
  echo "AutoAcceptCertificates enabled for: (collective join)"
  echo "-----------------------------------------------------"
  
  sleep 2
  
  $WLP_HOME/bin/collective join $SERVER_NAME --host=$CONTROLLER_HOSTNAME --port=$CONTROLLER_HTTPS_PORT --user=admin --password=admin --keystorePassword=memberKSPassword --autoAcceptCertificates --createConfigFile=$WLP_HOME/usr/servers/$SERVER_NAME/controller.xml

  if [[ $? != 0 ]]; then
    echo "#ERROR Failed to join $SERVER_NAME to the collective. See the error message that was returned!" | tee -a $LOG
   
    exit 1
  fi 


  echo "# Collective member $SERVER_NAME joined the collective, and is viewable from the Liberty Admin Center" | tee -a $LOG 

  sleep 2
}


start_local_liberty_server()
{
#start the Local Liberty server (NOT USED)
  echo "" | tee -a $LOG
  echo "# Start the local Liberty Server member" | tee -a $LOG
  echo "$WLP_HOME/bin/server start $SERVER_NAME" | tee -a $LOG
  echo "" | tee -a $LOG
  
  $WLP_HOME/bin/server start $SERVER_NAME
  
   if [[ $? != 0 ]]; then
   echo "FAILED to start the local Liberty server $SERVER_NAME. See the error message that was returned!"
   exit $?
  fi 
  echo "----------------------------------------------------------------------------" 
  echo "Server $SERVER_NAME started! It is now viewable in the Liberty Admin Center!" 
  echo "----------------------------------------------------------------------------" 
}




process_remoteserver_log()
{
 
#Check if we find text 'ERROR' in the log from remote server. 

#If we find ERRROR, then remove the local Liberty server directory and package archive   
  echo ""
  echo "logRetreived: $logRetrieved"
  echo ""
  echo "remote log: $REMOTE_LOG"
  echo ""
  if [ "$logRetrieved" = "1" ]; then
    echo "# Found the log, now checking for ERRORS reported in the log" | tee -a $LOG
    gotErrors=$(cat $REMOTE_LOG | grep ERROR | wc -l)
    echo "gotErrors: $gotErrors"
    #If ERROR found in the log, delete the servers/$SERVER_NAME directory and the packageServer on controller host.
    if [ "$gotErrors" != "0" ]; then
      echo "OK to delete the server directory and packageServer archive"
      #cleanup the local server and packaged serverarchive
      #####delete_liberty_server $SERVER_NAME
      #####delete_package_server_archive $SERVER_NAME
      echo "" | tee -a $LOG
      echo "#------------------------------------------------------------------" | tee -a $LOG
      echo "# Errors found in $REMOTE_LOG" | tee -a $LOG
      echo "#" | tee -a $LOG
      echo "# ERROR! The joinRemoteMember.sh script ended with errors. Check the console messages. " | tee -a $LOG
      echo "# Then correct the errors and rerun the createMember.sh" | tee -a $LOG
      echo "#" | tee -a $LOG
      echo "# Verify the parameters passed into the'createMember.sh. Perhaps you specified the wrong hostname on the '-h' flag or incorrect serverName on the -n flag"  | tee -a $LOG
      echo "#" | tee -a $LOG
      echo "# You entered the command as $SAVE_COMMAND" | tee -a $LOG
      echo "------------------------------------------------------------------" | tee -a $LOG
    else #no errors found
      echo "#" | tee -a $LOG
      echo "#---------------------------------" | tee -a $LOG
      echo "# Yeah! No errors found in the log!" | tee -a $LOG
      echo "#---------------------------------" | tee -a $LOG
      echo "#" | tee -a $LOG
    fi
      
  fi
  
}



setup_firewall_ports()
{

#The Controllers HTTPS port needs to be opened on server0.gym.lan

echo "" | tee -a $LOG
echo "# The Collective Controller HTTPS port $CONTROLLER_HTTPS_PORT needs to be open for joining members to the collective." | tee -a $LOG
echo "" | tee -a $LOG


#open Controller HTTPS port, if not found
  controllerHttpsPortFound=$(sudo firewall-cmd --list-ports | grep $CONTROLLER_HTTPS_PORT/tcp | wc -l)

  if [[ "$controllerHttpsPortFound" -lt 1 ]]; then
    echo "Need to open port $CONTROLLER_HTTPS_PORT for the colective controller HTTPS port"
    sudo firewall-cmd --permanent --zone=public --add-port=$CONTROLLER_HTTPS_PORT/tcp 
    sleep 1
  fi  

    
#reload the firewall settings
  echo "reloading the firewall rules!" 
  sudo firewall-cmd --reload 
  
  echo "WAITING for Firewall rules to be reloaded............ " 

  sleep 2
  

#List the ports 
  echo "" | tee -a $LOG
  echo "# List the opened ports"  | tee -a $LOG
  echo "" | tee -a $LOG
  echo "# $(sudo firewall-cmd --list-ports)" | tee -a $LOG
  
  echo "" | tee -a $LOG
  echo "#INFORMATION ONLY!!! The ports were opened by using the following commands on the Liberty Controller VM."  | tee -a $LOG
  echo "" | tee -a $LOG
  echo "#----------------------------------------------------------------------------" | tee -a $LOG
  echo "# Note: The Collective Controller HTTPS port must be opened for members to join the collective" | tee -a $LOG 
  echo "# firewall-cmd --list-ports" | tee -a $LOG 
  echo "# firewall-cmd --permanent --zone=public --add-port=$CONTROLLER_HTTPS_PORT/tcp" | tee -a $LOG
  echo "# firewall-cmd --reload" | tee -a $LOG
  echo "#----------------------------------------------------------------------------" | tee -a $LOG
  echo "" | tee -a $LOG
 
#verify the Controllers HTTPS port is opened. Exit if not opened.  
 
#Get updated state... 
   controllerHttpsPortFound=$(sudo firewall-cmd --list-ports | grep $CONTROLLER_HTTPS_PORT/tcp | wc -l)

#Variable is > 0 if the port is found in the command above, listing the opened ports. 
  if [[ "$controllerHttpsPortFound" -gt "0" ]];  then
    echo "----------------------------------------------------------------------------" 
    echo "Required port $CONTROLLER_HTTPS_PORT for the Liberty Controller HTTPS port is opened" 
    echo "Script will continue!" 
    echo "----------------------------------------------------------------------------" 
    sleep 1
  else 
    echo "Required port $CONTROLLER_HTTPS_PORT for the Liberty Controller HTTPS not opend." 
    echo "Exiting!" 
    echo ""
    echo "open the required ports using the following commands on the Liberty Controller VM." 
    echo "Then rerun the script."  
    echo "----------------------------------------------------------------------------" 
    echo "sudo firewall-cmd --permanent --zone=public --add-port=$CONTROLLER_HTTPS_PORT/tcp" 
    echo "----------------------------------------------------------------------------" 
  
    exit 1
  fi  
  
}


join_remote_member()
{
#This function will scp Liberty Archive and a shell script to the remote Liberty Host. 
#The remote shell script runs which extracts the Liberty archive and joins the remote Lberty Server to the collective. 

echo "#---------------------------------------------" 
echo "# Now running join_remote_member() function" 
echo "#---------------------------------------------" 
echo ""


#Register the remote host to the collective


echo "" | tee -a $LOG
echo "# Register the remote host to the collective" | tee -a $LOG
echo " "
echo "" | tee -a $LOG
echo  "$CONTROLLER_WLP_HOME/bin/collective registerHost $MEMBER_HOSTNAME --controller=admin:admin@$CONTROLLER_HOSTNAME:$CONTROLLER_HTTPS_PORT --hostJavaHome=/opt/IBM/ibm-java-x86_64-80/jre/ --rpcuser=techzone --rpcUserPassword='IBMDem0s!'" |  tee -a $LOG
echo "" | tee -a $LOG

echo "---------------------------------------------------------" 
echo "AutoAcceptCertificates enabled for: (collective register)" 
echo "---------------------------------------------------------" 

echo "" | tee -a $LOG

sleep 2


$CONTROLLER_WLP_HOME/bin/collective registerHost $MEMBER_HOSTNAME --controller=admin:admin@$CONTROLLER_HOSTNAME:$CONTROLLER_HTTPS_PORT --hostJavaHome=/opt/IBM/ibm-java-x86_64-80/jre/ --autoAcceptCertificates --rpcuser=techzone --rpcUserPassword='IBMDem0s!'

rc=$?
echo "return code from register host command: $rc" 

# The command returns 0 if successful ad 255 if host is already registered. 
if [[ $rc != 0 ]] && [[ $rc != 255 ]]; then

   echo "#ERROR Failed to register $MEMBER_HOSTNAME with the controller. See the error message that was returned!" | tee -a $LOG
   
   exit 1
fi


echo "Host registered: $MEMBER_HOSTNAME" 


#The testConnection command is used to verify connectivity. The command validates RXA connectivity between the controller and the host where the member reside"

echo " " | tee -a $LOG
echo "# Test the connection between the controller and registered host." | tee -a $LOG
echo "$CONTROLLER_WLP_HOME/bin/collective testConnection $MEMBER_HOSTNAME --host=$CONTROLLER_HOSTNAME --port=$CONTROLLER_HTTPS_PORT --user=admin --password=admin --autoAcceptCertificates" | tee -a $LOG
echo " " | tee -a $LOG


$CONTROLLER_WLP_HOME/bin/collective testConnection $MEMBER_HOSTNAME --host=$CONTROLLER_HOSTNAME --port=$CONTROLLER_HTTPS_PORT --user=admin --password=admin --autoAcceptCertificates

#echo "return code from the collective testConnection command: $?"

if [[ $? != 0 ]]; then
   echo "#ERROR Testing the connnection between the Controller and $MEMBER_HOSTNAME FAILED. See the error message that was returned!" | tee -a $LOG
    
   exit 1
fi 

echo "Test connection between Controller and host $MEMBER_HOSTNAME completed succesfully." 
echo ""

sleep 2
    
#echo "---------------------------------------------------------------------------"
#echo "You will be prompted multiple times for the password for the techzone user"
#echo " as files are securly copied to the remote VM, and ssh into the remote vm to run scripts."
#echo "---------------------------------------------------------------------------"
#sleep 7
    

echo " " | tee -a $LOG
echo "# Copy the Liberty Archive $PACKAGED_ARCHIVE_NAME to the remote server $MEMBER_HOSTNAME" | tee -a $LOG
echo "scp $FULL_PATH_PACKAGED_SERVER_PATH.zip techzone@$MEMBER_HOSTNAME:/home/techzone/Downloads" | tee -a $LOG
echo " " | tee -a $LOG


  
echo "---------------------------------------------------------------------------"
echo "--->  Send the Liberty Server Package to the remote server"
echo "---------------------------------------------------------------------------"
sleep 3

sshpass -p "IBMDem0s!" scp $FULL_PATH_PACKAGED_SERVER_PATH.zip  techzone@$MEMBER_HOSTNAME:/home/techzone/Downloads


echo " " | tee -a $LOG
echo "# Copy $LAB_FILES/addRemoteMember.sh to the remote server $MEMBER_HOSTNAME" | tee -a $LOG
echo "scp $LAB_FILES/scripts/addRemoteMember.sh techzone@$MEMBER_HOSTNAME:/home/techzone" | tee -a $LOG
echo " "  | tee -a $LOG

 
echo "---------------------------------------------------------------------------"
echo "--->  Send the shell script to the remote server"
echo "---------------------------------------------------------------------------"
sleep 3


sshpass -p "IBMDem0s!" scp $SCRIPT_ARTIFACTS/addRemoteMember.sh techzone@$MEMBER_HOSTNAME:/home/techzone

echo " " | tee -a $LOG
echo "# ssh to $MEMBER_HOSTNAME and run addRemoteMember.sh" | tee -a $LOG
echo "ssh -t $MEMBER_HOSTNAME . /home/techzone/addRemoteMember.sh $SERVER_NAME $LIBERTY_VERSION $HTTP_PORT  $HTTPS_PORT $CONTROLLER_HTTPS_PORT" | tee -a $LOG
echo " " | tee -a $LOG


#Join the remote server to the collective. The -t option is REQUIRED to run the ssh in interactive mode. Otherwise the command will fail, as you will be unable to respond to accept the key chain during the join command. 


echo "---------------------------------------------------------------------------"
echo "--->  SSH into the remote server and run the script to deploy Liberty"
echo "---------------------------------------------------------------------------"
sleep 3

sshpass -p "IBMDem0s!" ssh -t $MEMBER_HOSTNAME . /home/techzone/addRemoteMember.sh $SERVER_NAME $LIBERTY_VERSION $HTTP_PORT $HTTPS_PORT $CONTROLLER_HTTPS_PORT


# We are back from running the addRemoteMember script. Now get the logs from the remote host

echo "#----------------------------------------------- " | tee -a $LOG
echo "# addRemoteMember.sh completed on $MEMBER_HOSTNAME" | tee -a $LOG
echo " " | tee -a $LOG
echo "# --> Now retrieving the logs from $MEMBER_HOSTNAME" | tee -a $LOG
echo "#----------------------------------------------- " | tee -a $LOG


# Retrieve the addRemoteMember.log file from the remote host. 
echo " " | tee -a $LOG
echo "# Retreive the addRemoteMember.log from the remote server $MEMBER_HOSTNAME" | tee -a $LOG
echo "scp techzone@$MEMBER_HOSTNAME:/home/techzone/2_addRemoteMember.log $REMOTE_LOG" | tee -a $LOG
echo " " | tee -a $LOG

  
echo "---------------------------------------------------------------------------"
echo "--->  Retreive the addRemoteMember.log from the remote server"
echo "---------------------------------------------------------------------------"
sleep 2

sshpass -p "IBMDem0s!" scp techzone@$MEMBER_HOSTNAME:/home/techzone/2_addRemoteMember.log $REMOTE_LOG

echo ""
echo "The remote log name is: $REMOTE_LOG"
echo ""

if [ -f "$REMOTE_LOG" ]; then
    echo "$REMOTE_LOG retreived from remote Host $MEMBER_HOSTNAME" 
    logRetrieved=1   
    process_remoteserver_log $logRetrieved $REMOTE_LOG 
else 
   echo "#ERROR! Could not retreive $REMOTE_LOG from $SERVER_NAME" | tee -a $LOG
   echo "# Manual cleanup will be required to create a server with the SAME name: $SERVER_NAME" | tee -a $LOG
   logRetrieved=0
   
   exit 1
fi 


} 




#MAIN PROGRAM

echo "========================="
echo "Running 'addMember.sh'"
echo "========================="

  verify_server_package_exists
  
   
  if [[ "$MEMBER_TYPE" = "remote" ]]; then 
    setup_firewall_ports
    join_remote_member    
  else 
    join_Local_Member
#    start_local_liberty_server
  fi
  
  
echo ""     
echo "---------------------------------------------------------------"
echo ""
echo "Review the log file. It shows the commands the script executed."
echo "" 
echo "  $LOG"
echo ""
echo "---------------------------------------------------------------"
echo ""   
 
  
 echo "" | tee -a $LOG 
 echo "# End of createMember.sh script." | tee -a $LOG
 echo "" | tee -a $LOG 
 