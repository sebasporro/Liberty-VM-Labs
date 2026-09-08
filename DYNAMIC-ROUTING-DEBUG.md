# Liberty 26 Dynamic Routing — Debug Summary

**Repo:** `github.com/sebasporro/Liberty-VM-Labs` | **Branch:** `main`  
**Environment:** IBM TechZone single-VM (`vm-1`, user `itzuser`)  
**Last updated:** Sep 8 2026

---

## Architecture (confirmed)

```
Browser -> IHS:8080 -> mod_was_ap24_http.so + libodr.so
                              |
                    POST /ibm/api/dynamicRouting  (HTTP/1.1, interests body)
                              |
                    controller:9443  (Liberty 26.0.0.8 ND)
                              |
                    Returns live member routing table
                              |
             member1:9081  member2:9082  (direct HTTP)
```

- **No ODR daemon/process.** `libodr.so` is an internal shared library loaded by `mod_was_ap24_http.so` at IHS startup.
- `dynamicRouting-1.0` on the controller serves `/ibm/api/dynamicRouting`.
- `restConnector-2.0` is needed only for the one-time `dynamicRouting setup` CLI call.
- Static routing (step1, `plugin-cfg.xml` with explicit servers) confirmed working.
- Members: `member1:9081` HTTP 200, `member2:9082` HTTP 200 (direct).

---

## Environment Facts

| Item | Value |
|---|---|
| VM hostname | `vm-1`, user `itzuser` |
| Workspace | `/home/itzuser/Liberty-VM-Labs` |
| Liberty version | WebSphere Liberty ND 26.0.0.8 |
| IHS | `/home/itzuser/IBM/HTTPServer`, port 8080 |
| IHS plugin version | WAS plugin 9.0.5.24, built Apr 21 2025 |
| Controller | `installs/controller/wlp`, HTTP 9080, HTTPS 9443 |
| Plugin dir | `$IHS/config/webserver1/` |
| Keystore password | `Liberty26ctrl!` |
| Admin credentials | `admin / admin` |
| Collective hostname | `localhost` (all certs issued to localhost) |

---

## Bugs Found and Fixed

### FIX 1 — `clientAuthenticationSupported="true"` in `collective-create.xml`

**Symptom:** `CWWKO0801E: SSLHandshakeException: (unknown_ca) Received fatal alert: unknown_ca`

**Cause:** `collective create` writes `<ssl id="defaultSSLConfig" clientAuthenticationSupported="true"/>` into `collective-create.xml`. Liberty **merges** same-id SSL elements across all config dropins. So even though `role-override.xml` sets `clientAuthentication="false"`, the merged result still demands a TLS client cert from the WAS plugin — which the plugin does not present.

**Fix:** Strip the `<ssl>` element from `collective-create.xml` via Python regex after `collective create` runs. `role-override.xml` owns the SSL config.

**Files:** `scripts/install-controller.sh`, `scripts/step2-dynamic-routing.sh` (live patch)

---

### FIX 2 — Em-dash characters in XML comments caused `ConfigParserException`

**Symptom:** `com.ibm.websphere.config.ConfigParserException: ParseError at [row,col]:[37,51]`

**Cause:** UTF-8 em-dash (`—`) characters in XML comments in `role-override.xml` caused Liberty's XML parser to fail on the live dropin copy.

**Fix:** Replaced all em-dashes with plain ASCII in `config/controller/role-override.xml`.

---

### FIX 3 — `dynamicRouting setup` ran before controller SSL reload completed

**Symptom:** `The specified port 9443 could not be reached for collective`

**Cause:** 15s sleep after copying `role-override.xml` was insufficient. Liberty's SSL channel takes longer to reinitialize after removing `clientAuthenticationSupported`.

**Fix:** SSL channel changes require a **full controller restart**. Step2 patches the dropin; caller must restart the controller before re-running.

---

### FIX 4 — HTTP/2 on controller HTTPS endpoint caused 307 from `libodr.so`

**Symptom:**
```
curl -k -u admin:admin -H "Accept: application/json" https://localhost:9443/ibm/api/dynamicRouting
→ HTTP 307  reason: Require a new 'interests' POST  (no Location header)

Plugin log: odrLibAbort: odrHttpContextRelease: called with NULL proxy
```

**Cause:** Liberty 26 defaults to HTTP/2 on HTTPS endpoints. The WAS plugin's `libodr.so` (v9.0.5.24) uses HTTP/1.1 for its interests POST. Liberty returns 307 signaling a protocol requirement that `libodr.so` doesn't follow, causing it to abort with NULL proxy.

**Fix:** Added `<httpOptions http2Enabled="false"/>` inside `<httpEndpoint>` in `config/controller/ports-override.xml`.

**Note:** Requires a controller **restart** to take effect.

---

### FIX 5 — Duplicate `WebSpherePluginConfig` in `httpd.conf`

**Symptom:** Two identical `WebSpherePluginConfig` lines after re-running step2.

**Cause:** Python rewrite appended a new line when replacement logic failed to match duplicates from prior runs.

