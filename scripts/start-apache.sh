#!/bin/zsh
# =============================================================================
# start-apache.sh
# Configures Apache HTTP Server as the Liberty Collective front-end and
# starts (or reloads) it.
#
# Usage:  scripts/start-apache.sh
#
# What it does:
#   1. Detects Homebrew Apache httpd.conf location
#   2. Enables required proxy/balancer modules (uncomments LoadModule lines)
#   3. Adds the Liberty include (idempotent — safe to run multiple times)
#   4. Tests the Apache configuration
#   5. Starts or gracefully reloads Apache
#   6. Verifies routing to Liberty members
#
# Note: Apache on macOS Homebrew listens on port 8080 by default.
#       Port 80 requires sudo and a Listen port change — not done here.
# =============================================================================

SCRIPT_DIR="${0:A:h}"
source "${SCRIPT_DIR}/00-set-env.sh"

HTTPD_CONF="/opt/homebrew/etc/httpd/httpd.conf"
LIBERTY_CONF="${WORKSPACE_ROOT}/config/apache/httpd-liberty.conf"

echo ""
echo "=== Apache HTTP Server — Configure and Start ==="
echo ""

# ---------------------------------------------------------------------------
# 1. Verify httpd.conf exists
# ---------------------------------------------------------------------------
echo "[1/6] Locating Apache configuration..."
if [[ ! -f "${HTTPD_CONF}" ]]; then
    # Try Intel Homebrew path
    if [[ -f "/usr/local/etc/httpd/httpd.conf" ]]; then
        HTTPD_CONF="/usr/local/etc/httpd/httpd.conf"
    else
        echo "  ERROR: httpd.conf not found at ${HTTPD_CONF}"
        echo "  Install Apache via: brew install httpd"
        exit 1
    fi
fi
APACHE_PORT=$(grep "^Listen " "${HTTPD_CONF}" | head -1 | awk '{print $2}')
echo "      httpd.conf: ${HTTPD_CONF}"
echo "      Listen port: ${APACHE_PORT}"
echo ""

# ---------------------------------------------------------------------------
# 2. Enable required modules
# ---------------------------------------------------------------------------
echo "[2/6] Enabling required Apache modules..."

MODULES=(
    "proxy_module lib/httpd/modules/mod_proxy.so"
    "proxy_http_module lib/httpd/modules/mod_proxy_http.so"
    "proxy_balancer_module lib/httpd/modules/mod_proxy_balancer.so"
    "slotmem_shm_module lib/httpd/modules/mod_slotmem_shm.so"
    "lbmethod_byrequests_module lib/httpd/modules/mod_lbmethod_byrequests.so"
)

for entry in "${MODULES[@]}"; do
    mod_name="${entry%% *}"
    mod_file="${entry##* }"
    if grep -q "^LoadModule ${mod_name}" "${HTTPD_CONF}"; then
        echo "      ${mod_name}: already enabled"
    else
        sed -i '' "s|^#LoadModule ${mod_name}.*|LoadModule ${mod_name} ${mod_file}|" "${HTTPD_CONF}"
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
echo "[4/6] Testing Apache configuration..."
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
# 5. Start or reload Apache
# ---------------------------------------------------------------------------
echo "[5/6] Starting / reloading Apache..."
echo ""

# Check if Apache is already listening on the configured port
if lsof -iTCP:${APACHE_PORT} -sTCP:LISTEN &>/dev/null; then
    echo "      Apache is already running on port ${APACHE_PORT} — reloading config..."
    sudo apachectl graceful
    if [[ $? -ne 0 ]]; then
        echo "  ERROR: Apache graceful reload failed."
        echo "  Check: /opt/homebrew/var/log/httpd/error_log"
        exit 1
    fi
    sleep 1
else
    echo "      Apache is NOT running on port ${APACHE_PORT}."
    echo "      (sudo required — run in your terminal if this fails)"
    sudo apachectl start
    if [[ $? -ne 0 ]]; then
        echo ""
        echo "  ERROR: Apache failed to start."
        echo "  Run manually:  sudo apachectl start"
        echo "  Check logs:    /opt/homebrew/var/log/httpd/error_log"
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

check_url "Apache LB       (:${APACHE_PORT}/server-info/)" \
    "http://localhost:${APACHE_PORT}/server-info/" "200"
check_url "Balancer Manager (:${APACHE_PORT}/balancer-manager)" \
    "http://localhost:${APACHE_PORT}/balancer-manager" "200"

echo ""
echo "=== Apache setup complete ==="
echo ""
echo "  App via Apache:   http://localhost:${APACHE_PORT}/server-info/"
echo "  Balancer Manager: http://localhost:${APACHE_PORT}/balancer-manager"
echo "  Admin Center:     https://localhost:9443/adminCenter  (admin / admin)"
echo ""
