# Liberty Collective Lab — Plan (Revised)

## Top-Level Overview

Build a complete, repeatable IBM WebSphere Liberty Collective demonstration environment
on a single macOS machine using a **package-first, override-driven deployment pattern**
— analogous to container image → container instance.

**The core idea:**
1. Install the Liberty 26.0.0.8 runtime once (the "base image")
2. Create a generic template server (`template-26.0.0.8`) with the app pre-deployed
3. Package that template server into a redistributable ZIP (`liberty-package-26.0.0.8.zip`)
4. Use `server package --include=all` so the ZIP is self-contained (runtime + config + app)
5. Unzip the package N times (once per target server) and apply per-server overrides
   to produce the controller, member1, and member2 — without touching the template

This gives you a single golden artifact per Liberty version that can be stamped out
into any number of server instances, identical to how a container image works.

**A second lab (not in scope here) will follow the same pattern for Liberty 25.0.0.1
using `template-25.0.0.1`.**

**Topology (this lab):**
- One Collective Controller (`controller`) — Liberty 26.0.0.8
- Two Collective Member Servers (`member1`, `member2`) — Liberty 26.0.0.8
- One Apache HTTP Server front-end (assumed installed; config generated only)
- All components under the workspace root:
  `/Users/sebastianporro/Documents/2026/ITZ/Liberty-VM-Labs`

**Source artifacts:**
- `Resources/wlp-nd-all-26.0.0.8.jar` — Liberty ND 26.0.0.8 self-extracting installer
- `App/server-info.war` — application deployed to both members

---

## Architecture

```
[Package Build Phase]
  wlp-nd-all-26.0.0.8.jar
        │
        ▼
   wlp/ (runtime)
        │
        ├── server create template-26.0.0.8
        │       └── deploy server-info.war
        │       └── generic server.xml (no ports, no role)
        │
        └── server package template-26.0.0.8 --include=all
                └── packages/liberty-package-26.0.0.8.zip  ← golden artifact

[Deploy Phase — package unzipped + overrides applied per instance]
  liberty-package-26.0.0.8.zip
        │
        ├── → installs/controller/   + overrides/controller.env
        ├── → installs/member1/      + overrides/member1.env
        └── → installs/member2/      + overrides/member2.env
```

---

## Port Assignment Matrix

| Component  | HTTP | HTTPS | IPC/Bootstrap | Role             |
|------------|------|-------|---------------|------------------|
| controller | 9080 | 9443  | 9632          | collectiveController + adminCenter |
| member1    | 9081 | 9444  | 9633          | collectiveMember |
| member2    | 9082 | 9445  | 9634          | collectiveMember |
| Apache     | 80   | 443   | —             | reverse proxy    |

All Liberty ports are in the unprivileged range (>1024).
Apache ports 80/443 require `sudo` on macOS — Apache config only.

---

## Directory Structure (final state)

```
<workspace>/
├── wlp/                              # Liberty 26.0.0.8 runtime (extracted once)
│   └── usr/servers/
│       └── template-26.0.0.8/       # template server (build phase only)
│           ├── server.xml
│           ├── bootstrap.properties
│           ├── jvm.options
│           └── apps/
│               └── server-info.war
│
├── packages/
│   └── liberty-package-26.0.0.8.zip # golden artifact produced by server package
│
├── installs/                         # deployed instances (unpacked from package)
│   ├── controller/                   # self-contained Liberty install
│   │   └── wlp/usr/servers/controller/
│   ├── member1/
│   │   └── wlp/usr/servers/member1/
│   └── member2/
│       └── wlp/usr/servers/member2/
│
├── config/
│   ├── template/                     # source configs for template-26.0.0.8
│   │   ├── server.xml
│   │   ├── bootstrap.properties
│   │   └── jvm.options
│   ├── controller/                   # configDropins/overrides files applied post-unpack
│   │   ├── role-override.xml         # adds collectiveController + adminCenter features
│   │   └── ports-override.xml        # sets HTTP/HTTPS ports
│   ├── member1/
│   │   ├── role-override.xml         # adds collectiveMember feature
│   │   └── ports-override.xml        # sets HTTP/HTTPS ports
│   ├── member2/
│   │   ├── role-override.xml         # adds collectiveMember feature
│   │   └── ports-override.xml        # sets HTTP/HTTPS ports
│   └── apache/
│       └── httpd-liberty.conf
│
├── scripts/
│   ├── 00-set-env.sh                 # exports JAVA_HOME (Java 17), WLP_HOME, WORKSPACE_ROOT
│   ├── 01-install-runtime.sh         # extract JAR → wlp/ (sources 00-set-env.sh)
│   ├── 02-build-template.sh          # create + configure template server
│   ├── 03-build-package.sh           # server package → packages/
│   ├── 04-deploy-instances.sh        # unpack package × 3, drop in configDropins overrides
│   ├── 05-create-collective.sh       # start controller, join members
│   ├── 06-configure-apache.sh        # print Apache include instructions
│   └── 07-validate.sh                # Lab Readiness Report
│
├── App/
│   └── server-info.war               # already present
├── Resources/
│   └── wlp-nd-all-26.0.0.8.jar      # already present
├── TROUBLESHOOTING.md
└── liberty-collective-lab-plan.md
```

