#!/bin/bash
# =============================================================================
# install-ihs.sh
# Cleans any previous IHS install, installs IBM HTTP Server from the
# pre-provisioned ARCHIVE ZIP, and installs the WAS plugin.
#
# Usage:  scripts/install-ihs.sh
#
# Overrides:
#   IHS_INSTALLER_DIR   directory that contains the IHS ZIP  (default below)
#   IHS_INSTALL_ROOT    where IHS is installed               (default below)
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
# 1. Clean previous install
# ---------------------------------------------------------------------------
if [[ -d "${IHS_INSTALL_ROOT}" ]]; then
    echo "[1/3] Removing previous install at ${IHS_INSTALL_ROOT}..."
    rm -rf "${IHS_INSTALL_ROOT}"
fi

# ---------------------------------------------------------------------------
# 2. Locate and extract the installer ZIP
# ---------------------------------------------------------------------------
echo "[2/3] Installing IHS..."

if [[ ! -d "${IHS_INSTALLER_DIR}" ]]; then
    echo "  ERROR: Installer directory not found: ${IHS_INSTALLER_DIR}" >&2
    echo "         Set IHS_INSTALLER_DIR to the directory containing the IHS ZIP." >&2
    exit 1
fi

IHS_ZIP=$(find "${IHS_INSTALLER_DIR}" -maxdepth 2 -name "*.zip" | head -1)
if [[ -z "${IHS_ZIP}" ]]; then
    echo "  ERROR: No ZIP file found in ${IHS_INSTALLER_DIR}" >&2
    exit 1
fi
echo "      ZIP: ${IHS_ZIP}"

rm -rf "${IHS_STAGING}"
mkdir -p "${IHS_STAGING}"
unzip -q "${IHS_ZIP}" -d "${IHS_STAGING}"

# Find the top-level subdirectory that contains a bin/ — that is the IHS tree
ARCHIVE_DIR=""
for dir in "${IHS_STAGING}"/*/; do
    if [[ -d "${dir}bin" ]]; then
        ARCHIVE_DIR="${dir%/}"
        break
    fi
done

if [[ -z "${ARCHIVE_DIR}" ]]; then
    echo "  ERROR: Could not find IHS directory inside ZIP." >&2
    rm -rf "${IHS_STAGING}"
    exit 1
fi

mkdir -p "$(dirname "${IHS_INSTALL_ROOT}")"
mv "${ARCHIVE_DIR}" "${IHS_INSTALL_ROOT}"
rm -rf "${IHS_STAGING}"
echo "      Installed to ${IHS_INSTALL_ROOT}"

# ---------------------------------------------------------------------------
# 3. Install WAS plugin (mod_was_ap24_http.so)
# ---------------------------------------------------------------------------
echo "[3/3] Installing WAS plugin..."

WAS_PLUGIN_SRC=$(find "${IHS_INSTALLER_DIR}" -name "mod_was_ap24_http.so" 2>/dev/null | head -1)

if [[ -n "${WAS_PLUGIN_SRC}" ]]; then
    cp "${WAS_PLUGIN_SRC}" "${IHS_INSTALL_ROOT}/modules/mod_was_ap24_http.so"
else
    PLUGIN_ENTRY=$(unzip -l "${IHS_ZIP}" 2>/dev/null | grep "mod_was_ap24_http.so" | awk '{print $NF}' | head -1)
    if [[ -n "${PLUGIN_ENTRY}" ]]; then
        unzip -q -j "${IHS_ZIP}" "${PLUGIN_ENTRY}" -d "${IHS_INSTALL_ROOT}/modules/"
    else
        echo "  WARNING: mod_was_ap24_http.so not found — plugin not installed." >&2
    fi
fi
echo "      ${IHS_INSTALL_ROOT}/modules/mod_was_ap24_http.so"

# ---------------------------------------------------------------------------
# 4. Add IHS to PATH
# ---------------------------------------------------------------------------
if ! grep -qF "${IHS_INSTALL_ROOT}/bin" ~/.bashrc; then
    echo "export PATH=\"${IHS_INSTALL_ROOT}/bin:\$PATH\"" >> ~/.bashrc
    echo "      Added IHS bin to ~/.bashrc"
fi
# Make apachectl available in the current session immediately
export PATH="${IHS_INSTALL_ROOT}/bin:${PATH}"

echo ""
echo "=== Done. IHS installed at ${IHS_INSTALL_ROOT} ==="
echo ""
echo "  NOTE: If you opened a new terminal after running this script,"
echo "        run: source ~/.bashrc"
echo ""
