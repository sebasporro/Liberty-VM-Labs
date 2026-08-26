#!/bin/bash
# =============================================================================
# start-apache.sh
# Configures IBM HTTP Server (IHS) as the Liberty Collective front-end and
# starts (or reloads) it.
#
# Usage:  scripts/start-apache.sh
#
# What it does:
#   1. Locates httpd.conf (checks common IHS and Apache paths on Linux)
#   2. Enables required proxy/balancer modules (uncomments LoadModule lines)
#   3. Adds the Liberty include (idempotent — safe to run multiple times)
#   4. Tests the IHS/Apache configuration
#   5. Starts or gracefully reloads IHS/Apache
#   6. Verifies routing to Liberty members
#
# IHS default install: /home/itzuser/IBM/HTTPServer
# httpd.conf location: /home/itzuser/IBM/HTTPServer/conf/httpd.conf
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

LIBERTY_CONF="${WORKSPACE_ROOT}/config/apache/httpd-liberty.conf"

echo ""
echo "=== IBM HTTP Server — Configure and Start ==="
echo ""

# ---------------------------------------------------------------------------
# 1. Locate httpd.conf
# ---------------------------------------------------------------------------
echo "[1/6] Locating IHS/Apache configuration..."

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

if [[ -z "${HTTPD_CONF}" ]]; then
    echo "  ERROR: httpd.conf not found. Run scripts/install-ihs.sh first."
    echo "  Expected: ${IHS_ROOT}/conf/httpd.conf"
    exit 1
fi

# Ensure IHS apachectl is on PATH
if [[ -x "${IHS_ROOT}/bin/apachectl" && ":${PATH}:" != *":${IHS_ROOT}/bin:"* ]]; then
    export PATH="${IHS_ROOT}/bin:${PATH}"
fi

APACHE_PORT=$(grep "^Listen " "${HTTPD_CONF}" | head -1 | awk '{print $2}')
APACHE_PORT="${APACHE_PORT:-8080}"
echo "      httpd.conf:  ${HTTPD_CONF}"
echo "      Listen port: ${APACHE_PORT}"
echo ""

# ---------------------------------------------------------------------------
# 2. Enable required modules
# ---------------------------------------------------------------------------
echo "[2/6] Enabling required proxy/balancer modules..."

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
            echo "  ERROR: Could not enable ${mod_name}"
            echo "  Add manually to ${HTTPD_CONF}: LoadModule ${mod_name} ${mod_file}"
            exit 1
        fi
    fi
done
echo ""

# ---------------------------------------------------------------------------
# 3. Add Liberty include (idempotent)
# ---------------------------------------------------------------------------
echo "[3/6] Adding Liberty include to httpd.conf..."
INCLUDE_LINE="Include ${LIBERTY_CONF}"
if grep -qF "${INCLUDE_LINE}" "${HTTPD_CONF}"; then
    echo "      Include already present — skipped"
else
    echo "" >> "${HTTPD_CONF}"
    echo "# Liberty Collective load balancer — added by start-apache.sh" >> "${HTTPD_CONF}"
    echo "${INCLUDE_LINE}" >> "${HTTPD_CONF}"
    echo "      Include added"
fi
echo ""

# ---------------------------------------------------------------------------
# 4. Config test
# ---------------------------------------------------------------------------
echo "[4/6] Testing IHS/Apache configuration..."
RESULT=$(apachectl configtest 2>&1)
if echo "${RESULT}" | grep -q "Syntax OK"; then
    echo "      Syntax OK"
else
    echo "  ERROR: Apache config test failed:"
    echo "${RESULT}"
    exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# 5. Start or reload IHS/Apache
# ---------------------------------------------------------------------------
echo "[5/6] Starting / reloading IHS/Apache..."
echo ""

# Check if already listening on the configured port (ss is standard on Linux)
if ss -tlnp 2>/dev/null | grep -q ":${APACHE_PORT} "; then
    echo "      IHS/Apache already running on port ${APACHE_PORT} — reloading config..."
    apachectl graceful
    if [[ $? -ne 0 ]]; then
        echo "  ERROR: Graceful reload failed."
        echo "  Check IHS error log (typically /home/itzuser/IBM/HTTPServer/logs/error_log)"
        exit 1
    fi
    sleep 1
else
    echo "      IHS/Apache not running on port ${APACHE_PORT} — starting..."
    apachectl start
    if [[ $? -ne 0 ]]; then
        echo ""
        echo "  ERROR: IHS/Apache failed to start."
        echo "  Run manually:  apachectl start"
        echo "  Check logs:    /home/itzuser/IBM/HTTPServer/logs/error_log"
        exit 1
    fi
    sleep 2
fi
echo ""

# ---------------------------------------------------------------------------
# 6. Verify routing
# ---------------------------------------------------------------------------
echo "[6/6] Verifying routing..."

check_url() {
    local label="$1"
    local url="$2"
    local expected="$3"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "${url}" 2>/dev/null)
    if [[ "${code}" == "${expected}" ]]; then
        printf "      %-44s  \033[0;32mPASS\033[0m  (HTTP %s)\n" "${label}" "${code}"
    else
        printf "      %-44s  \033[0;31mFAIL\033[0m  (HTTP %s, expected %s)\n" \
            "${label}" "${code}" "${expected}"
    fi
}

# Discover running members dynamically
for member_dir in "${WORKSPACE_ROOT}/installs"/member*/; do
    member_name=$(basename "${member_dir}")
    member_port=$(grep "default.http.port" \
        "${member_dir}/wlp/usr/servers/${member_name}/bootstrap.properties" 2>/dev/null \
        | cut -d= -f2)
    if [[ -n "${member_port}" ]]; then
        check_url "${member_name} direct (:${member_port}/server-info/)" \
            "http://localhost:${member_port}/server-info/" "200"
    fi
done

check_url "IHS/Apache LB    (:${APACHE_PORT}/server-info/)" \
    "http://localhost:${APACHE_PORT}/server-info/" "200"
check_url "Balancer Manager (:${APACHE_PORT}/balancer-manager)" \
    "http://localhost:${APACHE_PORT}/balancer-manager" "200"

echo ""
echo "=== IHS/Apache setup complete ==="
echo ""
echo "  App via IHS/Apache: http://localhost:${APACHE_PORT}/server-info/"
echo "  Balancer Manager:   http://localhost:${APACHE_PORT}/balancer-manager"
echo "  Admin Center:       https://localhost:9443/adminCenter  (admin / admin)"
echo ""
