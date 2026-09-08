

echo ""
echo "-------------------------------------------------"
echo "Running updateInstanaAgentCOnfiguration.sh script"
echo "-------------------------------------------------" 
echo "" 


echo ""
echo "---> Stopping the Instana agent"
echo "" 

sudo systemctl stop instana-agent
sleep 5

echo ""
echo "---> Updating Instana 'configuration.yaml' file for PlantsByWebSphere app"
echo "     (/opt/instana/agent/etc/instana/configuration.yaml)"
echo ""

sudo cp -f /home/techzone/liberty_admin_pot/lab-scripts/scriptArtifacts/instana-configuration.yaml /opt/instana/agent/etc/instana/configuration.yaml
sleep 5

echo ""
echo "---> Starting the Instana agent"
echo "" 

sudo systemctl start instana-agent

echo ""
echo "updateInstanaAgentCOnfiguration.sh script completed." 
echo "" 