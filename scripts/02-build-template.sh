#!/bin/bash
# 02-build-template.sh — Create and stage the role-neutral template server
# Usage: bash scripts/02-build-template.sh
#
# What this script does:
#   1. Sources 00-set-env.sh to set JAVA_HOME, WLP_HOME, WORKSPACE_ROOT
#   2. Creates the Liberty server 'template-26.0.0.8' (idempotent — skips if exists)
#   3. Overwrites server.xml, bootstrap.properties, and jvm.options from config/template/
#   4. Stages App/server-info.war and App/WhereAmI.war into the server's apps/ directory
#
# No collective role is assigned here — configDropins/overrides/ is populated
# per-instance at deploy time (Sub-Task 4).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

SERVER_NAME="template-26.0.0.8"
SERVER_DIR="${WLP_HOME}/usr/servers/${SERVER_NAME}"
CONFIG_SRC="${WORKSPACE_ROOT}/config/template"
WAR_SRC="${WORKSPACE_ROOT}/App/server-info.war"
WHEREAMI_SRC="${WORKSPACE_ROOT}/App/WhereAmI.war"

echo "=== 02-build-template: building ${SERVER_NAME} ==="
echo "    WLP_HOME      = ${WLP_HOME}"
echo "    JAVA_HOME     = ${JAVA_HOME}"
echo ""

# ---------------------------------------------------------------------------
# Step 1 — Create server (idempotent)
# ---------------------------------------------------------------------------
if [[ -d "${SERVER_DIR}" ]]; then
  echo "[1/5] Server directory already exists — skipping create."
else
  echo "[1/5] Creating server ${SERVER_NAME}..."
  "${WLP_HOME}/bin/server" create "${SERVER_NAME}"
fi

# ---------------------------------------------------------------------------
# Step 2 — Stage configuration files
# ---------------------------------------------------------------------------
echo "[2/5] Copying config files from ${CONFIG_SRC}..."
cp "${CONFIG_SRC}/server.xml"            "${SERVER_DIR}/server.xml"
cp "${CONFIG_SRC}/bootstrap.properties"  "${SERVER_DIR}/bootstrap.properties"
cp "${CONFIG_SRC}/jvm.options"           "${SERVER_DIR}/jvm.options"

# ---------------------------------------------------------------------------
# Step 3 — Stage application WARs
# ---------------------------------------------------------------------------
echo "[3/5] Staging server-info.war and WhereAmI.war..."
mkdir -p "${SERVER_DIR}/apps"
cp "${WAR_SRC}"       "${SERVER_DIR}/apps/server-info.war"
cp "${WHEREAMI_SRC}"  "${SERVER_DIR}/apps/WhereAmI.war"

# ---------------------------------------------------------------------------
# Step 4 — Quick status check
# ---------------------------------------------------------------------------
echo "[4/5] Verifying server status..."
"${WLP_HOME}/bin/server" status "${SERVER_NAME}" || true

echo ""
echo "[5/5] Staged apps:"
echo "    server-info.war : $(ls -lh "${SERVER_DIR}/apps/server-info.war" | awk '{print $5, $9}')"
echo "    WhereAmI.war    : $(ls -lh "${SERVER_DIR}/apps/WhereAmI.war"    | awk '{print $5, $9}')"
echo ""
echo "=== 02-build-template: DONE ==="
echo "    Server directory : ${SERVER_DIR}"
echo "    server.xml       : $(ls -lh "${SERVER_DIR}/server.xml" | awk '{print $5, $9}')"
