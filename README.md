# IBM WebSphere Liberty Collective Lab

A complete, repeatable IBM WebSphere Liberty 26.0.0.8 Collective demonstration environment
running on a single machine, built using a **package-first, override-driven deployment pattern**
analogous to container images.

---

## Architecture

```
wlp-nd-all-26.0.0.8.jar
        │  (extracted once)
        ▼
   wlp-26/  ── build-phase runtime
        │
        └── template-26.0.0.8  ── role-neutral server + server-info.war
                │
                └── server package --include=all
                        │
                        ▼
            liberty-package-26.0.0.8.zip  ◄── Golden Artifact
                        │
          ┌─────────────┼──────────────┐
          ▼             ▼              ▼
    controller      member1        member2
    (HTTPS 9443)   (HTTP 9081)   (HTTP 9082)
          │             │              │
          └─────────────┴──────────────┘
                        │
               IBM HTTP Server (IHS)
                    (port 8080)
```

Each deployed instance receives its identity by dropping XML files into
`${server.config.dir}/configDropins/overrides/` — Liberty merges them at startup
with highest precedence. The golden package is never modified.

---

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| Java | 17 | Pre-installed on lab VM (IBM Semeru recommended) |
| IBM HTTP Server (IHS) | 2.4+ | Installer ZIP pre-provisioned at `/home/itzuser/software/IHS/` |
| Shell | bash | All scripts use `#!/bin/bash` |
| Liberty installer | 26.0.0.8 ND | Pre-provisioned at `/home/itzuser/software/Liberty/Liberty/wlp-nd-all-26.0.0.8.jar` |
| Liberty installer | 25.0.0.1 Base | Pre-provisioned at `/home/itzuser/software/Liberty/Liberty/wlp-base-all-25.0.0.1.jar` |
| Application WAR | — | `App/server-info.war` (committed to repo) |

> **Note:** Installer binaries are pre-provisioned on the lab VM at fixed paths and are not
> committed to git. No manual download is required before running the scripts.

---

## Running the Lab — Full Sequence

The lab supports two Liberty versions running as members of the **same collective**:

| Version | Runtime | Members | Package |
|---------|---------|---------|---------|
| 26.0.0.8 ND | `wlp-26/` | controller, member1, member2 | `liberty-package-26.0.0.8.zip` |
| 25.0.0.1 Base | `wlp-25/` | member3, member4 | `liberty-package-25.0.0.1.zip` |

The controller always runs 26.0.0.8. The collective protocol is version-agnostic — members
of different Liberty versions coexist in the same collective without any special configuration.

---

### Step 0 — Clone the Repository

Open a terminal on the lab VM. All commands in this lab are run from
`/home/itzuser/Liberty-VM-Labs` unless noted otherwise.

```bash
cd /home/itzuser
git clone https://github.com/sebasporro/Liberty-VM-Labs.git
cd Liberty-VM-Labs
```

Once cloned, update the `WORKSPACE_ROOT` variable in `scripts/00-set-env.sh` to match
the clone location:

```bash
sed -i 's|^export WORKSPACE_ROOT=.*|export WORKSPACE_ROOT="/home/itzuser/Liberty-VM-Labs"|' \
  scripts/00-set-env.sh
```

Verify the change:

```bash
grep WORKSPACE_ROOT scripts/00-set-env.sh
# Expected output:
# export WORKSPACE_ROOT="/home/itzuser/Liberty-VM-Labs"
```

> **Note:** Every other path in the lab scripts is derived from `WORKSPACE_ROOT`, so this
> one-line change is the only configuration required after cloning.

---

### Step 0b — Install IBM HTTP Server (IHS)

IHS is the front-end HTTP server that load-balances requests across the Liberty collective
members. Install it once before running the lab steps.

```bash
scripts/install-ihs.sh
```

This script:
1. Locates the IHS installer ZIP at `/home/itzuser/software/IHS/`
2. Extracts and runs the silent installer → installs to `/opt/IBM/HTTPServer`
3. Configures IHS to listen on port **8080**

