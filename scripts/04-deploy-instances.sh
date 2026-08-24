#!/bin/zsh
# 04-deploy-instances.sh — Deploy controller, member1, member2 from package
# Usage: ./scripts/04-deploy-instances.sh
# Requires: packages/liberty-package-26.0.0.8.zip (built by Sub-Task 3)

set -euo pipefail

source "$(dirname "$0")/00-set-env.sh"

PACKAGE="${WORKSPACE_ROOT}/packages/liberty-package-26.0.0.8.zip"
CONFIG_DIR="${WORKSPACE_ROOT}/config"
INSTALLS_DIR="${WORKSPACE_ROOT}/installs"
TEMPLATE_SERVER="template-26.0.0.8"

# ---------------------------------------------------------------------------
# Per-instance configuration
# ---------------------------------------------------------------------------
declare -A HTTP_PORT=(  [controller]=9080 [member1]=9081 [member2]=9082 )
declare -A HTTPS_PORT=( [controller]=9443 [member1]=9444 [member2]=9445 )
declare -A KS_PASS=(    [controller]="Liberty26ctrl!" [member1]="Liberty26mbr1!" [member2]="Liberty26mbr2!" )

INSTANCES=(controller member1 member2)

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [[ ! -f "${PACKAGE}" ]]; then
  echo "[04-deploy] ERROR: Package not found: ${PACKAGE}" >&2
  exit 1
fi

echo "[04-deploy] Using package: ${PACKAGE}"
echo "[04-deploy] JAVA_HOME    : ${JAVA_HOME}"
echo ""

# ---------------------------------------------------------------------------
# Deploy loop
# ---------------------------------------------------------------------------
for INSTANCE in "${INSTANCES[@]}"; do
  INST_DIR="${INSTALLS_DIR}/${INSTANCE}"
  SERVER_DIR="${INST_DIR}/wlp/usr/servers/${INSTANCE}"
  OVERRIDES_DIR="${SERVER_DIR}/configDropins/overrides"

  echo "──────────────────────────────────────────────"
  echo "[04-deploy] Deploying instance: ${INSTANCE}"
  echo "──────────────────────────────────────────────"

  # 1. Clean and recreate the instance directory
  echo "[04-deploy]   Cleaning ${INST_DIR}..."
  rm -rf "${INST_DIR}"
  mkdir -p "${INST_DIR}"

  # 2. Unzip package into instance directory
  echo "[04-deploy]   Unzipping package..."
  unzip -q "${PACKAGE}" -d "${INST_DIR}/"

  # 3. Rename template server to instance name
  TEMPLATE_DIR="${INST_DIR}/wlp/usr/servers/${TEMPLATE_SERVER}"
  if [[ ! -d "${TEMPLATE_DIR}" ]]; then
    echo "[04-deploy] ERROR: Expected server dir not found: ${TEMPLATE_DIR}" >&2
    exit 1
  fi
  echo "[04-deploy]   Renaming server '${TEMPLATE_SERVER}' -> '${INSTANCE}'..."
  mv "${TEMPLATE_DIR}" "${SERVER_DIR}"

  # 4. Create configDropins/overrides directory
  echo "[04-deploy]   Creating configDropins/overrides/..."
  mkdir -p "${OVERRIDES_DIR}"

  # 5. Copy role and port override XML files
  echo "[04-deploy]   Copying config overrides from config/${INSTANCE}/..."
  cp "${CONFIG_DIR}/${INSTANCE}/role-override.xml"  "${OVERRIDES_DIR}/role-override.xml"
  cp "${CONFIG_DIR}/${INSTANCE}/ports-override.xml" "${OVERRIDES_DIR}/ports-override.xml"

  # 6. Write per-instance bootstrap.properties
  echo "[04-deploy]   Writing bootstrap.properties..."
  cat > "${SERVER_DIR}/bootstrap.properties" <<BOOTSTRAP
default.http.port=${HTTP_PORT[$INSTANCE]}
default.https.port=${HTTPS_PORT[$INSTANCE]}
keystore.password=${KS_PASS[$INSTANCE]}
admin.password=admin
BOOTSTRAP

  echo "[04-deploy]   Done: ${INSTANCE}"
  echo ""
done

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
echo "──────────────────────────────────────────────"
echo "[04-deploy] Verifying deployed instances..."
echo "──────────────────────────────────────────────"

FAIL=0
for INSTANCE in "${INSTANCES[@]}"; do
  SERVER_DIR="${INSTALLS_DIR}/${INSTANCE}/wlp/usr/servers/${INSTANCE}"
  OVERRIDES_DIR="${SERVER_DIR}/configDropins/overrides"
  for EXPECTED in \
      "${SERVER_DIR}" \
      "${OVERRIDES_DIR}/role-override.xml" \
      "${OVERRIDES_DIR}/ports-override.xml" \
      "${SERVER_DIR}/bootstrap.properties"; do
    if [[ -e "${EXPECTED}" ]]; then
      echo "[04-deploy]   OK  : ${EXPECTED#${WORKSPACE_ROOT}/}"
    else
      echo "[04-deploy]   MISS: ${EXPECTED#${WORKSPACE_ROOT}/}" >&2
      FAIL=1
    fi
  done
done

echo ""
if [[ ${FAIL} -eq 0 ]]; then
  echo "[04-deploy] All instances deployed successfully."
else
  echo "[04-deploy] ERROR: One or more expected paths are missing. See above." >&2
  exit 1
fi
