#!/bin/zsh
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
#   5. Reloads Apache to apply the clean config
#   6. Removes wlp-26/  (extracted Liberty 26.0.0.8 runtime)
#   7. Clears packages/  (golden package ZIP)
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

SCRIPT_DIR="${0:A:h}"
source "${SCRIPT_DIR}/00-set-env.sh"

HTTPD_CONF="/opt/homebrew/etc/httpd/httpd.conf"
LIBERTY_CONF="${WORKSPACE_ROOT}/config/apache/httpd-liberty.conf"

echo ""
echo "=== Liberty Lab — Reset Environment ==="
echo "    Resetting to clean slate (ready for Phase 1)"
echo ""

# ---------------------------------------------------------------------------
# 1. Stop all Liberty servers
# ---------------------------------------------------------------------------
echo "[1/5] Stopping Liberty servers..."

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
echo "[2/5] Removing installs/ directories..."
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
echo "[3/5] Removing Liberty include from Apache httpd.conf..."
if [[ -f "${HTTPD_CONF}" ]]; then
    # Remove the include line and the comment above it
    sed -i '' "/# Liberty Collective load balancer/d" "${HTTPD_CONF}"
    sed -i '' "\|Include ${LIBERTY_CONF}|d" "${HTTPD_CONF}"
    echo "      Include removed from ${HTTPD_CONF}"
else
    echo "      httpd.conf not found — skipped"
fi
echo ""

# ---------------------------------------------------------------------------
# 4. Disable proxy/balancer modules in httpd.conf (comment them back out)
# ---------------------------------------------------------------------------
echo "[4/5] Disabling proxy/balancer modules in httpd.conf..."
if [[ -f "${HTTPD_CONF}" ]]; then
    MODULES=(
        "proxy_module"
        "proxy_http_module"
        "proxy_balancer_module"
        "slotmem_shm_module"
        "lbmethod_byrequests_module"
    )
    for mod_name in "${MODULES[@]}"; do
        if grep -q "^LoadModule ${mod_name}" "${HTTPD_CONF}"; then
            sed -i '' "s|^LoadModule ${mod_name}|#LoadModule ${mod_name}|" "${HTTPD_CONF}"
            echo "      ${mod_name}: disabled"
        else
            echo "      ${mod_name}: already disabled — skipped"
        fi
    done
fi
echo ""

# ---------------------------------------------------------------------------
# 5. Reload Apache to apply clean config
# ---------------------------------------------------------------------------
echo "[5/5] Reloading Apache..."
APACHE_RUNNING=false
APACHE_PORT=$(grep "^Listen " "${HTTPD_CONF}" 2>/dev/null | head -1 | awk '{print $2}')
if lsof -iTCP:${APACHE_PORT:-8080} -sTCP:LISTEN &>/dev/null; then
    APACHE_RUNNING=true
fi

if [[ "${APACHE_RUNNING}" == "true" ]]; then
    apachectl configtest 2>/dev/null | grep -q "Syntax OK" && \
        sudo apachectl graceful 2>/dev/null && \
        echo "      Apache reloaded" || \
        echo "      WARNING: Apache reload failed — reload manually with: sudo apachectl graceful"
else
    echo "      Apache not running — skipped"
fi
echo ""

# ---------------------------------------------------------------------------
# 6. Remove wlp-26/ runtime — Liberty 26.0.0.8 (Phase 1 — script 01)
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
# 7. Remove wlp-25/ runtime — Liberty 25.0.0.1 (Phase 1 — script 01-25)
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
# 8. Clear packages/ (Phase 1 — scripts 03 and 03-25)
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
echo "    scripts/add-member.sh member1"
echo "    scripts/add-member.sh member2"
echo "    scripts/add-member-25.sh member3"
echo "    scripts/add-member-25.sh member4"
echo "    scripts/start-apache.sh"
echo ""