**Fix:** Rewrote the Python block to deduplicate — keeps first occurrence, drops all subsequent.

---

### FIX 6 — `dynamicRouting setup` flag compatibility

Removed runtime probe for `--webServerName` vs `--webServerNames`. Liberty 26 always uses `--webServerNames`. Removed `--targetPath`; replaced with `cd WORK_DIR` before CLI call (matches reference lab behavior).

---

### FIX 7 — `ServerCluster` stanzas stripped by `dynamicRouting setup`

Liberty 26's `dynamicRouting setup` strips `ServerCluster`, `VirtualHostGroup`, `UriGroup`, and `Route` from the output `plugin-cfg.xml`. The WAS plugin parser requires these stanzas even in dynamic mode. Step2 injects a placeholder `ServerCluster` named `defaultCollective` (matching the `IntelligentManagement` stanza) before installing the file.

---

## Current Status (as of last run)

| Check | Status | Notes |
|---|---|---|
| member1:9081 direct | OK 200 | |
| member2:9082 direct | OK 200 | |
| Controller admin center | OK 302 | Redirects to login |
| Controller SSL (no client cert) | OK | Fixed by FIX 1 |
| `/ibm/api/dynamicRouting` no Accept | 500 | Liberty 26 bug — throws instead of 406. Expected from curl; plugin sends correct headers. |
| `/ibm/api/dynamicRouting` Accept:json | 307 | Was HTTP/2 protocol mismatch. Fixed by FIX 4. **Needs verification after restart.** |
| libodr.so initialized | Aborting | NULL proxy after 307. Should resolve once HTTP/2 disabled (FIX 4). |
| IHS routing via plugin | **PENDING** | Waiting for verification after HTTP/2 fix |

---

## Key Config Files (live on VM)

| File | Purpose | Key settings |
|---|---|---|
| `configDropins/overrides/role-override.xml` | Features + security | `dynamicRouting-1.0`, `restConnector-2.0`, `administrator-role`, `clientAuthentication="false"` |
| `configDropins/overrides/collective-create.xml` | Collective PKI | Keystores, `defaultHostName=localhost`. SSL element **STRIPPED** by step2. |
| `configDropins/overrides/ports-override.xml` | HTTP/HTTPS ports + HTTP/2 | HTTP 9080, HTTPS 9443, `http2Enabled="false"` |
| `configDropins/overrides/dynamic-routing.xml` | **Unknown dropin (on VM only)** | Present Sep 7 15:42 — **NOT in repo**. Contents unknown. **May conflict.** |
| `config/webserver1/plugin-cfg.xml` | WAS plugin config | `IntelligentManagement` with `ConnectorCluster` → localhost:9443, `Keyfile/Stashfile` at `config/webserver1/` |

---

## OPEN ISSUE — Unknown `dynamic-routing.xml` dropin

The controller's `configDropins/overrides/` contains a `dynamic-routing.xml` file (dated Sep 7 15:42) that is **not in the repo**. Its contents have never been captured. It may contain a conflicting SSL or feature declaration.

**First thing to do in the next session:**
```bash
cat ~/Liberty-VM-Labs/installs/controller/wlp/usr/servers/controller/configDropins/overrides/dynamic-routing.xml
```

---

## Recovery Procedure for Existing VM

```bash
cd ~/Liberty-VM-Labs && git pull origin main

# Stop controller, apply fixed overrides, restart
~/Liberty-VM-Labs/installs/controller/wlp/bin/server stop controller
cp config/controller/ports-override.xml \
   installs/controller/wlp/usr/servers/controller/configDropins/overrides/ports-override.xml
~/Liberty-VM-Labs/installs/controller/wlp/bin/server start controller

# Wait for ready
until curl -k -s -o /dev/null -w "%{http_code}" \
  https://localhost:9443/adminCenter 2>/dev/null | grep -q "200\|302"; do
  sleep 2; printf "."; done; echo " Ready"

# Run step 2 (patches collective-create.xml, sets up plugin)
bash scripts/step2-dynamic-routing.sh
```

---

## Scripts Reference

| Script | Purpose |
|---|---|
| `scripts/step1-was-plugin.sh` | Static WAS plugin routing (round-robin). Run first. Confirmed working. |
| `scripts/step2-dynamic-routing.sh` | Dynamic routing setup. Patches `collective-create.xml`, copies overrides, runs `dynamicRouting setup`, converts keystore, installs files, restarts IHS. Inline diagnostics at `[5/5]`. |
| `scripts/collect-debug.sh` | Collects all diagnostic info to `/tmp/liberty-debug-*.txt`. Run when step2 fails. |
| `scripts/check-dynamic-routing.sh` | 7-point quick check: members, httpd.conf, plugin-cfg.xml, keystores, controller endpoint, IHS routing, plugin log. |
| `scripts/install-controller.sh` | Full controller install. Strips both `quickStartSecurity` and `clientAuthenticationSupported ssl` from `collective-create.xml`. |
| `scripts/apply-routing-rules.sh` | Pin URIs to specific members (dynamic routing rules). Run after step2 succeeds. |
