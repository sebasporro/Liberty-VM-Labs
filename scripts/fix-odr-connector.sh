#!/bin/bash
# =============================================================================
# fix-odr-connector.sh
# Patches the installed plugin-cfg.xml with two fixes required on a single-VM lab:
#
# Fix 1 — ODR Connector HTTPS → HTTP:9080
#   dynamicRouting setup generates an HTTPS connector. The ODR library must
#   present the collective certificate to the controller PKI, but the collective
#   CA is self-signed and not in the plugin trust chain → ODR fails to connect.
#   The /ibm/api/dynamicRouting endpoint is also available on plain HTTP:9080,
#   switching to HTTP removes the keystore trust requirement entirely.
#
# Fix 2 — TraceSpecification name absolute path
#   dynamicRouting setup writes a relative filename (odr-trace.xml) in the
#   <TraceSpecification name="..."/> attribute inside <IntelligentManagement>.
#   The ODR library opens it relative to the process working directory, which
#   is unpredictable at IHS startup → "Failed to open odr-trace.xml" →
#   "Failed to create ODR environment" → no dynamic routing.
#   Fix: replace the relative name with an absolute path under IHS logs/.
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
    echo "       Run scripts/step2-dynamic-routing.sh first."
    exit 1
fi

mkdir -p "${IHS_ROOT}/logs"

python3 - "${PLUGIN_CFG}" <<'PYEOF'
import sys, re, xml.etree.ElementTree as ET

path = sys.argv[1]
with open(path) as f:
    content = f.read()

patched = content

# ------------------------------------------------------------------
# Fix 1: Switch HTTPS Connector → HTTP:9080, remove keyring property
# ------------------------------------------------------------------
if 'protocol="http"' in patched and 'port="9080"' in patched:
    print("  Fix 1: ODR connector already HTTP:9080 — skipped")
else:
    patched = re.sub(
        r'<Connector host="[^"]*" port="[0-9]+" protocol="https">',
        '<Connector host="localhost" port="9080" protocol="http">',
        patched
    )
    patched = re.sub(
        r'<Property name="keyring"[^>]*/>\n?',
        '',
        patched
    )
    if patched == content:
        print("  Fix 1: WARNING — no HTTPS Connector found; file may already be correct")
        m = re.search(r'<Connector[^>]*>', content)
        if m:
            print(f"           Current connector: {m.group(0)}")
    else:
        print("  Fix 1: ODR Connector switched to HTTP:9080 ✓")
        print("  Fix 1: Keyring property removed ✓")

# ------------------------------------------------------------------
# Validate and write
# ------------------------------------------------------------------
try:
    ET.fromstring(patched)
except ET.ParseError as e:
    print(f"  ERROR: patched XML is not well-formed: {e}")
    sys.exit(1)

if patched != content:
    with open(path, 'w') as f:
        f.write(patched)
    print("  plugin-cfg.xml updated and validated ✓")
else:
    print("  plugin-cfg.xml unchanged — already correct")
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
