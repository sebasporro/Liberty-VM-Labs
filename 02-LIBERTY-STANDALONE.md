> **⚠️ Beta Version** — This lab is under active development. If you encounter any errors,
> broken steps, or unclear instructions, please report them to **Sebastian Porro**
> (sebastian.porro@ibm.com). Your feedback helps improve the experience for everyone.


# Liberty Standalone

## Lab Objectives

By the end of this lab you will be able to:

- Install a Liberty runtime from an archive file and understand its directory structure.
- Create, start, stop, and monitor a Liberty server from the command line.
- Read and modify `server.xml` to enable features and configure endpoints.
- Enable the Liberty Admin Center and log in to the browser-based management UI.
- Deploy a WAR application manually and verify it is running.
- Install and configure IBM HTTP Server (IHS) with the WAS plugin to front Liberty.
- Trace a request end-to-end from a browser through IHS to the Liberty application.

All steps are performed with manual commands — no automation scripts — so that every
building block is visible before the [Liberty Collective Lab](03-LIBERTY-COLLECTIVES.md)
automates the same concepts at scale.

---

## Target Architecture

At the end of this lab you will have the following topology running on the VM:

```
┌─────────────────────────────────────────────────────────┐
│                        Lab VM                           │
│                                                         │
│   Browser / curl                                        │
│        │                                                │
│        │  HTTP :1080                                    │
│        ▼                                                │
│  ┌─────────────────────────────┐                        │
│  │   IBM HTTP Server (IHS)     │                        │
│  │   Apache 2.4 — port 1080    │                        │
│  │                             │                        │
│  │   mod_was_ap24_http.so      │                        │
│  │   plugin-cfg.xml            │                        │
│  └──────────────┬──────────────┘                        │
│                 │  HTTP :9080  (URI: /server-info/*)    │
│                 ▼                                       │
│  ┌─────────────────────────────┐                        │
│  │  Liberty standalone         │                        │
│  │  server: myServer           │                        │
│  │  port: 9080 / 9443          │                        │
│  │                             │                        │
│  │  ├── adminCenter-1.0        │                        │
│  │  ├── appSecurity-5.0        │                        │
│  │  └── server-info.war        │                        │
│  └─────────────────────────────┘                        │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

| Layer | Product | Port |
|-------|---------|------|
| Web server | IBM HTTP Server 9.0.5 | 1080 |
| Application server | WebSphere Liberty 26.0.0.8 | 9080 (HTTP) / 9443 (HTTPS) |
| Application | server-info.war | `/server-info/` context root |

---

## Table of Contents

1. [Section 1 — Liberty Installation](#section-1--liberty-installation)
2. [Section 2 — Create a server, start/stop, and check logs](#section-2--create-a-server-startstop-and-check-logs)
3. [Section 3 — Review server.xml and enable Admin Center](#section-3--review-serverxml-and-enable-admin-center)
4. [Section 4 — Deploy server-info.war manually](#section-4--deploy-server-infowar-manually)
5. [Section 5 — Add IHS as a front-end](#section-5--add-ihs-as-a-front-end)

---

> **Before you begin:** Make sure you have cloned the lab repository to
> `/home/itzuser/Liberty-VM-Labs` on the VM. If you haven't done that yet, see
> [01-START-HERE.md](01-START-HERE.md) for setup instructions. All commands in this
> lab are run from the repo root unless otherwise noted.

---

## Section 1 — Liberty Installation

### Installation options

Liberty can be installed in two ways:

| Method | When to use |
|--------|-------------|
| **IBM Installation Manager (IM)** | Enterprise environments where a central administrator manages fix packs, license entitlements, and multiple product installations from a single tool. IM tracks what is installed and can apply maintenance packages automatically. |
| **Archive file (ZIP or JAR)** | Development, lab, and cloud-native scenarios where a self-contained, portable runtime is preferred. No additional tooling is required — extraction is a single command, and multiple runtimes can coexist side by side without conflict. |

These labs use the **archive method**. The Liberty installer ships as a self-executing JAR (`wlp-nd-all-*.jar`). Running it with `--acceptLicense` extracts a complete, ready-to-use `wlp/` directory to the path you specify — no installation registry, no elevated privileges, no post-install configuration tool required.

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
binary lands at `wlp-standalone/wlp/`. The resulting layout looks like this:

```
wlp-standalone/
└── wlp/
    ├── bin/                ← server, serverenv, securityUtility, …
    ├── dev/                ← API JARs and SPI stubs for development
    ├── etc/                ← global JVM and environment defaults
    ├── lib/                ← Liberty kernel and feature bundles
    ├── templates/          ← server.xml templates used by `server create`
    └── usr/
        └── servers/        ← your server instances will be created here