After install, add IHS to your PATH so `apachectl` is available to all lab scripts:

```bash
echo 'export PATH="/opt/IBM/HTTPServer/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

Verify:

```bash
apachectl -v
# Expected: Server version: IBM_HTTP_Server/...
```

> **If the ZIP is at a different path**, override the search directory:
> ```bash
> export IHS_INSTALLER_DIR=/path/to/dir/containing/ihs-zip
> scripts/install-ihs.sh
> ```

---

### Step 1 — Build (run once per version)

Build both golden packages before deploying anything. Only needs to be repeated if the
template configuration or application changes.

> **Before running:** confirm the Liberty installer JARs are present at their expected paths:
> ```bash
> ls /home/itzuser/software/Liberty/Liberty/wlp-nd-all-26.0.0.8.jar
> ls /home/itzuser/software/Liberty/Liberty/wlp-base-all-25.0.0.1.jar
> ```
> If the files are at a different location, export the paths first:
> ```bash
> export LIBERTY_INSTALLER_26=/path/to/wlp-nd-all-26.0.0.8.jar
> export LIBERTY_INSTALLER_25=/path/to/wlp-base-all-25.0.0.1.jar
> # Hint — find them with:
> find / -name 'wlp-nd-all-26.0.0.8.jar' 2>/dev/null
> ```

#### Liberty 26.0.0.8

```bash
scripts/01-install-runtime.sh && \
scripts/02-build-template.sh && \
scripts/03-build-package.sh
```

#### Liberty 25.0.0.1

```bash
scripts/01-install-runtime-25.sh && \
scripts/02-build-template-25.sh && \
scripts/03-build-package-25.sh
```

---

### Step 2 — Deploy Controller and 26.0.0.8 Members

```bash
scripts/install-controller.sh      # Deploy + start controller
scripts/add-member-26.sh member1   # Deploy member1, join collective
scripts/add-member-26.sh member2   # Deploy member2, join collective
```

**Expected state:** Admin Center at `https://localhost:9443/adminCenter` (admin/admin),
member1 at `http://localhost:9081/server-info/`, member2 at `http://localhost:9082/server-info/`.

---

### Step 3 — Configure IHS with Dynamic Routing

Enable Liberty Dynamic Routing on the controller so that new members joining the collective
are automatically picked up by IHS — no manual balancer config changes needed.

```bash
# Configure IHS with the static balancer config (enables modules + adds include)
scripts/start-apache.sh

# Enable dynamicRouting-1.0 on the controller, restart it, generate IHS dynamic config
scripts/enable-dynamic-routing.sh
```

The script prints the exact `Include` change to make in `httpd.conf`. After making the change:

```bash
apachectl graceful
```

**Expected state:** `http://localhost:8080/server-info/` routes via the controller dynamically
to member1 or member2.

---

### Step 4 — Add 25.0.0.1 Members

With dynamic routing active, member3 and member4 are automatically added to the routing
table as soon as they join — no IHS config changes required.

```bash
scripts/add-member-25.sh member3   # Deploy member3 (25.0.0.1), join collective
scripts/add-member-25.sh member4   # Deploy member4 (25.0.0.1), join collective
```

**Expected state:** All four members visible in Admin Center. IHS at
`http://localhost:8080/server-info/` now rotates across all four members.

---

### Step 5 — Validate

```bash
scripts/07-validate.sh
```

Checks all 4 members (directories, ports, app response, configDropins), the controller
(Admin Center, dropins), both package files, the 26.0.0.8 runtime, and the IHS front-end.
**Expected result:** All checks `PASS`.

Direct member verification:
```bash
curl http://localhost:9081/server-info/   # member1 (26.0.0.8)
curl http://localhost:9082/server-info/   # member2 (26.0.0.8)
curl http://localhost:9083/server-info/   # member3 (25.0.0.1)
curl http://localhost:9084/server-info/   # member4 (25.0.0.1)
curl http://localhost:8080/server-info/   # IHS → dynamic routing
```

