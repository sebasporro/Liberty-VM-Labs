#!/bin/bash
# =============================================================================
# reset-environment.sh
# Completely resets the Liberty Collective lab environment back to a clean
# state ready to start from Phase 1 (01-install-runtime.sh).
#
# What it does:
#   1. Stops all Liberty servers (controller + all members)
#   2. Removes installs/  (all deployed instances)
#   3. Removes the Apache Liberty include from httpd.conf
#   4. Disables the proxy/balancer modules in httpd.conf
#   5. Reloads IHS/Apache to apply the clean config
#   6. Removes wlp-26/  (extracted Liberty 26.0.0.8 runtime)
#   7. Removes wlp-25/  (extracted Liberty 25.0.0.1 runtime)
#   8. Clears packages/  (golden package ZIPs)
#
# Usage:
#   scripts/reset-environment.sh          # full reset — ready for Phase 1
#   scripts/reset-environment.sh --full   # identical (kept for compatibility)
#
# After reset, re-run the full pipeline from Phase 1:
#   scripts/01-install-runtime.sh
#   scripts/02-build-template.sh
#   scripts/03-build-package.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

LIBERTY_CONF="${WORKSPACE_ROOT}/config/apache/httpd-liberty.conf"

# Locate httpd.conf (IHS on Linux)
IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/IBM/HTTPServer}"
HTTPD_CONF=""
for candidate in \
    "${IHS_ROOT}/conf/httpd.conf" \
    "/etc/httpd/conf/httpd.conf" \
    "/etc/apache2/apache2.conf" \
    "/usr/local/apache2/conf/httpd.conf"; do
    if [[ -f "${candidate}" ]]; then
        HTTPD_CONF="${candidate}"
        break
    fi
done

# Ensure IHS apachectl is on PATH
if [[ -x "${IHS_ROOT}/bin/apachectl" && ":${PATH}:" != *":${IHS_ROOT}/bin:"* ]]; then
    export PATH="${IHS_ROOT}/bin:${PATH}"
fi

echo ""
echo "=== Liberty Lab — Reset Environment ==="
echo "    Resetting to clean slate (ready for Phase 1)"
echo ""

# ---------------------------------------------------------------------------
# 1. Stop all Liberty servers
# ---------------------------------------------------------------------------
echo "[1/8] Stopping Liberty servers..."

# Stop controller
CTRL_BIN="${WORKSPACE_ROOT}/installs/controller/wlp/bin/server"
if [[ -x "${CTRL_BIN}" ]]; then
    STATUS=$(${CTRL_BIN} status controller 2>/dev/null)
    if echo "${STATUS}" | grep -q "is running"; then
        echo "      Stopping controller..."
        ${CTRL_BIN} stop controller 2>/dev/null
        echo "      controller: stopped"
    else
        echo "      controller: not running — skipped"
    fi
else
    echo "      controller: not installed — skipped"
fi

# Stop all members dynamically — with pkill fallback on timeout
for member_dir in "${WORKSPACE_ROOT}/installs"/member*/; do
    [[ -d "${member_dir}" ]] || continue
    member_name=$(basename "${member_dir}")
    member_bin="${member_dir}/wlp/bin/server"
    if [[ -x "${member_bin}" ]]; then
        STATUS=$(${member_bin} status "${member_name}" 2>/dev/null)
        if echo "${STATUS}" | grep -q "is running"; then
            echo "      Stopping ${member_name}..."
            # Run stop with 15s timeout; fall back to pkill if it hangs
            ( ${member_bin} stop "${member_name}" 2>/dev/null ) &
            STOP_PID=$!
            WAITED=0
            while kill -0 $STOP_PID 2>/dev/null && [[ $WAITED -lt 15 ]]; do
                sleep 1; (( WAITED++ ))
            done
            if kill -0 $STOP_PID 2>/dev/null; then
                kill $STOP_PID 2>/dev/null
                pkill -f "ws-server.jar.*${member_name}" 2>/dev/null
                echo "      ${member_name}: force-killed (stop timed out)"
            else
                echo "      ${member_name}: stopped"
            fi
        else
            echo "      ${member_name}: not running — skipped"
        fi
    fi
done
echo ""

# ---------------------------------------------------------------------------
# 2. Remove installs/ directories
# ---------------------------------------------------------------------------
echo "[2/8] Removing installs/ directories..."
if [[ -d "${WORKSPACE_ROOT}/installs" ]]; then
    rm -rf "${WORKSPACE_ROOT}/installs"
    mkdir -p "${WORKSPACE_ROOT}/installs"
    echo "      installs/ cleared"
else
    echo "      installs/ not found — skipped"
fi
echo ""

