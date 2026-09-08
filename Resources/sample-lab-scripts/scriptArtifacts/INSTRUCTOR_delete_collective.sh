##################################
#  INSTRUCTOR_delete_collective.sh
##################################

# --force flag is always required, just in case script is unintentionally run.
#Reply to continue script is also required


echo "#----------------------------------" 
echo "# Now running deleteCollective.sh  "
echo "#----------------------------------" 

sleep 3

numParms=$#
PARM1=$1

#Lab environment variable
LAB_HOME=/home/techzone
LAB_FILES=$LAB_HOME/liberty_admin_pot
SCRIPT_ARTIFACTS=$LAB_FILES/lab-scripts/scriptArtifacts
SERVER0_STAGING_DIR=$LAB_HOME/lab-work/liberty-staging
SERVER1_STAGING_DIR=/opt/IBM/liberty-staging
IHS_HOME=/opt/IBM/HTTPServer


HOST0="server0.gym.lan"
HOST1="server1.gym.lan"


if [[ "$numParms" -lt "1" ]] ; then 
  echo ""
  echo "--------------------------------------------------------------------"
  echo "The required parameters for this script have not been specified."
  echo ""
  echo "This script should only be run on advise from the lab instructor!!!!"
  echo ""
  echo "Exiting script..." 
  echo "--------------------------------------------------------------------"
  echo ""
  exit 1 
fi


FORCE="false"

if [[ ! -z "$PARM1" ]]; then
 # echo "parameter specified, need to see if it matches --force"

  if [[ "$PARM1" = "--force" ]]; then 
     FORCE="true"
     echo ""
     echo "====================================================================="
     echo "---> BEWARE! You have requested to FORCELFULLY DELETE the Collective!"
     echo ""
     echo "---> We hope you know what you are doing!"
     echo "====================================================================="
     echo ""
     sleep 3
  else 
     echo ""
     echo "===================================================="
     echo "---> You entered an invalid command line paraameter."
     echo "" 
     echo "---> Invalid parameter: $PARM1"
     echo ""
     echo "Eexiting!"
     echo "===================================================="
     echo ""
     exit 1 
  fi  
fi


#Have user reply "y" to continue the script to contiue 
echo "This script will FORCFULLY DELETE the Liberty Collective:"
echo ""
read -p "---> Are you sure you want to continue? (y/n)? " answer
case ${answer:0:1} in
    y|Y )
        echo continuing... 
    ;;
    * )
        exit 1
    ;;
esac


#run the instructor_delete_collective_resoures script on Server1 host

sshpass -p "IBMDem0s!" scp $SCRIPT_ARTIFACTS/INSTRUCTOR_delete_collective_resources.sh  techzone@$HOST1:/home/techzone
sleep 3

sshpass -p "IBMDem0s!" ssh -t $HOST1 . /home/techzone/INSTRUCTOR_delete_collective_resources.sh
sleep 2

#run the instructor_delete_collective_resoures script on Server0 host

/$SCRIPT_ARTIFACTS/INSTRUCTOR_delete_collective_resources.sh

echo "Stopping HTTP Server"
$IHS_HOME/bin/apachectl -k stop

  


