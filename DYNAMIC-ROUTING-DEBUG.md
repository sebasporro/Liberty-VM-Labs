# Liberty 26 Dynamic Routing — Debug Summary

**Repo:** `github.com/sebasporro/Liberty-VM-Labs` | **Branch:** `main`  
**Environment:** IBM TechZone single-VM (`vm-1`, user `itzuser`)  
**Last updated:** Sep 8 2026

---

## Architecture (confirmed)

```
Browser -> IHS:1080 -> mod_was_ap24_http.so + libodr.so
                              |
                    POST /ibm/api/dynamicRouting  (interests body, Accept: application/json required)
                              |
                    controller:9443  (Liberty 26.0.0.8 ND)
                              |
                    Returns live member routing table
                              |
             member1:9081  member2:9082  (direct HTTP)
```

- **No ODR daemon/process.** `libodr.so` is an internal shared library loaded by `mod_was_ap24_http.so` at IHS startup.
- `dynamicRouting-1.0` on the controller serves `/ibm/api/dynamicRouting`.
- `restConnector-2.0` is needed for the one-time `dynamicRouting setup` CLI call.
- Static routing (step1, `plugin-cfg.xml` with explicit servers) confirmed working.
- Members: `member1:9081` HTTP 200, `member2:9082` HTTP 200 (direct).
- `libodr.so` v9.0.5.24 connects over HTTP/2 fine — **do not attempt to disable HTTP/2**.

---

## Environment Facts

| Item | Value |
|---|---|
| VM hostname | `vm-1`, user `itzuser` |
| Workspace | `/home/itzuser/Liberty-VM-Labs` |
| Liberty version | WebSphere Liberty ND 26.0.0.8 |
| IHS | `/home/itzuser/IBM/HTTPServer`, port 1080 |
| IHS plugin version | WAS plugin 9.0.5.24, built Apr 21 2025 |
| Controller | `installs/controller/wlp`, HTTP 9080, HTTPS 9443 |
| Plugin dir | `$IHS/config/webserver1/` |
| Keystore password | `Liberty26ctrl!` |
| Admin credentials | `admin / admin` |
| Collective hostname | `localhost` (all certs issued to localhost) |

---

## Critical Facts — Read Before Debugging

### 1. There are TWO different `plugin-cfg.xml` files on the controller

| File | What it is | Use it? |
|---|---|---|
| `installs/controller/wlp/usr/servers/controller/plugin-cfg.xml` | Controller's **static self-routing file**. Routes HTTP traffic to the controller itself (hostname `vm-1.itz-qbbnma.local`, ports 9080/9443). Has **no** `IntelligentManagement` or `ConnectorCluster` stanza. Generated at server startup by the web container. | **NO — never use this for IHS** |
| `installs/controller/wlp/usr/servers/controller/logs/state/plugin-cfg.xml` | Same static self-routing file, written to `logs/state/` at startup | **NO** |
| `WORK_DIR/plugin-cfg.xml` (after `cd WORK_DIR && dynamicRouting setup`) | The **dynamic routing plugin config**. Has `IntelligentManagement`, `ConnectorCluster` → localhost:9443, proper keystore paths. This is the correct source. | **YES — this is the right file** |

### 2. HTTP/2 is NOT the problem — but the 307 IS a problem

`libodr.so` v9.0.5.24 connects to the controller over HTTP/2 without issues. Every attempt to disable HTTP/2 (`httpOptions`, `http2Enabled` attribute) was wasted. However, the 307 is a **real, repeating issue** caused by the missing trailing slash on the `uri` property (see FIX 14), not by HTTP/2 itself. Do not try to disable HTTP/2 to fix the 307.

### 3. Two Liberty 26 fixes needed in `plugin-cfg.xml`

**Fix A — AcceptType:** Liberty 26's `DynamicRoutingRestService` rejects requests without `Accept: application/json` with `UnsupportedOperationException` (HTTP 500). The `AcceptType` property in `plugin-cfg.xml` instructs `libodr.so` to send that header:

```xml
<ConnectorCluster ...>
    <Property name="AcceptType" value="application/json"/>
    ...
</ConnectorCluster>
```

