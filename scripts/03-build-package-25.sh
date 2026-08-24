#!/bin/zsh
# 03-build-package-25.sh — Package the Liberty 25.0.0.1 template into a golden artifact ZIP
#
# Output: packages/liberty-package-25.0.0.1.zip
#   - Full Liberty Base 25.0.0.1 runtime + config + server-info.war
#   - Used by add-member-25.sh to deploy member3 and member4
#
# Usage: zsh scripts/03-build-package-25.sh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
source "${SCRIPT_DIR}/00-set-env.sh"

WLP25_HOME="${WORKSPACE_ROOT}/wlp-25"
SERVER_NAME="template-25.0.0.1"
PACKAGES_DIR="${WORKSPACE_ROOT}/packages"
ARCHIVE="${PACKAGES_DIR}/liberty-package-25.0.0.1.zip"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [[ ! -d "${WLP25_HOME}/usr/servers/${SERVER_NAME}" ]]; then
  echo "[03-25] ERROR: Server directory not found: ${WLP25_HOME}/usr/servers/${SERVER_NAME}" >&2
  echo "[03-25] Run scripts/02-build-template-25.sh first." >&2
  exit 1
fi

if [[ ! -f "${WLP25_HOME}/usr/servers/${SERVER_NAME}/apps/server-info.war" ]]; then
  echo "[03-25] ERROR: server-info.war missing from apps directory." >&2
  echo "[03-25] Ensure 02-build-template-25.sh completed successfully." >&2
  exit 1
fi

mkdir -p "${PACKAGES_DIR}"

# ---------------------------------------------------------------------------
# Package the server
# ---------------------------------------------------------------------------
echo "[03-25] Packaging ${SERVER_NAME} → ${ARCHIVE}"
echo "[03-25] This bundles the full Liberty 25.0.0.1 runtime + config + apps."

"${WLP25_HOME}/bin/server" package "${SERVER_NAME}" \
  --include=all \
  --archive="${ARCHIVE}"

# ---------------------------------------------------------------------------
# Verify the archive
# ---------------------------------------------------------------------------
echo ""
echo "[03-25] Verifying archive..."

if [[ ! -f "${ARCHIVE}" ]]; then
  echo "[03-25] ERROR: Archive not created: ${ARCHIVE}" >&2
  exit 1
fi

ARCHIVE_SIZE=$(du -sh "${ARCHIVE}" | awk '{print $1}')
echo "[03-25] Archive size : ${ARCHIVE_SIZE}"

for ENTRY in \
  "wlp/usr/servers/${SERVER_NAME}/server.xml" \
  "wlp/usr/servers/${SERVER_NAME}/bootstrap.properties" \
  "wlp/usr/servers/${SERVER_NAME}/apps/server-info.war"; do
  HITS=$(unzip -l "${ARCHIVE}" | grep -c "${ENTRY}" || true)
  if [[ "${HITS}" -ge 1 ]]; then
    echo "[03-25] ✓  ${ENTRY}"
  else
    echo "[03-25] ERROR: Expected entry not found in archive: ${ENTRY}" >&2
    exit 1
  fi
done

echo ""
echo "[03-25] Golden package (25.0.0.1) ready at:"
echo "        ${ARCHIVE}"
