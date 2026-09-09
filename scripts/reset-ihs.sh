#!/bin/bash
# =============================================================================
# reset-ihs.sh
# Stops IHS and completely removes all installed IHS files and configurations,
# returning the environment to the initial state where only the installer ZIP
# remains.
# =============================================================================

echo ""
echo "=== Resetting IBM HTTP Server (IHS) ==="
echo ""

# 1. Stop any running IHS instance
echo "[1/3] Stopping IHS processes..."
if [[ -f "/home/itzuser/usr/IBM/IHS/bin/apachectl" ]]; then
    /home/itzuser/usr/IBM/IHS/bin/apachectl stop 2>/dev/null || true
fi

pkill -9 -f "httpd" 2>/dev/null || true
sleep 2

# 2. Remove extracted IHS directory and files under ~/usr/IBM/IHS
echo "[2/3] Removing installed IHS directory and configurations..."
rm -rf /home/itzuser/usr/IBM/IHS

# 3. Clean any staging or temporary dynamicRouting directories
echo "[3/3] Cleaning temporary files..."
rm -rf /home/itzuser/temp/dynamicRouting

echo ""
echo "=== IHS Reset Complete ==="
echo "All IHS installations and configurations removed."
echo "Installer ZIP remains at: /home/itzuser/software/IHS/WAS/9.0.5-WS-IHS-ARCHIVE-linux-x86_64-FP025.zip"
echo ""
