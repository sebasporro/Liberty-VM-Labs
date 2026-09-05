#!/bin/bash
# =============================================================================
# patch-ihs-serverroot.sh
# Substitutes the @@SERVERROOT@@ placeholder in IHS bin/ wrapper scripts.
#
# The IHS ARCHIVE ZIP ships scripts (gskcapicmd, etc.) with @@SERVERROOT@@
# as a literal token. IBM Installation Manager replaces it at install time.
# When the archive is extracted directly (without IM) the token is left as-is,
# causing the scripts to fail with "No such file or directory".
#
# This script performs the same substitution against the live IHS install.
# Safe to run multiple times (idempotent — skips files already patched).
#
# Usage:
#   scripts/patch-ihs-serverroot.sh
#
# Override install root:
#   IHS_INSTALL_ROOT=/path/to/ihs scripts/patch-ihs-serverroot.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/IBM/HTTPServer}"

echo ""
echo "=== IHS @@SERVERROOT@@ patch ==="
echo "    Install root: ${IHS_ROOT}"
echo ""

if [[ ! -d "${IHS_ROOT}/bin" ]]; then
    echo "  ERROR: IHS bin directory not found at ${IHS_ROOT}/bin"
    echo "         Run scripts/install-ihs.sh first."
    exit 1
fi

PATCHED=0
SKIPPED=0

while IFS= read -r -d '' f; do
    if grep -qF '@@SERVERROOT@@' "${f}" 2>/dev/null; then
        sed -i "s|@@SERVERROOT@@|${IHS_ROOT}|g" "${f}"
        echo "  Patched : $(basename "${f}")"
        (( PATCHED++ ))
    else
        (( SKIPPED++ ))
    fi
done < <(find "${IHS_ROOT}/bin" -maxdepth 1 -type f -print0)

echo ""
if [[ ${PATCHED} -gt 0 ]]; then
    echo "  ${PATCHED} file(s) patched, ${SKIPPED} already clean."
else
    echo "  Nothing to patch — all bin/ scripts already clean (${SKIPPED} files checked)."
fi

# Smoke-test gskcapicmd
GSKCAPICMD="${IHS_ROOT}/bin/gskcapicmd"
if [[ -x "${GSKCAPICMD}" ]]; then
    if "${GSKCAPICMD}" -version >/dev/null 2>&1; then
        echo "  gskcapicmd : functional ✓"
    else
        echo "  WARNING: gskcapicmd still fails — check ${GSKCAPICMD} manually."
        echo "           Run: head -20 ${GSKCAPICMD}"
    fi
fi
echo ""