---

### Reset and Redeploy

`reset-environment.sh` performs a **complete wipe** — stops all servers, removes all deployed
instances, removes both runtimes (`wlp-26/`, `wlp-25/`), clears both packages, and restores
IHS to its original state. After a reset the system is at a clean Step 1 baseline.

```bash
# Wipe everything
scripts/reset-environment.sh

# Rebuild Step 1 — both versions
scripts/01-install-runtime.sh
scripts/02-build-template.sh
scripts/03-build-package.sh
scripts/01-install-runtime-25.sh
scripts/02-build-template-25.sh
scripts/03-build-package-25.sh

# Redeploy Steps 2–4
scripts/install-controller.sh
scripts/add-member-26.sh member1
scripts/add-member-26.sh member2
scripts/start-apache.sh
scripts/enable-dynamic-routing.sh
apachectl graceful
scripts/add-member-25.sh member3
scripts/add-member-25.sh member4

# Validate
scripts/07-validate.sh
```

> **Note:** The `--full` flag is accepted for backwards compatibility but is a no-op —
> a reset is always a full reset.

---

### Access Points

| Endpoint | URL | Credentials |
|----------|-----|-------------|
| Admin Center | `https://localhost:9443/adminCenter` | `admin` / `admin` |
| Member1 app (direct) | `http://localhost:9081/server-info/` | — |
| Member2 app (direct) | `http://localhost:9082/server-info/` | — |
| Member3 app (direct) | `http://localhost:9083/server-info/` | — |
| Member4 app (direct) | `http://localhost:9084/server-info/` | — |
| IHS load balancer | `http://localhost:8080/server-info/` | — |
| Balancer Manager | `http://localhost:8080/balancer-manager` | localhost only |

---

## Directory Structure

Pre-provisioned on the lab VM (outside the repo):
```
/home/itzuser/software/Liberty/Liberty/
├── wlp-nd-all-26.0.0.8.jar          # Liberty ND 26.0.0.8 installer
└── wlp-base-all-25.0.0.1.jar        # Liberty Base 25.0.0.1 installer

/home/itzuser/software/IHS/
└── <ihs-installer>.zip               # IBM HTTP Server installer
```

Workspace (this repository):
```
Liberty-VM-Labs/
├── App/
│   └── server-info.war                  # Application WAR
├── wlp-26/                               # Build-phase runtime — Liberty 26.0.0.8
├── wlp-25/                              # Build-phase runtime — Liberty 25.0.0.1
├── packages/
│   ├── liberty-package-26.0.0.8.zip     # Golden artifact 26.0.0.8 (~416 MB)
│   └── liberty-package-25.0.0.1.zip     # Golden artifact 25.0.0.1 (~368 MB)
├── installs/
│   ├── controller/                      # Collective Controller (26.0.0.8)
│   ├── member1/                         # Member 1 (26.0.0.8)
│   ├── member2/                         # Member 2 (26.0.0.8)
│   ├── member3/                         # Member 3 (25.0.0.1)
│   └── member4/                         # Member 4 (25.0.0.1)
├── config/
│   ├── template/                        # Role-neutral template configs (shared)
│   │   ├── server.xml
│   │   ├── bootstrap.properties
│   │   └── jvm.options
│   ├── controller/                      # Controller configDropins overrides
│   │   ├── role-override.xml
│   │   └── ports-override.xml
│   ├── member1/                         # Member1 configDropins overrides
│   │   ├── role-override.xml
│   │   └── ports-override.xml
│   ├── member2/                         # Member2 configDropins overrides
│   │   ├── role-override.xml
│   │   └── ports-override.xml
│   ├── member3/                         # Member3 configDropins overrides (25.0.0.1)
│   │   ├── role-override.xml
│   │   └── ports-override.xml
│   ├── member4/                         # Member4 configDropins overrides (25.0.0.1)
│   │   ├── role-override.xml
│   │   └── ports-override.xml
│   └── apache/
│       ├── httpd-liberty.conf           # Static mod_proxy_balancer config
│       └── httpd-liberty-dynamic.conf   # Dynamic routing config (after enable-dynamic-routing.sh)
├── scripts/                             # All automation scripts (see below)
├── TROUBLESHOOTING.md
└── README.md
```

