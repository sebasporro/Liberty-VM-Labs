# Liberty Collective Dynamic Routing — Lab Guide

## Overview

This document captures the design, behavior, diagnostic approach, and real-world use cases
for the `routing.sh` script and the Liberty Collective dynamic routing (Intelligent Management)
capability. It is the reference for anyone presenting or extending this lab.

---

## Architecture

```
Browser / curl
      │
      │  HTTP :1080
      ▼
IBM HTTP Server (IHS)
  mod_was_ap24_http.so
  plugin-cfg.xml  ←── ConnectorCluster → localhost:9443
      │
      │  ODR polls controller every RefreshInterval seconds
      │  fetches live routing topology + active routing rules
      │
      ▼
Liberty Collective Controller  :9443
  dynamicRouting-1.0
  configDropins/overrides/routing-rules.xml  ←── written by routing.sh
      │
      ├──► member1 :9081
      ├──► member2 :9082
      ├──► member3 :9083
      └──► member4 :9084
```

The WAS plugin operates in **Intelligent Management (ODR) mode** — it does not contain a
static list of member servers. Instead it contacts the controller's `/ibm/api/dynamicRouting`
REST endpoint on every `RefreshInterval` and receives the live routing table. Routing rules
written into `configDropins/overrides/routing-rules.xml` are picked up by Liberty instantly
(hot config dropin), then propagated to the plugin on the next poll cycle.

---

## routing.sh Reference

**Location:** `scripts/routing.sh`

### Subcommands

| Command | Effect |
|---|---|
| `routing.sh list` | Lists collective members, port state, and HTTP app status. Reports current routing mode (pinned or round-robin). |
| `routing.sh pin <member>` | Writes a `routing-rules.xml` dropin that sends all `/server-info/*` traffic to the named member. Restarts IHS gracefully. |
| `routing.sh roundrobin` | Removes `routing-rules.xml`, restoring Liberty's default round-robin. Restarts IHS gracefully. |

### Key paths the script touches

| Path | Purpose |
|---|---|
| `installs/controller/wlp/usr/servers/controller/configDropins/overrides/routing-rules.xml` | Live routing rule dropin — written by `pin`, removed by `roundrobin` |
| `installs/controller/wlp/bin/collective` | Liberty collective CLI — used by `list` to query members |
| `$IHS_ROOT/bin/apachectl` | IHS control binary — called for graceful restart after every routing change |

---

## How the routing rule is enforced — layer by layer

```
Incoming request
      │
      ▼
IHS / WAS Plugin
      │
      ├─ Does request carry a JSESSIONID cookie?
      │     YES → route to the member that owns this session (session affinity)
      │     NO  → consult ODR routing topology
      │
      ▼
ODR (Intelligent Management)
      │
      ├─ Is there a matching <routingRule> in routing-rules.xml?
      │     YES → enforce the rule (e.g. pin to member2)
      │     NO  → apply ConnectorCluster load balance policy (RoundRobin)
      │
      ▼
Target member
```

**Critical:** session affinity is evaluated **before** dynamic routing rules. A browser with
an existing `JSESSIONID` will always return to the member that issued it, regardless of any
pin rule. Use `curl -c /dev/null` (discard cookies) as the authoritative test for routing
behavior. Never use a browser with an active session to validate routing changes.

---

## RefreshInterval — the propagation delay

The `plugin-cfg.xml` `RefreshInterval` attribute controls how often the WAS plugin polls the
controller for routing updates. **Current lab value: `10` seconds.**

```xml
<Config ... RefreshInterval="10" ...>
```

After any routing change (`pin` or `roundrobin`):

1. Liberty picks up the new `routing-rules.xml` dropin **instantly** (hot config watcher).
2. The WAS plugin continues using the old routing topology until its next poll.
3. After up to `RefreshInterval` seconds the plugin fetches the updated rules and enforces them.

**Always wait up to 10 seconds after a routing change and confirm with curl before testing
in a browser.**

