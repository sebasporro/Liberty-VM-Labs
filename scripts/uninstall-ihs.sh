#!/bin/bash
# =============================================================================
# uninstall-ihs.sh
# Completely removes IBM HTTP Server (IHS) — use before testing a fresh install.
#
# What it does:
#   1. Stops any running IHS/httpd processes
#   2. Removes the IHS installation directory
#   3. Removes the staging directory (if left over from a failed install)
#   4. Removes the PATH export from ~/.bashrc
#   5. Confirms clean state
#
# Usage:  scripts/uninstall-ihs.sh
# =============================================================================

IHS_INSTALL_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/IBM/HTTPServer}"
IHS_STAGING="${HOME}/Liberty-VM-Labs/_ihs_staging"

echo ""
echo "=== IBM HTTP Server — Uninstall ==="
echo ""

# ---------------------------------------------------------------------------
# 1. Stop IHS if running
# ---------------------------------------------------------------------------
echo "[1/4] Stopping IHS..."

if [[ -x "${IHS_INSTALL_ROOT}/bin/apachectl" ]]; then
    "${IHS_INSTALL_ROOT}/bin/apachectl" stop 2>/dev/null
    sleep 2
    echo "      apachectl stop: done"
fi

# Kill any remaining httpd processes from this IHS install
if pgrep -f "${IHS_INSTALL_ROOT}/bin/httpd" &>/dev/null; then
    pkill -f "${IHS_INSTALL_ROOT}/bin/httpd" 2>/dev/null
    sleep 1
    echo "      Remaining httpd processes killed"
else
    echo "      No running IHS processes found"
fi
echo ""

# ---------------------------------------------------------------------------
# 2. Remove IHS installation directory
# ---------------------------------------------------------------------------
echo "[2/4] Removing IHS installation..."

if [[ -d "${IHS_INSTALL_ROOT}" ]]; then
    rm -rf "${IHS_INSTALL_ROOT}"
    echo "      Removed: ${IHS_INSTALL_ROOT}"
else
    echo "      Not found: ${IHS_INSTALL_ROOT} — skipped"
fi

# Also remove the parent IBM/ dir if now empty
IBM_DIR="$(dirname "${IHS_INSTALL_ROOT}")"
if [[ -d "${IBM_DIR}" ]] && [[ -z "$(ls -A "${IBM_DIR}" 2>/dev/null)" ]]; then
    rm -rf "${IBM_DIR}"
    echo "      Removed empty parent: ${IBM_DIR}"
fi
echo ""

# ---------------------------------------------------------------------------
# 3. Remove staging directory
# ---------------------------------------------------------------------------
echo "[3/4] Removing staging directory..."

if [[ -d "${IHS_STAGING}" ]]; then
    rm -rf "${IHS_STAGING}"
    echo "      Removed: ${IHS_STAGING}"
else
    echo "      Not found: ${IHS_STAGING} — skipped"
fi
echo ""

# ---------------------------------------------------------------------------
# 4. Remove PATH export from ~/.bashrc
# ---------------------------------------------------------------------------
echo "[4/4] Cleaning ~/.bashrc..."

if grep -q "IBM/HTTPServer/bin" ~/.bashrc 2>/dev/null; then
    sed -i '/IBM\/HTTPServer\/bin/d' ~/.bashrc
    echo "      PATH entry removed from ~/.bashrc"
    # Reload to take effect in current shell
    # shellcheck disable=SC1090
    source ~/.bashrc 2>/dev/null
else
    echo "      No IHS PATH entry found in ~/.bashrc — skipped"
fi
echo ""

# ---------------------------------------------------------------------------
# Verify clean state
# ---------------------------------------------------------------------------
echo "--- Verify clean state ---"
echo ""

CLEAN=true

if [[ -d "${IHS_INSTALL_ROOT}" ]]; then
    echo "  [WARN] Install dir still exists: ${IHS_INSTALL_ROOT}"
    CLEAN=false
else
    echo "  [OK]   ${IHS_INSTALL_ROOT} removed"
fi

if pgrep -f "IBM/HTTPServer/bin/httpd" &>/dev/null; then
    echo "  [WARN] IHS httpd processes still running"
    pgrep -fa "IBM/HTTPServer/bin/httpd"
    CLEAN=false
else
    echo "  [OK]   No IHS httpd processes running"
fi

if command -v apachectl &>/dev/null; then
    echo "  [WARN] apachectl still found on PATH: $(command -v apachectl)"
    echo "         Open a new terminal or run: source ~/.bashrc"
    CLEAN=false
else
    echo "  [OK]   apachectl not on PATH"
fi

echo ""
if [[ "${CLEAN}" == "true" ]]; then
    echo "  IHS fully removed. Ready for a fresh install:"
    echo "    scripts/install-ihs.sh"
else
    echo "  One or more items above need attention before re-installing."
fi
echo ""
