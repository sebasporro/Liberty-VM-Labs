

echo ""
echo "-------------------------------------"
echo "Running instanaAddSererTags.sh script"
echo "-------------------------------------" 
echo "" 
sed -i '1iINSTANA_SERVICE_NAME=appServer1' /home/techzone/lab-work/liberty-staging/22.0.0.8-appServer1/wlp/usr/servers/appServer1/server.env

echo ""
echo "---> Added'1iINSTANA_SERVICE_NAME=appServer1' to appServer1's server.env file"
echo "" 


sshpass -p "IBMDem0s!" ssh server1.gym.lan 'sed -i "1iINSTANA_SERVICE_NAME=appServer2" /opt/IBM/liberty-staging/22.0.0.8-appServer2/wlp/usr/servers/appServer2/server.env'


echo ""
echo "---> Added '1iINSTANA_SERVICE_NAME=appServer2' to appServer2's server.env file"
echo "" 


echo ""
echo "instanaAddSererTags.sh completed"
echo "" 