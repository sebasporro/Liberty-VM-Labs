# Liberty Collective Lab — Troubleshooting Guide

> **Workspace root:** `/Users/sebastianporro/Documents/2026/ITZ/Liberty-VM-Labs`
> **Liberty version:** 26.0.0.8 ND  |  **Java:** 17 (IBM Semeru via SDKMAN)

---

## Quick Diagnostics

Run these 5 commands first whenever anything is broken:

```zsh
# 1. Check all server statuses
installs/controller/wlp/bin/server status controller
installs/member1/wlp/bin/server status member1
installs/member2/wlp/bin/server status member2

# 2. Check ports in use
for port in 9080 9081 9082 9443 9444 9445; do
  lsof -iTCP:$port -sTCP:LISTEN 2>/dev/null && echo "PORT $port IN USE" || echo "PORT $port free"
done

# 3. Tail controller messages.log (last 50 lines)
tail -50 installs/controller/wlp/usr/servers/controller/logs/messages.log

# 4. Confirm Java 17 is active
java -version 2>&1
echo "JAVA_HOME=${JAVA_HOME}"

# 5. List configDropins/overrides for all instances
for name in controller member1 member2; do
  echo "--- ${name} ---"
  ls installs/${name}/wlp/usr/servers/${name}/configDropins/overrides/ 2>/dev/null || echo "(empty or missing)"
done
```

---

## 1. Member Registration Failures

### `CollectiveRegistration MBean not found`

**Symptom:** `collective join` fails with `CWWKX8000E: CollectiveRegistration MBean was not found`.

**Cause:** The controller was started without first running `collective create`. The Collective Controller requires PKI initialization (`collective create`) before its MBean is registered.

**Resolution:**
```zsh
# Stop the controller if running
installs/controller/wlp/bin/server stop controller

# Initialize the collective (generates keystore/truststore in the server dir)
installs/controller/wlp/bin/collective create controller \
  --keystorePassword=Liberty26ctrl! \
  --createConfigFile=installs/controller/wlp/usr/servers/controller/configDropins/overrides/collective-create.xml

# Restart the controller
installs/controller/wlp/bin/server start controller
```

---

### `CWPKI0824E SSL handshake failure` during `collective join`

**Symptom:** `collective join` fails with `CWPKI0824E: SSL handshake error` or `Certificate CN does not match`.

**Cause:** `collective create` was run without `--hostName=localhost`, so the collective certificate was issued to the machine's LAN IP instead of `localhost`. The `install-controller.sh` script always passes `--hostName=localhost` to prevent this.

**Resolution:** Reset and reinstall the controller so the cert is reissued to `localhost`:
```zsh
scripts/reset-environment.sh
scripts/install-controller.sh
scripts/add-member.sh member1
scripts/add-member.sh member2
```

If you must join without reinstalling, pass `--disableHostnameVerification` to `collective join` and leave `controllerHost=localhost` in the generated `collective-join.xml`.

---

### Controller not running when `collective join` is called

**Symptom:** `collective join` fails with connection refused or timeout.

**Cause:** The controller process is not started, or is still starting up.

**Resolution:**
```zsh
# Check controller status
installs/controller/wlp/bin/server status controller

# If not running, start it
installs/controller/wlp/bin/server start controller

# Wait for "server is ready" in the log
grep -m1 "server is ready" <(tail -f installs/controller/wlp/usr/servers/controller/logs/messages.log)
```

---

### Wrong `--port` in `collective join`

**Symptom:** `collective join` connects but authentication fails or MBean not found.

**Cause:** `--port` must be the **controller's** HTTPS port (9443), not the member's HTTPS port.

**Resolution:** Always use `--port=9443` (controller HTTPS) regardless of which member you are joining.

---

## 2. Package Build / Deploy Failures

### Java not found or wrong version

**Symptom:** `java -jar Resources/wlp-nd-all-26.0.0.8.jar` fails with `command not found` or wrong version error.

**Cause:** JAVA_HOME not set, or default Java is not version 17.

**Resolution:**
```zsh
# Using SDKMAN (this lab)
source ~/.sdkman/bin/sdkman-init.sh
sdk use java 17.0.15-sem

# Or using macOS java_home
export JAVA_HOME=$(/usr/libexec/java_home -v 17)
export PATH=$JAVA_HOME/bin:$PATH

# Verify
java -version  # must show 17.x.x
```

---

### `server package` fails — features not resolved

**Symptom:** `server package` exits with error about unresolved features or missing files.

**Cause:** The template server has never been started, so Liberty has not downloaded/resolved all feature bundles. The `--include=all` packaging requires the feature cache to be populated.