---

## Sub-Tasks

---

### Sub-Task 1 — Locate Java 17 and Install Liberty 26.0.0.8 Runtime

**Intent**
Locate the Java 17 installation on this macOS machine, set `JAVA_HOME` explicitly
to that path, and then extract the Liberty ND 26.0.0.8 runtime using that JVM.
All subsequent Liberty processes (server start, package, collective join) must
also use this same Java 17 path — set via `JAVA_HOME` in `jvm.options` and scripts.

**Expected Outcomes**
- Java 17 home path identified and confirmed (e.g. via `/usr/libexec/java_home -v 17`)
- `JAVA_HOME` exported and used for the JAR extraction
- `wlp/` directory exists at workspace root
- `wlp/bin/server` is executable
- `wlp/lib/versions/WebSphereApplicationServer.properties` shows version `26.0.0.8`
- `$JAVA_HOME/bin/java -version` reports `17.x.x`

**Todo List**
1. Locate Java 17 home path:
   ```zsh
   /usr/libexec/java_home -v 17
   ```
   If that fails, check Homebrew paths:
   ```zsh
   ls /opt/homebrew/opt/openjdk@17/bin/java   # Apple Silicon
   ls /usr/local/opt/openjdk@17/bin/java       # Intel
   ```
2. Export `JAVA_HOME` to the discovered path, for example:
   ```zsh
   export JAVA_HOME=$(/usr/libexec/java_home -v 17)
   export PATH=$JAVA_HOME/bin:$PATH
   ```
3. Confirm the correct Java is active:
   ```zsh
   java -version   # must report 17.x.x
   ```
4. Extract the Liberty runtime using that Java:
   ```zsh
   $JAVA_HOME/bin/java -jar Resources/wlp-nd-all-26.0.0.8.jar \
     --acceptLicense \
     --verbose \
     --installRoot wlp
   ```
5. Confirm `wlp/bin/server` exists and is executable
6. Record the resolved `JAVA_HOME` path — it will be written into
   `config/template/jvm.options` as `-Dsun.java.command` is not needed,
   but the path is embedded in `scripts/00-set-env.sh` (a new shared env file)
   so every script sources it

**Relevant Context**
- Installer: `Resources/wlp-nd-all-26.0.0.8.jar`
- Liberty ND is required — `collectiveController` and `collectiveMember` features
  are ND-only and not present in Liberty Core/Base
- Liberty respects `JAVA_HOME` at launch time — if set, `wlp/bin/server` uses
  `$JAVA_HOME/bin/java` automatically; no `server.xml` change needed
- macOS `/usr/libexec/java_home -v 17` is the canonical way to resolve a
  specific JDK version on macOS regardless of Homebrew vs system install
- Script: `scripts/01-install-runtime.sh`
- A new shared file `scripts/00-set-env.sh` will export `JAVA_HOME`, `WLP_HOME`,
  and workspace root — sourced by all other scripts

**Status:** `[ ] pending`

---

### Sub-Task 2 — Build Template Server (`template-26.0.0.8`)

