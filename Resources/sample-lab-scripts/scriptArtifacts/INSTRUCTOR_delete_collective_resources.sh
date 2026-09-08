#############################################
#  INSTRUCTOR_delete_collective_resources.sh
############################################
HOSTNAME=`hostname`


echo "#----------------------------------------------------------------------" 
echo "# Now running instructor_delete_collective_resources.sh on VM $HOSTNAME"
echo "#----------------------------------------------------------------------" 

sleep 3

numParms=$#
PARM1=$1

#Lab environment variable
LAB_HOME=/home/techzone
LAB_WORK=$LAB_HOME/lab-work
SERVER0_STAGING_DIR=$LAB_HOME/lab-work/liberty-staging
SERVER1_STAGING_DIR=/opt/IBM/liberty-staging

HOST0="server0.gym.lan"
HOST1="server1.gym.lan"


echo "Kill java processes for appServer* processes"


while [[ $(ps -ef | grep appServer | head -n 1 | awk '{print $3}') -eq "1" ]] 
do
  echo "in while loop"

  appServer_process=$(ps -ef | grep appServer | head -n 1 | awk '{print $2}')

  echo "appServer process: $appServer_process"

  if [[ ! -z $appServer_process ]]; then 
 
    echo "appServer1 Java process ID: $appServer_process"

    echo "killing process ID: $appServer_process"
    kill -9 $appServer_process 
  fi
done


#remove the liberty-staging dir on server0 VM
HOSTNAME=`hostname`

echo "hostname: $HOSTNAME"

if [[ "$HOSTNAME" = "$HOST0" ]]; then

  if [ -d "$SERVER0_STAGING_DIR" ]; then
     echo "Deleting Liberty staging directory: $SERVER0_STAGING_DIR on $HOST0"
     rm -rf $SERVER0_STAGING_DIR ;
  fi
fi



#remove the liberty-staging dir on server1 VM

if [[ "$HOSTNAME" == "$HOST1" ]]; then

  if [ -d "$SERVER1_STAGING_DIR" ]; then
     echo "Deleting Liberty staging dirctory: $SERVER1_STAGING_DIR on $HOST1"
     rm -rf $SERVER1_STAGING_DIR ;
  fi
fi


#Force kill the Collective Controller process on server0 VM

if [[ "$HOSTNAME" = "$HOST0" ]]; then

  echo "Kill java process for CollectiveController process"

  while [[ $(ps -ef | grep CollectiveController | wc -l ) -gt "1" ]] 
  do
    echo "in while loop"

    controller_process=$(ps -ef | grep CollectiveController | head -n 1 | awk '{print $2}')

    echo "controller process: $controller_process"

    if [[ ! -z $controller_process ]]; then 
 
      echo "Collective Controller Java process ID: $controller_process"

      echo "killing Collective Controller process ID: $controller_process"
      kill -9 $controller_process
    fi
  done
fi




#remove the 'lab-work' dir on server1 VM

if [[ "$HOSTNAME" == "$HOST0" ]]; then

  if [ -d "$LAB_WORK" ]; then
     echo "Deleting $LAB_WORK directory on $HOST0"
     rm -rf $LAB_WORK ;
  fi
fi



echo " " 
echo "#---------------------------------------------------------------------------" 
echo "# Completed 'instructor_delete_collective_resources.sh script' on $HOSTNAME "
echo "#---------------------------------------------------------------------------" 
echo " "  
