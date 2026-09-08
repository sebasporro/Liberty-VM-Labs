#########################
#  mavenBuild.sh
#########################


#  -v LIBETYVERSION 
#  -v 22.0.0.8 
#  -v 22.0.0.12 

if [[ "$#" -lt 2 ]]; then
  echo "Missing command parameters, check usage"
  echo "---------------------------------------"
  echo "Usage:" 
  echo "-v Version of Liberty to install <22.0.0.8 | 22.0.0.12>"
  echo ""
  echo "example: mavenBuild.sh -v 22.0.0.8"
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
    -v|--version)
    LIBERTY_VERSION="$2"
     let "numKeys+=1"
    shift # past argument
    ;;
  esac
shift # past argument or value
#echo "numKeys: $numKeys"
done

#Make sure all of the required keys were passed in (-n -p -s -h)
if [[ $numKeys != 1 ]]; then
  echo "Missing command parameters, check usage"
  echo "---------------------------------------"
  echo "Usage:" 
  echo "-v Version of Liberty to install <22.0.0.8 | 22.0.0.12>"
  echo ""
  echo "example: mavenBuild.sh -v 22.0.0.8"
  echo ""
   echo "---------------------------------------"
  exit 1
fi


#Verify -v flag matches 22.0.0.8 or 22.0.0.12
if [[ "$LIBERTY_VERSION" = "22.0.0.8" ]]; then 
    LIBERTY_ARCHIVE="wlp-kernel-22.0.0.8.zip"
elif [[ "$LIBERTY_VERSION" = "22.0.0.12" ]]; then 
    LIBERTY_ARCHIVE="wlp-kernel-22.0.0.12.zip"
else 
    echo "Only 22.0.0.8 and 22.0.0.12 are valid versions of Liberty for the lab environment"
    echo ""
    echo "Check your input paramters and rerun the script"
    exit 1	
fi

COMMAND_SAVE="mavenBuild.sh -v $LIBERTY_VERSION" 
HOME_DIR=/home/techzone
PBW_SERVER_NAME="pbwServerX"
LAB_FILES_DIR=$HOME_DIR/liberty_admin_pot
SRC_MAVEN_LAB_FILES=$HOME_DIR/liberty_admin_pot_src
SRC_MAVEN_GIT_REPO="https://github.com/IBMTechSales/liberty_admin_pot_src"
#SRC_MAVEN_GIT_REPO="https://github.com/IBMTechSales/liberty_admin_pot_src --branch enablehttps"
SERVER_PACKAGE_FROM_MAVEN_BUILD="$SRC_MAVEN_LAB_FILES/liberty-server/target/$LIBERTY_VERSION-$PBW_SERVER_NAME.zip"
WORK_DIR=$HOME_DIR/lab-work
PACKAGED_SERVER_DIR=$WORK_DIR/packagedServers
LOGS=$WORK_DIR/logs
LOG=$LOGS/mavenBuild-$LIBERTY_VERSION.log


#create the WORK_DIR for the labs
if [ ! -d "$WORK_DIR" ]; then
     mkdir $WORK_DIR ;
     echo "Create the Working directory if it does not exist: $WORK_DIR"
fi 


if [ ! -d "$LOGS" ]; then
     echo "Create Logs Directory: $LOGS"
     mkdir $LOGS ;
fi

if [ -f "$LOG" ]; then
     echo "remove old log file: $LOG"
     rm $LOG ;
fi 



# List the variables used in the script
echo " "  | tee $LOG
echo "#-------------------------------------------------------------" | tee -a  $LOG
echo "# List the variables used in the script" | tee -a $LOG
echo "#-------------------------------------------------------------" | tee -a  $LOG
echo "# The command you entered: $COMMAND_SAVE" | tee -a $LOG
echo "# Liberty Version: $LIBERTY_VERSION" | tee -a $LOG
echo "# Home directory: $HOME_DIR" | tee -a $LOG
echo "# Maven working Directory: $SRC_MAVEN_LAB_FILES" | tee -a $LOG
echo "# Liberty Server package from Maven build: $SERVER_PACKAGE_FROM_MAVEN_BUILD" | tee -a $LOG
echo "# Packaged Servers directory for labs: $PACKAGED_SERVER_DIR" | tee -a $LOG
echo "# Logs directory: $LOGS" | tee -a $LOG
echo "# Log file name: $LOG" | tee -a $LOG
echo "#-------------------------------------------------------------" | tee -a  $LOG

