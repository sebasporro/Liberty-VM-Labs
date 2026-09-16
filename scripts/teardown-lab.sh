#!/bin/bash
# =============================================================================
# teardown-lab.sh
# Performs a complete end-of-lab teardown of the Liberty VM Labs environment.
#
# Removes:
#   - All running Liberty servers (controller + members, graceful stop + pkill fallback)
#   - installs/           (all deployed Liberty instances)
#   - wlp-26/             (Liberty ND 26.0.0.8 extracted runtime)
#   - wlp-25/             (Liberty Base 25.0.0.1 extracted runtime)
#   - wlp-standalone/     (standalone orientation server, if created)
#   - ~/usr/IBM/IHS       (full IBM HTTP Server installation)
#   - /home/itzuser/temp/dynamicRouting  (dynamic routing temp files)
#
# Preserves (never touched):
#   - packages/           (golden package ZIPs — expensive to rebuild)
#   - App/server-info.war (committed to repo)
#   - Liberty installer JARs at /home/itzuser/software/Liberty/Liberty/
#   - IHS installer ZIP   at /home/itzuser/software/IHS/
#   - All repo source files (scripts/, config/, README.md, etc.)
#
# Usage:
#   bash scripts/teardown-lab.sh
#
# After teardown, restart the lab from the full sequence in README.md.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/usr/IBM/IHS}"

echo ""
echo "=== Liberty VM Labs — Full Teardown ==="
echo "    Removing all lab installations (preserving installer binaries and packages/)"
echo ""

# ---------------------------------------------------------------------------
# Helper: stop a single Liberty server with a 15 s timeout + pkill fallback
# ---------------------------------------------------------------------------
_stop_server() {
    local bin="$1" name="$2"
    if [[ ! -x "${bin}" ]]; then
        echo "      ${name}: not installed — skipped"
        return
    fi
    if ! "${bin}" status "${name}" 2>/dev/null | grep -q "is running"; then
        echo "      ${name}: not running — skipped"
        return
    fi
    echo "      Stopping ${name}..."
    ( "${bin}" stop "${name}" 2>/dev/null ) &
    local stop_pid=$! waited=0
    while kill -0 "${stop_pid}" 2>/dev/null && [[ ${waited} -lt 15 ]]; do
        sleep 1; (( waited++ ))
    done
    if kill -0 "${stop_pid}" 2>/dev/null; then
        kill "${stop_pid}" 2>/dev/null
        pkill -f "ws-server.jar.*${name}" 2>/dev/null || true
        echo "      ${name}: force-killed (stop timed out)"
    else
        echo "      ${name}: stopped"
    fi
}

# ---------------------------------------------------------------------------
# Phase 1 — Stop all Liberty servers
# ---------------------------------------------------------------------------
echo "[1/6] Stopping Liberty servers..."

_stop_server "${WORKSPACE_ROOT}/installs/controller/wlp/bin/server" "controller"

for member_dir in "${WORKSPACE_ROOT}/installs"/member*/; do
    [[ -d "${member_dir}" ]] || continue
    member_name=$(basename "${member_dir}")
    _stop_server "${member_dir}/wlp/bin/server" "${member_name}"
done

# Also stop any standalone orientation server if present
if [[ -x "${WORKSPACE_ROOT}/wlp-standalone/bin/server" ]]; then
    for srv_dir in "${WORKSPACE_ROOT}/wlp-standalone/usr/servers"/*/; do
        [[ -d "${srv_dir}" ]] || continue
        srv_name=$(basename "${srv_dir}")
        _stop_server "${WORKSPACE_ROOT}/wlp-standalone/bin/server" "${srv_name}"
    done
fi

echo ""

# ---------------------------------------------------------------------------
# Phase 2 — Remove deployed instances
# ---------------------------------------------------------------------------
echo "[2/6] Removing deployed Liberty instances (installs/)..."
rm -rf "${WORKSPACE_ROOT}/installs"
mkdir -p "${WORKSPACE_ROOT}/installs"
touch "${WORKSPACE_ROOT}/installs/.gitkeep"
echo "      installs/ cleared (.gitkeep restored)"
echo ""

# ---------------------------------------------------------------------------
# Phase 3 — Remove extracted Liberty runtimes
# ---------------------------------------------------------------------------
echo "[3/6] Removing Liberty runtimes..."

for runtime_dir in wlp-26 wlp-25 wlp-standalone; do
    target="${WORKSPACE_ROOT}/${runtime_dir}"
    if [[ -d "${target}" ]]; then
        rm -rf "${target}"
        echo "      ${runtime_dir}/ removed"
    else
        echo "      ${runtime_dir}/ not found — skipped"
    fi
done
echo ""

# ---------------------------------------------------------------------------
# Phase 4 — Remove IHS installation
# ---------------------------------------------------------------------------
echo "[4/6] Removing IBM HTTP Server installation..."

# Graceful stop first (best effort)
if [[ -f "${IHS_ROOT}/bin/apachectl" ]]; then
    echo "      Stopping IHS..."
    "${IHS_ROOT}/bin/apachectl" stop 2>/dev/null || true
fi
# Kill any remaining httpd processes
pkill -f "httpd" 2>/dev/null || true
sleep 1

if [[ -d "${IHS_ROOT}" ]]; then
    rm -rf "${IHS_ROOT}"
    echo "      ${IHS_ROOT} removed"
else
    echo "      IHS not found at ${IHS_ROOT} — skipped"
fi

# Remove dynamic routing temp directory
if [[ -d "/home/itzuser/temp/dynamicRouting" ]]; then
    rm -rf "/home/itzuser/temp/dynamicRouting"
    echo "      /home/itzuser/temp/dynamicRouting removed"
fi
echo ""

# ---------------------------------------------------------------------------
# Phase 5 — Confirm packages/ preserved
# ---------------------------------------------------------------------------
echo "[5/6] Verifying packages/ preserved..."
mkdir -p "${WORKSPACE_ROOT}/packages"
pkg_count=$(find "${WORKSPACE_ROOT}/packages" -maxdepth 1 -name "*.zip" 2>/dev/null | wc -l | tr -d ' ')
if [[ "${pkg_count}" -gt 0 ]]; then
    echo "      packages/ intact (${pkg_count} ZIP(s) preserved)"
    find "${WORKSPACE_ROOT}/packages" -maxdepth 1 -name "*.zip" | sort | sed "s|^|      |"
else
    echo "      packages/ is empty (golden ZIPs were never built — Step 2 required)"
fi
echo ""

# ---------------------------------------------------------------------------
# Phase 6 — Summary
# ---------------------------------------------------------------------------
echo "[6/6] Teardown complete."
echo ""
echo "  Removed:"
echo "    installs/        — all deployed Liberty instances"
echo "    wlp-26/          — Liberty ND 26.0.0.8 runtime"
echo "    wlp-25/          — Liberty Base 25.0.0.1 runtime"
echo "    wlp-standalone/  — standalone orientation server"
echo "    ~/usr/IBM/IHS    — IBM HTTP Server installation"
echo ""
echo "  Preserved:"
echo "    packages/        — golden package ZIPs (if any)"
echo "    App/             — server-info.war"
echo "    scripts/ config/ — repo source files"
echo "    /home/itzuser/software/  — installer JARs and ZIPs (never touched)"
echo ""
echo "  To restart the lab from scratch, follow the full sequence in README.md."
echo ""
