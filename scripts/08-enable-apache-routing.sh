#!/bin/bash
# =============================================================================
# 08-enable-apache-routing.sh
# Enables IHS routing to the Liberty Collective via the WAS plugin
# (mod_was_ap24_http.so + plugin-cfg.xml).
#
# What this script does:
#   1. Checks Liberty member servers are running
#   2. Ensures was_ap24_module is loaded in httpd.conf
#   3. Copies plugin-cfg.xml to the IHS conf directory
#   4. Adds the Liberty include to httpd.conf (idempotent)
#   5. Tests the IHS config
#   6. Starts (or reloads) IHS and verifies routing
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

LIBERTY_CONF="${WORKSPACE_ROOT}/config/apache/httpd-liberty.conf"
PLUGIN_CFG_SRC="${WORKSPACE_ROOT}/config/apache/plugin-cfg.xml"

IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/IBM/HTTPServer}"
HTTPD_CONF="${IHS_ROOT}/conf/httpd.conf"
PLUGIN_CFG_DEST="${IHS_ROOT}/conf/plugin-cfg.xml"

# Ensure IHS apachectl is on PATH
if [[ -x "${IHS_ROOT}/bin/apachectl" && ":${PATH}:" != *":${IHS_ROOT}/bin:"* ]]; then
    export PATH="${IHS_ROOT}/bin:${PATH}"
fi

if [[ ! -f "${HTTPD_CONF}" ]]; then
    echo "  ERROR: httpd.conf not found. Run scripts/install-ihs.sh first."
    echo "  Expected: ${HTTPD_CONF}"
    exit 1
fi

echo ""
echo "=== Liberty IHS WAS Plugin Routing Setup ==="
echo "    httpd.conf:    ${HTTPD_CONF}"
echo "    plugin-cfg.xml: ${PLUGIN_CFG_DEST}"
echo ""

# ---------------------------------------------------------------------------
# Step 1 — Check Liberty member servers are running
# ---------------------------------------------------------------------------
echo "[1/6] Checking Liberty member servers..."

ALL_RUNNING=true
for member in member1 member2; do
    BIN="${WORKSPACE_ROOT}/installs/${member}/wlp/bin/server"
    STATUS=$(${BIN} status ${member} 2>/dev/null)
    if echo "${STATUS}" | grep -q "is running"; then
        echo "      ${member}: running"
    else
        echo "      ${member}: not running — starting..."
        ${BIN} start ${member}
        if [[ $? -ne 0 ]]; then
            echo "  ERROR: Failed to start ${member}."
            echo "    Logs: ${WORKSPACE_ROOT}/installs/${member}/wlp/usr/servers/${member}/logs/messages.log"
            ALL_RUNNING=false
        fi
    fi
done
echo ""

# ---------------------------------------------------------------------------
# Step 2 — Ensure was_ap24_module is loaded in httpd.conf
# ---------------------------------------------------------------------------
echo "[2/6] Ensuring was_ap24_module is loaded in ${HTTPD_CONF}..."

WAS_MODULE_LINE="LoadModule was_ap24_module modules/mod_was_ap24_http.so"

if grep -q "^LoadModule was_ap24_module" "${HTTPD_CONF}"; then
    echo "      was_ap24_module: already enabled"
elif grep -q "^#.*LoadModule was_ap24_module" "${HTTPD_CONF}"; then
    sed -i "s|^#.*LoadModule was_ap24_module.*|${WAS_MODULE_LINE}|" "${HTTPD_CONF}"
    echo "      was_ap24_module: uncommented"
else
    echo "" >> "${HTTPD_CONF}"
    echo "# WAS plugin — added by 08-enable-apache-routing.sh" >> "${HTTPD_CONF}"
    echo "${WAS_MODULE_LINE}" >> "${HTTPD_CONF}"
    echo "      was_ap24_module: added"
fi

# Ensure proxy modules are NOT active (they are not needed and their .so files
# are partially absent — leaving them active will cause configtest failures)
for mod in proxy_balancer_module lbmethod_byrequests_module; do
    if grep -q "^LoadModule ${mod}" "${HTTPD_CONF}"; then
        sed -i "s|^LoadModule ${mod}|# LoadModule ${mod}|" "${HTTPD_CONF}"
        echo "      ${mod}: commented out (not needed with WAS plugin)"
    fi
done
echo ""

# ---------------------------------------------------------------------------
# Step 3 — Deploy plugin-cfg.xml to IHS conf directory
# ---------------------------------------------------------------------------
echo "[3/6] Deploying plugin-cfg.xml to ${IHS_ROOT}/conf/..."

if [[ ! -f "${PLUGIN_CFG_SRC}" ]]; then
    echo "  ERROR: plugin-cfg.xml not found at ${PLUGIN_CFG_SRC}"
    exit 1
fi

cp "${PLUGIN_CFG_SRC}" "${PLUGIN_CFG_DEST}"
echo "      Copied: ${PLUGIN_CFG_DEST}"
echo ""

# ---------------------------------------------------------------------------
# Step 4 — Add WebSpherePluginConfig directly to httpd.conf (idempotent)
#           The WAS plugin reads this directive before Include files are
#           processed, so it must live in the main httpd.conf directly.
# ---------------------------------------------------------------------------
echo "[4/6] Adding WebSpherePluginConfig to ${HTTPD_CONF}..."

PLUGIN_LINE="WebSpherePluginConfig ${PLUGIN_CFG_DEST}"

if grep -qF "WebSpherePluginConfig" "${HTTPD_CONF}"; then
    # Update the path in case it changed
    sed -i "s|^WebSpherePluginConfig .*|${PLUGIN_LINE}|" "${HTTPD_CONF}"
    echo "      WebSpherePluginConfig: already present (path updated)"
else
    echo "" >> "${HTTPD_CONF}"
    echo "# Liberty Collective WAS plugin routing — added by 08-enable-apache-routing.sh" >> "${HTTPD_CONF}"
    echo "${PLUGIN_LINE}" >> "${HTTPD_CONF}"
    echo "      WebSpherePluginConfig: added"
fi
echo ""

# ---------------------------------------------------------------------------
# Step 5 — Test IHS configuration
# ---------------------------------------------------------------------------
echo "[5/6] Testing IHS configuration..."
CONFIGTEST=$(apachectl configtest 2>&1)
if echo "${CONFIGTEST}" | grep -q "Syntax OK"; then
    echo "      Syntax OK"
else
    echo "  ERROR: IHS config test failed:"
    echo "${CONFIGTEST}"
    exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# Step 6 — Start or reload IHS
# ---------------------------------------------------------------------------
echo "[6/6] Starting / reloading IHS..."

APACHE_PORT=$(grep "^Listen " "${HTTPD_CONF}" | head -1 | awk '{print $2}')
APACHE_PORT="${APACHE_PORT:-8080}"

if ss -tlnp 2>/dev/null | grep -q ":${APACHE_PORT} "; then
    echo "      IHS already running — reloading gracefully..."
    apachectl graceful
else
    echo "      Starting IHS..."
    apachectl start
fi

if [[ $? -ne 0 ]]; then
    echo "  ERROR: IHS failed to start."
    echo "  Check: ${IHS_ROOT}/logs/error_log"
    exit 1
fi
echo "      IHS running on port ${APACHE_PORT}"
echo ""

echo "=== Setup complete ==="
echo ""
echo "  WAS plugin config: ${PLUGIN_CFG_DEST}"
echo "  IHS error log:     ${IHS_ROOT}/logs/error_log"
echo ""
echo "  Verify routing:"
echo "    curl -I http://localhost:${APACHE_PORT}/server-info/"
echo ""