---

## Port Assignment

| Component | HTTP | HTTPS | Version | Role |
|-----------|------|-------|---------|------|
| controller | 9080 | 9443 | 26.0.0.8 ND | collectiveController + adminCenter-1.0 |
| member1 | 9081 | 9444 | 26.0.0.8 ND | collectiveMember |
| member2 | 9082 | 9445 | 26.0.0.8 ND | collectiveMember |
| member3 | 9083 | 9446 | 25.0.0.1 Base | collectiveMember |
| member4 | 9084 | 9447 | 25.0.0.1 Base | collectiveMember |
| IHS | 8080 | — | — | mod_proxy_balancer front-end |

---

## Scripts Reference

All scripts use `#!/bin/bash` and source `scripts/00-set-env.sh` for shared
environment variables (`JAVA_HOME`, `WLP_HOME`, `WORKSPACE_ROOT`).

---

### `scripts/00-set-env.sh`

**Purpose:** Shared environment bootstrap — sourced by every other script.

Sets:
- `WORKSPACE_ROOT` — absolute path to the cloned repository (`/home/itzuser/Liberty-VM-Labs`); update this if cloned elsewhere
- `JAVA_HOME` — resolved in order: existing `$JAVA_HOME` env var → SDKMAN `current` candidate → system `java` on PATH
- `PATH` — prepends `$JAVA_HOME/bin`
- `WLP_HOME` — path to the build-phase Liberty 26.0.0.8 runtime (`$WORKSPACE_ROOT/wlp-26`)

**Usage:**
```bash
source scripts/00-set-env.sh   # from another script
scripts/00-set-env.sh          # run directly to print current values
```

---

### `scripts/01-install-runtime.sh`

**Purpose:** Extracts the Liberty ND 26.0.0.8 runtime from the self-extracting JAR into `wlp-26/`.

This is a **one-time build step**. The resulting `wlp-26/` directory is the build-phase
runtime used to create and package the template server. Each deployed instance carries
its own copy of the runtime inside the package ZIP.

**Usage:**
```bash
scripts/01-install-runtime.sh
```

**Output:** `wlp-26/` at workspace root with `wlp-26/bin/server` executable.

---

### `scripts/02-build-template.sh`

**Purpose:** Creates the generic `template-26.0.0.8` server inside the build-phase runtime.

The template is role-neutral — no collective role, no hardcoded ports.
All ports are variable-based (`${default.http.port}`) resolved from `bootstrap.properties`.
`server-info.war` is pre-staged in `apps/`.

**Usage:**
```bash
scripts/02-build-template.sh
```

**Output:** `wlp-26/usr/servers/template-26.0.0.8/` with `server.xml`, `bootstrap.properties`,
`jvm.options`, and `apps/server-info.war`.

---

### `scripts/03-build-package.sh`

**Purpose:** Packages the template server into the self-contained golden artifact ZIP.

Runs `server package --include=all` which bundles the full Liberty runtime,
server configuration, and application into a single redistributable ZIP.

**Usage:**
```bash
scripts/03-build-package.sh
```

**Output:** `packages/liberty-package-26.0.0.8.zip` (~416 MB).

> **Note:** This is a one-time build step. The package only needs to be rebuilt
> if the template configuration or application changes.

---

### `scripts/install-controller.sh`  ⭐

**Purpose:** Deploys and starts the Liberty Collective Controller from the golden package.

