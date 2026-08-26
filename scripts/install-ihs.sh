#!/bin/bash
# =============================================================================
# install-ihs.sh
# Installs IBM HTTP Server (IHS) from the pre-provisioned installer ZIP.
#
# Usage:  scripts/install-ihs.sh
#
# Supported ZIP formats:
#   - ARCHIVE format (e.g. 9.0.5-WS-IHS-ARCHIVE-linux-x86_64.zip)
#     The ZIP extracts directly to a ready-to-use IHS directory tree.
#     The script detects this and moves it into place — no installer binary needed.
#   - Traditional installer (install / installc binary inside the ZIP)
#     The script finds and runs the binary with --silent --acceptLicense.
#
# Override defaults:
#   export IHS_INSTALLER_DIR=/path/to/dir/containing/ihs-zip
#   export IHS_INSTALL_ROOT=/opt/IBM/HTTPServer   (default)
#
# IHS installs to: /home/itzuser/IBM/HTTPServer  (default — no sudo required)
# Override: export IHS_INSTALL_ROOT=/opt/IBM/HTTPServer  (requires sudo)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

IHS_INSTALL_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/IBM/HTTPServer}"
IHS_INSTALLER_DIR="${IHS_INSTALLER_DIR:-/home/itzuser/software/IHS}"
IHS_STAGING="${WORKSPACE_ROOT}/_ihs_staging"

echo ""
echo "=== IBM HTTP Server — Install ==="
echo ""

# ---------------------------------------------------------------------------
# 1. Check if already installed
# ---------------------------------------------------------------------------
if [[ -x "${IHS_INSTALL_ROOT}/bin/apachectl" ]]; then
    echo "[INFO] IHS already installed at ${IHS_INSTALL_ROOT}"
    echo "       Remove ${IHS_INSTALL_ROOT} to re-install."
    echo ""
    "${IHS_INSTALL_ROOT}/bin/apachectl" -v 2>&1 | head -2
    exit 0
fi

# ---------------------------------------------------------------------------
# 2. Locate the installer ZIP
# ---------------------------------------------------------------------------
echo "[1/4] Locating IHS installer ZIP in ${IHS_INSTALLER_DIR}..."

if [[ ! -d "${IHS_INSTALLER_DIR}" ]]; then
    echo "  ERROR: Installer directory not found: ${IHS_INSTALLER_DIR}" >&2
    echo "         Set IHS_INSTALLER_DIR to the directory containing the IHS ZIP." >&2
    echo "         Hint: find / -name '*IHS*.zip' 2>/dev/null" >&2
    exit 1
fi

IHS_ZIP=$(find "${IHS_INSTALLER_DIR}" -maxdepth 2 -name "*.zip" | head -1)

if [[ -z "${IHS_ZIP}" ]]; then
    echo "  ERROR: No ZIP file found in ${IHS_INSTALLER_DIR}" >&2
    echo "         Hint: find / -name '*IHS*.zip' 2>/dev/null" >&2
    exit 1
fi

echo "      Found: ${IHS_ZIP}"
echo ""

# ---------------------------------------------------------------------------
# 3. Extract installer ZIP
# ---------------------------------------------------------------------------
echo "[2/4] Extracting installer..."
rm -rf "${IHS_STAGING}"
mkdir -p "${IHS_STAGING}"
unzip -q "${IHS_ZIP}" -d "${IHS_STAGING}"
echo "      Extracted to: ${IHS_STAGING}"
echo ""

# ---------------------------------------------------------------------------
# 4. Install IHS
#
# Detect layout:
#   a) ARCHIVE format — ZIP extracts to a directory containing bin/apachectl.
#      The directory may be named "IHS", "HTTPServer", or similar.
#      Move it directly into IHS_INSTALL_ROOT — no installer binary needed.
#
#   b) Traditional installer — ZIP contains an install or installc binary.
#      Run it with --silent --acceptLicense.
# ---------------------------------------------------------------------------
echo "[3/4] Installing IHS to ${IHS_INSTALL_ROOT}..."

