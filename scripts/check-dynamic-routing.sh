#!/bin/bash
# check-dynamic-routing.sh — Focused diagnostics for dynamic routing failures.
# Run this after step2-dynamic-routing.sh fails at [5/5].

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/usr/IBM/IHS}"
PLUGIN_DIR="${IHS_ROOT}/config/webserver1"
HTTPD_CONF="${IHS_ROOT}/conf/httpd.conf"

PASS="  [OK]"
FAIL="  [FAIL]"

echo ""
echo "=== Dynamic Routing Check ==="
echo ""

# ── 1. Members reachable directly ──────────────────────────────────────────
echo "1. Members reachable directly (bypassing IHS):"
for p in 9081 9082 9083 9084; do
    c=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${p}/server-info/" 2>/dev/null)
    [[ "${c}" == "200" ]] && echo "${PASS} port ${p}: HTTP ${c}" \
                          || echo "${FAIL} port ${p}: HTTP ${c} (member down or app not deployed)"
done
echo ""

# ── 2. httpd.conf points at the right plugin-cfg.xml ──────────────────────
echo "2. WebSpherePluginConfig directive:"
ACTIVE=$(grep -i "WebSpherePluginConfig" "${HTTPD_CONF}" 2>/dev/null | head -1)
echo "     ${ACTIVE}"
if echo "${ACTIVE}" | grep -q "config/webserver1"; then
    echo "${PASS} points at config/webserver1/plugin-cfg.xml"
else
    echo "${FAIL} still pointing at conf/plugin-cfg.xml — re-run step2"
fi
echo ""

# ── 3. Installed plugin-cfg.xml has IntelligentManagement ─────────────────
echo "3. Installed plugin-cfg.xml has <IntelligentManagement>:"
if grep -q "IntelligentManagement" "${PLUGIN_DIR}/plugin-cfg.xml" 2>/dev/null; then
    echo "${PASS} found"
    grep -o 'host="[^"]*" port="[^"]*"' "${PLUGIN_DIR}/plugin-cfg.xml" | head -3 | sed 's/^/       /'
else
    echo "${FAIL} missing — re-run step2"
fi
echo ""

# ── 4. Keystore files present ─────────────────────────────────────────────
echo "4. Keystore files in ${PLUGIN_DIR}:"
for ext in kdb sth; do
    [[ -f "${PLUGIN_DIR}/plugin-key.${ext}" ]] \
        && echo "${PASS} plugin-key.${ext}" \
        || echo "${FAIL} plugin-key.${ext} missing — re-run step2"
done
echo ""

# ── 5. Controller dynamic routing endpoint ────────────────────────────────
echo "5. Controller /ibm/api/dynamicRouting endpoint (https://localhost:9443):"
ODR=$(curl -k -s -o /dev/null -w "%{http_code}" \
    -u admin:admin "https://localhost:9443/ibm/api/dynamicRouting" 2>/dev/null)
[[ "${ODR}" == "200" ]] \
    && echo "${PASS} HTTP ${ODR} — endpoint reachable, WAS plugin can connect" \
    || echo "${FAIL} HTTP ${ODR} — endpoint not available (dynamicRouting-1.0 feature loaded?)"

if [[ "${ODR}" != "200" ]]; then
    CTRL_LOG="${WORKSPACE_ROOT}/installs/controller/wlp/usr/servers/controller/logs/messages.log"
    echo ""
    echo "     Controller features loaded (from messages.log):"
    grep "CWWKF0012I" "${CTRL_LOG}" 2>/dev/null | tail -1 | sed 's/^/     /'
    echo ""
    echo "     Controller errors (last 10 lines with ERROR/CWWK):"
    grep -E "ERROR|CWWK[A-Z][0-9]+E" "${CTRL_LOG}" 2>/dev/null \
        | tail -10 | sed 's/^/     /' \
        || echo "     (no errors found or log not accessible)"
fi
echo ""

# ── 6. IHS via plugin ─────────────────────────────────────────────────────
echo "6. Request through IHS → plugin → member:"
IHS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:1080/server-info/ 2>/dev/null)
[[ "${IHS}" == "200" ]] \
    && echo "${PASS} HTTP ${IHS} — dynamic routing is working" \
    || echo "${FAIL} HTTP ${IHS}"
echo ""

# ── 7. Plugin log — last relevant lines ──────────────────────────────────
echo "7. Plugin log — last relevant lines:"
grep -i "transport\|connect\|routing\|app server\|intelligent" \
    "${IHS_ROOT}/logs/webserver1/http_plugin.log" 2>/dev/null \
    | tail -8 | sed 's/^/     /' \
    || echo "     (log not found)"
echo ""
