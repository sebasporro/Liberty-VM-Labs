# Install IHS

unzip /home/itzuser/software/IHS/WAS/9.0.5-WS-IHS-ARCHIVE-linux-x86_64-FP025.zip  -d ~/usr/IBM
cd ~/usr/IBM/IHS/
./postinstall.sh 
sed -i 's/Listen 80/Listen 1080/g' conf/httpd.conf

bin/apachectl -version

#Copy the plugin from the current IHS installation
cp ~/IBM/HTTPServer/conf/plugin-cfg.xml /home/itzuser/usr/IBM/IHS/plugin/config/webserver1/
# Adjust the HTTP port from 8080 to 1080
sed -i 's/8080/1080/g' /home/itzuser/usr/IBM/IHS/plugin/config/webserver1/plugin-cfg.xml

# Start IHS
/home/itzuser/usr/IBM/IHS/bin/apachectl start 
# Verify that round robin works
curl -s http://localhost:1080/server-info/