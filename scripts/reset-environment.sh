#!/bin/bash
# =============================================================================
# reset-environment.sh
# Completely resets the Liberty Collective lab environment back to a clean
# state ready to start from Phase 1 (01-install-runtime.sh).
#
# What it does:
#   1. Stops all Liberty servers (controller + all members), with pkill fallback
#   2. Removes installs/  (all deployed instances); recreates empty dir + .gitkeep
#   3. Stops IHS and rewrites httpd.conf to a clean baseline
#   4. Removes all WAS plugin files from IHS conf/
#      (plugin-cfg.xml, plugin-key.p12, plugin-key.kdb, plugin-key.sth)
#   5. Removes wlp-26/  (extracted Liberty 26.0.0.8 runtime)
#   6. Removes wlp-25/  (extracted Liberty 25.0.0.1 runtime)
#   7. Preserves packages/  (golden ZIPs kept — skip Step 1 if ZIPs already exist)
#
# Usage:
#   scripts/reset-environment.sh          # full reset — ready for Phase 1
#   scripts/reset-environment.sh --full   # identical (kept for compatibility)
#
# After reset, re-run the full pipeline:
#   Step 1: scripts/01-install-runtime.sh  ...  03-build-package-25.sh
#   Step 2: scripts/install-controller.sh  +  add-member-26.sh member1/member2
#   Step 3: scripts/reset-ihs.sh  +  step1-was-plugin.sh  +  step2-dynamic-routing.sh
#   Step 4: scripts/add-member-25.sh member3/member4
#   Step 5: scripts/07-validate.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/IBM/HTTPServer}"
HTTPD_CONF="${IHS_ROOT}/conf/httpd.conf"
APACHECTL="${IHS_ROOT}/bin/apachectl"
IHS_LIB="${IHS_ROOT}/lib"
HTTPD_BIN="${IHS_ROOT}/bin/httpd"

# Ensure IHS apachectl is on PATH
if [[ -x "${APACHECTL}" && ":${PATH}:" != *":${IHS_ROOT}/bin:"* ]]; then
    export PATH="${IHS_ROOT}/bin:${PATH}"
fi

echo ""
echo "=== Liberty Lab — Reset Environment ==="
echo "    Resetting to clean slate (ready for Phase 1)"
echo ""

# ---------------------------------------------------------------------------
# 1. Stop all Liberty servers (controller first, then members)
#    Each stop runs with a 15 s timeout and falls back to pkill if it hangs.
# ---------------------------------------------------------------------------
echo "[1/7] Stopping Liberty servers..."

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
    while kill -0 ${stop_pid} 2>/dev/null && [[ ${waited} -lt 15 ]]; do
        sleep 1; (( waited++ ))
    done
    if kill -0 ${stop_pid} 2>/dev/null; then
        kill ${stop_pid} 2>/dev/null
        pkill -f "ws-server.jar.*${name}" 2>/dev/null || true
        echo "      ${name}: force-killed (stop timed out)"
    else
        echo "      ${name}: stopped"
    fi
}

_stop_server "${WORKSPACE_ROOT}/installs/controller/wlp/bin/server" "controller"

for member_dir in "${WORKSPACE_ROOT}/installs"/member*/; do
    [[ -d "${member_dir}" ]] || continue
    member_name=$(basename "${member_dir}")
    _stop_server "${member_dir}/wlp/bin/server" "${member_name}"
done
echo ""

# ---------------------------------------------------------------------------
# 2. Remove installs/ — all deployed Liberty instances
#    Recreate the directory and restore .gitkeep so git status stays clean.
# ---------------------------------------------------------------------------
echo "[2/7] Removing installs/ directories..."
rm -rf "${WORKSPACE_ROOT}/installs"
mkdir -p "${WORKSPACE_ROOT}/installs"
touch "${WORKSPACE_ROOT}/installs/.gitkeep"
echo "      installs/ cleared (.gitkeep restored)"
echo ""

# ---------------------------------------------------------------------------
# 3. Stop IHS and rewrite httpd.conf to a clean baseline
#    The lab adds WebSpherePluginConfig and loads mod_was_ap24_http.so via
#    step1/step2. A full reset must return httpd.conf to the state that
#    install-ihs.sh originally wrote — no plugin directives, no stale config.
# ---------------------------------------------------------------------------
echo "[3/7] Resetting IHS httpd.conf to clean baseline..."

if [[ -f "${HTTPD_CONF}" ]]; then
    # Stop IHS outright (not graceful) — we are replacing httpd.conf wholesale
    if ss -tlnp 2>/dev/null | grep -q ":8080 "; then
        echo "      Stopping IHS..."
        "${APACHECTL}" stop 2>/dev/null || true
        sleep 2
    fi

    mkdir -p "${IHS_ROOT}/logs" "${IHS_ROOT}/htdocs"

    cat > "${HTTPD_CONF}" <<CONF_EOF
# =============================================================================
# IBM HTTP Server — clean baseline
# Reset by reset-environment.sh — safe to regenerate via scripts/reset-ihs.sh
# =============================================================================
ServerRoot "${IHS_ROOT}"
Listen 8080
ServerName localhost:8080
ServerAdmin admin@localhost

LoadModule mpm_worker_module      modules/mod_mpm_worker.so
LoadModule authz_core_module      modules/mod_authz_core.so
LoadModule log_config_module      modules/mod_log_config.so
LoadModule unixd_module           modules/mod_unixd.so
LoadModule dir_module             modules/mod_dir.so
LoadModule mime_module            modules/mod_mime.so

