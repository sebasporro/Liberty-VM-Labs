#!/bin/zsh
# =============================================================================
# add-member-25.sh
# Deploys a Liberty 25.0.0.1 Collective Member and joins it to the running
# Collective Controller (26.0.0.8).
#
# Mixed-version collective: the controller runs 26.0.0.8; members deployed
# by this script run Liberty Base 25.0.0.1. The collective protocol is
# version-agnostic — members of different versions can coexist.
#
# Usage:  scripts/add-member-25.sh <member-name>
#
# Examples:
#   scripts/add-member-25.sh member3
#   scripts/add-member-25.sh member4
#
# Port allocation (auto-assigned based on member index):
#   member3 → HTTP 9083 / HTTPS 9446
#   member4 → HTTP 9084 / HTTPS 9447
#   memberN → HTTP 908N / HTTPS (9443 + N)
#
# Prerequisites:
#   - packages/liberty-package-25.0.0.1.zip must exist
#     (run scripts/01-install-runtime-25.sh → 02-build-template-25.sh → 03-build-package-25.sh)
#   - Collective Controller must be running
#     (run scripts/install-controller.sh)
# =============================================================================

SCRIPT_DIR="${0:A:h}"
source "${SCRIPT_DIR}/00-set-env.sh"

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
MEMBER_NAME="$1"

if [[ -z "${MEMBER_NAME}" ]]; then
    echo ""
    echo "  Usage: $0 <member-name>"
    echo "  Example: $0 member3"
    echo ""
    exit 1
fi

PACKAGE="${WORKSPACE_ROOT}/packages/liberty-package-25.0.0.1.zip"
INSTALL_DIR="${WORKSPACE_ROOT}/installs/${MEMBER_NAME}"
SERVER_DIR="${INSTALL_DIR}/wlp/usr/servers/${MEMBER_NAME}"
WLP_BIN="${INSTALL_DIR}/wlp/bin/server"
OVERRIDES_DIR="${SERVER_DIR}/configDropins/overrides"
CONFIG_SRC="${WORKSPACE_ROOT}/config/${MEMBER_NAME}"

CONTROLLER_HOST="localhost"
CONTROLLER_HTTPS=9443
CONTROLLER_ADMIN_USER="admin"
CONTROLLER_ADMIN_PASS="admin"

# ---------------------------------------------------------------------------
# Port assignment — derive from member index (member3=3, member4=4, etc.)
# ---------------------------------------------------------------------------
MEMBER_INDEX="${MEMBER_NAME//[^0-9]/}"   # extract numeric suffix
if [[ -z "${MEMBER_INDEX}" ]]; then
    MEMBER_INDEX=$(ls -d "${WORKSPACE_ROOT}/installs"/member* 2>/dev/null | wc -l | tr -d ' ')
    (( MEMBER_INDEX++ ))
fi

MEMBER_HTTP=$(( 9080 + MEMBER_INDEX ))
MEMBER_HTTPS=$(( 9443 + MEMBER_INDEX ))
KEYSTORE_PASS="Liberty25${MEMBER_NAME}!"

echo ""
echo "=== Liberty 25.0.0.1 Collective Member — Install: ${MEMBER_NAME} ==="
echo "    HTTP  port: ${MEMBER_HTTP}"
echo "    HTTPS port: ${MEMBER_HTTPS}"
echo ""

# ---------------------------------------------------------------------------
# 1. Pre-flight checks
# ---------------------------------------------------------------------------
echo "[1/10] Pre-flight checks..."

if [[ ! -f "${PACKAGE}" ]]; then
    echo "  ERROR: Package not found: ${PACKAGE}"
    echo "  Run the 25.0.0.1 build pipeline first:"
    echo "    scripts/01-install-runtime-25.sh"
    echo "    scripts/02-build-template-25.sh"
    echo "    scripts/03-build-package-25.sh"
    exit 1
fi
echo "      Package (25.0.0.1): found"

