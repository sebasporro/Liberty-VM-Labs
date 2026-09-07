#!/bin/bash
# =============================================================================
# step2-dynamic-routing.sh
# Enables Liberty Intelligent Management dynamic routing.
#
# The controller already has dynamicRouting-1.0 + restConnector-2.0 declared
# in config/controller/role-override.xml — no dropin changes are needed.
#
# What this script does:
#   1. Runs 'dynamicRouting setup' against the controller (HTTPS 9443)
#   2. Converts the generated plugin-key.p12 (PKCS12) → plugin-key.kdb (CMS)
#   3. Installs plugin-cfg.xml + key files into $IHS_ROOT/config/webserver1/
#   4. Wires WebSpherePluginConfig in httpd.conf, restarts IHS
#   5. Patches the ODR connector to HTTP:9080 (avoids collective CA trust issues)
#
# Usage:  scripts/step2-dynamic-routing.sh
#
# Prerequisites:
#   - scripts/install-controller.sh completed (controller on HTTPS 9443)
#   - scripts/add-member-26.sh member1 completed (at least one member joined)
#   - scripts/install-ihs.sh completed (gskcapicmd functional)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/IBM/HTTPServer}"
CONTROLLER_DIR="${WORKSPACE_ROOT}/installs/controller"
WLP_BIN="${CONTROLLER_DIR}/wlp/bin"
PLUGIN_DIR="${IHS_ROOT}/config/webserver1"
HTTPD_CONF="${IHS_ROOT}/conf/httpd.conf"
APACHECTL="${IHS_ROOT}/bin/apachectl"
GSKCAPICMD="${IHS_ROOT}/bin/gskcapicmd"
SCRATCH_DIR="/tmp/liberty-dr-$$"
KEYSTORE_PASS="Liberty26ctrl!"

echo ""
echo "=== Step 2: Enable Dynamic Routing (Intelligent Management) ==="
echo ""

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [[ ! -x "${WLP_BIN}/dynamicRouting" ]]; then
    echo "ERROR: dynamicRouting binary not found at ${WLP_BIN}/dynamicRouting"
    echo "       Run scripts/install-controller.sh first."
    exit 1
fi

if [[ ! -x "${GSKCAPICMD}" ]]; then
    echo "ERROR: gskcapicmd not found at ${GSKCAPICMD}"
    echo "       Run scripts/install-ihs.sh first."
    exit 1
fi

if ! curl -k -s -o /dev/null -w "%{http_code}" https://localhost:9443/adminCenter 2>/dev/null | grep -qE "^(200|302)$"; then
    echo "ERROR: Controller is not responding on HTTPS 9443."
    echo "       Run scripts/install-controller.sh first."
    exit 1
fi

mkdir -p "${PLUGIN_DIR}" "${SCRATCH_DIR}"

# ---------------------------------------------------------------------------
# Pre-create odr-trace.xml that the ODR library looks for at startup.
# The WAS Plugins package ships this under $pluginInstallRoot/properties/.
# When --pluginInstallRoot points at the IHS root (not a separate Plugins
# install) that directory does not exist and the ODR library fails with:
#   "Failed to open odr-trace.xml" → "Failed to create ODR environment"
# Creating a minimal valid file at that path is all that is required.
# ---------------------------------------------------------------------------
mkdir -p "${IHS_ROOT}/properties"
if [[ ! -f "${IHS_ROOT}/properties/odr-trace.xml" ]]; then
    cat > "${IHS_ROOT}/properties/odr-trace.xml" <<'ODR_TRACE_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<TraceSpecification>
    <Component name="default" specification=":INFO"/>
</TraceSpecification>
ODR_TRACE_EOF
    echo "      Created ${IHS_ROOT}/properties/odr-trace.xml"
fi

# ---------------------------------------------------------------------------
# 1. Run dynamicRouting setup
# ---------------------------------------------------------------------------
echo "[1/4] Running dynamicRouting setup..."
cd "${SCRATCH_DIR}"
"${WLP_BIN}/dynamicRouting" setup \
    --host=localhost \
    --port=9443 \
    --user=admin \
    --password=admin \
    --keystorePassword="${KEYSTORE_PASS}" \
    --pluginInstallRoot="${IHS_ROOT}" \
    --webServerNames=webserver1 \
    --autoAcceptCertificates
DR_RC=$?

if [[ ${DR_RC} -ne 0 ]]; then
    echo "ERROR: dynamicRouting setup exited with code ${DR_RC}."
    exit 1
fi
if [[ ! -f "${SCRATCH_DIR}/plugin-cfg.xml" ]]; then
    echo "ERROR: dynamicRouting setup succeeded but plugin-cfg.xml was not produced."
    echo "       Check that --pluginInstallRoot and --webServerNames are correct."
    exit 1
fi
echo "      dynamicRouting setup complete"
echo ""