**Intent**
Create a generic, role-neutral Liberty server called `template-26.0.0.8` inside the
build-phase `wlp/` runtime. This server is the "image definition" — it contains:
- A minimal `server.xml` with no collective role, no fixed ports, no hostnames
- The `server-info.war` application pre-staged in `apps/`
- A `bootstrap.properties` that uses variable references for all runtime values
- A `jvm.options` with sensible defaults

The template does **not** know if it will become a controller or a member.
That identity is applied later via overrides.

**Expected Outcomes**
- `wlp/usr/servers/template-26.0.0.8/` directory exists
- `server.xml` loads `server-info.war` using a variable path
- No hardcoded ports — all ports reference `${env.HTTP_PORT}`, `${env.HTTPS_PORT}` etc.
- `wlp/bin/server status template-26.0.0.8` returns "not running" (not an error)

**Files to generate:**

`config/template/server.xml`
- Features: `servlet-6.0`, `ssl`, `appSecurity` (no collective role yet)
- HTTP/HTTPS ports: variables (`${default.http.port}` / `${default.https.port}`)
  resolved from `bootstrap.properties` — no hardcoded values
- Application: `server-info.war` from `${server.config.dir}/apps/`
- Keystore password: `${keystore.password}` resolved from `bootstrap.properties`
- Basic registry: admin user placeholder
- **No `configDropins` content in the template** — the template is role-neutral

`config/template/bootstrap.properties`
- Defines default variable values used by `server.xml`
- These values are the baseline; per-instance `bootstrap.properties` written
  at deploy time will override them

`config/template/jvm.options`
- `-Xms128m -Xmx256m`
- `-Duser.timezone=America/New_York`
- GC logging disabled (lab simplicity)
- **Does not hardcode `JAVA_HOME`** — Java 17 is enforced via `JAVA_HOME`
  set in `scripts/00-set-env.sh`, which Liberty picks up automatically at launch

**Todo List**
1. Write `config/template/server.xml`
2. Write `config/template/bootstrap.properties`
3. Write `config/template/jvm.options`
4. Write `scripts/00-set-env.sh` — exports `JAVA_HOME` (Java 17 path), `WLP_HOME`,
   and `WORKSPACE_ROOT`; sourced at the top of every other script
5. Run `wlp/bin/server create template-26.0.0.8` (with `JAVA_HOME` set)
6. Copy config files into `wlp/usr/servers/template-26.0.0.8/`
7. Copy `App/server-info.war` into `wlp/usr/servers/template-26.0.0.8/apps/`
8. Script: `scripts/02-build-template.sh`

**Relevant Context**
- The template server name `template-26.0.0.8` is deliberately version-stamped
  so a future `template-25.0.0.1` can coexist in the same workspace
- Variable substitution in `server.xml` reads from `bootstrap.properties`
  (`${varname}` syntax) — this is Liberty's built-in config variable mechanism
- The `configDropins/overrides/` directory does not exist in the template;
  it is created and populated at deploy time per instance

**Status:** `[x] complete`

---

### Sub-Task 3 — Package the Template (`liberty-package-26.0.0.8.zip`)

**Intent**
Run `server package` with `--include=all` to produce a self-contained ZIP that
bundles the Liberty runtime, the template server configuration, and the application.
This ZIP is the single redistributable artifact — equivalent to a container image.

**Expected Outcomes**
- `packages/liberty-package-26.0.0.8.zip` exists
- Unzipping it produces a standalone `wlp/` directory with the server inside
- The ZIP can be copied to any machine with Java and exploded without any
  separate Liberty installer

**Todo List**
1. Create `packages/` directory
2. Run:
   ```zsh
   wlp/bin/server package template-26.0.0.8 \
     --include=all \
     --archive=packages/liberty-package-26.0.0.8.zip
   ```
3. Verify ZIP was created and is non-zero in size
4. Spot-check ZIP contents:
   ```zsh
   unzip -l packages/liberty-package-26.0.0.8.zip | head -40
   ```
   Confirm `wlp/usr/servers/template-26.0.0.8/apps/server-info.war` is present
5. Script: `scripts/03-build-package.sh`