```bash
# Authoritative routing test — cookies discarded, no session affinity
curl -s -c /dev/null http://localhost:1080/server-info/api/health \
  | python3 -c 'import json,sys; s=json.load(sys.stdin)["server"]; print(s["port"], s["serverSoftware"])'
```

---

## Real-world use cases for routing rules

### 1. Canary / staged rollout
Deploy a new application version to `member2` only. Pin a test group (or your own IP) to
`member2` using a routing rule. Validate behavior. Roll out to remaining members and remove
the pin. This is the primary real-world justification for `<routingRule>` with a specific
destination.

### 2. Maintenance drain
Before patching or restarting a member, pin traffic **away** from it. Wait for active
sessions to drain naturally. Take the member down cleanly. Liberty's dynamic routing also
supports a `<blockAction>` for this — more surgical than a full pin.

### 3. Production debugging
A specific member is behaving differently (memory leak, slow thread pool, bad deployment).
Pin your own test traffic to that member to reproduce and diagnose without affecting all users.

### 4. Stateful workload affinity
If the app uses in-memory session state that is not replicated, dynamic routing rules can
express affinity as explicit policy rather than relying on JSESSIONID cookie luck.

---

## Demo script — recommended flow for presenting this lab

### Setup (before the audience arrives)
```bash
# Confirm all members are running and in the collective
scripts/routing.sh list

# Confirm round-robin is active
for i in $(seq 6); do
  curl -s -c /dev/null http://localhost:1080/server-info/api/health \
    | python3 -c 'import json,sys; s=json.load(sys.stdin)["server"]; print(s["port"])'
done
# expected: 9081 9082 9081 9082 9081 9082
```

### Step 1 — Show round-robin (baseline)
```bash
scripts/routing.sh roundrobin
for i in $(seq 8); do
  curl -s -c /dev/null http://localhost:1080/server-info/api/health \
    | python3 -c 'import json,sys; s=json.load(sys.stdin)["server"]; print(s["port"])'
done
```
> "Traffic is spreading across all members. No configuration on the member side — the
> controller drives this automatically."

### Step 2 — Pin to member2 (canary scenario)
```bash
scripts/routing.sh pin member2
sleep 12   # wait for ODR poll cycle (RefreshInterval=10)
for i in $(seq 6); do
  curl -s -c /dev/null http://localhost:1080/server-info/api/health \
    | python3 -c 'import json,sys; s=json.load(sys.stdin)["server"]; print(s["port"])'
done
# expected: all 9082
```
> "New version deployed to member2 only. All traffic is now pinned there for validation.
> One XML file, no IHS config change, no member restart."

### Step 3 — Restore round-robin
```bash
scripts/routing.sh roundrobin
sleep 12
for i in $(seq 6); do
  curl -s -c /dev/null http://localhost:1080/server-info/api/health \
    | python3 -c 'import json,sys; s=json.load(sys.stdin)["server"]; print(s["port"])'
done
# expected: alternating ports
```

### Step 4 — Failover (most impactful demo)
```bash
# Start the curl loop in a background watch
watch -n1 'curl -s -c /dev/null http://localhost:1080/server-info/api/health \
  | python3 -c "import json,sys; s=json.load(sys.stdin)[\"server\"]; print(s[\"port\"])"'

# In another terminal — stop member1
~/Liberty-VM-Labs/installs/member1/wlp/bin/server stop member1
# Within ~10 seconds all responses shift to 9082/9083/9084 — member1 is gone from rotation

# Restart member1
~/Liberty-VM-Labs/installs/member1/wlp/bin/server start member1
# Within ~10 seconds port 9081 re-appears in the rotation
```
> "No IHS restart. No plugin-cfg.xml edit. The controller detected the member leaving and
> joining and updated the routing table automatically."

---

## Diagnostic runbook

Use this sequence when routing behavior does not match expectations.

