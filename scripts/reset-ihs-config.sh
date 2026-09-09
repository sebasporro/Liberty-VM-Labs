#!/bin/bash
# =============================================================================
# reset-ihs-config.sh
# Reverts IHS configuration back to a clean post-installation baseline.
# Clears all static and dynamic routing configurations, plugin-cfg.xml, and dynamic certificates
# so you can run step1-was-plugin.sh (static) or step2-dynamic-routing.sh (dynamic) again.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

IHS_ROOT="/home/itzuser/usr/IBM/IHS"
HTTPD_CONF="${IHS_ROOT}/conf/httpd.conf"
PLUGIN_DIR="${IHS_ROOT}/plugin/config/webserver1"

echo "============================================================="
echo " Reverting IHS to clean baseline (Post-Install status)"
echo "============================================================="

# 1. Stop IHS cleanly
echo "[1/4] Stopping IHS..."
"${IHS_ROOT}/bin/apachectl" stop 2>/dev/null || true
pkill -9 -f "${IHS_ROOT}/bin/httpd" 2>/dev/null || true
sleep 1

# 2. Clear any plugin-cfg.xml and certificates (static/dynamic keys)
echo "[2/4] Removing all WAS plugin configuration and certificates..."
rm -f "${PLUGIN_DIR}"/plugin-cfg.xml
rm -f "${PLUGIN_DIR}"/plugin-key.kdb
rm -f "${PLUGIN_DIR}"/plugin-key.sth
rm -f "${PLUGIN_DIR}"/plugin-key.rdb
rm -f "${PLUGIN_DIR}"/plugin-key.p12
rm -rf ~/temp/dynamicRouting
echo "      Configurations cleared."

# 3. Restore httpd.conf to clean post-install baseline
echo "[3/4] Restoring httpd.conf to post-install state..."
cat > "${HTTPD_CONF}" <<EOF
# IBM HTTP Server — Clean Post-Install Baseline
ServerRoot "${IHS_ROOT}"
Listen 1080
ServerName localhost:1080

LoadModule mpm_worker_module      modules/mod_mpm_worker.so
LoadModule authz_core_module      modules/mod_authz_core.so
LoadModule log_config_module      modules/mod_log_config.so
LoadModule unixd_module           modules/mod_unixd.so
LoadModule dir_module             modules/mod_dir.so
LoadModule mime_module            modules/mod_mime.so

# Load WAS Plugin Module
LoadModule was_ap24_module plugin/bin/64bits/mod_was_ap24_http.so

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
EOF
echo "      httpd.conf restored."

# 4. Start IHS
echo "[4/4] Starting IHS..."
"${IHS_ROOT}/bin/apachectl" start

echo "============================================================="
echo " IHS is reverted to a clean post-install baseline!"
echo " You can now toggle routing configs by running:"
echo "   - Static Routing : bash scripts/step1-was-plugin.sh"
echo "   - Dynamic Routing: bash scripts/step2-dynamic-routing.sh"
echo "============================================================="
echo ""
