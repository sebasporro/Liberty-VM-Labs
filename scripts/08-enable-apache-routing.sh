#!/bin/bash
# =============================================================================
# 08-enable-apache-routing.sh
# Enables IHS/Apache routing to the Liberty Collective members.
#
# What this script does:
#   1. Starts the Liberty member servers (member1, member2)
#   2. Enables required proxy/balancer modules in httpd.conf (uncomments them)
#   3. Adds the Liberty include to httpd.conf (idempotent — won't add twice)
#   4. Tests the IHS/Apache config
#   5. Starts (or reloads) IHS/Apache
#   6. Verifies routing is working
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

LIBERTY_CONF="${WORKSPACE_ROOT}/config/apache/httpd-liberty.conf"

# Locate httpd.conf (IHS on Linux)
IHS_ROOT="${IHS_INSTALL_ROOT:-/opt/IBM/HTTPServer}"
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

if [[ -z "${HTTPD_CONF}" ]]; then
    echo "  ERROR: httpd.conf not found. Run scripts/install-ihs.sh first."
    echo "  Expected: ${IHS_ROOT}/conf/httpd.conf"
    exit 1
fi

# Ensure IHS apachectl is on PATH
if [[ -x "${IHS_ROOT}/bin/apachectl" && ":${PATH}:" != *":${IHS_ROOT}/bin:"* ]]; then
    export PATH="${IHS_ROOT}/bin:${PATH}"
fi

echo ""
echo "=== Liberty IHS/Apache Routing Setup ==="
echo "    httpd.conf: ${HTTPD_CONF}"
echo ""

# ---------------------------------------------------------------------------
# Step 1 — Start Liberty member servers
# ---------------------------------------------------------------------------
echo "[1/6] Starting Liberty member servers..."

for member in member1 member2; do
    BIN="${WORKSPACE_ROOT}/installs/${member}/wlp/bin/server"
    STATUS=$(${BIN} status ${member} 2>/dev/null)
    if echo "${STATUS}" | grep -q "is running"; then
        echo "      ${member}: already running — skipped"
    else
        echo "      Starting ${member}..."
        ${BIN} start ${member}
        if [[ $? -ne 0 ]]; then
            echo "  ERROR: Failed to start ${member}. Check logs at:"
            echo "    ${WORKSPACE_ROOT}/installs/${member}/wlp/usr/servers/${member}/logs/messages.log"
            exit 1
        fi
        echo "      ${member}: started"
    fi
done
echo ""

# ---------------------------------------------------------------------------
# Step 2 — Enable required modules in httpd.conf (uncomment if commented)
# ---------------------------------------------------------------------------
echo "[2/6] Enabling required modules in ${HTTPD_CONF}..."

MODULES=(
    "proxy_module modules/mod_proxy.so"
    "proxy_http_module modules/mod_proxy_http.so"
    "proxy_balancer_module modules/mod_proxy_balancer.so"
    "slotmem_shm_module modules/mod_slotmem_shm.so"
    "lbmethod_byrequests_module modules/mod_lbmethod_byrequests.so"
)

for entry in "${MODULES[@]}"; do
    mod_name="${entry%% *}"
    mod_file="${entry##* }"
    if grep -q "^LoadModule ${mod_name}" "${HTTPD_CONF}"; then
        echo "      ${mod_name}: already enabled"
    else
        sed -i "s|^#LoadModule ${mod_name}.*|LoadModule ${mod_name} ${mod_file}|" "${HTTPD_CONF}"
        if grep -q "^LoadModule ${mod_name}" "${HTTPD_CONF}"; then
            echo "      ${mod_name}: enabled"
        else
            echo "  ERROR: Could not enable ${mod_name} in ${HTTPD_CONF}"
            echo "  Add this line manually: LoadModule ${mod_name} ${mod_file}"
            exit 1
        fi
    fi
done
echo ""

# ---------------------------------------------------------------------------
# Step 3 — Add Liberty include to httpd.conf (idempotent)
# ---------------------------------------------------------------------------
echo "[3/6] Adding Liberty include to ${HTTPD_CONF}..."

INCLUDE_LINE="Include ${LIBERTY_CONF}"

if grep -qF "${INCLUDE_LINE}" "${HTTPD_CONF}"; then
    echo "      Include already present — skipped"
else
    echo "" >> "${HTTPD_CONF}"
    echo "# Liberty Collective load balancer — added by 08-enable-apache-routing.sh" >> "${HTTPD_CONF}"
    echo "${INCLUDE_LINE}" >> "${HTTPD_CONF}"
    echo "      Include added"
fi
echo ""

# ---------------------------------------------------------------------------
# Step 4 — Test IHS/Apache configuration
# ---------------------------------------------------------------------------
echo "[4/6] Testing IHS/Apache configuration..."
CONFIGTEST=$(apachectl configtest 2>&1)
if echo "${CONFIGTEST}" | grep -q "Syntax OK"; then
    echo "      Syntax OK"
else
    echo "  ERROR: IHS/Apache config test failed:"
    echo "${CONFIGTEST}"
    exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# Step 5 — Start or reload IHS/Apache
# ---------------------------------------------------------------------------
echo "[5/6] Starting / reloading IHS/Apache..."

APACHE_PORT=$(grep "^Listen " "${HTTPD_CONF}" | head -1 | awk '{print $2}')
APACHE_PORT="${APACHE_PORT:-8080}"

if ss -tlnp 2>/dev/null | grep -q ":${APACHE_PORT} "; then
    echo "      IHS/Apache already running — reloading gracefully..."
    apachectl graceful
else
    echo "      Starting IHS/Apache..."
    apachectl start
fi

if [[ $? -ne 0 ]]; then
    echo "  ERROR: IHS/Apache failed to start."
    echo "  Check: /opt/IBM/HTTPServer/logs/error_log"
    exit 1
fi
echo "      IHS/Apache running"
echo ""

# ---------------------------------------------------------------------------
# Step 6 — Verify routing
# ---------------------------------------------------------------------------
echo "[6/6] Verifying IHS/Apache → Liberty routing..."
sleep 2   # brief pause for IHS/Apache to fully reload

check_url() {
    local label="$1"
    local url="$2"
    local expected="$3"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "${url}" 2>/dev/null)
    if [[ "${code}" == "${expected}" ]]; then
        printf "      %-40s  \033[0;32mPASS\033[0m  (HTTP %s)\n" "${label}" "${code}"
    else
        printf "      %-40s  \033[0;31mFAIL\033[0m  (HTTP %s, expected %s)\n" "${label}" "${code}" "${expected}"
    fi
}

check_url "member1 direct  (:9081/server-info/)"  "http://localhost:9081/server-info/"  "200"
check_url "member2 direct  (:9082/server-info/)"  "http://localhost:9082/server-info/"  "200"
check_url "IHS/Apache LB   (:8080/server-info/)"  "http://localhost:8080/server-info/"  "200"
check_url "Balancer Manager (:8080/balancer-mgr)" "http://localhost:8080/balancer-manager" "200"

echo ""
echo "=== Setup complete ==="
echo ""
echo "  App via IHS/Apache:  http://localhost:8080/server-info/"
echo "  Balancer Manager:    http://localhost:8080/balancer-manager"
echo "  Admin Center:        https://localhost:9443/adminCenter  (admin / admin)"
echo ""