# WAS plugin — activated by scripts/step1-was-plugin.sh or step2-dynamic-routing.sh
LoadModule was_ap24_module        modules/mod_was_ap24_http.so

User itzuser
Group itzuser

DocumentRoot "${IHS_ROOT}/htdocs"
<Directory "${IHS_ROOT}/htdocs">
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>

ErrorLog  "logs/error_log"
LogLevel  warn
LogFormat "%h %l %u %t \"%r\" %>s %b" common
CustomLog "logs/access_log" common

TypesConfig conf/mime.types
CONF_EOF

    # Ensure mime.types exists (install-ihs.sh creates it; preserve if present)
    if [[ ! -f "${IHS_ROOT}/conf/mime.types" ]]; then
        cat > "${IHS_ROOT}/conf/mime.types" <<'MIME_EOF'
text/html  html htm
text/plain txt
application/octet-stream bin
MIME_EOF
    fi

    echo "      httpd.conf: rewritten to clean baseline"
else
    echo "      httpd.conf not found — IHS may not be installed (skipped)"
fi
echo ""

# ---------------------------------------------------------------------------
# 4. Remove all WAS plugin artifacts from IHS conf/
#    step2-dynamic-routing.sh installs plugin-cfg.xml + plugin-key.p12 here.
#    A clean reset must remove all of them.
# ---------------------------------------------------------------------------
echo "[4/7] Removing WAS plugin artifacts from IHS conf/..."
if [[ -d "${IHS_ROOT}/conf" ]]; then
    REMOVED=0
    for f in \
        "${IHS_ROOT}/conf/plugin-cfg.xml" \
        "${IHS_ROOT}/conf/plugin-key.p12" \
        "${IHS_ROOT}/conf/plugin-key.kdb" \
        "${IHS_ROOT}/conf/plugin-key.sth"; do
        if [[ -f "${f}" ]]; then
            rm -f "${f}"
            echo "      Removed: $(basename "${f}")"
            (( REMOVED++ ))
        fi
    done
    [[ ${REMOVED} -eq 0 ]] && echo "      Nothing to remove"
else
    echo "      IHS conf/ not found — skipped"
fi
echo ""

# ---------------------------------------------------------------------------
# 5. Remove wlp-26/ runtime — Liberty 26.0.0.8
# ---------------------------------------------------------------------------
echo "[5/7] Removing wlp-26/ runtime (26.0.0.8)..."
if [[ -d "${WORKSPACE_ROOT}/wlp-26" ]]; then
    rm -rf "${WORKSPACE_ROOT}/wlp-26"
    echo "      wlp-26/ removed"
else
    echo "      wlp-26/ not found — skipped"
fi
echo ""

# ---------------------------------------------------------------------------
# 6. Remove wlp-25/ runtime — Liberty 25.0.0.1
# ---------------------------------------------------------------------------
echo "[6/7] Removing wlp-25/ runtime (25.0.0.1)..."
if [[ -d "${WORKSPACE_ROOT}/wlp-25" ]]; then
    rm -rf "${WORKSPACE_ROOT}/wlp-25"
    echo "      wlp-25/ removed"
else
    echo "      wlp-25/ not found — skipped"
fi
echo ""

# ---------------------------------------------------------------------------
# 7. Preserve packages/ (golden ZIPs are kept across resets to avoid rebuilds)
# ---------------------------------------------------------------------------
echo "[7/7] Preserving packages/..."
mkdir -p "${WORKSPACE_ROOT}/packages"
PKG_COUNT=$(find "${WORKSPACE_ROOT}/packages" -maxdepth 1 -name "*.zip" 2>/dev/null | wc -l | tr -d ' ')
if [[ "${PKG_COUNT}" -gt 0 ]]; then
    echo "      packages/ kept (${PKG_COUNT} ZIP(s) preserved — skip Step 1 rebuild)"
    find "${WORKSPACE_ROOT}/packages" -maxdepth 1 -name "*.zip" | sort | sed 's/^/      /'
else
    echo "      packages/ empty — Step 1 build required"
fi
echo ""

echo "=== Reset complete — system is at a clean Phase 1 baseline ==="
echo ""
echo "  Step 1 — Build runtimes and packages (skip if ZIPs above are present):"
echo "    scripts/01-install-runtime.sh"
echo "    scripts/02-build-template.sh"
echo "    scripts/03-build-package.sh"
echo "    scripts/01-install-runtime-25.sh"
echo "    scripts/02-build-template-25.sh"
echo "    scripts/03-build-package-25.sh"
echo ""
echo "  Step 2 — Deploy controller and 26.0.0.8 members:"
echo "    scripts/install-controller.sh"
echo "    scripts/add-member-26.sh member1"
echo "    scripts/add-member-26.sh member2"
echo ""
echo "  Step 3 — Configure IHS and enable dynamic routing:"
echo "    scripts/reset-ihs.sh"
echo "    scripts/step1-was-plugin.sh      # static routing first (verify)"
echo "    scripts/step2-dynamic-routing.sh # switch to dynamic routing"
echo ""
echo "  Step 4 — Add 25.0.0.1 members (after dynamic routing is active):"
echo "    scripts/add-member-25.sh member3"
echo "    scripts/add-member-25.sh member4"
echo ""
echo "  Step 5 — Validate:"
echo "    scripts/07-validate.sh"
echo ""