# --- Detect archive format: look for known IHS binaries one level deep ---
ARCHIVE_DIR=""
for dir in "${IHS_STAGING}"/*/; do
    if [[ -f "${dir}bin/apachectl" || -f "${dir}bin/httpd" || \
          -f "${dir}bin/apachectl2" || -d "${dir}bin" ]]; then
        ARCHIVE_DIR="${dir%/}"   # strip trailing slash
        break
    fi
done

if [[ -n "${ARCHIVE_DIR}" ]]; then
    # ARCHIVE format — move the extracted tree into place
    echo "      Detected: ARCHIVE format (${ARCHIVE_DIR##*/})"
    echo "      Moving to ${IHS_INSTALL_ROOT}..."
    # Use sudo only if the parent directory is not writable by the current user
    PARENT_DIR="$(dirname "${IHS_INSTALL_ROOT}")"
    if [[ -w "${PARENT_DIR}" ]] || mkdir -p "${PARENT_DIR}" 2>/dev/null; then
        mkdir -p "${PARENT_DIR}"
        mv "${ARCHIVE_DIR}" "${IHS_INSTALL_ROOT}"
    else
        sudo mkdir -p "${PARENT_DIR}"
        sudo mv "${ARCHIVE_DIR}" "${IHS_INSTALL_ROOT}"
    fi
    rm -rf "${IHS_STAGING}"
    echo "      Installed"
else
    # --- Traditional installer format ---
    INSTALLER_BIN=""
    for candidate in \
        "${IHS_STAGING}/install" \
        "${IHS_STAGING}/installc" \
        "${IHS_STAGING}/IHS/install" \
        "${IHS_STAGING}/IHS/installc"; do
        if [[ -f "${candidate}" ]]; then
            INSTALLER_BIN="${candidate}"
            break
        fi
    done

    if [[ -z "${INSTALLER_BIN}" ]]; then
        echo "  ERROR: Could not detect IHS installer format." >&2
        echo "  Staging directory contents:" >&2
        find "${IHS_STAGING}" -maxdepth 2 >&2
        rm -rf "${IHS_STAGING}"
        exit 1
    fi

    echo "      Detected: traditional installer ($(basename "${INSTALLER_BIN}"))"
    chmod +x "${INSTALLER_BIN}"
    "${INSTALLER_BIN}" \
        --silent \
        --acceptLicense \
        -installationDirectory "${IHS_INSTALL_ROOT}" 2>&1

    if [[ $? -ne 0 ]]; then
        echo "  ERROR: IHS installer exited with an error." >&2
        echo "  Check the installer log in ${IHS_INSTALL_ROOT}/logs/" >&2
        rm -rf "${IHS_STAGING}"
        exit 1
    fi
    rm -rf "${IHS_STAGING}"
fi

# ---------------------------------------------------------------------------
# 5. Install required system libraries (APR / APR-util)
#    IHS 9.x dynamically links against libapr-1 and libaprutil-1.
#    These are standard packages on all RHEL/CentOS/Fedora systems.
# ---------------------------------------------------------------------------
echo ""
echo "[4/5] Installing APR/APR-util system dependencies..."

if command -v dnf &>/dev/null; then
    sudo dnf install -y apr apr-util 2>&1 | tail -3
elif command -v yum &>/dev/null; then
    sudo yum install -y apr apr-util 2>&1 | tail -3
elif command -v apt-get &>/dev/null; then
    sudo apt-get install -y libapr1 libaprutil1 2>&1 | tail -3
else
    echo "  WARNING: Could not detect package manager. Install apr and apr-util manually." >&2
    echo "  e.g.:  sudo dnf install -y apr apr-util" >&2
fi
echo ""

# ---------------------------------------------------------------------------
# 6. Verify and configure Listen port
# ---------------------------------------------------------------------------
echo ""
echo "[5/5] Verifying IHS installation..."

