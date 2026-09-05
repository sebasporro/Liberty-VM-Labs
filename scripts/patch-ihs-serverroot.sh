#!/bin/bash
# =============================================================================
# patch-ihs-serverroot.sh
# Fixes IHS bin/ wrapper scripts after ZIP extraction.
#
# The IHS ARCHIVE ZIP ships wrapper scripts with unresolved tokens that IBM
# Installation Manager substitutes at install time. When extracting the
# archive directly these must be patched manually:
#
#   @@SERVERROOT@@       → actual IHS install root  (gskcapicmd, apachectl, etc.)
#   @@SHLIBPATH_ENVAR@@  → LD_LIBRARY_PATH           (gsk_envvars)
#
# Additionally, the ARCHIVE ZIP stores GSKit binaries in a hidden directory
# (.gsk8/) but the wrapper scripts reference a non-hidden path (gsk8/).
# This script creates a gsk8 → .gsk8 symlink to resolve the mismatch.
#
# Safe to run multiple times (idempotent).
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
echo "=== IHS bin/ patch ==="
echo "    Install root: ${IHS_ROOT}"
echo ""

if [[ ! -d "${IHS_ROOT}/bin" ]]; then
    echo "  ERROR: IHS bin directory not found at ${IHS_ROOT}/bin"
    echo "         Run scripts/install-ihs.sh first."
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Substitute all unresolved tokens in bin/ scripts
# ---------------------------------------------------------------------------
echo "[1/3] Substituting placeholder tokens in bin/ scripts..."
PATCHED=0
SKIPPED=0

while IFS= read -r -d '' f; do
    CHANGED=0
    # @@SERVERROOT@@ → IHS install root
    if grep -qF '@@SERVERROOT@@' "${f}" 2>/dev/null; then
        sed -i "s|@@SERVERROOT@@|${IHS_ROOT}|g" "${f}"
        CHANGED=1
    fi
    # @@SHLIBPATH_ENVAR@@ → LD_LIBRARY_PATH (Linux x86_64)
    if grep -qF '@@SHLIBPATH_ENVAR@@' "${f}" 2>/dev/null; then
        sed -i "s|@@SHLIBPATH_ENVAR@@|LD_LIBRARY_PATH|g" "${f}"
        CHANGED=1
    fi
    if [[ ${CHANGED} -eq 1 ]]; then
        echo "  Patched : $(basename "${f}")"
        (( PATCHED++ ))
    else
        (( SKIPPED++ ))
    fi
done < <(find "${IHS_ROOT}/bin" -maxdepth 1 -type f -print0)

echo "  ${PATCHED} file(s) patched, ${SKIPPED} already clean."
echo ""

# ---------------------------------------------------------------------------
# 2. Create gsk8 → .gsk8 symlink
#
#    The ARCHIVE ZIP stores GSKit in a hidden directory (.gsk8/) but the
#    wrapper scripts reference gsk8/ (no leading dot). Create a symlink so
#    both paths resolve to the same location.
# ---------------------------------------------------------------------------
echo "[2/3] Resolving gsk8 → .gsk8 path..."
GSK8_HIDDEN="${IHS_ROOT}/.gsk8"
GSK8_VISIBLE="${IHS_ROOT}/gsk8"

if [[ -d "${GSK8_HIDDEN}" ]]; then
    if [[ -L "${GSK8_VISIBLE}" ]]; then
        echo "  Symlink already exists: gsk8 → .gsk8"
    elif [[ -d "${GSK8_VISIBLE}" ]]; then
        echo "  gsk8/ directory already present — no symlink needed."
    else
        ln -s "${GSK8_HIDDEN}" "${GSK8_VISIBLE}"
        echo "  Created symlink: ${GSK8_VISIBLE} → ${GSK8_HIDDEN}"
    fi
elif [[ -d "${GSK8_VISIBLE}" ]]; then
    echo "  gsk8/ directory present (no hidden dir) — OK."
else
    echo "  WARNING: Neither gsk8/ nor .gsk8/ found under ${IHS_ROOT}"
    echo "           gskcapicmd will not be able to locate GSKit binaries."
fi

# Fix execute permissions on GSKit binaries — the ARCHIVE ZIP ships them
# as non-executable (644). chmod +x the bin/ directory.
GSK8_BIN="${IHS_ROOT}/gsk8/bin"
if [[ -d "${GSK8_BIN}" ]]; then
    chmod +x "${GSK8_BIN}"/gsk8capicmd_64 \
              "${GSK8_BIN}"/gsk8ver_64 \
              "${GSK8_BIN}"/private_verifyinstall_64 2>/dev/null || true
    echo "  chmod +x : ${GSK8_BIN}/gsk8capicmd_64"
fi
echo ""

# ---------------------------------------------------------------------------
# 3. Smoke-test gskcapicmd
# ---------------------------------------------------------------------------
echo "[3/3] Smoke-testing gskcapicmd..."
GSKCAPICMD="${IHS_ROOT}/bin/gskcapicmd"
if [[ ! -x "${GSKCAPICMD}" ]]; then
    echo "  WARNING: gskcapicmd not found at ${GSKCAPICMD}"
else
    if "${GSKCAPICMD}" -version >/dev/null 2>&1; then
        echo "  gskcapicmd : functional ✓"
    else
        echo "  ERROR: gskcapicmd still fails. Output:"
        "${GSKCAPICMD}" -version 2>&1 | head -5 | sed 's/^/    /'
        echo ""
        echo "  Check that ${IHS_ROOT}/gsk8/bin/gsk8capicmd_64 exists:"
        ls -la "${IHS_ROOT}/gsk8/bin/" 2>/dev/null | sed 's/^/    /' || \
            echo "    (directory not found)"
    fi
fi
echo ""