sleep 1


clone-repo()
{

   echo "" | tee -a  $LOG
   echo "===========================" | tee -a  $LOG
   echo "Clone Git Repo Step" | tee -a  $LOG
   echo "===========================" | tee -a  $LOG
   echo "" | tee -a  $LOG
   sleep 3


  echo "" | tee -a $LOG
  echo "# Change to Directory: $HOME_DIR. " | tee -a $LOG
  echo "cd  $HOME_DIR" | tee -a $LOG
  echo "" | tee -a $LOG  
  sleep 1


  cd  $HOME_DIR
 

  if [ -d "$SRC_MAVEN_LAB_FILES" ]; then
     rm -rf $SRC_MAVEN_LAB_FILES ;
     echo ""
     echo "cleanup existing cloned source code repo for maven builds: $SRC_MAVEN_LAB_FILES"
     echo ""
  fi
  
  
  
#clone the git repo that contains application source for building EAR/WAR and creating server package  

  echo "" | tee -a $LOG
  echo "# Cloning the git repo: $SRC_MAVEN_GIT_REPO. " | tee -a $LOG
  echo "git clone $SRC_MAVEN_GIT_REPO" | tee -a $LOG
  echo "" | tee -a $LOG  
  sleep 1


  git clone $SRC_MAVEN_GIT_REPO
  rc1=$?
  
  echo "Return code from git clone: $rc1"
    
  if [[ "$rc1" != "0" ]]; then
    echo ""
    echo "ERROR! Failed to clone the git repo: $SRC_MAVEN_GIT_REPO"
    echo "Exiting.... "
    echo ""
    exit 1
  else 
    echo ""
    echo "Successfully cloned the git repo:$SRC_MAVEN_GIT_REPO"
    echo ""
  fi  
  


}



maven-build()
{

   echo "" | tee -a  $LOG
   echo "===========================" | tee -a  $LOG
   echo "Maven Build Step" | tee -a  $LOG
   echo "===========================" | tee -a  $LOG
   echo "" | tee -a  $LOG
   sleep 3
  
   echo ""
   echo "Maven to build applications and produce a Liberty Server Package as output." 
   echo ""
  
  echo "" | tee -a $LOG
  echo "# Change to the Maven working directory of the cloned repo. " | tee -a $LOG
  echo "cd $SRC_MAVEN_LAB_FILES" | tee -a $LOG
  echo "" | tee -a $LOG  
  sleep 1
  
  cd $SRC_MAVEN_LAB_FILES
  
  
  echo "" | tee -a $LOG
  echo "# Run the Maven build process" | tee -a $LOG
  echo "mvn -Dliberty.runtime.version=$LIBERTY_VERSION -DskipTests=true clean install" | tee -a $LOG
  echo "" | tee -a $LOG  
  sleep 2

  mvn -Dliberty.runtime.version=$LIBERTY_VERSION -DskipTests=true clean install
  rc2=$?
  echo "resturn code from maven build: $rc2"

  if [[ "$rc2" != "0" ]]; then
    echo ""
    echo "ERROR! Maven Build failed. See the errors on the console"
    echo "Exiting.... "
    echo ""
    exit 1
  else 
     echo ""
     echo "Maven Build Successfully completed."
     echo ""
     echo "The build output is located in the following directory:" 
     echo "$SRC_MAVEN_LAB_FILES/liberty-server/target"
     echo ""
  fi  
 

}