```

Move its contents up one level so the runtime root is `wlp-standalone/` directly.

#### `bin/` command reference

The `bin/` directory contains the scripts you will use throughout these labs:

| Command | Purpose |
|---------|---------|
| `server` | Main lifecycle command — `create`, `start`, `stop`, `status`, `run`, `debug`, `package`, `dump`, `javadump`, `version` |
| `securityUtility` | Encode passwords, generate TLS certificates, and create LTPA keys for use in `server.xml` |
| `featureUtility` | Install individual Liberty features from Maven Central or a local mirror without rerunning the full installer |
| `productInfo` | Display installed Liberty edition, version, and applied iFixes |
| `serverenv` | Print the effective environment variables Liberty will use at runtime (useful for diagnosing `WLP_USER_DIR` and `JAVA_HOME` resolution) |
| `installUtility` | Older feature installer (superseded by `featureUtility`); still present for compatibility |
| `wlpenv` | Shell helper that sets `WLP_HOME` and related variables for the current session |

> **Most-used in this lab:** `server` is the only command you need for the standalone exercises.
> `securityUtility encode` becomes useful in the Collective lab when managing keystore passwords.

```bash
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

**1. Replace the entire `<featureManager>` block**

The default block contains only `jsp-2.3` (Java EE 7). Replace the whole block with the
one below. `pages-3.1` is the Jakarta EE 10 equivalent of `jsp-2.3` — keeping the old
feature alongside `appSecurity-5.0` would cause a generation conflict that prevents
Liberty from loading any features at all.

```xml
    <featureManager>
        <feature>pages-3.1</feature>
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
        <feature>pages-3.1</feature>          <!-- Jakarta EE 10 JSP/pages support -->
        <feature>adminCenter-1.0</feature>
        <feature>appSecurity-5.0</feature>
        <feature>restConnector-2.0</feature>
        <feature>servlet-6.0</feature>        <!-- required by server-info.war -->
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
> this feature, Liberty will not load the application. Note that `pages-3.1` (Jakarta
> Pages / JSP) is kept from Section 3 — it does not conflict with `servlet-6.0` since
> they target the same Jakarta EE 10 generation.

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

You can also open the application in a web browser. Navigate to:

```
http://localhost:9080/server-info/
```

The page displays a summary of the running Liberty instance, including:

- **Server name** — the name you gave the server (`myServer`)
- **Liberty version** — the full build version string (e.g. `26.0.0.8`)
- **JVM information** — vendor, version, and heap settings
- **Host name** — the machine the server is running on

> **Tip:** Bookmark this URL — you will return to it in Section 5 to confirm the same
> page is reachable through IHS on port **1080** instead of Liberty's direct port **9080**.

---

## Section 5 — Add IHS as a front-end

### Why front an application server with a web server?

Running Liberty directly on a public port works fine for development, but production
deployments typically place a dedicated web server in front of the application server
for several reasons:

| Concern | How IHS helps |
|---------|--------------|
| **Static content performance** | IHS serves HTML, CSS, images, and downloads directly from disk without involving the JVM, freeing Liberty threads for application logic. |
| **SSL/TLS termination** | TLS handshakes are offloaded to IHS, reducing CPU overhead on Liberty. |
| **Port standardisation** | IHS listens on the standard HTTP port (80/443). Liberty can run on unprivileged ports without requiring root. |
| **Load balancing** | In a collective, IHS distributes requests across multiple Liberty members. The WAS plugin handles session affinity and failover automatically. |
| **Security boundary** | Only IHS is exposed to the network. Liberty members sit on an internal network and are not directly reachable by clients. |

Even in this single-server standalone lab the pattern is the same as in a multi-member
collective — learning it here makes the collective setup in Section 5 of the next lab
immediately recognisable.

### Components involved

Three pieces work together to route a request from a browser to Liberty:

```
Browser
  │  HTTP request
  ▼
