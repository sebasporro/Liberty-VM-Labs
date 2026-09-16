# Liberty Standalone

> **What is this?**  
> Before diving into the Liberty Collective lab, this module walks you through a complete
> hands-on lifecycle of a **single, standalone Liberty server** — install, create, configure,
> operate, deploy an app, and front it with IBM HTTP Server (IHS) — all with manual commands,
> no automation scripts.  
> Once you are comfortable, continue to the [Liberty Collective Lab](03-LIBERTY-COLLECTIVES.md).

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Section 1 — Extract the Liberty runtime](#section-1--extract-the-liberty-runtime)
3. [Section 2 — Create a server, start/stop, and check logs](#section-2--create-a-server-startstop-and-check-logs)
4. [Section 3 — Review server.xml and enable Admin Center](#section-3--review-serverxml-and-enable-admin-center)
5. [Section 4 — Deploy server-info.war manually](#section-4--deploy-server-infowar-manually)
6. [Section 5 — Add IHS as a front-end](#section-5--add-ihs-as-a-front-end)

---

## Prerequisites

| Requirement | Version | Where to find it on the lab VM |
|-------------|---------|-------------------------------|
| Java 17 | 17 | Pre-installed; verify with `java -version` |
| Liberty ND installer JAR | 26.0.0.8 | `/home/itzuser/software/Liberty/Liberty/wlp-nd-all-26.0.0.8.jar` |
| IHS + WAS Plugins installer ZIP | 9.0.5 FP025 | Pre-provisioned at `/home/itzuser/software/IHS/WAS/9.0.5-WS-IHS-ARCHIVE-linux-x86_64-FP025.zip` |
| Application WAR | — | `App/server-info.war` (in this repo) |

All commands in this module are run from the repo root
(`/home/itzuser/Liberty-VM-Labs`) unless otherwise noted.

---

## Section 1 — Extract the Liberty runtime

This module uses its own `wlp-standalone/` directory, completely separate from the
`wlp-26/` and `wlp-25/` runtimes used by the collective lab.

### 1.1 Extract the installer JAR

The Liberty installer is a self-executing JAR. Run it with `--acceptLicense` and specify
the target directory:

```bash
java -jar /home/itzuser/software/Liberty/Liberty/wlp-nd-all-26.0.0.8.jar \
  --acceptLicense \
  /home/itzuser/Liberty-VM-Labs/wlp-standalone
```

The installer always extracts into a `wlp/` sub-folder of the target, so the actual
binary lands at `wlp-standalone/wlp/`. Move its contents up one level:

```bash
cd Liberty-VM-Labs
mv wlp-standalone/wlp/* wlp-standalone/
rmdir wlp-standalone/wlp
```

### 1.2 Verify the installation

```bash
wlp-standalone/bin/server version
```

Expected output (last line):
```
WebSphere Application Server 26.0.0.8
```

> **Note:** `wlp-standalone/` is listed in `.gitignore` (under the `wlp/` pattern) and
> will not appear in `git status`. It is safe to delete and recreate at any time.

---

## Section 2 — Create a server, start/stop, and check logs

### 2.1 Create a named server

```bash
wlp-standalone/bin/server create myServer
```

Liberty creates a server configuration directory at:

```
wlp-standalone/usr/servers/myServer/
├── server.xml          ← main configuration file
├── bootstrap.properties  ← variable overrides (created on first start if absent)
└── logs/               ← created on first start
```

### 2.2 Start the server

```bash
wlp-standalone/bin/server start myServer
```

The server starts in the background. Watch it come up in real time:

```bash
tail -f wlp-standalone/usr/servers/myServer/logs/messages.log
```

Look for this line — it is the Liberty readiness signal:

```
CWWKF0011I: The myServer server is ready to run a smarter planet.
```

Press `Ctrl+C` to stop the tail without stopping the server.

### 2.3 Check server status

```bash
wlp-standalone/bin/server status myServer
```

Output when running:
```
Server myServer is running with process ID <pid>.
```

### 2.4 Stop the server

```bash
wlp-standalone/bin/server stop myServer
```

### 2.5 Log file locations

| File | Purpose |
|------|---------|
| `wlp-standalone/usr/servers/myServer/logs/messages.log` | Persistent structured log — survives restarts |
| `wlp-standalone/usr/servers/myServer/logs/console.log` | stdout/stderr from the JVM process |

> **Tip:** `messages.log` is the log to watch during troubleshooting. It contains feature
> loading events, application start/stop messages, and error FFDCs.

---

## Section 3 — Review server.xml and enable Admin Center

### 3.1 Anatomy of the default server.xml

Open the generated file:

```bash
cat wlp-standalone/usr/servers/myServer/server.xml
```

The default content looks like this:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<server description="new server">

    <!-- Enable features -->
    <featureManager>
        <feature>jsp-2.3</feature>
    </featureManager>

    <!-- To access this server from a remote client,
         add a host attribute to the following element, e.g. host="*" -->
    <httpEndpoint id="defaultHttpEndpoint"
                  httpPort="9080"
                  httpsPort="9443" />

    <!-- Automatically expand WAR files and EAR files -->
    <applicationManager autoExpand="true"/>

</server>
```

Key points:
- **`<featureManager>`** — the only features Liberty loads are those listed here. Liberty's
  zero-footprint model means nothing is loaded until you declare it.
- **`<httpEndpoint>`** — HTTP listens on `9080`, HTTPS on `9443` by default.
- There is no application declared yet — the server starts empty.

### 3.2 Add Admin Center

Open `wlp-standalone/usr/servers/myServer/server.xml` in a text editor. You need to make
three additions to the existing file — do **not** replace the whole file.

**1. Replace the default feature and add three new features inside `<featureManager>`**

The existing block has only `jsp-2.3`. **Replace** `jsp-2.3` with `pages-3.1` (the
Jakarta EE 10 equivalent) and add the three Admin Center features. Keeping `jsp-2.3`
here would cause a Java EE 7 / Jakarta EE 10 generation conflict that prevents Liberty
from loading _any_ features.

```xml
    <featureManager>
        <feature>pages-3.1</feature>          <!-- replaces jsp-2.3 -->
        <!-- Add these three: -->
        <feature>adminCenter-1.0</feature>
        <feature>appSecurity-5.0</feature>
        <feature>restConnector-2.0</feature>
    </featureManager>
```

**2. Add `host="*"` to `<httpEndpoint>`**

Without `host="*"` the Admin Center UI will not load. Change the existing element to:

```xml
    <httpEndpoint id="defaultHttpEndpoint"
                  host="*"
                  httpPort="9080"
                  httpsPort="9443" />
```

**3. Add the user registry, administrator role, and keystore before `</server>`**

Paste these three new elements anywhere inside the `<server>` block (e.g. just before
`</server>`):

```xml
    <!-- User registry: admin / admin -->
    <basicRegistry id="basic">
        <user name="admin" password="admin"/>
    </basicRegistry>

    <!-- Grant admin the Administrator role for Admin Center and REST API -->
    <administrator-role>
        <user>admin</user>
    </administrator-role>

    <keyStore id="defaultKeyStore" password="Liberty1"/>
```

Your complete `server.xml` should now look like this:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<server description="new server">

    <featureManager>
        <feature>pages-3.1</feature>          <!-- Jakarta EE 10 replacement for jsp-2.3 -->
        <feature>adminCenter-1.0</feature>
        <feature>appSecurity-5.0</feature>
        <feature>restConnector-2.0</feature>
    </featureManager>

    <httpEndpoint id="defaultHttpEndpoint"
                  host="*"
                  httpPort="9080"
                  httpsPort="9443" />

    <applicationManager autoExpand="true"/>

    <basicRegistry id="basic">
        <user name="admin" password="admin"/>
    </basicRegistry>

    <administrator-role>
        <user>admin</user>
    </administrator-role>

    <keyStore id="defaultKeyStore" password="Liberty1"/>

</server>
```

### 3.3 Restart and connect

```bash
wlp-standalone/bin/server stop myServer
wlp-standalone/bin/server start myServer
```

Once `CWWKF0011I` appears in `messages.log`, open a browser and navigate to:

```
https://localhost:9443/adminCenter
```

> **Self-signed certificate warning:** The browser will show a security warning because
> Liberty generates a self-signed TLS certificate on first start. Click **Advanced →
> Accept the Risk and Continue** (Firefox) or **Proceed to localhost** (Chrome) to
> continue. This is expected in a lab environment.

Log in with:
- **Username:** `admin`  
- **Password:** `admin`

You should see the Liberty Admin Center dashboard with the single `myServer` instance listed.

---

## Section 4 — Deploy server-info.war manually

### 4.1 Create the apps directory and copy the WAR

```bash
mkdir -p wlp-standalone/usr/servers/myServer/apps
cp App/server-info.war wlp-standalone/usr/servers/myServer/apps/
```

### 4.2 Declare the application in server.xml

Add the following `<application>` element inside the `<server>` block of
`wlp-standalone/usr/servers/myServer/server.xml`:

```xml
    <!-- Deploy server-info.war -->
    <application id="server-info"
                 name="server-info"
                 location="server-info.war"
                 type="war"
                 context-root="/server-info"/>
```

Your complete `server.xml` should now look like this:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<server description="Standalone Liberty — Admin Center enabled">

    <featureManager>
        <feature>adminCenter-1.0</feature>
        <feature>appSecurity-5.0</feature>
        <feature>restConnector-2.0</feature>
        <feature>servlet-6.0</feature>
    </featureManager>

    <httpEndpoint id="defaultHttpEndpoint"
                  host="*"
                  httpPort="9080"
                  httpsPort="9443"/>

    <basicRegistry id="basic">
        <user name="admin" password="admin"/>
    </basicRegistry>

    <administrator-role>
        <user>admin</user>
    </administrator-role>

    <keyStore id="defaultKeyStore" password="Liberty1"/>

    <applicationManager autoExpand="true"/>

    <!-- Deploy server-info.war -->
    <application id="server-info"
                 name="server-info"
                 location="server-info.war"
                 type="war"
                 context-root="/server-info"/>

</server>
```

> **Why `servlet-6.0`?** The `server-info.war` uses Jakarta Servlet 6.0 APIs. Without
> this feature, Liberty will not load the application.

### 4.3 Restart and verify

```bash
wlp-standalone/bin/server stop myServer
wlp-standalone/bin/server start myServer
```

Watch `messages.log` for the application started message:

```
CWWKZ0001I: Application server-info started in X.XXX seconds.
```

Verify the application is responding:

```bash
curl http://localhost:9080/server-info/
```

Or open `http://localhost:9080/server-info/` in a browser. You should see the
server-info page showing the Liberty server name, version, and JVM details.

---

## Section 5 — Add IHS as a front-end

IBM HTTP Server (IHS) uses the WebSphere Application Server (WAS) plugin
(`mod_was_ap24_http.so`) to proxy requests to Liberty. In this section you will
install IHS, hand-craft a minimal `plugin-cfg.xml`, and verify end-to-end routing
from IHS port **1080** through to the standalone Liberty server on port **9080**.

### 5.1 Install IBM HTTP Server

The IHS installer is a ZIP archive that you unzip directly into `~/usr/IBM`:

```bash
unzip /home/itzuser/software/IHS/WAS/9.0.5-WS-IHS-ARCHIVE-linux-x86_64-FP025.zip \
  -d ~/usr/IBM
```

Run the post-install script (sets up OS-level symlinks and permissions):

```bash
cd /home/itzuser/usr/IBM/IHS
./postinstall.sh
```

Change the default listen port from 80 to 1080 (required on the lab VM where port 80
requires root):

```bash
sed -i 's/Listen 80/Listen 1080/g' /home/itzuser/usr/IBM/IHS/conf/httpd.conf
```

Verify IHS installed correctly:

```bash
/home/itzuser/usr/IBM/IHS/bin/apachectl -version
```

Expected output includes a line like:
```
Server version: IBM_HTTP_Server/9.0.5.25
```

Create a simple static index page so you can confirm IHS responds independently of Liberty:

```bash
mkdir -p /home/itzuser/usr/IBM/IHS/htdocs
echo "<html><body><h1>IBM HTTP Server is running!</h1></body></html>" \
  > /home/itzuser/usr/IBM/IHS/htdocs/index.html
```

Start IHS and confirm the static page loads:

```bash
/home/itzuser/usr/IBM/IHS/bin/apachectl start
curl -s http://localhost:1080/
# Expected: IBM HTTP Server is running!
```

### 5.2 Create plugin directories and write plugin-cfg.xml

Create the WAS plugin configuration and log directories:

```bash
mkdir -p /home/itzuser/usr/IBM/IHS/plugin/config/webserver1
mkdir -p /home/itzuser/usr/IBM/IHS/plugin/logs/webserver1
```

Write the plugin configuration file:

```bash
cat > /home/itzuser/usr/IBM/IHS/plugin/config/webserver1/plugin-cfg.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<Config ASDisableNagle="false" AcceptAllContent="false"
        AppServerPortPreference="HostHeader" ChunkedResponse="false"
        FIPSEnable="false" IgnoreDNSFailures="false"
        RefreshInterval="60" ResponseChunkSize="64"
        TrustedProxyEnable="false" VHostMatchingCompat="false">

    <!-- Plugin log file -->
    <Log LogLevel="Error"
         Name="/home/itzuser/usr/IBM/IHS/plugin/logs/webserver1/http_plugin.log"/>

    <!-- Single-server cluster pointing at the standalone Liberty server -->
    <ServerCluster Name="standaloneCluster" LoadBalance="Round Robin"
                   CloneSeparatorChange="false" GetDWLMTable="false"
                   IgnoreAffinityRequests="true" PostSizeLimit="-1"
                   RemoveSpecialHeaders="true" RetryInterval="60">
        <Server CloneID="myServer" Name="myServer_9080"
                ConnectTimeout="5" ExtendedHandshake="false"
                MaxConnections="-1" ServerIOTimeout="900"
                WaitForContinue="false">
            <Transport Hostname="localhost" Port="9080" Protocol="http"/>
        </Server>
        <PrimaryServers>
            <Server Name="myServer_9080"/>
        </PrimaryServers>
    </ServerCluster>

    <!-- Route /server-info/* through the plugin -->
    <UriGroup Name="standaloneCluster_URIs">
        <Uri AffinityCookie="JSESSIONID" AffinityURLIdentifier="jsessionid"
             Name="/server-info/*"/>
    </UriGroup>

    <!-- Respond to requests on IHS port 1080 -->
    <VirtualHostGroup Name="standaloneCluster_Hosts">
        <VirtualHost Name="*:1080"/>
    </VirtualHostGroup>

    <Route ServerCluster="standaloneCluster"
           UriGroup="standaloneCluster_URIs"
           VirtualHostGroup="standaloneCluster_Hosts"/>

</Config>
EOF
```

### 5.3 Configure httpd.conf to load the WAS plugin

Add the `LoadModule` directive for the WAS plugin binary and the `WebSpherePluginConfig`
directive pointing at the file you just wrote. Both commands are idempotent — they only
append if the directive is not already present:

```bash
# Load the WAS plugin shared library
grep -q "mod_was_ap24_http.so" /home/itzuser/usr/IBM/IHS/conf/httpd.conf || \
  echo "LoadModule was_ap24_module /home/itzuser/usr/IBM/IHS/plugin/bin/64bits/mod_was_ap24_http.so" \
  >> /home/itzuser/usr/IBM/IHS/conf/httpd.conf

# Point the plugin at our plugin-cfg.xml
grep -q "^WebSpherePluginConfig" /home/itzuser/usr/IBM/IHS/conf/httpd.conf || \
  echo "WebSpherePluginConfig /home/itzuser/usr/IBM/IHS/plugin/config/webserver1/plugin-cfg.xml" \
  >> /home/itzuser/usr/IBM/IHS/conf/httpd.conf
```

### 5.4 Restart IHS and verify end-to-end routing

Restart IHS to pick up the new plugin directives:

```bash
/home/itzuser/usr/IBM/IHS/bin/apachectl stop 2>/dev/null || true
/home/itzuser/usr/IBM/IHS/bin/apachectl start
```

Confirm IHS itself is still serving static content:

```bash
curl -s http://localhost:1080/
# Expected: IBM HTTP Server is running!
```

Verify end-to-end routing through the plugin to Liberty:

```bash
curl http://localhost:1080/server-info/
```

You should see the same server-info page you saw in Section 4, but now routed through
IHS on port 1080 instead of hitting Liberty directly on port 9080.

Check the plugin log for any errors:

```bash
tail /home/itzuser/usr/IBM/IHS/plugin/logs/webserver1/http_plugin.log
```

An empty file (or a file with only INFO lines) means the plugin is working correctly.

---

## What you have built

```
Browser / curl
      │
      ▼  port 1080
IBM HTTP Server (IHS)
      │  mod_was_ap24_http.so
      │  plugin-cfg.xml → standaloneCluster
      ▼  port 9080
Liberty standalone (myServer)
      │
      └── server-info.war
```

You have manually installed Liberty, created and configured a server, deployed an
application, and placed IHS in front of it — all the building blocks that the
Liberty Collective lab automates at scale across a controller and four members.

---

## → Next: Liberty Collective Lab

Continue with the full [Liberty Collective Lab](01-START-HERE.md) to see how these same
concepts apply across a **controller + four-member collective** with Intelligent
Management dynamic routing.

When you are finished with this standalone orientation and ready to proceed, you can
clean up the standalone server:

```bash
# Stop the standalone server
wlp-standalone/bin/server stop myServer

# Remove the standalone runtime (keep the installer JAR)
rm -rf wlp-standalone/
```

IHS can remain running — the collective lab reuses the same IHS installation.