# ---------------------------------------------------------------------------
# 3. Remove Apache Liberty include from httpd.conf
# ---------------------------------------------------------------------------
echo "[3/8] Removing Liberty include from httpd.conf..."
if [[ -n "${HTTPD_CONF}" && -f "${HTTPD_CONF}" ]]; then
    # Remove the include line and the comment above it (GNU sed — no empty extension)
    sed -i "/# Liberty Collective load balancer/d" "${HTTPD_CONF}"
    sed -i "\|Include ${LIBERTY_CONF}|d" "${HTTPD_CONF}"
    echo "      Include removed from ${HTTPD_CONF}"
else
    echo "      httpd.conf not found — skipped"
fi
echo ""

# ---------------------------------------------------------------------------
# 4. Disable proxy/balancer modules in httpd.conf (comment them back out)
# ---------------------------------------------------------------------------
echo "[4/8] Disabling proxy/balancer modules in httpd.conf..."
if [[ -n "${HTTPD_CONF}" && -f "${HTTPD_CONF}" ]]; then
    MODULES=(
        "proxy_module"
        "proxy_http_module"
        "proxy_balancer_module"
        "slotmem_shm_module"
        "lbmethod_byrequests_module"
    )
    for mod_name in "${MODULES[@]}"; do
        if grep -q "^LoadModule ${mod_name}" "${HTTPD_CONF}"; then
            sed -i "s|^LoadModule ${mod_name}|#LoadModule ${mod_name}|" "${HTTPD_CONF}"
            echo "      ${mod_name}: disabled"
        else
            echo "      ${mod_name}: already disabled — skipped"
        fi
    done
else
    echo "      httpd.conf not found — skipped"
fi
echo ""

# ---------------------------------------------------------------------------
# 5. Reload IHS/Apache to apply clean config
# ---------------------------------------------------------------------------
echo "[5/8] Reloading IHS/Apache..."
APACHE_PORT=""
if [[ -n "${HTTPD_CONF}" ]]; then
    APACHE_PORT=$(grep "^Listen " "${HTTPD_CONF}" 2>/dev/null | head -1 | awk '{print $2}')
fi
APACHE_PORT="${APACHE_PORT:-8080}"

# ss is standard on Linux; fall back to netstat if unavailable
if ss -tlnp 2>/dev/null | grep -q ":${APACHE_PORT} "; then
    apachectl configtest 2>/dev/null | grep -q "Syntax OK" && \
        apachectl graceful 2>/dev/null && \
        echo "      IHS/Apache reloaded" || \
        echo "      WARNING: IHS/Apache reload failed — run: apachectl graceful"
else
    echo "      IHS/Apache not running — skipped"
fi
echo ""

# ---------------------------------------------------------------------------
# 6. Remove wlp-26/ runtime — Liberty 26.0.0.8
# ---------------------------------------------------------------------------
echo "[6/8] Removing wlp-26/ runtime (26.0.0.8)..."
if [[ -d "${WORKSPACE_ROOT}/wlp-26" ]]; then
    rm -rf "${WORKSPACE_ROOT}/wlp-26"
    echo "      wlp-26/ removed"
else
    echo "      wlp-26/ not found — skipped"
fi
echo ""

# ---------------------------------------------------------------------------
# 7. Remove wlp-25/ runtime — Liberty 25.0.0.1
# ---------------------------------------------------------------------------
echo "[7/8] Removing wlp-25/ runtime (25.0.0.1)..."
if [[ -d "${WORKSPACE_ROOT}/wlp-25" ]]; then
    rm -rf "${WORKSPACE_ROOT}/wlp-25"
    echo "      wlp-25/ removed"
else
    echo "      wlp-25/ not found — skipped"
fi
echo ""

# ---------------------------------------------------------------------------
# 8. Clear packages/ (golden ZIPs)
# ---------------------------------------------------------------------------
echo "[8/8] Clearing packages/..."
if [[ -d "${WORKSPACE_ROOT}/packages" ]]; then
    rm -rf "${WORKSPACE_ROOT}/packages"
    mkdir -p "${WORKSPACE_ROOT}/packages"
    echo "      packages/ cleared"
else
    mkdir -p "${WORKSPACE_ROOT}/packages"
    echo "      packages/ not found — recreated"
fi
echo ""

echo "=== Reset complete — system is at a clean Phase 1 baseline ==="
echo ""
echo "  Run Phase 1 — Liberty 26.0.0.8:"
echo "    scripts/01-install-runtime.sh"
echo "    scripts/02-build-template.sh"
echo "    scripts/03-build-package.sh"
echo ""
echo "  Run Phase 1 — Liberty 25.0.0.1:"
echo "    scripts/01-install-runtime-25.sh"
echo "    scripts/02-build-template-25.sh"
echo "    scripts/03-build-package-25.sh"
echo ""
echo "  Then deploy:"
echo "    scripts/install-controller.sh"
echo "    scripts/add-member-26.sh member1"
echo "    scripts/add-member-26.sh member2"
echo "    scripts/add-member-25.sh member3"
echo "    scripts/add-member-25.sh member4"
echo "    scripts/start-apache.sh"
echo ""