CTRL_STATUS=$(curl -k -s -o /dev/null -w "%{http_code}" \
    https://${CONTROLLER_HOST}:${CONTROLLER_HTTPS}/adminCenter 2>/dev/null)
if [[ "${CTRL_STATUS}" != "200" && "${CTRL_STATUS}" != "302" ]]; then
    echo "  ERROR: Collective Controller is not running (HTTP ${CTRL_STATUS})."
    echo "  Run scripts/install-controller.sh first."
    exit 1
fi
echo "      Controller (26.0.0.8): running (HTTP ${CTRL_STATUS})"

# Check for per-member config overrides; generate generic ones if missing
if [[ ! -d "${CONFIG_SRC}" ]]; then
    echo "      No config/${MEMBER_NAME}/ found — generating generic member overrides..."
    mkdir -p "${CONFIG_SRC}"

    cat > "${CONFIG_SRC}/role-override.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<server description="${MEMBER_NAME} role override">
    <featureManager>
        <feature>collectiveMember-1.0</feature>
    </featureManager>

    <application id="serverinfo"
                 name="server-info"
                 type="war"
                 location="\${server.config.dir}/apps/server-info.war">
        <application-bnd>
            <security-role name="Everyone">
                <special-subject type="EVERYONE"/>
            </security-role>
        </application-bnd>
    </application>
</server>
EOF

    cat > "${CONFIG_SRC}/ports-override.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<server description="${MEMBER_NAME} ports override">
    <httpEndpoint id="defaultHttpEndpoint"
                  host="*"
                  httpPort="${MEMBER_HTTP}"
                  httpsPort="${MEMBER_HTTPS}"/>
</server>
EOF
    echo "      Generated: config/${MEMBER_NAME}/role-override.xml"
    echo "      Generated: config/${MEMBER_NAME}/ports-override.xml"
fi
echo ""

# ---------------------------------------------------------------------------
# 2. Clean previous install
# ---------------------------------------------------------------------------
echo "[2/10] Cleaning previous install for '${MEMBER_NAME}'..."
rm -rf "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
echo "      Clean"
echo ""

# ---------------------------------------------------------------------------
# 3. Unpack 25.0.0.1 package
# ---------------------------------------------------------------------------
echo "[3/10] Unpacking 25.0.0.1 package..."
unzip -q "${PACKAGE}" -d "${INSTALL_DIR}"
echo "      Unpacked to ${INSTALL_DIR}"
echo ""

# ---------------------------------------------------------------------------
# 4. Rename server template-25.0.0.1 → <member-name>
# ---------------------------------------------------------------------------
echo "[4/10] Renaming server to '${MEMBER_NAME}'..."
TEMPLATE_DIR="${INSTALL_DIR}/wlp/usr/servers/template-25.0.0.1"
if [[ ! -d "${TEMPLATE_DIR}" ]]; then
    echo "  ERROR: Template directory not found: ${TEMPLATE_DIR}"
    exit 1
fi
mv "${TEMPLATE_DIR}" "${SERVER_DIR}"
echo "      Renamed → ${SERVER_DIR}"
echo ""

# ---------------------------------------------------------------------------
# 5-6. Drop in configDropins/overrides
# ---------------------------------------------------------------------------
echo "[5/10] Applying configDropins overrides..."
mkdir -p "${OVERRIDES_DIR}"
cp "${CONFIG_SRC}/role-override.xml"  "${OVERRIDES_DIR}/role-override.xml"
cp "${CONFIG_SRC}/ports-override.xml" "${OVERRIDES_DIR}/ports-override.xml"
echo "      role-override.xml  → collectiveMember-1.0 + server-info app"
echo "      ports-override.xml → HTTP ${MEMBER_HTTP} / HTTPS ${MEMBER_HTTPS}"
echo ""

# ---------------------------------------------------------------------------
# 7. Write bootstrap.properties
# ---------------------------------------------------------------------------
echo "[6/10] Writing bootstrap.properties..."
cat > "${SERVER_DIR}/bootstrap.properties" <<EOF
# ${MEMBER_NAME} bootstrap properties — generated by add-member-25.sh
default.http.port=${MEMBER_HTTP}
default.https.port=${MEMBER_HTTPS}
keystore.password=${KEYSTORE_PASS}
admin.password=admin
EOF
echo "      Written"
echo ""

# ---------------------------------------------------------------------------
# 8. Collective join — use the instance's own wlp/bin/collective
# ---------------------------------------------------------------------------
echo "[7/10] Joining collective (collective join)..."
"${INSTALL_DIR}/wlp/bin/collective" join "${MEMBER_NAME}" \
    --host="${CONTROLLER_HOST}" \
    --port="${CONTROLLER_HTTPS}" \
    --user="${CONTROLLER_ADMIN_USER}" \
    --password="${CONTROLLER_ADMIN_PASS}" \
    --keystorePassword="${KEYSTORE_PASS}" \
    --createConfigFile="${OVERRIDES_DIR}/collective-join.xml" \
    --autoAcceptCertificates \
    --disableHostnameVerification 2>&1 | tail -5

if [[ $? -ne 0 ]]; then
    echo "  ERROR: collective join failed."
    exit 1
fi
echo "      Joined (controllerHost=localhost)"
echo ""

# ---------------------------------------------------------------------------
# 9. Start the member
# ---------------------------------------------------------------------------
echo "[8/10] Starting ${MEMBER_NAME}..."
"${WLP_BIN}" start "${MEMBER_NAME}"
if [[ $? -ne 0 ]]; then
    echo "  ERROR: ${MEMBER_NAME} failed to start."
    echo "  Check: ${SERVER_DIR}/logs/messages.log"
    exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# 10. Wait for ready and verify app
# ---------------------------------------------------------------------------
echo "[9/10] Waiting for ${MEMBER_NAME} to be ready..."
MAX_WAIT=60
WAITED=0
while [[ ${WAITED} -lt ${MAX_WAIT} ]]; do
    if grep -q "server is ready" "${SERVER_DIR}/logs/messages.log" 2>/dev/null; then
        break
    fi
    sleep 2
    (( WAITED += 2 ))
    echo "      Waiting... (${WAITED}s)"
done

echo ""
echo "[10/10] Verifying app..."
CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    "http://${CONTROLLER_HOST}:${MEMBER_HTTP}/server-info/" 2>/dev/null)
if [[ "${CODE}" == "200" ]]; then
    echo "      server-info app: READY (HTTP ${CODE})"
else
    echo "      WARNING: App returned HTTP ${CODE} — may still be starting"
fi

echo ""
echo "=== Member '${MEMBER_NAME}' (Liberty 25.0.0.1) install complete ==="
echo ""
echo "  App URL:       http://localhost:${MEMBER_HTTP}/server-info/"
echo "  HTTPS port:    ${MEMBER_HTTPS}"
echo "  Admin Center:  https://localhost:${CONTROLLER_HTTPS}/adminCenter"
echo ""
