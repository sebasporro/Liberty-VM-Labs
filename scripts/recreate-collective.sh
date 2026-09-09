#!/bin/bash
# =============================================================================
# recreate-collective.sh
# Stops, removes, and recreates the controller, member1, and member2 from scratch.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

echo "============================================================="
echo " Recreating Collective (Controller, member1, member2)"
echo "============================================================="
echo ""

# ---------------------------------------------------------------------------
# Helper function to stop a server safely and force-kill if needed
# ---------------------------------------------------------------------------
stop_server() {
    local name="$1"
    local server_bin="${WORKSPACE_ROOT}/installs/${name}/wlp/bin/server"
    if [[ -x "${server_bin}" ]]; then
        echo "Stopping server ${name} gracefully..."
        "${server_bin}" stop "${name}" 2>/dev/null || true
        sleep 1
    fi
    # Force kill fallback if the process is still running
    if pgrep -f "ws-server.jar.*${name}" >/dev/null 2>&1; then
        echo "Force-killing remaining process for ${name}..."
        pkill -9 -f "ws-server.jar.*${name}" 2>/dev/null || true
    fi
}

# 1. Stop running servers and clear target ports
echo "[1/4] Stopping running controller and member instances..."
stop_server "member1"
stop_server "member2"
stop_server "controller"

echo "Ensuring collective ports are clear..."
for port in 9080 9443 9081 9082 9444 9445; do
    pid=$(lsof -t -iTCP:$port -sTCP:LISTEN 2>/dev/null)
    if [[ -n "${pid}" ]]; then
        echo "  Port ${port} in use by process ${pid} — force-killing..."
        kill -9 ${pid} 2>/dev/null || true
    fi
done
echo "      All servers stopped and ports cleared."
echo ""

# 2. Clean up previous deployments
echo "[2/4] Removing installs for controller, member1, and member2..."
rm -rf "${WORKSPACE_ROOT}/installs/controller"
rm -rf "${WORKSPACE_ROOT}/installs/member1"
rm -rf "${WORKSPACE_ROOT}/installs/member2"
echo "      Cleaned."
echo ""

# 3. Install and start controller
echo "[3/4] Installing and starting fresh controller..."
bash "${SCRIPT_DIR}/install-controller.sh"
if [[ $? -ne 0 ]]; then
    echo "ERROR: Failed to install controller."
    exit 1
fi
echo ""

# 4. Deploy and start member1 and member2
echo "[4/4] Deploying and joining member1 and member2..."
bash "${SCRIPT_DIR}/add-member-26.sh" member1
if [[ $? -ne 0 ]]; then
    echo "ERROR: Failed to add member1."
    exit 1
fi

echo ""
bash "${SCRIPT_DIR}/add-member-26.sh" member2
if [[ $? -ne 0 ]]; then
    echo "ERROR: Failed to add member2."
    exit 1
fi

echo ""
echo "============================================================="
echo " Collective successfully recreated from scratch!"
echo "   Controller : running on localhost (9080/9443)"
echo "   member1    : running on localhost (9081/9444)"
echo "   member2    : running on localhost (9082/9445)"
echo "============================================================="
echo ""
