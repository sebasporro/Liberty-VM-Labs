#!/bin/bash
# =============================================================================
# install-ihs.sh
# Installs IBM HTTP Server (IHS) from the pre-provisioned installer ZIP.
#
# Usage:  scripts/install-ihs.sh
#
# What it does:
#   1. Locates the IHS installer ZIP under /home/itzuser/software/IHS/
#   2. Extracts the ZIP to a staging directory
#   3. Runs the IHS silent installer
#   4. Verifies /opt/IBM/HTTPServer/bin/apachectl is executable
#   5. Configures IHS to listen on port 8080
#
# Override the installer search directory:
#   export IHS_INSTALLER_DIR=/path/to/dir/containing/ihs-zip
#
# IHS installs to: /opt/IBM/HTTPServer
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

IHS_INSTALL_ROOT="/opt/IBM/HTTPServer"
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
    echo "         Hint: find / -name '*.zip' -path '*IHS*' 2>/dev/null" >&2
    exit 1
fi

IHS_ZIP=$(find "${IHS_INSTALLER_DIR}" -maxdepth 2 -name "*.zip" | head -1)

if [[ -z "${IHS_ZIP}" ]]; then
    echo "  ERROR: No ZIP file found in ${IHS_INSTALLER_DIR}" >&2
    echo "         Hint: find / -name '*.zip' -path '*IHS*' 2>/dev/null" >&2
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
# 4. Run silent install
# Handles two common IHS installer layouts:
#   a) install — traditional IHS binary installer
#   b) installc — IIM (Installation Manager) console mode
# ---------------------------------------------------------------------------
echo "[3/4] Running IHS silent install to ${IHS_INSTALL_ROOT}..."

# Find the installer binary
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
    echo "  ERROR: Could not find installer binary in extracted ZIP." >&2
    echo "  Contents of staging dir:" >&2
    ls "${IHS_STAGING}" >&2
    exit 1
fi

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
echo "      Staging directory cleaned up"
echo ""

# ---------------------------------------------------------------------------
# 5. Verify and configure Listen port
# ---------------------------------------------------------------------------
echo "[4/4] Verifying IHS installation..."

if [[ ! -x "${IHS_INSTALL_ROOT}/bin/apachectl" ]]; then
    echo "  ERROR: ${IHS_INSTALL_ROOT}/bin/apachectl not found after install." >&2
    exit 1
fi

echo "      apachectl: OK"
"${IHS_INSTALL_ROOT}/bin/apachectl" -v 2>&1 | head -2

HTTPD_CONF="${IHS_INSTALL_ROOT}/conf/httpd.conf"

# Ensure IHS listens on port 8080 (default IHS Listen is 80)
if grep -q "^Listen 80$" "${HTTPD_CONF}" 2>/dev/null; then
    sed -i 's/^Listen 80$/Listen 8080/' "${HTTPD_CONF}"
    echo "      Listen port set to 8080"
fi

echo ""
echo "=== IHS install complete ==="
echo ""
echo "  Install root:  ${IHS_INSTALL_ROOT}"
echo "  httpd.conf:    ${HTTPD_CONF}"
echo "  apachectl:     ${IHS_INSTALL_ROOT}/bin/apachectl"
echo ""
echo "  Add apachectl to PATH for the lab scripts:"
echo "    export PATH=\"${IHS_INSTALL_ROOT}/bin:\$PATH\""
echo "  Or add that line to ~/.bashrc for persistence."
echo ""
