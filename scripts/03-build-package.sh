#!/bin/bash
# 03-build-package.sh — Package the Liberty template server into a self-contained ZIP
#
# Output: packages/liberty-package-26.0.0.8.zip
#   - Contains the full Liberty runtime + usr directory (config + apps)
#   - Equivalent to a "golden image" that Sub-Task 4 stamps out 3 times
#
# Usage: bash scripts/03-build-package.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SERVER_NAME="template-26.0.0.8"
PACKAGES_DIR="${WORKSPACE_ROOT}/packages"
ARCHIVE="${PACKAGES_DIR}/liberty-package-26.0.0.8.zip"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [[ ! -d "${WLP_HOME}/usr/servers/${SERVER_NAME}" ]]; then
  echo "[03] ERROR: Server directory not found: ${WLP_HOME}/usr/servers/${SERVER_NAME}" >&2
  echo "[03] Run Sub-Task 2 first to create the template server." >&2
  exit 1
fi

if [[ ! -f "${WLP_HOME}/usr/servers/${SERVER_NAME}/apps/server-info.war" ]]; then
  echo "[03] ERROR: server-info.war missing from apps directory." >&2
  echo "[03] Ensure Sub-Task 2 completed successfully." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Create output directory
# ---------------------------------------------------------------------------
mkdir -p "${PACKAGES_DIR}"

# ---------------------------------------------------------------------------
# Package the server
# ---------------------------------------------------------------------------
echo "[03] Packaging ${SERVER_NAME} → ${ARCHIVE}"
echo "[03] This bundles the full Liberty runtime + config + apps (~400 MB)."

"${WLP_HOME}/bin/server" package "${SERVER_NAME}" \
  --include=all \
  --archive="${ARCHIVE}"

# ---------------------------------------------------------------------------
# Verify the archive
# ---------------------------------------------------------------------------
echo ""
echo "[03] Verifying archive …"

if [[ ! -f "${ARCHIVE}" ]]; then
  echo "[03] ERROR: Archive not created: ${ARCHIVE}" >&2
  exit 1
fi

ARCHIVE_SIZE=$(du -sh "${ARCHIVE}" | awk '{print $1}')
echo "[03] Archive size : ${ARCHIVE_SIZE}"

# Spot-check for key entries (grep -c; pipefail-safe via explicit exit-code check)
for ENTRY in \
  "wlp/usr/servers/${SERVER_NAME}/server.xml" \
  "wlp/usr/servers/${SERVER_NAME}/bootstrap.properties" \
  "wlp/usr/servers/${SERVER_NAME}/apps/server-info.war"; do
  HITS=$(unzip -l "${ARCHIVE}" | grep -c "${ENTRY}" || true)
  if [[ "${HITS}" -ge 1 ]]; then
    echo "[03] ✓  ${ENTRY}"
  else
    echo "[03] ERROR: Expected entry not found in archive: ${ENTRY}" >&2
    exit 1
  fi
done

echo ""
echo "[03] Sub-Task 3 complete. Golden package ready at:"
echo "     ${ARCHIVE}"