# Find the IHS control binary — IHS 9.x may use apachectl, apachectl2, or httpd
IHS_CTL=""
for candidate in \
    "${IHS_INSTALL_ROOT}/bin/apachectl" \
    "${IHS_INSTALL_ROOT}/bin/apachectl2" \
    "${IHS_INSTALL_ROOT}/bin/httpd"; do
    if [[ -x "${candidate}" ]]; then
        IHS_CTL="${candidate}"
        break
    fi
done

if [[ -z "${IHS_CTL}" ]]; then
    echo "  ERROR: IHS control binary not found after install." >&2
    echo "  Install root tree:" >&2
    find "${IHS_INSTALL_ROOT}" -maxdepth 3 2>/dev/null >&2
    exit 1
fi

# IHS bundles its own APR/APR-util in lib/. Set LD_LIBRARY_PATH so the
# IHS binaries use their own libraries rather than the system ones.
# Strategy:
#   - If the archive ships its own apachectl control script, preserve it
#     and instead prepend LD_LIBRARY_PATH in the environment permanently
#     via ~/.bashrc (so all subprocesses inherit it).
#   - Only write a wrapper when there is no real apachectl control script.
IHS_LIB="${IHS_INSTALL_ROOT}/lib"

REAL_APACHECTL="${IHS_INSTALL_ROOT}/bin/apachectl"

if [[ -x "${REAL_APACHECTL}" && "${REAL_APACHECTL}" != "${IHS_CTL}" ]]; then
    # Archive ships its own apachectl — wrap it to prepend LD_LIBRARY_PATH
    mv "${REAL_APACHECTL}" "${REAL_APACHECTL}.real"
    cat > "${REAL_APACHECTL}" <<WRAPPER_EOF
#!/bin/bash
# IHS apachectl wrapper — prepends IHS bundled lib path
export LD_LIBRARY_PATH="${IHS_LIB}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "${REAL_APACHECTL}.real" "\$@"
WRAPPER_EOF
    chmod +x "${REAL_APACHECTL}"
    echo "      Wrapped existing apachectl (original saved as apachectl.real)"
elif [[ ! -x "${REAL_APACHECTL}" ]]; then
    # No apachectl in archive — write a full control wrapper around httpd
    cat > "${REAL_APACHECTL}" <<WRAPPER_EOF
#!/bin/bash
# IHS apachectl wrapper — translates start/stop/graceful to httpd flags
export LD_LIBRARY_PATH="${IHS_LIB}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
HTTPD="${IHS_CTL}"
HTTPD_CONF="${IHS_INSTALL_ROOT}/conf/httpd.conf"
case "\$1" in
    start)    exec "\${HTTPD}" -f "\${HTTPD_CONF}" -k start ;;
    stop)     exec "\${HTTPD}" -f "\${HTTPD_CONF}" -k stop ;;
    restart)  exec "\${HTTPD}" -f "\${HTTPD_CONF}" -k restart ;;
    graceful) exec "\${HTTPD}" -f "\${HTTPD_CONF}" -k graceful ;;
    configtest) exec "\${HTTPD}" -f "\${HTTPD_CONF}" -t ;;
    -v|-V)    exec "\${HTTPD}" "\$@" ;;
    *)        exec "\${HTTPD}" -f "\${HTTPD_CONF}" "\$@" ;;
esac
WRAPPER_EOF
    chmod +x "${REAL_APACHECTL}"
    echo "      Control wrapper written: ${REAL_APACHECTL}"
else
    # apachectl IS the detected binary — wrap it in-place
    mv "${REAL_APACHECTL}" "${REAL_APACHECTL}.real"
    cat > "${REAL_APACHECTL}" <<WRAPPER_EOF
#!/bin/bash
export LD_LIBRARY_PATH="${IHS_LIB}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "${REAL_APACHECTL}.real" "\$@"
WRAPPER_EOF
    chmod +x "${REAL_APACHECTL}"
    echo "      Wrapped apachectl in-place (original saved as apachectl.real)"