### 1. Confirm the routing rule file is in place
```bash
cat ~/Liberty-VM-Labs/installs/controller/wlp/usr/servers/controller/configDropins/overrides/routing-rules.xml
```

### 2. Confirm Liberty hot-reloaded the dropin
```bash
grep 'routing-rules\|CWWKG0017I' \
  ~/Liberty-VM-Labs/installs/controller/wlp/usr/servers/controller/logs/messages.log \
  | tail -10
```
Look for `CWWKG0093A` (dropin processed) and `CWWKG0017I` (config update complete) timestamped
after the routing change.

### 3. Confirm dynamicRouting-1.0 is loaded (no collectiveMember contamination)
```bash
grep -r 'dynamicRouting\|collectiveMember' \
  ~/Liberty-VM-Labs/installs/controller/wlp/usr/servers/controller/
```
`dynamicRouting-1.0` must be present. `collectiveMember-1.0` must **not** appear anywhere in
the controller's config tree — if it does, the DynamicRouting MBean will not register and all
routing rules are silently ignored.

### 4. Confirm the plugin is in dynamic (ODR) mode
```bash
grep -E 'ODR|Intelligent Management|ConnectorCluster' \
  ~/usr/IBM/IHS/plugin/logs/webserver1/http_plugin.log | tail -10
```
Should show `Intelligent Management library ... loaded` and `ODR Library Version`. If absent,
the plugin is running in static mode and knows nothing about the controller's routing rules.

### 5. Test with curl (cookies discarded) — never with a browser for routing validation
```bash
curl -s -c /dev/null http://localhost:1080/server-info/api/health \
  | python3 -c 'import json,sys; s=json.load(sys.stdin)["server"]; print(s["port"])'
```

### 6. If curl is correct but browser is wrong
The browser has a `JSESSIONID` cookie that is pinning it to the old member via session
affinity. This is evaluated at the plugin level **before** dynamic routing rules.
- Use an incognito/private window **and wait at least 10 seconds** after the routing change.
- Or clear cookies for `localhost` in DevTools → Application → Cookies.
- Hard-reload (Ctrl+Shift+R) does not help — the cookie is still sent.

---

## Common failure modes

| Symptom | Root cause | Fix |
|---|---|---|
| curl returns wrong member after pin | ODR poll cycle not complete yet | Wait 10 s and retry |
| curl always returns same member regardless of rule | `dynamicRouting-1.0` not loaded on controller | Check `role-override.xml` for the feature |
| curl always returns same member regardless of rule | `collectiveMember-1.0` on controller | Remove `collective-join.xml` from controller's `configDropins/overrides/` and restart controller |
| ODR log shows no connect attempts to 9443 | `ConnectorCluster` missing from `plugin-cfg.xml` | Re-run `step2-dynamic-routing.sh` |
| Pin rule written but ignored | `plugin-cfg.xml` was overwritten with a static config | Re-run `step2-dynamic-routing.sh` |
| Browser always returns member1 after pin | JSESSIONID cookie affinity | Test with incognito + wait 10 s; or clear cookies |
| `routing.sh list` falls back to filesystem scan | `collective` CLI binary not executable or controller not running | Check `installs/controller/wlp/bin/collective` exists and controller is up |
| `Current routing: PINNED to 'unknown'` | `routing-rules.xml` exists but destination format was manually edited | Re-run `routing.sh pin <member>` to rewrite it in the expected format |

---

## Prerequisites

Before using `routing.sh`, the following must be in place:

1. `scripts/step2-dynamic-routing.sh` has been run successfully — this generates and installs
   the dynamic `plugin-cfg.xml` and the `plugin-key.kdb` keystore into
   `$IHS_ROOT/plugin/config/webserver1/`.
2. The Collective Controller is running on HTTPS port 9443.
3. At least one collective member is running and registered in the collective.
4. IHS is running on port 1080 with the WAS plugin loaded.
5. `dynamicRouting-1.0` is present in the controller's feature list (it is in `role-override.xml`).
