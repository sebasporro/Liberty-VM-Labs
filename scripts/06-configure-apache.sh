#!/bin/bash
# =============================================================================
# 06-configure-apache.sh
# Prints the IHS/Apache httpd.conf include instructions for the Liberty front-end.
# Does NOT modify httpd.conf — prints the line you need to add manually.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

CONF_FILE="${WORKSPACE_ROOT}/config/apache/httpd-liberty.conf"

echo ""
echo "=== Liberty IHS/Apache Front-End Configuration ==="
echo ""
echo "Config file: ${CONF_FILE}"
echo ""

# ---------------------------------------------------------------------------
# Detect IHS/Apache httpd.conf location (Linux paths)
# ---------------------------------------------------------------------------
HTTPD_CONF=""
APACHE_TYPE=""
for candidate in \
    "/home/itzuser/IBM/HTTPServer/conf/httpd.conf" \
    "/etc/httpd/conf/httpd.conf" \
    "/etc/apache2/apache2.conf" \
    "/usr/local/apache2/conf/httpd.conf"; do
    if [[ -f "${candidate}" ]]; then
        HTTPD_CONF="${candidate}"
        case "${candidate}" in
            /opt/IBM/*) APACHE_TYPE="IBM HTTP Server (IHS)" ;;
            /etc/httpd/*) APACHE_TYPE="System Apache (RHEL/CentOS)" ;;
            /etc/apache2/*) APACHE_TYPE="System Apache (Debian/Ubuntu)" ;;
            *) APACHE_TYPE="Apache" ;;
        esac
        break
    fi
done

if [[ -z "${HTTPD_CONF}" ]]; then
    HTTPD_CONF="<httpd.conf not found — locate manually>"
    APACHE_TYPE="Unknown"
fi

echo "Detected:        ${APACHE_TYPE}"
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
echo "Checking required modules..."
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
    echo "Example LoadModule lines (IHS default — adjust path if different):"
    echo "  LoadModule proxy_module           modules/mod_proxy.so"
    echo "  LoadModule proxy_balancer_module  modules/mod_proxy_balancer.so"
    echo "  LoadModule proxy_http_module      modules/mod_proxy_http.so"
    echo "  LoadModule lbmethod_byrequests_module modules/mod_lbmethod_byrequests.so"
    echo "  LoadModule slotmem_shm_module     modules/mod_slotmem_shm.so"
fi

echo ""
echo "-----------------------------------------------------------"
echo "After adding the Include line, test and reload IHS/Apache:"
echo ""
echo "  apachectl configtest"
echo "  apachectl graceful"
echo ""
echo "Access points after reload:"
echo "  Load-balanced app:  http://localhost:8080/server-info/"
echo "  Balancer Manager:   http://localhost:8080/balancer-manager"
echo "-----------------------------------------------------------"
echo ""
