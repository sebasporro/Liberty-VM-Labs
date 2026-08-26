#!/bin/bash
# 01-install-runtime-25.sh — Extract WebSphere Liberty Base 25.0.0.1 into wlp-25/
# Usage: bash scripts/01-install-runtime-25.sh
#
# The installer JAR path defaults to the TechZone VM pre-provisioned location.
# Override by setting LIBERTY_INSTALLER_25 before running:
#   export LIBERTY_INSTALLER_25=/path/to/wlp-base-all-25.0.0.1.jar

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

INSTALLER_JAR="${LIBERTY_INSTALLER_25:-/home/itz/software/Liberty/Liberty/wlp-base-all-25.0.0.1.jar}"
WLP25_HOME="${WORKSPACE_ROOT}/wlp-25"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
echo "==> [01-25] Checking Java 17..."
"${JAVA_HOME}/bin/java" -version 2>&1 | head -1

echo "==> [01-25] Checking installer JAR..."
if [[ ! -f "${INSTALLER_JAR}" ]]; then
  echo "ERROR: Installer JAR not found at: ${INSTALLER_JAR}" >&2
  echo "       Locate the JAR and re-run with:" >&2
  echo "       export LIBERTY_INSTALLER_25=/path/to/wlp-base-all-25.0.0.1.jar" >&2
  echo "       Hint: find / -name 'wlp-base-all-25.0.0.1.jar' 2>/dev/null" >&2
  exit 1
fi

if [[ -x "${WLP25_HOME}/bin/server" ]]; then
  echo "==> [01-25] Liberty 25.0.0.1 runtime already installed at ${WLP25_HOME} — skipping."
  echo "           Remove ${WLP25_HOME} to re-install."
  exit 0
fi

# ---------------------------------------------------------------------------
# Extract Liberty runtime into wlp-25/
# The JAR installer extracts a wlp/ subtree; we redirect into a temp dir
# then rename to wlp-25/ so it coexists with the 26.0.0.8 runtime.
# ---------------------------------------------------------------------------
echo "==> [01-25] Extracting Liberty Base 25.0.0.1 into ${WLP25_HOME} ..."

EXTRACT_STAGING="${WORKSPACE_ROOT}/_wlp25_staging"
rm -rf "${EXTRACT_STAGING}"
mkdir -p "${EXTRACT_STAGING}"

"${JAVA_HOME}/bin/java" -jar "${INSTALLER_JAR}" \
  --acceptLicense \
  "${EXTRACT_STAGING}"

# The installer creates EXTRACT_STAGING/wlp/ — move it to wlp-25/
mv "${EXTRACT_STAGING}/wlp" "${WLP25_HOME}"
rm -rf "${EXTRACT_STAGING}"

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
echo "==> [01-25] Verifying installation..."

if [[ ! -x "${WLP25_HOME}/bin/server" ]]; then
  echo "ERROR: wlp-25/bin/server not found or not executable after extraction." >&2
  exit 1
fi
echo "    [OK] wlp-25/bin/server is executable"

if [[ ! -x "${WLP25_HOME}/bin/collective" ]]; then
  echo "ERROR: wlp-25/bin/collective not found — wrong edition (need WS Liberty Base/ND)." >&2
  exit 1
fi
echo "    [OK] wlp-25/bin/collective is present"

PROPS="${WLP25_HOME}/lib/versions/WebSphereApplicationServer.properties"
if [[ ! -f "${PROPS}" ]]; then
  echo "ERROR: Version properties not found: ${PROPS}" >&2
  exit 1
fi

VERSION=$(grep '^com.ibm.websphere.productVersion=' "${PROPS}" | cut -d= -f2)
echo "    [OK] Liberty version: ${VERSION}"

if [[ "${VERSION}" != "25.0.0.1" ]]; then
  echo "WARNING: Expected version 25.0.0.1 but found ${VERSION}" >&2
fi

echo ""
echo "==> [01-25] Liberty Base ${VERSION} installed successfully at: ${WLP25_HOME}"