**Relevant Context**
- `--include=all` packages runtime + usr directory (config + apps)
- `--include=usr` packages only config/apps without the runtime (smaller, requires
  a pre-installed runtime at deploy target) — use `all` for this lab for portability
- The resulting ZIP is the artifact that gets "deployed" in Sub-Task 4

**Status:** `[ ] pending`

---

### Sub-Task 4 — Deploy Instances from Package (controller, member1, member2)

**Intent**
Unzip `liberty-package-26.0.0.8.zip` three times into `installs/controller/`,
`installs/member1/`, and `installs/member2/`. After unpacking, apply per-instance
overrides by:
1. Renaming the server from `template-26.0.0.8` to the instance name
2. Creating `${server.config.dir}/configDropins/overrides/` and dropping in
   role-specific and ports-specific XML files
3. Writing a per-instance `bootstrap.properties` with port and password values

This is the "container run" step — same image, different runtime parameters.

**Expected Outcomes**
- Three independent Liberty installs under `installs/`
- Each has a correctly named server directory (controller / member1 / member2)
- Each has `configDropins/overrides/` populated with `role-override.xml`
  and `ports-override.xml`
- `installs/controller/wlp/bin/server status controller` returns "not running"

**configDropins override files to generate (two XML files per instance):**

`config/controller/role-override.xml`
- Placed at: `installs/controller/wlp/usr/servers/controller/configDropins/overrides/`
- Adds features: `collectiveController`, `adminCenter-1.0`
- Liberty merges this with the base `server.xml` automatically at startup

`config/controller/ports-override.xml`
- Placed at same `configDropins/overrides/` directory
- Sets `<httpEndpoint>` with ports 9080 (HTTP) and 9443 (HTTPS)
- Also sets `keystore.password` and `collective.password` values

`config/member1/role-override.xml`
- Adds feature: `collectiveMember`

`config/member1/ports-override.xml`
- Sets HTTP 9081 / HTTPS 9444

`config/member2/role-override.xml`
- Adds feature: `collectiveMember`

`config/member2/ports-override.xml`
- Sets HTTP 9082 / HTTPS 9445

**Per-instance `bootstrap.properties` (written at deploy time):**
- `default.http.port=<port>` — resolves variable in template `server.xml`
- `default.https.port=<port>`
- `keystore.password=<secret>`

**Todo List**
1. Write all `role-override.xml` and `ports-override.xml` files under `config/`
2. Write deploy logic in `scripts/04-deploy-instances.sh`:
   - For each instance name in `[controller, member1, member2]`:
     a. Create `installs/<name>/`
     b. Unzip `packages/liberty-package-26.0.0.8.zip` into `installs/<name>/`
     c. Rename `installs/<name>/wlp/usr/servers/template-26.0.0.8/`
        → `installs/<name>/wlp/usr/servers/<name>/`
     d. Create `installs/<name>/wlp/usr/servers/<name>/configDropins/overrides/`
     e. Copy `config/<name>/role-override.xml` into that directory
     f. Copy `config/<name>/ports-override.xml` into that directory
     g. Write `installs/<name>/wlp/usr/servers/<name>/bootstrap.properties`
        with instance-specific port and password values
3. Verify all three instances have correct server directory names and
   `configDropins/overrides/` populated

**Relevant Context**
- Liberty automatically scans `${server.config.dir}/configDropins/overrides/`
  at startup and merges all XML files found there on top of `server.xml`
- `configDropins/overrides/` takes precedence over `server.xml` — conflicts
  resolve in favour of the dropin
- `configDropins/defaults/` (lower precedence) also exists but is not used here
- Features declared in dropins are **additive** — the template features are kept
  and the role features are merged in

**Status:** `[ ] pending`

---

### Sub-Task 5 — Form the Collective (controller + join members)

**Intent**
Start the controller, then use `collective join` to register `member1` and `member2`
with it. This establishes the management trust relationship and generates the
SSL certificates required for collective communication.

**Expected Outcomes**
- Controller running at `https://localhost:9443/adminCenter`
- `member1` and `member2` visible in Admin Center under "Servers"
- Both members running and serving `server-info.war`
- `collective status` exits 0