IBM HTTP Server (IHS)                    ← Apache-based web server
  │  mod_was_ap24_http.so                ← WAS plugin module loaded into IHS
  │  reads plugin-cfg.xml                ← routing rules: which URIs go to which Liberty servers
  ▼
Liberty (myServer, port 9080)            ← application server
  └── server-info.war
```

| Component | Role |
|-----------|------|
| **IBM HTTP Server (IHS)** | Apache HTTP Server 2.4 packaged and supported by IBM. Handles the client-facing connection. |
| **WAS Plugin (`mod_was_ap24_http.so`)** | A native Apache module that intercepts matched requests and forwards them to Liberty over HTTP or HTTPS using IBM's proprietary binary protocol. |
| **`plugin-cfg.xml`** | XML file that tells the plugin which URI patterns to intercept, which Liberty servers exist (hostname + port), and how to handle failover and session affinity. |

In a Liberty Collective, `plugin-cfg.xml` is generated and refreshed automatically by
the controller's Intelligent Management feature. In this standalone lab you will write it
by hand (via the helper script) to understand its structure before automation takes over.

### 5.1 Configure IHS and WAS Plugin for Standalone Liberty

IBM HTTP Server (IHS) uses the WebSphere Application Server (WAS) plugin
(`mod_was_ap24_http.so`) to proxy requests to Liberty. In this section you will
configure IHS with a minimal `plugin-cfg.xml` and verify end-to-end routing
from IHS port **1080** through to the standalone Liberty server on port **9080**.

### 5.1 Configure IHS and WAS Plugin for Standalone Liberty

To streamline setting up IHS and the WAS plugin to route traffic to the standalone Liberty server, execute the helper script [`scripts/configure-standalone-ihs.sh`](scripts/configure-standalone-ihs.sh).

#### What the script does
1. **Installs & Post-configures IHS:** Extracts the IHS installer archive to `~/usr/IBM/IHS` (if not already extracted), runs `./postinstall.sh`, and sets the listening port to `1080` (non-root).
2. **Creates Static Document Root:** Writes an `index.html` in `htdocs` to test direct IHS static responses.
3. **Creates WAS Plugin Directories:** Ensures `$IHS_ROOT/plugin/config/webserver1` and `$IHS_ROOT/plugin/logs/webserver1` exist.
4. **Generates `plugin-cfg.xml`:** Creates a static routing configuration directing requests for `/server-info/*` to the standalone Liberty instance on port `9080`.
5. **Updates `httpd.conf` Directives:** Adds `LoadModule was_ap24_module` and `WebSpherePluginConfig` pointing to `plugin-cfg.xml`.
6. **Restarts & Validates IHS:** Starts IHS and performs test requests against both the static root (`/`) and the proxied Liberty app (`/server-info/`).

Run the script from the repository root:

```bash
bash scripts/configure-standalone-ihs.sh
```

#### Generated `plugin-cfg.xml` sample:

```xml
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
```

#### Key directives added to `httpd.conf` sample

```apache
# Load the WebSphere plugin binary module
LoadModule was_ap24_module /home/itzuser/usr/IBM/IHS/plugin/bin/64bits/mod_was_ap24_http.so

# Specify the path to the WAS plugin configuration file
WebSpherePluginConfig /home/itzuser/usr/IBM/IHS/plugin/config/webserver1/plugin-cfg.xml
```

### 5.2 Verify end-to-end routing

The script already started IHS and ran initial validation. If you need to restart
IHS manually after a config change, use:

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

Continue with the full [Liberty Collective Lab](03-LIBERTY-COLLECTIVES.md) to see how these same
concepts apply across a **controller + four-member collective** with Intelligent
Management dynamic routing.

When you are finished with this standalone orientation and ready to proceed, you can
clean up the standalone server and reset IHS:

```bash
# Stop the standalone server
wlp-standalone/bin/server stop myServer

# Remove the standalone runtime
rm -rf wlp-standalone/

# Reset IHS to default configuration
bash scripts/reset-ihs.sh
```
