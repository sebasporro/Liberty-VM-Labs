LAB_HOME=/home/techzone
LAB_FILES=/home/techzone/liberty_admin_pot
JMETER_HOME="/home/techzone/apache-jmeter-5.5/"
SCRIPTS_DIR=$LAB_FILES/lab-scripts

$JMETER_HOME/bin/jmeter -n -t $SCRIPTS_DIR/scriptArtifacts/PBW_Test_Plan_https.jmx -l $LAB_HOME/Downloads/pbwLoadTest.cvs
