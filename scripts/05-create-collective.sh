#!/bin/bash
# =============================================================================
# 05-create-collective.sh
# Sub-Task 5 — Form the Liberty Collective (controller + members)
#
# Steps performed:
#   1. collective create on the controller  (generates certs/keystores)
#   2. Start the controller and wait for readiness
#   3. collective join for member1 and member2
#   4. Start member1 and member2 and wait for readiness
#   5. Verify all servers and app endpoints
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

# --- paths ---
CTRL_BIN="installs/controller/wlp/bin"
MBR1_BIN="installs/member1/wlp/bin"
MBR2_BIN="installs/member2/wlp/bin"

CTRL_OVERRIDES="installs/controller/wlp/usr/servers/controller/configDropins/overrides"
MBR1_OVERRIDES="installs/member1/wlp/usr/servers/member1/configDropins/overrides"
MBR2_OVERRIDES="installs/member2/wlp/usr/servers/member2/configDropins/overrides"

CTRL_LOG="installs/controller/wlp/usr/servers/controller/logs/messages.log"
MBR1_LOG="installs/member1/wlp/usr/servers/member1/logs/messages.log"
MBR2_LOG="installs/member2/wlp/usr/servers/member2/logs/messages.log"

# --- passwords & ports ---
CTRL_KS_PASS="Liberty26ctrl!"
MBR1_KS_PASS="Liberty26mbr1!"
MBR2_KS_PASS="Liberty26mbr2!"
ADMIN_USER="admin"
ADMIN_PASS="admin"
CTRL_HTTPS_PORT="9443"

# collective create uses --hostName=localhost so the cert CN matches localhost.
# No IP resolution needed — all collective URLs use localhost throughout.

# =============================================================================
# Helper: wait for a Liberty server to print CWWKF0011I (server is ready)
# Usage: wait_for_ready <log_file> <server_name>
# =============================================================================
wait_for_ready() {
  local log_file="$1"
  local server_name="$2"
  echo "Waiting for ${server_name} to be ready..."
  for i in $(seq 1 40); do
    if grep -q "CWWKF0011I" "${log_file}" 2>/dev/null; then
      echo "  ${server_name} is ready (attempt ${i})"
      return 0
    fi
    sleep 3
  done
  echo "ERROR: ${server_name} did not become ready within 120 seconds" >&2
  return 1
}

# =============================================================================
# Step 1 — collective create (initialises collective certs on controller)
# =============================================================================
echo ""
echo "=== Step 1: collective create (controller) ==="
# Stop controller if already running to avoid lock conflicts
if "${CTRL_BIN}/server" status controller 2>/dev/null | grep -q "running"; then
  echo "  Stopping existing controller..."
  "${CTRL_BIN}/server" stop controller
fi

"${CTRL_BIN}/collective" create controller \
  --keystorePassword="${CTRL_KS_PASS}" \
  --hostName=localhost

echo "  Collective create succeeded."

# =============================================================================
# Step 2 — Start controller and wait for readiness
# =============================================================================
echo ""
echo "=== Step 2: Start controller ==="
"${CTRL_BIN}/server" start controller
wait_for_ready "${CTRL_LOG}" "controller"

# Confirm Admin Center is reachable
AC_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" https://localhost:${CTRL_HTTPS_PORT}/adminCenter)
echo "  Admin Center HTTP code: ${AC_CODE}"
if [[ "${AC_CODE}" != "200" && "${AC_CODE}" != "302" ]]; then
  echo "ERROR: Admin Center not reachable (got ${AC_CODE})" >&2
  exit 1
fi

# =============================================================================
# Step 3 — collective join for member1 and member2
# =============================================================================
echo ""
echo "=== Step 3: Join member1 to collective ==="
rm -rf "installs/member1/wlp/usr/servers/member1/resources/collective"
"${MBR1_BIN}/collective" join member1 \
  --host=localhost \
  --port="${CTRL_HTTPS_PORT}" \
  --user="${ADMIN_USER}" \
  --password="${ADMIN_PASS}" \
  --keystorePassword="${MBR1_KS_PASS}" \
  --createConfigFile="${MBR1_OVERRIDES}/collective-join.xml" \
  --autoAcceptCertificates \
  --disableHostnameVerification

echo "  member1 joined (controllerHost=localhost)."

echo ""
echo "=== Step 4: Join member2 to collective ==="
rm -rf "installs/member2/wlp/usr/servers/member2/resources/collective"
"${MBR2_BIN}/collective" join member2 \
  --host=localhost \
  --port="${CTRL_HTTPS_PORT}" \
  --user="${ADMIN_USER}" \
  --password="${ADMIN_PASS}" \
  --keystorePassword="${MBR2_KS_PASS}" \
  --createConfigFile="${MBR2_OVERRIDES}/collective-join.xml" \
  --autoAcceptCertificates \
  --disableHostnameVerification

echo "  member2 joined (controllerHost=localhost)."

# =============================================================================
# Step 5 — Start member1 and member2
# =============================================================================
echo ""
echo "=== Step 5: Start member1 and member2 ==="
"${MBR1_BIN}/server" start member1
"${MBR2_BIN}/server" start member2
wait_for_ready "${MBR1_LOG}" "member1"
wait_for_ready "${MBR2_LOG}" "member2"

# =============================================================================
# Step 6 — Verify
# =============================================================================
echo ""
echo "=== Step 6: Verification ==="
source "${SCRIPT_DIR}/00-set-env.sh"

"${CTRL_BIN}/server" status controller
"${MBR1_BIN}/server" status member1
"${MBR2_BIN}/server" status member2

M1=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9081/server-info/)
M2=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9082/server-info/)
AC=$(curl -k -s -o /dev/null -w "%{http_code}" https://localhost:9443/adminCenter)

echo "  member1 /server-info/ → ${M1}"
echo "  member2 /server-info/ → ${M2}"
echo "  adminCenter           → ${AC}"

FAIL=0
[[ "${M1}" == "200" ]] || { echo "FAIL: member1 app not 200"; FAIL=1; }
[[ "${M2}" == "200" ]] || { echo "FAIL: member2 app not 200"; FAIL=1; }
[[ "${AC}" == "200" || "${AC}" == "302" ]] || { echo "FAIL: adminCenter not 200/302"; FAIL=1; }

if [[ "${FAIL}" -eq 0 ]]; then
  echo ""
  echo "SUCCESS: Collective is formed and all endpoints are healthy."
else
  echo ""
  echo "FAILURE: One or more checks failed — review logs above." >&2
  exit 1
fi
