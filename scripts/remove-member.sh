#!/bin/bash
# =============================================================================
# remove-member.sh
# Removes a Liberty Collective Member from the collective registry and
# deletes its deployed install directory.
#
# Usage:  scripts/remove-member.sh <member-name>
#
# Examples:
#   scripts/remove-member.sh member1
#   scripts/remove-member.sh member2
#
# What it does:
#   1. Validates input and that the member install directory exists
#   2. Stops the member server (if running)
#   3. Removes the member from the collective registry via 'collective remove'
#   4. Deletes the member install directory
#
# Prerequisites:
#   - Collective Controller must be running (scripts/install-controller.sh)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

set -euo pipefail

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
MEMBER_NAME="$1"

if [[ -z "${MEMBER_NAME}" ]]; then
    echo ""
    echo "  Usage: $0 <member-name>"
    echo "  Example: $0 member1"
    echo "  Example: $0 member2"
    echo ""
    exit 1
fi

INSTALL_DIR="${WORKSPACE_ROOT}/installs/${MEMBER_NAME}"
SERVER_DIR="${INSTALL_DIR}/wlp/usr/servers/${MEMBER_NAME}"
WLP_BIN="${INSTALL_DIR}/wlp/bin/server"

CONTROLLER_HOST="localhost"
CONTROLLER_HTTPS=9443
CONTROLLER_ADMIN_USER="admin"
CONTROLLER_ADMIN_PASS="admin"

echo ""
echo "=== Liberty Collective Member — Remove: ${MEMBER_NAME} ==="
echo ""

# ---------------------------------------------------------------------------
# 1. Check install directory exists
# ---------------------------------------------------------------------------
echo "[1/4] Checking install directory..."
if [[ ! -d "${INSTALL_DIR}" ]]; then
    echo "      No install directory found at ${INSTALL_DIR} — nothing to remove."
    echo ""
    exit 0
fi
echo "      Found: ${INSTALL_DIR}"
echo ""

# ---------------------------------------------------------------------------
# 2. Stop the member server
# ---------------------------------------------------------------------------
echo "[2/4] Stopping ${MEMBER_NAME}..."
if "${WLP_BIN}" status "${MEMBER_NAME}" 2>/dev/null | grep -q "is running"; then
    "${WLP_BIN}" stop "${MEMBER_NAME}" 2>/dev/null || true
    echo "      Stopped"
else
    echo "      Already stopped (or status unknown) — continuing"
fi
echo ""

# ---------------------------------------------------------------------------
# 3. Remove from collective registry
# ---------------------------------------------------------------------------
echo "[3/4] Removing ${MEMBER_NAME} from collective registry..."
CTRL_STATUS=$(curl -k -s -o /dev/null -w "%{http_code}" \
    https://${CONTROLLER_HOST}:${CONTROLLER_HTTPS}/adminCenter 2>/dev/null)

if [[ "${CTRL_STATUS}" == "200" || "${CTRL_STATUS}" == "302" ]]; then
    "${WORKSPACE_ROOT}/installs/controller/wlp/bin/collective" remove "${MEMBER_NAME}" \
        --host="${CONTROLLER_HOST}" \
        --port="${CONTROLLER_HTTPS}" \
        --user="${CONTROLLER_ADMIN_USER}" \
        --password="${CONTROLLER_ADMIN_PASS}" \
        --autoAcceptCertificates \
        --disableHostnameVerification 2>/dev/null || true
    echo "      Removed from collective"
else
    echo "      Controller not reachable (HTTP ${CTRL_STATUS}) — skipping collective remove"
    echo "      Member install directory will still be deleted"
fi
echo ""

# ---------------------------------------------------------------------------
# 4. Delete install directory
# ---------------------------------------------------------------------------
echo "[4/4] Deleting install directory..."
rm -rf "${INSTALL_DIR}"
echo "      Deleted: ${INSTALL_DIR}"

echo ""
echo "=== Member '${MEMBER_NAME}' removed ==="
echo ""
