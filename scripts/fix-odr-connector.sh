#!/bin/bash
# =============================================================================
# fix-odr-connector.sh
# Patches the installed plugin-cfg.xml to use HTTP:9080 for the ODR connector
# instead of HTTPS:9443, then restarts IHS and verifies routing.
#
# WHY:
#   dynamicRouting setup generates an HTTPS connector with a keyring pointing
#   at plugin-key.kdb. The ODR library must present that certificate to the
#   controller's collective PKI. In a single-VM install the collective CA is
#   self-signed and not in the plugin trust chain, so ODR silently fails to
#   connect and keeps routing to the static placeholder server → HTTP 500.
#
#   The /ibm/api/dynamicRouting endpoint is available on plain HTTP (port 9080).
#   Switching to HTTP removes the keystore trust requirement entirely.
#
# Usage:
#   bash scripts/fix-odr-connector.sh
# =============================================================================

IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/IBM/HTTPServer}"
PLUGIN_CFG="${IHS_ROOT}/config/webserver1/plugin-cfg.xml"

echo ""
echo "=== Fix ODR connector: HTTPS → HTTP ==="
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

# Check whether already patched
if 'protocol="http"' in content and 'port="9080"' in content:
    print("  ODR connector already set to HTTP:9080 — nothing to do.")
    sys.exit(0)

# Switch HTTPS connector to HTTP:9080
patched = re.sub(
    r'<Connector host="[^"]*" port="[0-9]+" protocol="https">',
    '<Connector host="localhost" port="9080" protocol="http">',
    content
)

# Remove the keyring property inside the Connector (not needed for HTTP)
patched = re.sub(
    r'\s*<Property name="keyring"[^/]*/>\s*',
    '\n',
    patched
)

if patched == content:
    print("  WARNING: No HTTPS Connector found — file may already be correct.")
    m = re.search(r'<Connector[^>]*>', content)
    if m:
        print(f"  Current connector: {m.group(0)}")
    sys.exit(0)

# Validate result is well-formed XML
try:
    ET.fromstring(patched)
except ET.ParseError as e:
    print(f"  ERROR: patched XML is not well-formed: {e}")
    sys.exit(1)

with open(path, 'w') as f:
    f.write(patched)

print("  ODR Connector switched to HTTP:9080 ✓")
print("  Keyring property removed ✓")
print("  plugin-cfg.xml is valid XML ✓")
PYEOF

if [ $? -ne 0 ]; then
    echo "ERROR: patch failed — plugin-cfg.xml not modified."
    exit 1
fi

echo ""
echo "  Restarting IHS..."
"${IHS_ROOT}/bin/apachectl" stop 2>/dev/null; sleep 2
"${IHS_ROOT}/bin/apachectl" start; sleep 5

if ! ss -tlnp 2>/dev/null | grep -q ":8080 "; then
    echo "  ERROR: IHS failed to start"
    tail -10 "${IHS_ROOT}/logs/error_log" | sed 's/^/  /'
    exit 1
fi
echo "  IHS running on port 8080 ✓"

echo ""
echo "  Waiting up to 30s for ODR to connect and populate routing table..."
HTTP_CODE="000"
for t in $(seq 0 5 30); do
    [ $t -gt 0 ] && { sleep 5; echo "    ${t}s — HTTP ${HTTP_CODE}..."; }
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        http://localhost:8080/server-info/ 2>/dev/null)
    [ "${HTTP_CODE}" = "200" ] && break
done

echo ""
echo "  GET /server-info/ → HTTP ${HTTP_CODE}"
echo ""

if [ "${HTTP_CODE}" = "200" ]; then
    echo "=== Dynamic Routing is working ==="
    echo ""
    echo "  Verify round-robin:"
    echo "    for i in \$(seq 6); do curl -s http://localhost:8080/server-info/ | grep -o 'member[0-9]*'; done"
    echo ""
    echo "  Plugin log:"
    echo "    tail -f ${IHS_ROOT}/logs/webserver1/http_plugin.log"
else
    echo "  Still not routing. Last 20 lines of plugin log:"
    tail -20 "${IHS_ROOT}/logs/webserver1/http_plugin.log" | sed 's/^/  /'
fi
echo ""
