##################################
#  resetEnvironment.sh
##################################


1020() {
  echo "---> Resetting environment for lab 1020"
  echo ""
  echo "--->  This should take less than 1 minute"
  /home/techzone/liberty_admin_pot/lab-scripts/scriptArtifacts/INSTRUCTOR_delete_collective.sh --force
  /home/techzone/liberty_admin_pot/lab-scripts/scriptArtifacts/INSTRUCTOR_delete_instana_agent.sh 

  echo ""
  echo "--> Environment prepared for lab 1020"
  echo ""
  echo "-----------------------------------"
  echo "Ready to start lab 1020!"
  echo "-----------------------------------"

}

1030() {
  echo "---> Resetting environment for lab 1030"
  echo ""
  echo "--->  This will take about 5 to 7 minutes" 
  sleep 5 
  /home/techzone/liberty_admin_pot/lab-scripts/scriptArtifacts/INSTRUCTOR_delete_collective.sh --force
  /home/techzone/liberty_admin_pot/lab-scripts/scriptArtifacts/INSTRUCTOR_delete_instana_agent.sh 
  /home/techzone/liberty_admin_pot/lab-scripts/deployCollective.sh --lab1030
  echo ""
  echo "--> Environment prepared for lab 1030"
  echo ""
  echo "-----------------------------------"
  echo "Ready to start lab 1030!"
  echo "-----------------------------------"

}


1040() {
  echo "---> Resetting environment for lab 1040"
  echo ""
  echo "--->  This will take about 5 to 7 minutes" 
  sleep 5 
  /home/techzone/liberty_admin_pot/lab-scripts/scriptArtifacts/INSTRUCTOR_delete_collective.sh --force
  /home/techzone/liberty_admin_pot/lab-scripts/scriptArtifacts/INSTRUCTOR_delete_instana_agent.sh 
  /home/techzone/liberty_admin_pot/lab-scripts/deployCollective.sh
  echo ""
  echo "--> Environment prepared for lab 1040"
  echo ""
  echo "-----------------------------------"
  echo "Ready to start lab 1040!"
  echo "-----------------------------------"

}

1050() {
  echo "Resetting environment for lab 1050"
  echo ""
  echo "--->  This will take about 5 to 7 minutes" 
  sleep 5 
  /home/techzone/liberty_admin_pot/lab-scripts/scriptArtifacts/INSTRUCTOR_delete_collective.sh --force
  /home/techzone/liberty_admin_pot/lab-scripts/scriptArtifacts/INSTRUCTOR_delete_instana_agent.sh 
  /home/techzone/liberty_admin_pot/lab-scripts/deployCollective.sh
  echo ""
  echo "--> Environment prepared for lab 1050"
  echo ""
  echo "-----------------------------------"
  echo "Ready to start lab 1050!"
  echo "-----------------------------------"

}

1060() {
  echo "Resetting environment for lab 1060"
  echo ""
  echo "--->  This will take about 5 to 7 minutes" 
  sleep 5 
  /home/techzone/liberty_admin_pot/lab-scripts/scriptArtifacts/INSTRUCTOR_delete_collective.sh --force
  /home/techzone/liberty_admin_pot/lab-scripts/scriptArtifacts/INSTRUCTOR_delete_instana_agent.sh 
  /home/techzone/liberty_admin_pot/lab-scripts/deployCollective.sh
  echo ""
  echo "--> Environment prepared for lab 1060"
  echo ""
  echo "-----------------------------------"
  echo "Ready to start lab 1060!"
  echo "-----------------------------------"

}

1070() {
  echo "Resetting environment for lab 1070"
  echo ""
  echo "--->  This will take about 5 to 7 minutes" 
  sleep 5 
  /home/techzone/liberty_admin_pot/lab-scripts/scriptArtifacts/INSTRUCTOR_delete_collective.sh --force
  /home/techzone/liberty_admin_pot/lab-scripts/scriptArtifacts/INSTRUCTOR_delete_instana_agent.sh 
  /home/techzone/liberty_admin_pot/lab-scripts/deployCollective.sh
  echo ""
  echo "--> Environment prepared for lab 1070"
  echo ""
  echo "-----------------------------------"
  echo "Ready to start lab 1070!"
  echo "-----------------------------------"

}

delete-collective() {
  echo "Delete the Liberty Collective"
  echo "--->  This should take less than 1 minute"
  sleep 5 
  /home/techzone/liberty_admin_pot/lab-scripts/scriptArtifacts/INSTRUCTOR_delete_collective.sh --force
  /home/techzone/liberty_admin_pot/lab-scripts/scriptArtifacts/INSTRUCTOR_delete_instana_agent.sh 
  echo ""
  echo "---------------------------------------"
  echo "The Liberty Collective has been deleted"
  echo "---------------------------------------"

}




echo ""
echo "Select one of the options below to reset the environment to the desired state. "
echo ""
echo "--------------------------------------------------------------"
echo ""
echo " 1) Delete Liberty Collective  - Wipe the Liberty Collective"
echo " 2) Reset to start lab 1020    - Liberty enterprise deployment" 
echo " 3) Reset to start lab 1030    - Dynamic Routing"
echo " 4) Reset to start lab 1040    - HTTP Session Persistence"
echo " 5) Reset to start lab 1050    - Zero migration Liberty upgrade"
echo " 6) Reset to start lab 1060    - Liberty Day 2 operations"
echo " 7) Reset to start lab 1070    - Observability with Instana"
echo " 8) Exit"
echo ""
echo "--------------------------------------------------------------"


read n answer
case $n in
    1)
        echo "Remove Liberty Collective"
        delete-collective
    ;;
    2) 
        echo "Reset to start lab 1020..." 
        1020
    ;;
    3)
        echo "Reset to start lab 1030"
        1030
    ;;
    4)
        echo "Reset to start lab 1040"
        1040
    ;;
    5)
        echo "Reset to start lab 1050"
        1050
    ;;
    6)
        echo "Reset to start lab 1060"
        1060
    ;;
    7)
        echo "Reset to start lab 1070"
        1070
    ;;
    8)
       echo "selected EXIT"
       exit 1
esac



   