# ---------------------------------------------------------------------------
# 2. Convert plugin-key.p12 (PKCS12) → plugin-key.kdb (CMS)
# ---------------------------------------------------------------------------
echo "[2/4] Converting plugin keystore (PKCS12 → CMS)..."
"${GSKCAPICMD}" -keydb -convert \
    -pw "${KEYSTORE_PASS}" \
    -db "${SCRATCH_DIR}/plugin-key.p12" \
    -old_format pkcs12 \
    -target "${SCRATCH_DIR}/plugin-key.kdb" \
    -new_format cms \
    -stash

"${GSKCAPICMD}" -cert -setdefault \
    -pw "${KEYSTORE_PASS}" \
    -db "${SCRATCH_DIR}/plugin-key.kdb" \
    -label default

# IBM docs require chown of the generated keystore files to match the IHS
# User/Group in httpd.conf.  On this single-VM lab both IHS and Liberty run
# as itzuser, so the files are already correctly owned; the chown is explicit
# for compliance with the documented procedure.
IHS_USER=$(grep -E "^User " "${HTTPD_CONF}" | awk '{print $2}')
IHS_GROUP=$(grep -E "^Group " "${HTTPD_CONF}" | awk '{print $2}')
if [[ -n "${IHS_USER}" && -n "${IHS_GROUP}" ]]; then
    chown "${IHS_USER}:${IHS_GROUP}" \
        "${SCRATCH_DIR}/plugin-key.kdb" \
        "${SCRATCH_DIR}/plugin-key.rdb" \
        "${SCRATCH_DIR}/plugin-key.sth" 2>/dev/null || true
    echo "      chown ${IHS_USER}:${IHS_GROUP} applied to keystore files"
fi

echo "      Keystore conversion complete"
echo ""

# ---------------------------------------------------------------------------
# 3. Install plugin files into $IHS_ROOT/config/webserver1/
# ---------------------------------------------------------------------------
echo "[3/4] Installing plugin files to ${PLUGIN_DIR}..."
cp "${SCRATCH_DIR}/plugin-cfg.xml"  "${PLUGIN_DIR}/plugin-cfg.xml"
cp "${SCRATCH_DIR}/plugin-key.kdb"  "${PLUGIN_DIR}/plugin-key.kdb"
cp "${SCRATCH_DIR}/plugin-key.rdb"  "${PLUGIN_DIR}/plugin-key.rdb" 2>/dev/null || true
cp "${SCRATCH_DIR}/plugin-key.sth"  "${PLUGIN_DIR}/plugin-key.sth"
echo "      Files installed"
# Return to SCRIPT_DIR before removing SCRATCH_DIR — deleting the cwd causes
# every subsequent subprocess to fail with "getcwd: cannot access parent directories".
cd "${SCRIPT_DIR}"
rm -rf "${SCRATCH_DIR}"
echo ""

# ---------------------------------------------------------------------------
# 4. Wire WebSpherePluginConfig in httpd.conf and restart IHS
# ---------------------------------------------------------------------------
echo "[4/4] Updating httpd.conf and restarting IHS..."
PLUGIN_CFG_LINE="WebSpherePluginConfig ${PLUGIN_DIR}/plugin-cfg.xml"
if grep -q "^WebSpherePluginConfig" "${HTTPD_CONF}"; then
    sed -i "s|^WebSpherePluginConfig .*|${PLUGIN_CFG_LINE}|" "${HTTPD_CONF}"
    echo "      WebSpherePluginConfig: updated"
else
    echo "" >> "${HTTPD_CONF}"
    echo "# Dynamic routing — added by step2-dynamic-routing.sh" >> "${HTTPD_CONF}"
    echo "${PLUGIN_CFG_LINE}" >> "${HTTPD_CONF}"
    echo "      WebSpherePluginConfig: added"
fi

"${APACHECTL}" stop 2>/dev/null; sleep 2
pkill -9 -f "${IHS_ROOT}/bin/httpd" 2>/dev/null; sleep 1
"${APACHECTL}" start; sleep 3

if ! ss -tlnp 2>/dev/null | grep -q ":8080 "; then
    echo "ERROR: IHS failed to start. Check: ${IHS_ROOT}/logs/error_log"
    exit 1
fi
echo "      IHS running on port 8080"
echo ""

# ---------------------------------------------------------------------------
# Patch ODR connector to HTTP:9080 (avoids collective CA trust issue)
# ---------------------------------------------------------------------------
echo "  Patching ODR connector to HTTP:9080..."
bash "${SCRIPT_DIR}/fix-odr-connector.sh"

echo ""
echo "=== Step 2 complete: Dynamic Routing enabled ==="
echo ""
echo "  Verify round-robin across all members:"
echo "    for i in \$(seq 6); do curl -s http://localhost:8080/server-info/ | grep -o 'member[0-9]*'; done"
echo ""
echo "  Next (optional) — pin requests to a specific member:"
echo "    bash scripts/apply-routing-rules.sh -s member1"
echo ""
