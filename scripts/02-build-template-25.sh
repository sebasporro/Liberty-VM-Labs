#!/bin/bash
# 02-build-template-25.sh — Create and stage the role-neutral template server for 25.0.0.1
# Usage: zsh scripts/02-build-template-25.sh
#
# Mirrors 02-build-template.sh exactly but targets wlp-25/ and template-25.0.0.1.
# Uses the same config/template/ source files — features servlet-6.0, pages-3.1,
# expressionLanguage-5.0 are also present in Liberty Base 25.0.0.1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

WLP25_HOME="${WORKSPACE_ROOT}/wlp-25"
SERVER_NAME="template-25.0.0.1"
SERVER_DIR="${WLP25_HOME}/usr/servers/${SERVER_NAME}"
CONFIG_SRC="${WORKSPACE_ROOT}/config/template"
WAR_SRC="${WORKSPACE_ROOT}/App/server-info.war"

echo "=== 02-build-template-25: building ${SERVER_NAME} ==="
echo "    WLP25_HOME    = ${WLP25_HOME}"
echo "    JAVA_HOME     = ${JAVA_HOME}"
echo ""

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
if [[ ! -x "${WLP25_HOME}/bin/server" ]]; then
  echo "ERROR: wlp-25/bin/server not found." >&2
  echo "Run scripts/01-install-runtime-25.sh first." >&2
  exit 1
fi

if [[ ! -f "${WAR_SRC}" ]]; then
  echo "ERROR: App/server-info.war not found at ${WAR_SRC}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 1 — Create server (idempotent)
# ---------------------------------------------------------------------------
if [[ -d "${SERVER_DIR}" ]]; then
  echo "[1/4] Server directory already exists — skipping create."
else
  echo "[1/4] Creating server ${SERVER_NAME}..."
  "${WLP25_HOME}/bin/server" create "${SERVER_NAME}"
fi

# ---------------------------------------------------------------------------
# Step 2 — Stage configuration files
# ---------------------------------------------------------------------------
echo "[2/4] Copying config files from ${CONFIG_SRC}..."
cp "${CONFIG_SRC}/server.xml"           "${SERVER_DIR}/server.xml"
cp "${CONFIG_SRC}/bootstrap.properties" "${SERVER_DIR}/bootstrap.properties"
cp "${CONFIG_SRC}/jvm.options"          "${SERVER_DIR}/jvm.options"

# Update the server description to reflect 25.0.0.1
sed -i 's/Liberty Template Server 26.0.0.8/Liberty Template Server 25.0.0.1/' \
  "${SERVER_DIR}/server.xml"

# ---------------------------------------------------------------------------
# Step 3 — Stage application WAR
# ---------------------------------------------------------------------------
echo "[3/4] Staging server-info.war..."
mkdir -p "${SERVER_DIR}/apps"
cp "${WAR_SRC}" "${SERVER_DIR}/apps/server-info.war"

# ---------------------------------------------------------------------------
# Step 4 — Quick status check
# ---------------------------------------------------------------------------
echo "[4/4] Verifying server status..."
"${WLP25_HOME}/bin/server" status "${SERVER_NAME}" || true

echo ""
echo "=== 02-build-template-25: DONE ==="
echo "    Server directory : ${SERVER_DIR}"
echo "    server.xml       : $(ls -lh "${SERVER_DIR}/server.xml" | awk '{print $5, $9}')"
echo "    server-info.war  : $(ls -lh "${SERVER_DIR}/apps/server-info.war" | awk '{print $5, $9}')"