Steps performed:
1. Unpacks `liberty-package-26.0.0.8.zip` into `installs/controller/`
2. Renames server from `template-26.0.0.8` → `controller`
3. Drops `role-override.xml` (adds `collectiveController`, `adminCenter-1.0`) and `ports-override.xml` (HTTP 9080 / HTTPS 9443) into `configDropins/overrides/`
4. Writes `bootstrap.properties` with ports and passwords
5. Runs `collective create` to initialise the collective PKI (keystores and certificates)
6. Starts the controller and waits for it to be ready
7. Verifies Admin Center is accessible

**Usage:**
```bash
scripts/install-controller.sh
```

**Prerequisite:** `packages/liberty-package-26.0.0.8.zip` must exist (run steps 01–03 first).

---

### `scripts/add-member-26.sh`  ⭐

**Purpose:** Deploys a Liberty 26.0.0.8 Collective Member and joins it to the running controller.

Accepts the member name as a parameter. Ports are automatically assigned based
on the numeric suffix of the member name (member1 → 9081/9444, member2 → 9082/9445, etc.).
If no `config/<member-name>/` override files exist, generic ones are generated automatically.

Steps performed:
1. Validates the controller is running
2. Unpacks `liberty-package-26.0.0.8.zip` into `installs/<member-name>/`
3. Renames server from `template-26.0.0.8` → `<member-name>`
4. Drops role and port override files into `configDropins/overrides/`
5. Writes `bootstrap.properties`
6. Runs `collective join` to register the member with the controller
7. Starts the member and verifies the app is reachable

**Usage:**
```bash
scripts/add-member-26.sh member1
scripts/add-member-26.sh member2
```

**Prerequisite:** `packages/liberty-package-26.0.0.8.zip` must exist and controller must be running.

> **Note:** `scripts/add-member.sh` still exists as a compatibility wrapper that delegates
> to `add-member-26.sh`.

---

### `scripts/start-apache.sh`  ⭐

**Purpose:** Configures IBM HTTP Server (IHS) as the Liberty Collective front-end and starts it.

Idempotent — safe to run multiple times. Will not add duplicate includes or re-enable
already-enabled modules.

Steps performed:
1. Locates `/opt/IBM/HTTPServer/conf/httpd.conf`
2. Uncomments required `LoadModule` lines: `mod_proxy`, `mod_proxy_http`, `mod_proxy_balancer`, `mod_slotmem_shm`, `mod_lbmethod_byrequests`
3. Appends `Include` for `config/apache/httpd-liberty.conf`
4. Runs `apachectl configtest`
5. **Checks whether IHS is already listening on port 8080:**
   - Already running → issues `apachectl graceful` to reload the updated config
   - Not running → issues `apachectl start`
6. Verifies all member and IHS endpoints respond

**Usage:**
```bash
scripts/start-apache.sh
```

> **Note:** IHS listens on port **8080** in this lab configuration. `apachectl` must be on
> `PATH` — run `scripts/install-ihs.sh` and follow the PATH export instruction if not already done.

---

### `scripts/reset-environment.sh`  ⭐

**Purpose:** Completely resets the lab back to a clean Phase 1 baseline in a single command.

Steps performed (always — there is no partial mode):

| Step | What happens |
|------|-------------|
| 1 | Stops the controller (graceful `server stop`, 15 s pkill fallback) |
| 2 | Stops all members (same timeout + pkill fallback per member) |
| 3 | Removes `installs/` and recreates the empty directory |
| 4 | Strips the Liberty `Include` line and comment from `httpd.conf` |
| 5 | Comments out the five proxy/balancer `LoadModule` lines in `httpd.conf` |
| 6 | Reloads IHS (`apachectl graceful`) if it is running |
| 7 | Removes `wlp-26/` (extracted Liberty 26.0.0.8 runtime) |
| 8 | Removes `wlp-25/` (extracted Liberty 25.0.0.1 runtime) |
| 9 | Removes and recreates `packages/` (both golden ZIPs) |

**Usage:**
```bash
scripts/reset-environment.sh
```

