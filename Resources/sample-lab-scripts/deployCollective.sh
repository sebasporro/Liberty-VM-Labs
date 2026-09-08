######################
#  deployCollective.sh 
######################

numParms=$#
PARM1=$1
#echo "PARM1: $PARM1"

#if [[ -d "/home/techzone/lab-work/liberty-controller" ]]; then
#   echo ""
#   echo "-----------------------------------------------------------------------"
#   echo "The Collective Controller already exists."
#   echo ""
#   echo "This script cannot continue because the collective may already exist..."
#   echo ""
#   echo "Exiting!"
#   echo "" 
#   echo "--> Admin Center URL: https://server0.gym.lan:9491/adminCenter"
#   echo ""
#   echo "-----------------------------------------------------------------------"
#   echo ""
#   exit 1
#fi   
 


SKIP_1030="false"

if [[ ! -z "$PARM1" ]]; then
 # echo "parameter specified, need to see if it matches --skip1030"

  if [[ "$PARM1" = "--lab1030" ]]; then 
     SKIP_1030="true"
     echo ""
     echo "================================================="
     echo "---> Script will skip setting up dynamic routing!"
     echo "================================================="
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

#echo "skip1030: $SKIP_1030"


echo ""
echo "============================="
echo "Create the Liberty Collective"
echo "============================="
echo ""
sleep 3

/home/techzone/liberty_admin_pot/lab-scripts/createController.sh
rc=$? 

echo "Retern code from createController script: $rc"

if [[ "$rc" = "12" ]]; then
  echo ""
  echo "------------------------------------------------------------------------------"
  echo "--> The Collective Controller already exists. Exiting deployCollective script!"
  echo ""
  echo "--> You can access the Liberty Admin Center using the URL displayed above."
  echo "------------------------------------------------------------------------------"
  echo ""
  exit 1
fi   
  

if [[ $SKIP_1030 != "true" ]]; then  
  echo ""
  echo "============================="
  echo "Setup Dynamic Routing"
  echo "============================="
  echo ""
  sleep 3
  
  /home/techzone/liberty_admin_pot/lab-scripts/setupDynamicRouting.sh
fi 

echo ""
echo "========================================"
echo "Build and produce Liberty Server Package"
echo "========================================"
echo ""
sleep 3

/home/techzone/liberty_admin_pot/lab-scripts/mavenBuild.sh -v 22.0.0.8



echo ""
echo "========================================"
echo "Deploy appServer1"
echo "========================================"
echo ""
sleep 3

/home/techzone/liberty_admin_pot/lab-scripts/addMember.sh -n appServer1 -v 22.0.0.8 -p 9081:9441 -h server0.gym.lan SKIP_PROMPT


echo ""
echo "========================================"
echo "Deploy appServer2"
echo "========================================"
echo ""
sleep 3

/home/techzone/liberty_admin_pot/lab-scripts/addMember.sh -n appServer2 -v 22.0.0.8 -p 9082:9442 -h server1.gym.lan SKIP_PROMPT



echo ""
echo "========================================"
echo "Start the application database"
echo "========================================"
echo ""
sleep 3
docker start db2_demo_data



echo ""
echo "========================================"
echo "Liberty Collective Deployment Complete! "
echo "========================================"
echo ""