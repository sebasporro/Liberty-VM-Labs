#!/bin/bash
# =============================================================================
# remove-member.sh
# Gracefully removes one or more Collective Members from the running collective
# and cleans up their on-disk installations.
#
# Removal steps per member:
#   1. Stop the member server (graceful, with force-kill fallback)
#   2. Run 'collective remove' against the controller to deregister the member
#   3. Delete the install directory (installs/<member-name>)
#
# Usage:
#   scripts/remove-member.sh <member-name> [<member-name2> ...]
#
# Examples:
#   scripts/remove-member.sh member3
#   scripts/remove-member.sh member3 member4
#
# Prerequisites:
#   - Collective Controller must be running on localhost:9443
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
    echo ""
    echo "  Usage: $0 <member-name> [<member-name2> ...]"
    echo "  Example: $0 member3"
    echo "  Example: $0 member3 member4"
    echo ""
    exit 1
fi

CONTROLLER_HOST="localhost"
CONTROLLER_HTTPS=9443
CONTROLLER_ADMIN_USER="admin"
CONTROLLER_ADMIN_PASS="admin"

# ---------------------------------------------------------------------------
# Helper: stop a single server gracefully, force-kill if still running
# ---------------------------------------------------------------------------
stop_server() {
    local name="$1"
    local server_bin="${WORKSPACE_ROOT}/installs/${name}/wlp/bin/server"

    if [[ -x "${server_bin}" ]]; then
        echo "      Stopping ${name} gracefully..."
        "${server_bin}" stop "${name}" 2>/dev/null || true
        sleep 1
    else
        echo "      No server binary found for ${name} — skipping graceful stop"
    fi

    # Force-kill fallback if the JVM is still alive
    if pgrep -f "ws-server.jar.*${name}" >/dev/null 2>&1; then
        echo "      Force-killing remaining JVM process for ${name}..."
        pkill -9 -f "ws-server.jar.*${name}" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Process each member supplied on the command line
# ---------------------------------------------------------------------------
for MEMBER_NAME in "$@"; do

    INSTALL_DIR="${WORKSPACE_ROOT}/installs/${MEMBER_NAME}"
    SERVER_DIR="${INSTALL_DIR}/wlp/usr/servers/${MEMBER_NAME}"

    echo ""
    echo "=== Removing Collective Member: ${MEMBER_NAME} ==="
    echo ""

    # -------------------------------------------------------------------------
    # 1. Verify the install directory exists
    # -------------------------------------------------------------------------
    echo "[1/3] Checking install directory..."
    if [[ ! -d "${INSTALL_DIR}" ]]; then
        echo "      WARNING: Install directory not found: ${INSTALL_DIR}"
        echo "      Skipping collective remove — nothing to clean up."
        echo ""
        continue
    fi
    echo "      Found: ${INSTALL_DIR}"
    echo ""

    # -------------------------------------------------------------------------
    # 2. Stop the member server
    # -------------------------------------------------------------------------
    echo "[2/3] Stopping member server..."
    stop_server "${MEMBER_NAME}"
    echo "      Stopped"
    echo ""

    # -------------------------------------------------------------------------
    # 3. Deregister from the collective (collective remove)
    #    Uses the member's own collective binary so the correct trust store is
    #    available; falls back to the build-phase controller binary if the
    #    member install was already partially removed.
    # -------------------------------------------------------------------------
    echo "[3/3] Removing member from collective registry..."
    COLLECTIVE_BIN="${INSTALL_DIR}/wlp/bin/collective"
    if [[ ! -x "${COLLECTIVE_BIN}" ]]; then
        # Fall back to the controller-version binary
        COLLECTIVE_BIN="${WLP_HOME}/bin/collective"
    fi

    if [[ -x "${COLLECTIVE_BIN}" ]]; then
        "${COLLECTIVE_BIN}" remove "${MEMBER_NAME}" \
            --host="${CONTROLLER_HOST}" \
            --port="${CONTROLLER_HTTPS}" \
            --user="${CONTROLLER_ADMIN_USER}" \
            --password="${CONTROLLER_ADMIN_PASS}" \
            --hostName=localhost \
            --autoAcceptCertificates \
            --disableHostnameVerification 2>&1
        RC=${PIPESTATUS[0]:-$?}
        if [[ ${RC} -ne 0 ]]; then
            echo "      WARNING: collective remove returned non-zero (${RC})."
            echo "      The member may have already been deregistered, or the"
            echo "      controller may not be running. Continuing with disk cleanup."
        else
            echo "      Deregistered from collective"
        fi
    else
        echo "      WARNING: No collective binary available — skipping deregistration."
        echo "      The controller registry entry (if any) was not removed."
    fi

    # Wipe the install directory regardless of collective remove outcome
    echo "      Removing install directory: ${INSTALL_DIR}"
    rm -rf "${INSTALL_DIR}"
    echo "      Removed"

    echo ""
    echo "=== Member '${MEMBER_NAME}' removed ==="

done

echo ""
echo "Admin Center: https://localhost:${CONTROLLER_HTTPS}/adminCenter"
echo ""
