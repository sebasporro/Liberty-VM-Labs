#!/bin/bash
# 01-install-runtime.sh — Extract Liberty ND 26.0.0.8 runtime into wlp-26/
# Usage: bash scripts/01-install-runtime.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

INSTALLER_JAR="/home/itz/software/Liberty/Liberty/wlp-nd-all-26.0.0.8.jar"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
echo "==> [01] Checking Java 17..."
"${JAVA_HOME}/bin/java" -version 2>&1 | head -1

echo "==> [01] Checking installer JAR..."
if [[ ! -f "${INSTALLER_JAR}" ]]; then
  echo "ERROR: Installer JAR not found at: ${INSTALLER_JAR}" >&2
  exit 1
fi

if [[ -x "${WLP_HOME}/bin/server" ]]; then
  echo "==> [01] Liberty runtime already installed at ${WLP_HOME} — skipping extraction."
  echo "         Remove ${WLP_HOME} to re-install."
  exit 0
fi

# ---------------------------------------------------------------------------
# Extract Liberty runtime
# The JAR installer always extracts into a wlp/ subdirectory of the target.
# We extract into a staging dir then rename to wlp-26/ so the directory name
# is consistent with wlp-25/ for Liberty 25.0.0.1.
# ---------------------------------------------------------------------------
echo "==> [01] Extracting Liberty ND 26.0.0.8 into ${WLP_HOME} ..."

EXTRACT_STAGING="${WORKSPACE_ROOT}/_wlp26_staging"
rm -rf "${EXTRACT_STAGING}"
mkdir -p "${EXTRACT_STAGING}"

"${JAVA_HOME}/bin/java" -jar "${INSTALLER_JAR}" \
  --acceptLicense \
  --verbose \
  "${EXTRACT_STAGING}"

# The installer creates EXTRACT_STAGING/wlp/ — move it to wlp-26/
mv "${EXTRACT_STAGING}/wlp" "${WLP_HOME}"
rm -rf "${EXTRACT_STAGING}"

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
echo "==> [01] Verifying installation..."

if [[ ! -x "${WLP_HOME}/bin/server" ]]; then
  echo "ERROR: wlp-26/bin/server not found or not executable after extraction." >&2
  exit 1
fi
echo "    [OK] wlp-26/bin/server is executable"

PROPS="${WLP_HOME}/lib/versions/WebSphereApplicationServer.properties"
if [[ ! -f "${PROPS}" ]]; then
  echo "ERROR: Version properties file not found: ${PROPS}" >&2
  exit 1
fi

VERSION=$(grep '^com.ibm.websphere.productVersion=' "${PROPS}" | cut -d= -f2)
echo "    [OK] Liberty version: ${VERSION}"

if [[ "${VERSION}" != "26.0.0.8" ]]; then
  echo "WARNING: Expected version 26.0.0.8 but found ${VERSION}" >&2
fi

echo ""
echo "==> [01] Liberty ND ${VERSION} installed successfully at: ${WLP_HOME}"