> **Note:** The `--full` flag is accepted for backwards compatibility but is now
> a no-op — a reset is always a full reset.

After reset, run the full pipeline from Phase 1:
```bash
scripts/01-install-runtime.sh
scripts/02-build-template.sh
scripts/03-build-package.sh
scripts/01-install-runtime-25.sh
scripts/02-build-template-25.sh
scripts/03-build-package-25.sh
scripts/install-controller.sh
scripts/add-member-26.sh member1
scripts/add-member-26.sh member2
scripts/add-member-25.sh member3
scripts/add-member-25.sh member4
scripts/start-apache.sh
```

---

### `scripts/enable-dynamic-routing.sh`  ⭐

**Purpose:** Enables Liberty Dynamic Routing on the Collective Controller.

Liberty Dynamic Routing (`dynamicRouting-1.0`) allows the collective controller to
automatically manage request routing across registered members based on live health
and collective membership — without manually updating IHS config when members
are added or removed.

Steps performed:
1. Validates controller and at least one member are running
2. Adds `dynamic-routing.xml` dropin to controller's `configDropins/overrides/`
   (enables `dynamicRouting-1.0` feature)
3. Restarts the controller to load the new feature
4. Attempts to retrieve `plugin-cfg.xml` from the controller's routing API;
   generates a static version if the API is not yet available
5. Generates `config/apache/httpd-liberty-dynamic.conf` — an IHS config that
   routes through the controller instead of directly to members
6. Verifies the controller dynamic routing endpoint

**Usage:**
```bash
scripts/enable-dynamic-routing.sh
```

After running, switch IHS from static to dynamic routing by updating `httpd.conf`:
```
# Change this:
Include /path/to/config/apache/httpd-liberty.conf
# To this:
Include /path/to/config/apache/httpd-liberty-dynamic.conf
```
Then: `apachectl graceful`

**Prerequisite:** Controller and at least one member must be running.

---

### `scripts/07-validate.sh`

**Purpose:** Runs 26 checks across the entire lab topology and prints a Lab Readiness Report.

Checks performed:
- Java 17 available
- Both Liberty runtimes installed (`wlp-26/`, `wlp-25/`)
- Both golden packages exist
- Controller: directory, port 9443, Admin Center, configDropins
- Member1 (26.0.0.8): directory, port 9081, app response, configDropins
- Member2 (26.0.0.8): directory, port 9082, app response, configDropins
- Member3 (25.0.0.1): directory, port 9083, app response, configDropins
- Member4 (25.0.0.1): directory, port 9084, app response, configDropins
- Apache/IHS front-end reachable on port 8080

Exits 0 if all checks pass, exits 1 if any fail. Each failure prints the fix command.

**Usage:**
```bash
scripts/07-validate.sh
```

---

### `scripts/01-install-runtime-25.sh`

**Purpose:** Extracts the Liberty Base 25.0.0.1 runtime from `/home/itzuser/software/Liberty/Liberty/wlp-base-all-25.0.0.1.jar`
into `wlp-25/` at workspace root. Coexists with the 26.0.0.8 `wlp/` runtime.

Verifies that `wlp-25/bin/collective` is present (Base edition requirement for collective join).

**Usage:**
```bash
scripts/01-install-runtime-25.sh
```

**Output:** `wlp-25/` with `wlp-25/bin/server` and `wlp-25/bin/collective` executable.

---

### `scripts/02-build-template-25.sh`

**Purpose:** Creates the `template-25.0.0.1` server inside `wlp-25/` using the same shared
`config/template/` source files as the 26.0.0.8 template.

**Usage:**
```bash
scripts/02-build-template-25.sh
```

**Output:** `wlp-25/usr/servers/template-25.0.0.1/` with config and `apps/server-info.war`.

---

### `scripts/03-build-package-25.sh`

**Purpose:** Packages the 25.0.0.1 template into a self-contained golden artifact ZIP.

**Usage:**
```bash
scripts/03-build-package-25.sh
```

