#############################################
#  INSTRUCTOR_delete_instana_agent.sh
############################################
HOSTNAME=`hostname`


echo "#----------------------------------------------------------------------" 
echo "# Now running instructor_delete_instana_agent on VM $HOSTNAME"
echo "#----------------------------------------------------------------------" 

sleep 3


#Lab environment variable
LAB_HOME=/home/techzone
LAB_WORK=$LAB_HOME/lab-work
SERVER0_STAGING_DIR=$LAB_HOME/lab-work/liberty-staging
SERVER1_STAGING_DIR=/opt/IBM/liberty-staging

HOST0="server0.gym.lan"
HOST1="server1.gym.lan"


echo "Stopping the instana-agent service"

sudo systemctl stop instana-agent

echo "Removing the instana agent service"

sudo yum -y remove instana-agent-dynamic-j9.x86_64

echo "Cleaning up the instana agent directory"

sudo rm -rf /opt/instana/agent


echo " " 
echo "#---------------------------------------------------------------------------" 
echo "# Completed 'instructor_delete_instana_agent.sh script' on $HOSTNAME "
echo "#---------------------------------------------------------------------------" 
echo " "  