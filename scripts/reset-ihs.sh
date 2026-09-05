#!/bin/bash
# =============================================================================
# reset-ihs.sh
# Stops IHS and rewrites httpd.conf to a clean baseline.
# Removes all WAS plugin directives so the lab can start fresh.
# =============================================================================

IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/IBM/HTTPServer}"
HTTPD_CONF="${IHS_ROOT}/conf/httpd.conf"
APACHECTL="${IHS_ROOT}/bin/apachectl"

echo ""
echo "=== Reset IHS to clean baseline ==="
echo ""

# 1. Stop IHS if running
if "${APACHECTL}" status &>/dev/null || ss -tlnp 2>/dev/null | grep -q ":8080 "; then
    echo "[1/3] Stopping IHS..."
    "${APACHECTL}" stop 2>/dev/null
    sleep 2
else
    echo "[1/3] IHS not running — skipping stop"
fi

# 2. Overwrite httpd.conf with a clean baseline (no plugin directives)
echo "[2/3] Writing clean httpd.conf..."

mkdir -p "${IHS_ROOT}/logs" \
         "${IHS_ROOT}/htdocs"

cat > "${HTTPD_CONF}" <<CONF_EOF
# =============================================================================
# IBM HTTP Server — clean baseline
# Reset by reset-ihs.sh
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

# WAS plugin — enabled by lab scripts
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

echo "      Written: ${HTTPD_CONF}"

# 3. Remove stale WAS plugin files from IHS conf dir
echo "[3/3] Removing stale WAS plugin files..."
REMOVED=0
for f in \
    "${IHS_ROOT}/conf/plugin-cfg.xml" \
    "${IHS_ROOT}/conf/plugin-key.p12" \
    "${IHS_ROOT}/conf/plugin-key.kdb" \
    "${IHS_ROOT}/conf/plugin-key.sth"; do
    if [[ -f "${f}" ]]; then
        rm -f "${f}"
        echo "      Removed: ${f}"
        (( REMOVED++ ))
    fi
done
[[ ${REMOVED} -eq 0 ]] && echo "      Nothing to remove"

echo ""
echo "=== IHS reset complete ==="
echo "    httpd.conf: ${HTTPD_CONF}"
echo "    No WebSpherePluginConfig, no plugin-cfg.xml"
echo ""
echo "  Next steps:"
echo "    Step 1 — static WAS plugin routing:  bash scripts/step1-was-plugin.sh"
echo "    Step 2 — enable dynamic routing:     bash scripts/step2-dynamic-routing.sh"
echo ""