fi

HTTPD_CONF="${IHS_INSTALL_ROOT}/conf/httpd.conf"

# ---------------------------------------------------------------------------
# Generate httpd.conf if the archive did not include one
# ---------------------------------------------------------------------------
if [[ ! -f "${HTTPD_CONF}" ]]; then
    echo "      No httpd.conf found — generating minimal config..."
    mkdir -p "${IHS_INSTALL_ROOT}/conf"
    mkdir -p "${IHS_INSTALL_ROOT}/logs"
    mkdir -p "${IHS_INSTALL_ROOT}/conf/extra"
    cat > "${HTTPD_CONF}" <<CONF_EOF
# Minimal IBM HTTP Server configuration — generated by install-ihs.sh
ServerRoot "${IHS_INSTALL_ROOT}"
Listen 8080
ServerName localhost:8080
ServerAdmin admin@localhost

LoadModule mpm_worker_module modules/mod_mpm_worker.so
LoadModule authz_core_module modules/mod_authz_core.so
LoadModule log_config_module modules/mod_log_config.so
LoadModule unixd_module modules/mod_unixd.so
LoadModule dir_module modules/mod_dir.so
LoadModule mime_module modules/mod_mime.so

# Proxy / load-balancer modules (uncommented by start-apache.sh)
#LoadModule proxy_module modules/mod_proxy.so
#LoadModule proxy_http_module modules/mod_proxy_http.so
#LoadModule proxy_balancer_module modules/mod_proxy_balancer.so
#LoadModule slotmem_shm_module modules/mod_slotmem_shm.so
#LoadModule lbmethod_byrequests_module modules/mod_lbmethod_byrequests.so

User itzuser
Group itzuser

DocumentRoot "${IHS_INSTALL_ROOT}/htdocs"
<Directory "${IHS_INSTALL_ROOT}/htdocs">
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>

ErrorLog "logs/error_log"
LogLevel warn
LogFormat "%h %l %u %t \"%r\" %>s %b" common
CustomLog "logs/access_log" common

TypesConfig conf/mime.types
CONF_EOF

    # Generate a minimal mime.types so httpd doesn't complain
    cat > "${IHS_INSTALL_ROOT}/conf/mime.types" <<'MIME_EOF'
text/html html htm
text/plain txt
application/octet-stream bin
MIME_EOF

    # Create a default htdocs index
    mkdir -p "${IHS_INSTALL_ROOT}/htdocs"
    echo "<html><body><h1>IBM HTTP Server</h1></body></html>" \
        > "${IHS_INSTALL_ROOT}/htdocs/index.html"

    echo "      httpd.conf generated: ${HTTPD_CONF}"
else
    # Ensure IHS listens on port 8080 (default IHS Listen is 80)
    if grep -q "^Listen 80$" "${HTTPD_CONF}"; then
        sed -i 's/^Listen 80$/Listen 8080/' "${HTTPD_CONF}"
        echo "      Listen port changed: 80 → 8080"
    else
        CURRENT_PORT=$(grep "^Listen " "${HTTPD_CONF}" | head -1 | awk '{print $2}')
        echo "      Listen port: ${CURRENT_PORT:-8080}"
    fi
fi

# Verify
echo ""
echo "      Testing configtest..."
LD_LIBRARY_PATH="${IHS_LIB}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "${IHS_CTL}" -f "${HTTPD_CONF}" -t 2>&1 | head -3

echo ""
echo "=== IHS install complete ==="
echo ""
echo "  Install root:  ${IHS_INSTALL_ROOT}"
echo "  httpd.conf:    ${HTTPD_CONF}"
echo "  apachectl:     ${WRAPPER}"
echo ""
echo "  Add IHS to PATH (required for lab scripts):"
echo "    echo 'export PATH=\"${IHS_INSTALL_ROOT}/bin:\$PATH\"' >> ~/.bashrc"
echo "    source ~/.bashrc"
echo ""
