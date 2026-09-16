# AGENTS.md — Liberty VM Labs

Project-level instructions for AI agents (Bob, Codex, Claude, etc.) working in this repository.

---

## What This Repo Is

A complete, repeatable **IBM WebSphere Liberty Collective Lab
Liberty fronted by IBM HTTP server (IHS)
HTTP Server using WAS Plugin for both static and dynamic (Intelligent Management) routing modes.
Target runtime environment: **`/home/itzuser/Liberty-VM-Labs`** on a TechZone Linux VM.

---

## Repo Layout

```
scripts/          Shell scripts — the primary deliverables
config/           Declarative XML overrides (controller, member1–4, template, apache)
  controller/     role-override.xml, ports-override.xml, routing-rules.xml
  member{1-4}/    role-override.xml, ports-override.xml
  template/       server.xml, bootstrap.properties, jvm.options
  apache/         Static httpd config snippets and plugin-cfg.xml reference
App/              server-info.war (committed; deployed into every member)
packages/         Golden package ZIPs (git-ignored; produced by build scripts)
installs/         Live deployed instances (git-ignored; populated at runtime)
Resources/        Lab reference material
README.md         Canonical lab procedure — source of truth for step sequences
TROUBLESHOOTING.md  Symptom → cause → resolution guide
```

---

## Key Paths (on the lab VM)

| Variable / Path | Value |
|----------------|-------|
| `WORKSPACE_ROOT` | `/home/itzuser/Liberty-VM-Labs` |
| `WLP_HOME` | `$WORKSPACE_ROOT/wlp-26` (build-phase Liberty 26.0.0.8 runtime) |
| `IHS_ROOT` | `/home/itzuser/usr/IBM/IHS` (override with `IHS_INSTALL_ROOT`) |
| Plugin config dir | `$IHS_ROOT/plugin/config/webserver1/` ← **always `plugin/config/`, not `config/`** |
| Plugin log dir | `$IHS_ROOT/plugin/logs/webserver1/` |
| Controller install | `$WORKSPACE_ROOT/installs/controller/wlp/` |
| Member installs | `$WORKSPACE_ROOT/installs/member{1-4}/wlp/` |
| Liberty 26 installer | `/home/itzuser/software/Liberty/Liberty/wlp-nd-all-26.0.0.8.jar` |
| Liberty 25 installer | `/home/itzuser/software/Liberty/Liberty/wlp-base-all-25.0.0.1.jar` |
| IHS installer ZIP | `/home/itzuser/software/IHS/WAS/9.0.5-WS-IHS-ARCHIVE-linux-x86_64-FP025.zip` |

---

## Port Assignments

| Instance | HTTP | HTTPS |
|----------|------|-------|
| IHS front-end | 1080 | — |
| Controller | 9080 | 9443 |
| member1 | 9081 | 9444 |
| member2 | 9082 | 9445 |
| member3 | 9083 | 9446 |
| member4 | 9084 | 9447 |

Member port convention: numeric suffix of member name + 9080 (HTTP) / 9443 (HTTPS).

---

## Script Conventions

- Every script starts with `#!/bin/bash` and sources `scripts/00-set-env.sh`.
- `set -e` (or `set -euo pipefail`) must be present in scripts that mutate state.
- `IHS_ROOT` defaults to `/home/itzuser/usr/IBM/IHS` but respects `$IHS_INSTALL_ROOT`.
- Hardcoded credentials (`admin`/`admin`, keystore password `Liberty26ctrl!`) are
  **intentional for this lab context** — do not add secret-scanning workarounds or
  replace them with placeholders in lab scripts.
- Scripts are idempotent where noted. `reset-ihs.sh` and `patch-ihs-serverroot.sh`
  (if present) are always safe to re-run.

---

## Critical Path Gotcha — Plugin Directory

**This is the single most common source of bugs when editing scripts.**

The correct IHS plugin path is:

```
$IHS_ROOT/plugin/config/webserver1/plugin-cfg.xml   ✅
$IHS_ROOT/config/webserver1/plugin-cfg.xml           ❌  (missing plugin/ segment)
```

Every script that references `plugin-cfg.xml`, `plugin-key.kdb`, `plugin-key.sth`, or
`plugin-key.rdb` **must** use `$IHS_ROOT/plugin/config/webserver1/` as the target directory.
Verify this whenever reading or editing any IHS plugin-related script.

---

## Liberty Feature Names

Use exact, version-qualified feature tokens. Never invent or shorten feature names.

| Feature | Scope |
|---------|-------|
| `collectiveController-1.0` | Controller only (WebSphere Liberty ND) |
| `collectiveMember-1.0` | Members only — **must never appear in the controller's configDropins** |
| `dynamicRouting-1.0` | Controller only (WebSphere Liberty ND) |
| `adminCenter-1.0` | Controller only |
| `restConnector-2.0` | Controller (required by dynamicRouting and adminCenter REST APIs) |

> **`collectiveMember-1.0` on the controller** is a known failure mode: if
> `collective-join.xml` is accidentally placed in the controller's `configDropins/overrides/`,
> it loads `collectiveMember-1.0` which prevents the `DynamicRouting` MBean from registering,
> silently breaking Intelligent Management. Always check for this when debugging dynamic routing.

---

## Commit Message Style

```
<scope>: <short imperative summary>

<body — bullet list of what changed and why>
```

Examples from this repo:
- `step2-dynamic-routing: harden script after integrity review`
- `scripts: remove unused/undocumented scripts`

Scope is the affected script name (without path/extension) or a broad area (`scripts`, `config`, `readme`).

---

## Validation

There is no automated test suite. Validation is manual via:

```bash
scripts/07-validate.sh   # 26-check lab readiness report; exits 0 on all-pass
```

Before committing changes to any script, run a manual integrity check:
1. Verify `set -e` is present if the script mutates state.
2. Verify all IHS plugin paths use `$IHS_ROOT/plugin/config/webserver1/` (not `config/`).
3. Verify no new undocumented scripts are left without a `README.md` Scripts Reference entry.
4. Run `bash -n scripts/<name>.sh` for syntax validation on the target VM if possible.

---

## README.md Is the Source of Truth

`README.md` is the authoritative record of:
- The canonical step sequence (Steps 0–6 + Reset)
- Every script's purpose, prerequisites, and expected output (Scripts Reference section)
- Access points and port table

When adding a new script, **always add a corresponding `###` Scripts Reference entry** to
`README.md`. Scripts without a README entry are considered undocumented and are candidates
for removal during cleanup.