**Resolution:**
```zsh
# Start the template server once to resolve features
installs/template-26.0.0.8/wlp/bin/server start template-26.0.0.8
# Wait for it to start, then stop it
installs/template-26.0.0.8/wlp/bin/server stop template-26.0.0.8
# Now re-run the package command
scripts/03-build-package.sh
```

---

### Existing install not cleaned before re-deploy

**Symptom:** Server rename fails or old config leaks into new instance.

**Cause:** `installs/<name>/` contains leftover files from a previous deploy.

**Resolution:** Always clean before re-deploying:
```zsh
for name in controller member1 member2; do
  rm -rf installs/${name}/*
done
scripts/04-deploy-instances.sh
```

---

## 3. Application Deployment Failures

### `server-info.war` not found (404 on all paths)

**Symptom:** All HTTP requests return 404; messages.log shows `CWWKZ0013E: It is not possible to start two applications with the same name`.

**Cause:** The WAR file was not copied into the `apps/` directory before packaging.

**Resolution:**
```zsh
# Check the WAR is in the template before packaging
ls wlp/usr/servers/template-26.0.0.8/apps/server-info.war

# If missing, copy it and re-run the package step
cp App/server-info.war wlp/usr/servers/template-26.0.0.8/apps/
scripts/03-build-package.sh
scripts/04-deploy-instances.sh
```

---

### JSP pages return 403 / `SRVE0269W`

**Symptom:** Application loads but JSP pages return HTTP 403; `messages.log` contains `SRVE0269W`.

**Cause:** The `pages-3.1` feature (JSP/Faces renderer) is not loaded. Liberty 26.x separates servlet handling from JSP/Pages rendering.

**Resolution:** Add `pages-3.1` to the member `role-override.xml`:
```xml
<featureManager>
    <feature>collectiveMember-1.0</feature>
    <feature>pages-3.1</feature>
</featureManager>
```
Then restart the member:
```zsh
installs/member1/wlp/bin/server stop member1
cp config/member1/role-override.xml \
  installs/member1/wlp/usr/servers/member1/configDropins/overrides/role-override.xml
installs/member1/wlp/bin/server start member1
```

---

### Wrong application context root

**Symptom:** `http://localhost:9081/ServerInfo` returns 404 but the server is running.

**Cause:** The WAR's context root is `/server-info` (derived from the WAR filename `server-info.war`), not `/ServerInfo`.

**Resolution:** Use the correct URL:
```
http://localhost:9081/server-info/
```

---

### Feature version mismatch

**Symptom:** `CWWKF0001E: A feature named servlet-5.0 could not be found`.

**Cause:** Wrong servlet feature version for Liberty 26.x.

**Resolution:** Use `servlet-6.0` in `server.xml`:
```xml
<feature>servlet-6.0</feature>
```

---

## 4. Apache Routing Failures

### Required module not loaded

**Symptom:** Apache fails to start with `Invalid command 'ProxyPass'`.

**Cause:** `mod_proxy` and related modules are not enabled in `httpd.conf`.

**Resolution:** Uncomment or add these `LoadModule` lines in `httpd.conf`:
```apache
LoadModule proxy_module           libexec/apache2/mod_proxy.so
LoadModule proxy_balancer_module  libexec/apache2/mod_proxy_balancer.so
LoadModule proxy_http_module      libexec/apache2/mod_proxy_http.so
LoadModule lbmethod_byrequests_module libexec/apache2/mod_lbmethod_byrequests.so
LoadModule slotmem_shm_module     libexec/apache2/mod_slotmem_shm.so
```
For Homebrew Apache, module paths use `/opt/homebrew/lib/httpd/modules/` (Apple Silicon) or `/usr/local/lib/httpd/modules/` (Intel).

---

### Port mismatch in `httpd-liberty.conf`

**Symptom:** Apache routes to the wrong server or returns 503.

**Cause:** `BalancerMember` ports in `config/apache/httpd-liberty.conf` don't match the actual member ports.

**Resolution:** Verify the ports:
```zsh
grep "BalancerMember" config/apache/httpd-liberty.conf
# Should show: 9081 (member1) and 9082 (member2)
# Must match bootstrap.properties default.http.port values
```

---

### Apache config syntax error

**Symptom:** Apache won't reload; error in output.

**Resolution:**
```zsh
apachectl configtest   # diagnose
sudo apachectl graceful  # reload after fix
```

---

## 5. SSL / Keystore Issues

### `CWPKI0823E` — keystore file not found