**Todo List**
1. Start controller:
   ```zsh
   installs/controller/wlp/bin/server start controller
   ```
2. Confirm Admin Center is accessible:
   ```zsh
   curl -k -u admin:<password> https://localhost:9443/adminCenter
   ```
3. Join member1:
   ```zsh
   installs/member1/wlp/bin/collective join member1 \
     --host=localhost \
     --port=9443 \
     --user=admin \
     --password=<COLLECTIVE_PASSWORD> \
     --keystorePassword=<KEYSTORE_PASSWORD> \
     --serverHost=localhost \
     --serverHttpsPort=9444
   ```
4. Join member2 (same command, port 9445)
5. Start member1: `installs/member1/wlp/bin/server start member1`
6. Start member2: `installs/member2/wlp/bin/server start member2`
7. Verify both members appear in Admin Center
8. Script: `scripts/05-create-collective.sh`

**Relevant Context**
- `collective join` is run from the **member's** `wlp/bin/` — not the controller's
- The `--port` flag refers to the **controller's** HTTPS port (9443)
- `collective join` modifies the member's `server.xml` to add trust certificates;
  this is why the member's server directory must be fully set up before joining
- Members do not need to be running during `collective join`

**Status:** `[ ] pending`

---

### Sub-Task 6 — Generate Apache Front-End Configuration

**Intent**
Generate `config/apache/httpd-liberty.conf` — an Apache include file that
configures `mod_proxy_balancer` to load-balance across `member1` (9081) and
`member2` (9082) with sticky sessions via `JSESSIONID`.

**Expected Outcomes**
- `config/apache/httpd-liberty.conf` written
- Single public endpoint `http://localhost/ServerInfo` routes to both members
- Balancer Manager accessible at `http://localhost/balancer-manager` (localhost only)
- `apachectl configtest` passes after adding the include

**Configuration to generate:**
- Required modules: `mod_proxy`, `mod_proxy_balancer`, `mod_proxy_http`, `mod_lbmethod_byrequests`
- Balancer members: `http://localhost:9081` and `http://localhost:9082`
- Load balance method: `byrequests` (round-robin)
- Sticky sessions: `stickysession=JSESSIONID|jsessionid`
- Balancer Manager: restricted to `127.0.0.1`

**Todo List**
1. Write `config/apache/httpd-liberty.conf`
2. Write `scripts/06-configure-apache.sh` that prints the `Include` line to add
   to the main `httpd.conf` and the path to the generated config file
3. Document Homebrew Apache paths for both Intel and Apple Silicon macOS:
   - Intel: `/usr/local/etc/httpd/httpd.conf`
   - Apple Silicon: `/opt/homebrew/etc/httpd/httpd.conf`
4. Verify modules with: `apachectl -M | grep -E "proxy|balancer|lbmethod"`

**Relevant Context**
- Apache is assumed already installed — only the include config is generated
- Session affinity requires `mod_proxy_balancer` with `stickysession` directive
- Liberty generates `JSESSIONID` cookies for session tracking

**Status:** `[ ] pending`

---

### Sub-Task 7 — Validation Script and Lab Readiness Report

**Intent**
Produce `scripts/07-validate.sh` — a self-contained validation script that checks
every component in the lab and prints a structured **Lab Readiness Report**
with PASS/FAIL per check.

**Expected Outcomes**
- Script exits 0 only when all checks pass
- Printed report covers all topology components
- Any FAIL prints the specific fix command

**Checks to implement:**

| Check | Command | Expected |
|-------|---------|----------|
| Java available | `java -version` | exit 0 |
| Runtime installed | `test -x wlp/bin/server` | exit 0 |
| Package exists | `test -f packages/liberty-package-26.0.0.8.zip` | exit 0 |
| Controller port | `lsof -iTCP:9443 -sTCP:LISTEN` | process found |
| Member1 port | `lsof -iTCP:9081 -sTCP:LISTEN` | process found |
| Member2 port | `lsof -iTCP:9082 -sTCP:LISTEN` | process found |
| App on member1 | `curl -s -o /dev/null -w "%{http_code}" http://localhost:9081/ServerInfo` | 200 |
| App on member2 | `curl -s -o /dev/null -w "%{http_code}" http://localhost:9082/ServerInfo` | 200 |
| Apache routing | `curl -s -o /dev/null -w "%{http_code}" http://localhost/ServerInfo` | 200 |
| Collective status | `installs/controller/wlp/bin/collective status --host=localhost --port=9443 --user=admin --password=<pw>` | exit 0 |