**Output:** `packages/liberty-package-25.0.0.1.zip` (~368 MB).

---

### `scripts/add-member-25.sh`  ⭐

**Purpose:** Deploys a Liberty 25.0.0.1 member and joins it to the running 26.0.0.8 controller.

Mirrors `add-member-26.sh` exactly but unpacks `liberty-package-25.0.0.1.zip` and renames
`template-25.0.0.1` instead of `template-26.0.0.8`. The collective join protocol is
version-agnostic — mixed-version members coexist in the same collective.

**Usage:**
```bash
scripts/add-member-25.sh member3
scripts/add-member-25.sh member4
```

**Prerequisite:** `packages/liberty-package-25.0.0.1.zip` must exist and the controller must
be running.

---

### Legacy Build Scripts (04–06, 08)

These scripts were used during initial lab construction and are retained for reference.
Use the operational scripts above (`install-controller.sh`, `add-member-26.sh`, etc.) for
day-to-day use.

| Script | Purpose |
|--------|---------|
| `04-deploy-instances.sh` | Batch deploy of controller + member1 + member2 from package |
| `05-create-collective.sh` | Full collective setup (create + join + start all) |
| `06-configure-apache.sh` | Prints IHS include instructions (informational) |
| `08-enable-apache-routing.sh` | Original IHS setup script (superseded by `start-apache.sh`) |

---

## Override Mechanism

Each deployed instance is customised via two XML files dropped into
`${server.config.dir}/configDropins/overrides/` after unpacking the golden package:

| File | Purpose |
|------|---------|
| `role-override.xml` | Adds the collective role feature (`collectiveController` or `collectiveMember`) |
| `ports-override.xml` | Sets `<httpEndpoint>` with instance-specific HTTP/HTTPS ports |
| `collective-create.xml` | Generated by `collective create` — PKI config (controller only) |
| `collective-join.xml` | Generated by `collective join` — trust certificates (members only) |
| `dynamic-routing.xml` | Added by `enable-dynamic-routing.sh` — enables `dynamicRouting-1.0` |

Liberty merges all files in `configDropins/overrides/` on top of `server.xml` at startup.
Overrides take highest precedence. Features are additive — template features are retained.

---

## Troubleshooting

See [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) for detailed symptom → cause → resolution
guidance covering:

1. Member registration failures
2. Package build / deploy failures
3. Application deployment failures
4. IHS routing failures
5. SSL / keystore issues
6. Collective communication failures

**Quick diagnostics:**
```bash
# Check all server statuses
installs/controller/wlp/bin/server status controller
installs/member1/wlp/bin/server status member1
installs/member2/wlp/bin/server status member2
installs/member3/wlp/bin/server status member3
installs/member4/wlp/bin/server status member4

# Check ports
for port in 9080 9081 9082 9083 9084 9443 8080; do
  lsof -iTCP:$port -sTCP:LISTEN 2>/dev/null && echo "PORT $port IN USE" || echo "PORT $port free"
done

# Tail controller log
tail -50 installs/controller/wlp/usr/servers/controller/logs/messages.log
```

---

## Mixed-Version Collective

This workspace runs a **mixed-version Liberty collective**: the controller and member1/member2
run Liberty ND 26.0.0.8; member3 and member4 run Liberty Base 25.0.0.1. All four members
are registered with the same controller and visible in Admin Center.

Key points:
- The **collective protocol** is version-agnostic — members of different Liberty versions join the same controller without any special configuration.
- Each version has its own isolated runtime directory (`wlp-26/` vs `wlp-25/`) and golden package, so they never interfere.
- `reset-environment.sh` cleans **both** runtimes (`wlp-26/` and `wlp-25/`) and **both** packages.
- `add-member-26.sh` always uses the 26.0.0.8 package; `add-member-25.sh` always uses the 25.0.0.1 package.
- `add-member.sh` is kept as a compatibility wrapper that delegates to `add-member-26.sh`.
