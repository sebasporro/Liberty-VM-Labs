####################
#  removeMember.sh
####################
if [[ "$#" -lt 6 ]]; then
  echo "Missing command parameters, check usage"
  echo "---------------------------------------"
  echo "Usage:" 
  echo "-n Liberty member name"
  echo "-v Verion of Liberty to install <22.0.0.8 | 22.0.0.12>"
  echo "-h Liberty member hostname" 
  echo "   specify 'server0.gym.lan' for creating a local collective member"
  echo "   specify 'server1.gym.lan' for creating a remote collective member"
  echo ""
  echo "example: removeMember.sh -n server1 -v 22.0.0.8 -h server0.gym.lan"
  echo ""
  echo "---------------------------------------"
  exit 1
fi

#  $WLP_HOME/bin/collective remove $SERVER_NAME --host=$CONTROLLER_HOSTNAME --port=$CONTROLLER_HTTPS_PORT --user=admin --password=admin


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
if [[ $numKeys != 3 ]]; then
  echo "---------------------------------------"
  echo "Missing required FLAGS, check usage"
  echo "---------------------------------------"
  echo "Usage:" 
  echo "-n Liberty member name"
  echo "-v Verion of Liberty to install <22.0.0.8 | 22.0.0.12>"
  echo "-h Liberty member hostname" 
  echo "   specify 'server0.gym.lan' for creating a local collective member"
  echo "   specify 'server1.gym.lan' for creating a remote collective member"
  echo ""
  echo "example: removeMember.sh -n server1 -v 22.0.0.8 -h server0.gym.lan"
  echo ""
  echo "---------------------------------------"
  exit 1
fi

#Lab environment variable
LAB_HOME=/home/techzone
WORK_DIR=$LAB_HOME/lab-work
LAB_FILES=$LAB_HOME/liberty_admin_pot
SCRIPT_ARTIFACTS=$LAB_FILES/lab-scripts/scriptArtifacts
SAVE_COMMAND="removeMember.sh -n $SERVER_NAME -v $LIBERTY_VERSION -h $MEMBER_HOSTNAME"

#Controller variables
CONTROLLER_NAME="CollectiveController"
CONTROLLER_ROOT_DIR=$WORK_DIR/liberty-controller
CONTROLLER_HTTPS_PORT=9491
CONTROLLER_HOSTNAME=`hostname`
CONTROLLER_WLP_HOME="$CONTROLLER_ROOT_DIR/wlp"

#Remote member variables
KNOWN_REMOTE_HOST1="server1.gym.lan"


echo "Controller host name: $CONTROLLER_HOSTNAME"


#Ensure the -h flag contains a valid hostname for this lab environment

 if [[ "$MEMBER_HOSTNAME" = "$CONTROLLER_HOSTNAME" ]] || [[ "$MEMBER_HOSTNAME" = "$KNOWN_REMOTE_HOST1" ]]; then
      echo " "
else 
     echo "The -h flag specified contains an invalid member hostName parameter."
      echo "   specify 'server0.gym.lan' for creating a local collective member"
      echo "   specify 'server1.gym.lan' for creating a remote collective member"
     exit 1      
fi

LIBERTY_LOCAL_ROOT="$WORK_DIR/liberty-staging"
LIBERTY_REMOTE_ROOT="/opt/IBM/liberty-staging"


echo "#----------------------------------" 
echo "# Now running removeMember.sh"
echo "#----------------------------------" 

sleep 5



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
    sleep 7
  fi 
done

if [[ "$rc" != "0" ]]; then
  echo "Could not start the $CONTROLLER_NAME, exiting!"
  exit 1
fi  

echo " " 
echo "#-------------------------------------------------------------" 
echo "# Removing member '$SERVER_NAME' on Host $MEMBER_HOSTNAME from the Collective. "
echo "#-------------------------------------------------------------" 
echo " "  


# Is this a remote or local member being registered
if [[ "$MEMBER_HOSTNAME" = "$CONTROLLER_HOSTNAME" ]] ; then
  MEMBER_TYPE="local"
  WLP_HOME_LOCAL="$LIBERTY_ROOT/$LIBERTY_VERSION-$SERVER_NAME/wlp"  #this needs to be the liberty home for the verion of Liberty unzipped
  WLP_USR_DIR="$LIBERTY_LOCAL_ROOT/$LIBERTY_VERSION-$SERVER_NAME/wlp/usr"
  export  WLP_USER_DIR=$WLP_USR_DIR
else 
  MEMBER_TYPE="remote"  
  WLP_USR_DIR="$LIBERTY_REMOTE_ROOT/$LIBERTY_VERSION-$SERVER_NAME/wlp/usr"
   export  WLP_USER_DIR=$WLP_USR_DIR
fi

echo "wlp_user_dir: $WLP_USER_DIR"
echo "MEMBER_HOSTNAME: $MEMBER_HOSTNAME"


#Have user reply "y" to continue the script, after ensuring accuracy of the variables inout 
read -p "Do you wish to continue with the script to REMOVE '$SERVER_NAME' from the collective? (y/n)? " answer
case ${answer:0:1} in
    y|Y )
        echo continuing... 
    ;;
    * )
        exit 1
    ;;
esac


$CONTROLLER_WLP_HOME/bin/collective remove $SERVER_NAME --host=$CONTROLLER_HOSTNAME --hostName=$MEMBER_HOSTNAME --port=$CONTROLLER_HTTPS_PORT --user=admin --password=admin

  