**Todo List**
1. Write `scripts/07-validate.sh` with each check as a function returning PASS/FAIL
2. Aggregate results and print `Lab Readiness Report` table at the end
3. Exit with code 0 (all pass) or 1 (any fail)
4. Make script executable: `chmod +x scripts/07-validate.sh`

**Status:** `[ ] pending`

---

### Sub-Task 8 — Troubleshooting Guide

**Intent**
Write `TROUBLESHOOTING.md` covering the most common failure modes for this
specific package-deploy pattern on macOS, with symptom → diagnosis → resolution
structure.

**Expected Outcomes**
- `TROUBLESHOOTING.md` written at workspace root
- Covers all 6 failure categories
- Each entry includes: symptom, likely cause, resolution command/config fix,
  and relevant log file path

**Sections:**
1. **Member registration failures** — cert trust errors, wrong controller port,
   controller not running when `collective join` is called
2. **Package build/deploy failures** — JAR extraction errors, Java version mismatch,
   `server package` fails if server has never been started (apps not resolved)
3. **Application deployment failures** — WAR not found, wrong `server.xml` app path,
   feature mismatch (`servlet-5.0` vs `servlet-6.0`)
4. **Apache routing failures** — module not loaded, port mismatch, config syntax error
5. **SSL / keystore issues** — password mismatch between `bootstrap.properties` and
   `ports-override.xml`, expired default cert, untrusted self-signed CA in curl
6. **Collective communication failures** — wrong `--host`/`--port` in join,
   firewall blocking localhost ports on macOS, member started before join completes

**Liberty log file locations (macOS):**
- `installs/<name>/wlp/usr/servers/<name>/logs/messages.log`
- `installs/<name>/wlp/usr/servers/<name>/logs/console.log`

**Todo List**
1. Write `TROUBLESHOOTING.md` with all 6 sections
2. Include a "Quick Diagnostics" section at the top with 5 fast commands
   to run when anything is broken

**Status:** `[ ] pending`

---

## Execution Order and Dependencies

```
Sub-Task 1  (install runtime)
     │
Sub-Task 2  (build template server)
     │
Sub-Task 3  (server package → ZIP)
     │
Sub-Task 4  (deploy 3 instances from ZIP + apply overrides)
     │
Sub-Task 5  (form collective: start controller, join members)
     │
     ├── Sub-Task 6  (Apache config — can run in parallel with Sub-Task 5)
     ├── Sub-Task 7  (validation script — can run in parallel with Sub-Task 5)
     └── Sub-Task 8  (troubleshooting guide — can run in parallel)
```

Sub-Tasks 1 → 2 → 3 → 4 → 5 are strictly sequential (each depends on the previous).
Sub-Tasks 6, 7, 8 can be generated in parallel once the topology is defined.

---

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Java version | Java 17 via `JAVA_HOME` in `00-set-env.sh` | Liberty 26.x certified on Java 17; enforced at OS level so all scripts and Liberty processes inherit it |
| Java discovery | `/usr/libexec/java_home -v 17` | macOS-canonical; works for both system JDK and Homebrew installs |
| Package scope | `--include=all` | Self-contained; no separate runtime install at deploy target |
| Override mechanism | `configDropins/overrides/` XML files | Liberty-native merge; highest precedence; no template edits |
| Port/password injection | `ports-override.xml` + `bootstrap.properties` | Dropin sets endpoint; bootstrap resolves variables |
| Server naming in package | `template-26.0.0.8` | Version-stamped; coexists with future `template-25.0.0.1` |
| Role injection | `role-override.xml` in `configDropins/overrides/` | Features are additive; template stays role-neutral |
| Collective join direction | From member's `wlp/bin/` | Liberty requirement; join modifies member config |
| Apache session affinity | `JSESSIONID` cookie | Standard Liberty session cookie; no server-side config needed |