**Fix B — Trailing slash URI (FIX 14):** `dynamicRouting setup` writes `<Property name="uri" value="/ibm/api/dynamicRouting"/>` (no trailing slash). Liberty 26 returns HTTP 307 for that path. `libodr.so` does not follow redirects, so it never gets a routing table response and logs `Unable to find a transport`. The fix: use `/ibm/api/dynamicRouting/` (with trailing slash).

Both properties are absent from `dynamicRouting setup`'s output. Step2 injects both via Python regex after setup runs.

### 4. `git pull` does not overwrite locally-modified files

If the VM's script has local modifications, `git pull` reports "Already up to date" but leaves the old version in place. Use:
```bash
git fetch origin && git checkout origin/main -- scripts/step2-dynamic-routing.sh
```

---

## Bug History

| Fix | Issue | Root Cause | Resolution |
|---|---|---|---|
| FIX 1 | `unknown_ca` SSL handshake failure | `collective-create.xml` writes `clientAuthenticationSupported="true"` which merges across dropins | Strip `<ssl>` from `collective-create.xml`; `role-override.xml` owns SSL config |
| FIX 2 | `ConfigParserException` at row 37 | UTF-8 em-dash in XML comments | Replace em-dashes with ASCII hyphens in `role-override.xml` |
| FIX 3 | `port 9443 could not be reached` on `dynamicRouting setup` | SSL channel changes need full restart, not just config reload | Full restart before `dynamicRouting setup` |
| FIX 4 | ~~`libodr.so` aborts with NULL proxy; `dynamicRouting` returns HTTP 307~~ | ~~Liberty 26 defaults to HTTP/2~~ | **RETRACTED — HTTP/2 is fine. 307 was a one-time artifact. See FIX 14.** |
| FIX 5 | Duplicate `WebSpherePluginConfig` in `httpd.conf` | Python rewrite appended a second line on reruns | Deduplicate — keep first, drop all subsequent |
| FIX 6 | `dynamicRouting setup` flag errors | `--webServerName` vs `--webServerNames` mismatch | Always use `--webServerNames`; drop `--targetPath` |
| FIX 7 | Plugin `websphereFindTransport: Unable to find a transport` | `dynamicRouting setup` strips `ServerCluster/VirtualHostGroup/UriGroup/Route` | Re-inject placeholder stanzas after setup |
| FIX 8 | Wasted restarts chasing HTTP/2 | `CWWKG0018I: No functional changes` after dropin re-copy was misread as HTTP/2 not being disabled | **RETRACTED — HTTP/2 disable was never needed. See FIX 14.** |
| FIX 9 | `AcceptType` absent from installed `plugin-cfg.xml` | Python patch ran on wrong file — see FIX 12 | **Superseded by FIX 12** |
| FIX 10 | Unknown `dynamic-routing.xml` dropin may conflict | Unmanaged file from prior manual run | Read at runtime; neutralize if `<ssl>` or `<httpEndpoint>` present |
| FIX 11 | `AcceptType` injection silently failed | Wrongly used `CTRL_SERVER_DIR/plugin-cfg.xml` (controller's static self-routing file) as source — it has no `ConnectorCluster` to inject into | **Superseded by FIX 12** |
| FIX 12 | `AcceptType` injection failed: wrong source file | `CTRL_SERVER_DIR/plugin-cfg.xml` is the controller's own static web-container routing file (hostname `vm-1.itz-qbbnma.local`, no `IntelligentManagement`). `dynamicRouting setup` writes the correct dynamic file into `WORK_DIR` (because we `cd WORK_DIR` before the CLI call). The script was copying the wrong file. | Step2 now uses `WORK_DIR/plugin-cfg.xml` directly as the injection target. `dynamicRouting setup` is run first; its output in `WORK_DIR` is patched in-place. |
| FIX 13 | `git pull` left old script on VM | VM's `scripts/step2-dynamic-routing.sh` had local modifications — `git pull` never overwrites locally modified files | `git fetch origin && git checkout origin/main -- scripts/step2-dynamic-routing.sh` |
| FIX 14 | `libodr.so` still logs `Unable to find a transport` after AcceptType injected | `dynamicRouting setup` writes `<Property name="uri" value="/ibm/api/dynamicRouting"/>` — no trailing slash. Liberty 26 returns HTTP 307 Temporary Redirect for this path. `libodr.so` does not follow 307 redirects, so it never receives the routing table and falls back to the static placeholder server (which doesn't exist), causing transport failures. | Step2 patches the `uri` property to `/ibm/api/dynamicRouting/` (trailing slash) so Liberty serves the request directly with 200. |

---

## Current Status (as of Sep 8 — awaiting next run)

| Check | Status | Notes |
|---|---|---|
| member1:9081 direct | OK 200 | |
| member2:9082 direct | OK 200 | |
| Controller admin center | OK 302 | |
| Controller SSL (no client cert) | OK | FIX 1 |
| `/ibm/api/dynamicRouting` no Accept | 500 | Expected — Liberty 26 rejects missing Accept header |
| `/ibm/api/dynamicRouting/` Accept:json | **TBD** | Pending step2 run with FIX 12 + FIX 14 |
| `AcceptType` in installed plugin-cfg.xml | **TBD** | [5/5] will confirm |
| `uri` property trailing slash | **TBD** | [3/4] will print uri line for confirmation |
| `dynamic-routing.xml` dropin | Benign | Auto-neutralised if conflicting |
| IHS routing via plugin | **PENDING** | Run step2 after force-sync |

---

## Key Config Files (live on VM)

| File | Purpose | Key settings |
|---|---|---|
| `configDropins/overrides/role-override.xml` | Features + security | `dynamicRouting-1.0`, `restConnector-2.0`, `administrator-role`, `clientAuthentication="false"` |
| `configDropins/overrides/collective-create.xml` | Collective PKI | Keystores, `defaultHostName=localhost`. SSL element **STRIPPED** by step2. |
| `configDropins/overrides/ports-override.xml` | HTTP/HTTPS ports only | HTTP 9080, HTTPS 9443. No HTTP/2 settings — not needed. |
| `configDropins/overrides/dynamic-routing.xml` | Unmanaged dropin | Present Sep 7 15:42. Step2 neutralises it if it contains `<ssl>` or `<httpEndpoint>`. |
| `config/webserver1/plugin-cfg.xml` | WAS plugin dynamic config | `IntelligentManagement` + `ConnectorCluster` → localhost:9443, `AcceptType=application/json`, `uri=/ibm/api/dynamicRouting/` |

---

## Recovery Procedure for Existing VM

```bash
cd ~/Liberty-VM-Labs

# Force-sync scripts in case of local modifications
git fetch origin
git checkout origin/main -- scripts/step2-dynamic-routing.sh

# Run step 2
bash scripts/step2-dynamic-routing.sh
```

If `dynamicRouting setup` fails with "port 9443 could not be reached", restart the controller first:
```bash
installs/controller/wlp/bin/server stop controller
installs/controller/wlp/bin/server start controller
# wait ~10s then retry
bash scripts/step2-dynamic-routing.sh
```

---

## Scripts Reference

| Script | Purpose |
|---|---|
| `scripts/step1-was-plugin.sh` | Static WAS plugin routing (round-robin). Run first. Confirmed working. |
| `scripts/step2-dynamic-routing.sh` | Dynamic routing setup. Patches `collective-create.xml`, syncs overrides, runs `dynamicRouting setup`, injects `AcceptType` + trailing-slash `uri` into `WORK_DIR/plugin-cfg.xml`, converts keystore, installs files, restarts IHS. |
| `scripts/collect-debug.sh` | Collects all diagnostic info to `/tmp/liberty-debug-*.txt`. §12 captures full headers + Location on 307. §16 reports `AcceptType` YES/NO verdict. §33 reports ODR IPC socket state. |
| `scripts/install-controller.sh` | Full controller install. Strips both `quickStartSecurity` and `clientAuthenticationSupported ssl` from `collective-create.xml`. |
| `scripts/apply-routing-rules.sh` | Pin URIs to specific members (dynamic routing rules). Run after step2 succeeds. |