post-build-steps()
{

#Run Post-build steps to move the server package to the location for the labs. 

   echo "" | tee -a  $LOG
   echo "===========================" | tee -a  $LOG
   echo "Post Build Step" | tee -a  $LOG
   echo "===========================" | tee -a  $LOG
   echo "" | tee -a  $LOG
   sleep 3
  
echo "Post Build Steps" 

#echo "PACKAGED_SERVER_DIR: $PACKAGED_SERVER_DIR"

FULL_PATH_PACKAGED_SERVER_PATH=$PACKAGED_SERVER_DIR/$LIBERTY_VERSION-$PBW_SERVER_NAME


  
#Create the packagedServers directory if it does not already exist

  echo "" | tee -a $LOG
  echo "# Create the $PACKAGED_SERVER_DIR directory, if it does not exist" | tee -a $LOG
  echo "mkdir $PACKAGED_SERVER_DIR" | tee -a $LOG
  echo "" | tee -a $LOG  


if [ ! -d "$PACKAGED_SERVER_DIR" ]; then
    echo "Create the $PACKAGED_SERVER_DIR directory"
    mkdir $PACKAGED_SERVER_DIR
fi



#Create the packagedServers BACKUP directory if it does not already exist.

  echo "" | tee -a $LOG
  echo "# Create the $PACKAGED_SERVER_DIR/backups directory, if needed" | tee -a $LOG
  echo "mkdir $PACKAGED_SERVER_DIR/backups" | tee -a $LOG
  echo "" | tee -a $LOG  


if [ ! -d "$PACKAGED_SERVER_DIR/backups" ]; then
    echo "Create the $PACKAGED_SERVER_DIR/backups directory"
    mkdir $PACKAGED_SERVER_DIR/backups
fi


#If server package with same name already exists, make a backup of it, and recreate a new one


  echo "" | tee -a $LOG
  echo "# Create a backup of the Liberty server package" | tee -a $LOG
  echo "\cp $FULL_PATH_PACKAGED_SERVER_PATH.zip $PACKAGED_SERVER_DIR/backups" | tee -a $LOG
  echo "rm $FULL_PATH_PACKAGED_SERVER_PATH.zip" | tee -a $LOG
  echo "" | tee -a $LOG 


if [ -f "$FULL_PATH_PACKAGED_SERVER_PATH.zip" ]; then
    echo "copy archive: \cp $FULL_PATH_PACKAGED_SERVER_PATH.zip $PACKAGED_SERVER_DIR/backups:"
    
    \cp $FULL_PATH_PACKAGED_SERVER_PATH.zip $PACKAGED_SERVER_DIR/backups
    
    echo "rm archive"
    rm $FULL_PATH_PACKAGED_SERVER_PATH.zip ;
    echo "removed $FULL_PATH_PACKAGED_SERVER_PATH.zip"
fi

#Copy the server package from the Maven build output to the working directory of the labs. 


  echo "" | tee -a $LOG
  echo "# copy Server Package Archive: \cp $SERVER_PACKAGE_FROM_MAVEN_BUILD" | tee -a $LOG
  echo "\cp $SERVER_PACKAGE_FROM_MAVEN_BUILD $FULL_PATH_PACKAGED_SERVER_PATH.zip" | tee -a $LOG
  echo "" | tee -a $LOG 


  \cp $SERVER_PACKAGE_FROM_MAVEN_BUILD $FULL_PATH_PACKAGED_SERVER_PATH.zip
  rc3=$?
  
  echo "Return code from the post-build step is: $rc3"
    
  if [[ "$rc3" != "0" ]]; then
    echo ""
    echo "ERROR! The Server Package failed to be copied to the working directory. See the errors in the console output." 
    echo ""
    echo "Exiting.... "
    echo ""
    exit 1
  else 
     echo "" | tee -a $LOG
     echo "=========================================================" | tee -a $LOG
     echo "The Server package was succesfully created and copied to:"  | tee -a $LOG
     echo"" | tee -a $LOG
     echo "$FULL_PATH_PACKAGED_SERVER_PATH.zip" | tee -a $LOG
     echo "" | tee -a $LOG
     echo "=========================================================" | tee -a $LOG
     echo "" | tee -a $LOG
  fi  
    

}



  
#MAIN PROGRAM

echo "================================" | tee -a $LOG
echo "Running 'mavenBuild.sh'" | tee -a $LOG
echo "================================" | tee -a $LOG
  
  
  
  
clone-repo
maven-build
post-build-steps



echo ""     
echo "---------------------------------------------------------------"
echo ""
echo "Review the log file. It shows the commands the script executed."
echo "" 
echo "  $LOG"
echo ""
echo "---------------------------------------------------------------"
echo ""      
        
echo ""  | tee -a $LOG        
echo "mavenBuid.sh completed"  | tee -a $LOG
echo ""  | tee -a $LOG  
  
  
  
  
  
  
  