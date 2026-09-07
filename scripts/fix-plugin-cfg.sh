#!/bin/bash
# =============================================================================
# fix-plugin-cfg.sh
# Patches the installed plugin-cfg.xml in-place to add a placeholder <Server>
# inside <ServerCluster> so the WAS plugin parser accepts it at startup.
#
# The WAS plugin parser (mod_was_ap24_http.so) aborts with:
#   "configDestroy: Destroyed the config"
#   "Failed to load the config file"
# when it finds a <ServerCluster> with no <Server> children — even in ODR
# (dynamic routing) mode where the live server list is built at runtime.
# This script adds a placeholder Server entry that satisfies the parser.
# ODR overwrites the routing table once it connects to the controller.
#
# Usage:
#   bash scripts/fix-plugin-cfg.sh
#
# Run this after setupDynamicRouting-singleVM.sh if IHS fails to start
# with "Failed to parse the config file plugin-cfg.xml".
# =============================================================================

IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/IBM/HTTPServer}"
PLUGIN_CFG="${IHS_ROOT}/config/webserver1/plugin-cfg.xml"

echo ""
echo "=== Patching plugin-cfg.xml ==="
echo "    File: ${PLUGIN_CFG}"
echo ""

if [ ! -f "${PLUGIN_CFG}" ]; then
    echo "ERROR: ${PLUGIN_CFG} not found."
    echo "       Run setupDynamicRouting-singleVM.sh first."
    exit 1
fi

python3 - "${PLUGIN_CFG}" <<'PYEOF'
import sys, re, xml.etree.ElementTree as ET

path = sys.argv[1]

with open(path) as f:
    content = f.read()

# Check whether a placeholder Server is already present
if 'Name="placeholder"' in content:
    print("  Placeholder Server already present — nothing to do.")
    sys.exit(0)

# Find the empty ServerCluster and add placeholder Server + PrimaryServers
placeholder = '''\
    <Server CloneID="placeholder" ConnectTimeout="5" ExtendedHandshake="false"
            MaxConnections="-1" Name="placeholder" ServerIOTimeout="900" WaitForContinue="false">
        <Transport Hostname="localhost" Port="9081" Protocol="http"/>
    </Server>
    <PrimaryServers>
        <Server Name="placeholder"/>
    </PrimaryServers>
'''

# Replace closing tag of empty ServerCluster
patched = re.sub(
    r'(<ServerCluster\b[^>]*Name="defaultCollective"[^>]*>)\s*</ServerCluster>',
    r'\1\n' + placeholder + '</ServerCluster>',
    content,
    flags=re.DOTALL
)

if patched == content:
    print("  WARNING: Could not find empty ServerCluster — file may already be correct or have unexpected format.")
    print("  Current ServerCluster section:")
    m = re.search(r'<ServerCluster.*?</ServerCluster>', content, re.DOTALL)
    if m:
        print(m.group(0))
    sys.exit(1)

# Validate the result is well-formed XML
try:
    ET.fromstring(patched)
except ET.ParseError as e:
    print(f"  ERROR: patched XML is not well-formed: {e}")
    sys.exit(1)

with open(path, 'w') as f:
    f.write(patched)

print("  Placeholder Server injected into ServerCluster ✓")
print("  plugin-cfg.xml is valid XML ✓")
PYEOF

if [ $? -ne 0 ]; then
    echo ""
    echo "ERROR: patch failed — plugin-cfg.xml not modified."
    exit 1
fi

# Ensure plugin-key.rdb exists (WAS plugin requires all three keystore files)
RDB="${IHS_ROOT}/config/webserver1/plugin-key.rdb"
if [ ! -f "${RDB}" ]; then
    echo "  plugin-key.rdb missing — creating..."
    touch "${RDB}"
    chmod 644 "${RDB}"
    echo "  plugin-key.rdb created ✓"
fi

echo ""
echo "  Starting IHS..."
"${IHS_ROOT}/bin/apachectl" start
sleep 3

if ss -tlnp 2>/dev/null | grep -q ":8080 "; then
    echo "  IHS running on port 8080 ✓"
    echo ""
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/server-info/ 2>/dev/null)
    echo "  GET /server-info/ → HTTP ${HTTP_CODE}"
else
    echo "  ERROR: IHS failed to start"
    tail -10 "${IHS_ROOT}/logs/error_log" | sed 's/^/  /'
    exit 1
fi
echo ""