**Symptom:** Controller fails to start with `CWPKI0823E: The keystore ... could not be found`.

**Cause:** `collective create` was not run before `server start`. The collective keystores are generated by `collective create` and written to `resources/security/`.

**Resolution:**
```zsh
installs/controller/wlp/bin/collective create controller \
  --keystorePassword=Liberty26ctrl! \
  --createConfigFile=installs/controller/wlp/usr/servers/controller/configDropins/overrides/collective-create.xml
```

---

### Keystore password mismatch

**Symptom:** `CWPKI0033E: The keystore ... could not be loaded. The password may be incorrect`.

**Cause:** The password in `bootstrap.properties` (`keystore.password`) does not match the password used when the keystore was created.

**Resolution:** Ensure consistency across:
- `installs/controller/wlp/usr/servers/controller/bootstrap.properties` → `keystore.password=Liberty26ctrl!`
- `config/controller/ports-override.xml` → `<keyStore password="${keystore.password}"/>`
- The `--keystorePassword` used in `collective create`

---

### `curl` SSL certificate errors in the lab

**Symptom:** `curl` returns `SSL certificate problem: self-signed certificate`.

**Cause:** Liberty generates a self-signed certificate by default. This is expected in a lab environment.

**Resolution:** Use `-k` flag with curl in lab environments:
```zsh
curl -k https://localhost:9443/adminCenter
```
Do not use `-k` in production.

---

## 6. Collective Communication Failures

### Members show CWWKX errors after `collective join`

**Symptom:** Members start but remain in STOPPED state in Admin Center; `messages.log` shows `CWWKX` errors or SSL handshake failures.

**Cause:** The collective certificate was not issued to `localhost`. This occurs when `collective create` was run without `--hostName=localhost`.

**Resolution:** The scripts in this lab always pass `--hostName=localhost` to `collective create`. If you see this error, reset and reinstall:
```zsh
scripts/reset-environment.sh
scripts/install-controller.sh
scripts/add-member.sh member1
scripts/add-member.sh member2
```

---

### Member shows STOPPED in Admin Center

**Symptom:** Admin Center shows member1 or member2 as STOPPED even though the process is running.

**Cause:** The member cannot reach the controller's collective endpoint, or the `collectiveMember` feature is not loaded.

**Resolution:**
```zsh
# Check member log for CWWKX errors
grep "CWWKX\|collective\|error" \
  installs/member1/wlp/usr/servers/member1/logs/messages.log | tail -20

# Verify collectiveMember feature is loaded
grep -i "collectiveMember" \
  installs/member1/wlp/usr/servers/member1/configDropins/overrides/role-override.xml
```

---

### Member started before `collective join` completed

**Symptom:** Member is running but not registered in the collective.

**Resolution:**
```zsh
installs/member1/wlp/bin/server stop member1

# Re-run collective join
installs/member1/wlp/bin/collective join member1 \
  --host=localhost --port=9443 \
  --user=admin --password=admin \
  --keystorePassword=Liberty26mbr1! \
  --serverHost=localhost --serverHttpsPort=9444 \
  --createConfigFile=installs/member1/wlp/usr/servers/member1/configDropins/overrides/collective-join.xml \
  --autoAcceptCertificates --disableHostnameVerification

installs/member1/wlp/bin/server start member1
```

---

### macOS firewall blocking localhost ports

**Symptom:** Connections to 9443 / 9081 / 9082 time out even though servers are running.

**Resolution:** Check System Settings → Network → Firewall → Options, and ensure Java is not blocked. Alternatively, temporarily disable the firewall for testing:
```zsh
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off
# Re-enable after testing:
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
```

---

## Log File Reference

| Server | messages.log | console.log |
|--------|-------------|-------------|
| controller | `installs/controller/wlp/usr/servers/controller/logs/messages.log` | `installs/controller/wlp/usr/servers/controller/logs/console.log` |
| member1 | `installs/member1/wlp/usr/servers/member1/logs/messages.log` | `installs/member1/wlp/usr/servers/member1/logs/console.log` |
| member2 | `installs/member2/wlp/usr/servers/member2/logs/messages.log` | `installs/member2/wlp/usr/servers/member2/logs/console.log` |

**Useful log grep patterns:**
```zsh
# Find errors
grep "ERROR\|CWWKE\|CWPKI\|CWWKX" installs/controller/wlp/usr/servers/controller/logs/messages.log

# Find server ready message
grep "server is ready" installs/controller/wlp/usr/servers/controller/logs/messages.log

# Watch logs live
tail -f installs/member1/wlp/usr/servers/member1/logs/messages.log
```
