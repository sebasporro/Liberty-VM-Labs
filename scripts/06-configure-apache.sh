#!/bin/zsh
# =============================================================================
# 06-configure-apache.sh
# Prints the Apache httpd.conf include instructions for the Liberty front-end.
# Does NOT modify httpd.conf — prints the line you need to add manually.
# =============================================================================

SCRIPT_DIR="${0:A:h}"
source "${SCRIPT_DIR}/00-set-env.sh"

CONF_FILE="${WORKSPACE_ROOT}/config/apache/httpd-liberty.conf"

echo ""
echo "=== Liberty Apache Front-End Configuration ==="
echo ""
echo "Config file: ${CONF_FILE}"
echo ""

# ---------------------------------------------------------------------------
# Detect Homebrew Apache httpd.conf location
# ---------------------------------------------------------------------------
if [[ -f "/opt/homebrew/etc/httpd/httpd.conf" ]]; then
    HTTPD_CONF="/opt/homebrew/etc/httpd/httpd.conf"
    APACHE_TYPE="Homebrew (Apple Silicon)"
elif [[ -f "/usr/local/etc/httpd/httpd.conf" ]]; then
    HTTPD_CONF="/usr/local/etc/httpd/httpd.conf"
    APACHE_TYPE="Homebrew (Intel)"
elif [[ -f "/etc/httpd/conf/httpd.conf" ]]; then
    HTTPD_CONF="/etc/httpd/conf/httpd.conf"
    APACHE_TYPE="System Apache"
elif [[ -f "/etc/apache2/httpd.conf" ]]; then
    HTTPD_CONF="/etc/apache2/httpd.conf"
    APACHE_TYPE="macOS System Apache"
else
    HTTPD_CONF="<httpd.conf not found — locate manually>"
    APACHE_TYPE="Unknown"
fi

echo "Detected Apache: ${APACHE_TYPE}"
echo "httpd.conf path: ${HTTPD_CONF}"
echo ""
echo "-----------------------------------------------------------"
echo "Add this line to ${HTTPD_CONF}:"
echo ""
echo "    Include ${CONF_FILE}"
echo ""
echo "-----------------------------------------------------------"
echo ""

# ---------------------------------------------------------------------------
# Check required modules
# ---------------------------------------------------------------------------
echo "Checking required Apache modules..."
echo ""

REQUIRED_MODULES=("proxy_module" "proxy_balancer_module" "proxy_http_module" "lbmethod_byrequests_module" "slotmem_shm_module")
ALL_LOADED=true

if command -v apachectl &>/dev/null; then
    LOADED_MODULES=$(apachectl -M 2>/dev/null)
    for mod in "${REQUIRED_MODULES[@]}"; do
        if echo "${LOADED_MODULES}" | grep -q "${mod}"; then
            echo "  [LOADED]  ${mod}"
        else
            echo "  [MISSING] ${mod}  ← add LoadModule to httpd.conf"
            ALL_LOADED=false
        fi
    done
else
    echo "  apachectl not found — cannot check modules"
    ALL_LOADED=false
fi

echo ""

if [[ "${ALL_LOADED}" == "true" ]]; then
    echo "All required modules are loaded."
else
    echo "One or more modules are missing. Add the missing LoadModule lines to:"
    echo "  ${HTTPD_CONF}"
    echo ""
    echo "Example LoadModule lines (adjust path for your Apache installation):"
    echo "  LoadModule proxy_module           libexec/apache2/mod_proxy.so"
    echo "  LoadModule proxy_balancer_module  libexec/apache2/mod_proxy_balancer.so"
    echo "  LoadModule proxy_http_module      libexec/apache2/mod_proxy_http.so"
    echo "  LoadModule lbmethod_byrequests_module libexec/apache2/mod_lbmethod_byrequests.so"
    echo "  LoadModule slotmem_shm_module     libexec/apache2/mod_slotmem_shm.so"
fi

echo ""
echo "-----------------------------------------------------------"
echo "After adding the Include line, test and reload Apache:"
echo ""
echo "  apachectl configtest"
echo "  sudo apachectl graceful"
echo ""
echo "Access points after reload:"
echo "  Load-balanced app:  http://localhost/server-info/"
echo "  Balancer Manager:   http://localhost/balancer-manager"
echo "-----------------------------------------------------------"
echo ""
