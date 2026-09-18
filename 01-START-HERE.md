> **⚠️ Beta Version** — This lab is under active development. If you encounter any errors,
> broken steps, or unclear instructions, please report them to **Sebastian Porro**
> (sebastian.porro@ibm.com). Your feedback helps improve the experience for everyone.


# Liberty on Virtual Machines — Start Here

Welcome to the **WebSphere Liberty on Virtual Machines** labs. You will complete two hands-on
labs that take you from a single standalone Liberty server all the way to a fully automated
Liberty Collective with dynamic routing, two Liberty versions, and IBM HTTP Server (IHS)
acting as a front-end load balancer.

---

## Lab Overview

### Lab 1 — Liberty Standalone
**Guide:** [02-LIBERTY-STANDALONE.md](02-LIBERTY-STANDALONE.md)

A manual, step-by-step walkthrough of the core Liberty lifecycle on a single VM:

- Extract the Liberty 26.0.0.8 ND runtime from its installer JAR
- Create a server, start and stop it, and read its logs
- Edit `server.xml` to enable Admin Center (`adminCenter-1.0`, `appSecurity-5.0`)
- Deploy `server-info.war` and verify it via the browser
- Install IBM HTTP Server (IHS) and front the Liberty instance with the WAS plugin

**Duration:** ~30 minutes  
**Recommended for:** Anyone new to Liberty or the lab environment — complete this before Lab 2.

---

### Lab 2 — Liberty Collectives, Dynamic Routing & Zero Migration
**Guide:** [03-LIBERTY-COLLECTIVES.md](03-LIBERTY-COLLECTIVES.md)

An automated, script-driven lab that demonstrates enterprise Liberty patterns:

- Build a **golden package** from a role-neutral template server
- Deploy a **Collective Controller** (Liberty 26 ND) and up to four members across two Liberty versions (26 and 25)
- Join all members to the collective using the Liberty `collective join` CLI
- Configure **IBM HTTP Server (IHS)** with the WAS plugin in static and intelligent (dynamic) routing modes
- Demonstrate **Zero Migration**: Liberty 25 and Liberty 26 members coexisting in the same collective with no code changes

**Duration:** ~60–90 minutes  
**Requires:** Completion of Lab 1, or equivalent familiarity with Liberty server.xml and IHS.

---

## Prerequisites

### 1. TechZone VM

Both labs run on a pre-provisioned IBM TechZone Linux VM. All required software is
pre-installed at fixed paths — no downloads are needed.

| Software | Version | Path on VM |
|---|---|---|
| Java (IBM Semeru) | 17 | Pre-installed; verify with `java -version` |
| Liberty ND installer | 26.0.0.8 | `/home/itzuser/software/Liberty/Liberty/wlp-nd-all-26.0.0.8.jar` |
| Liberty Base installer | 25.0.0.1 | `/home/itzuser/software/Liberty/Liberty/wlp-base-all-25.0.0.1.jar` |
| IHS + WAS Plugins | 9.0.5 FP025 | `/home/itzuser/software/IHS/WAS/9.0.5-WS-IHS-ARCHIVE-linux-x86_64-FP025.zip` |

### 2. Clone the lab repository

All lab scripts, configuration files, and guides live in this GitHub repository. Clone it
into the standard working directory on the VM:

```bash
cd /home/itzuser
git clone https://github.com/sebasporro/Liberty-VM-Labs.git
cd Liberty-VM-Labs
```

> If the directory already exists from a previous session, pull the latest changes instead:
> ```bash
> cd /home/itzuser/Liberty-VM-Labs
> git pull
> ```

All commands in both labs are run from the repo root (`/home/itzuser/Liberty-VM-Labs`)
unless otherwise noted.

---

## Recommended Sequence

```
01-START-HERE.md          ← you are here
        │
        ▼
02-LIBERTY-STANDALONE.md  ← Lab 1: single server, manual steps (~30 min)
        │
        ▼
03-LIBERTY-COLLECTIVES.md ← Lab 2: collective, scripts, IHS, dynamic routing (~90 min)
```

Start with **[Lab 1 → 02-LIBERTY-STANDALONE.md](02-LIBERTY-STANDALONE.md)**.
