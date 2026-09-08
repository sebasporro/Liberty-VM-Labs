#!/bin/bash
# collect-debug.sh — Collect all diagnostic info for dynamic routing failures.
# Writes a single report to /tmp/liberty-debug-$(date +%Y%m%d-%H%M%S).txt
# Run: bash scripts/collect-debug.sh
# Then paste the output file content back for analysis.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

IHS_ROOT="${IHS_INSTALL_ROOT:-/home/itzuser/IBM/HTTPServer}"
CTRL_SERVER="${WORKSPACE_ROOT}/installs/controller/wlp/usr/servers/controller"
PLUGIN_DIR="${IHS_ROOT}/config/webserver1"
OUT="/tmp/liberty-debug-$(date +%Y%m%d-%H%M%S).txt"

# Helper: print a titled section
section() { echo "" >> "${OUT}"; echo "########################################" >> "${OUT}"; echo "## $*" >> "${OUT}"; echo "########################################" >> "${OUT}"; echo "" >> "${OUT}"; }

echo "Collecting debug info..."
echo "Output: ${OUT}"

> "${OUT}"
echo "Liberty Dynamic Routing — Debug Report" >> "${OUT}"
echo "Generated: $(date)" >> "${OUT}"
echo "Hostname:  $(hostname)" >> "${OUT}"
echo "User:      $(whoami)" >> "${OUT}"

# ---------------------------------------------------------------------------
section "1. CONTROLLER: installed features (last CWWKF0012I)"
grep "CWWKF0012I" "${CTRL_SERVER}/logs/messages.log" 2>/dev/null | tail -1 >> "${OUT}"

# ---------------------------------------------------------------------------
section "2. CONTROLLER: all errors and warnings since last start"
# Find timestamp of last server start, print everything after it
LAST_START=$(grep -n "CWWKF0011I\|server is ready" "${CTRL_SERVER}/logs/messages.log" 2>/dev/null | tail -1 | cut -d: -f1)
if [[ -n "${LAST_START}" ]]; then
    echo "(Lines after last server start, line ${LAST_START})" >> "${OUT}"
    tail -n +"${LAST_START}" "${CTRL_SERVER}/logs/messages.log" \
        | grep -E "^\[|CWWK[A-Z][0-9]+[EW]|Exception|ERROR|FFDC|dynamicRouting|CWWKV|CWWKO|CWWKS" \
        >> "${OUT}"
else
    grep -E "CWWK[A-Z][0-9]+[EW]|Exception|ERROR|FFDC|dynamicRouting|CWWKV|CWWKO|CWWKS" \
        "${CTRL_SERVER}/logs/messages.log" 2>/dev/null | tail -40 >> "${OUT}"
fi

# ---------------------------------------------------------------------------
section "3. CONTROLLER: last 30 lines of messages.log"
tail -30 "${CTRL_SERVER}/logs/messages.log" 2>/dev/null >> "${OUT}"

# ---------------------------------------------------------------------------
section "4. CONTROLLER: configDropins/overrides — file list"
ls -la "${CTRL_SERVER}/configDropins/overrides/" 2>/dev/null >> "${OUT}"

# ---------------------------------------------------------------------------
section "5. CONTROLLER: role-override.xml (live)"
cat "${CTRL_SERVER}/configDropins/overrides/role-override.xml" 2>/dev/null >> "${OUT}"

# ---------------------------------------------------------------------------
section "6. CONTROLLER: collective-create.xml (live)"
cat "${CTRL_SERVER}/configDropins/overrides/collective-create.xml" 2>/dev/null >> "${OUT}"

# ---------------------------------------------------------------------------
section "7. CONTROLLER: ports-override.xml (live)"
cat "${CTRL_SERVER}/configDropins/overrides/ports-override.xml" 2>/dev/null >> "${OUT}"

# ---------------------------------------------------------------------------
section "8. CONTROLLER: server.xml"
cat "${CTRL_SERVER}/server.xml" 2>/dev/null >> "${OUT}"

# ---------------------------------------------------------------------------
section "9. CONTROLLER: bootstrap.properties (passwords masked)"
sed 's/password=.*/password=***/' "${CTRL_SERVER}/bootstrap.properties" 2>/dev/null >> "${OUT}"

# ---------------------------------------------------------------------------
section "10. CONTROLLER: FFDC summary files (all)"
for f in "${CTRL_SERVER}/logs/ffdc/exception_summary_"*.log; do
    [[ -f "${f}" ]] || continue
    echo "--- ${f} ---" >> "${OUT}"
    cat "${f}" >> "${OUT}"
    echo "" >> "${OUT}"
done

# ---------------------------------------------------------------------------
section "11. CONTROLLER: latest FFDC full file"
LATEST_FFDC=$(ls -t "${CTRL_SERVER}/logs/ffdc/ffdc_"*.log 2>/dev/null | head -1)
if [[ -n "${LATEST_FFDC}" ]]; then
    echo "File: ${LATEST_FFDC}" >> "${OUT}"
    head -150 "${LATEST_FFDC}" >> "${OUT}"
else
    echo "(no FFDC files found)" >> "${OUT}"
fi

# ---------------------------------------------------------------------------
section "12. CONTROLLER: /ibm/api/dynamicRouting — HTTP status + response body"
echo "--- Without Accept header (what the WAS plugin sends) ---" >> "${OUT}"
curl -k -u admin:admin -s -w "\nHTTP_STATUS: %{http_code}\n" \
    https://localhost:9443/ibm/api/dynamicRouting 2>&1 >> "${OUT}"
echo "" >> "${OUT}"
echo "--- With Accept: application/json (full response body) ---" >> "${OUT}"
curl -k -u admin:admin -H "Accept: application/json" \
    -s -w "\nHTTP_STATUS: %{http_code}\n" \
    https://localhost:9443/ibm/api/dynamicRouting 2>&1 >> "${OUT}"
echo "" >> "${OUT}"
echo "--- Full verbose headers (no Accept) — shows HTTP/1.1 vs HTTP/2 ---" >> "${OUT}"
curl -k -u admin:admin -s -D - -o /dev/null \
    https://localhost:9443/ibm/api/dynamicRouting 2>&1 >> "${OUT}"
echo "" >> "${OUT}"
echo "--- Protocol in use on adminCenter (HTTP/1.1 required; HTTP/2 = restart needed) ---" >> "${OUT}"
curl -k -u admin:admin -s -D - -o /dev/null \
    https://localhost:9443/adminCenter 2>/dev/null | head -1 >> "${OUT}"

# ---------------------------------------------------------------------------
section "13. CONTROLLER: /adminCenter reachable"
curl -k -s -o /dev/null -w "HTTP_STATUS: %{http_code}\n" \
    https://localhost:9443/adminCenter >> "${OUT}"

# ---------------------------------------------------------------------------
section "14. CONTROLLER: /ibm/api/collective/v1/resources (restConnector check)"
curl -k -u admin:admin -H "Accept: application/json" \
    -s -w "\nHTTP_STATUS: %{http_code}\n" \
    https://localhost:9443/ibm/api/collective/v1/resources 2>&1 | head -20 >> "${OUT}"

# ---------------------------------------------------------------------------
section "15. PLUGIN: installed plugin-cfg.xml"
cat "${PLUGIN_DIR}/plugin-cfg.xml" 2>/dev/null >> "${OUT}"

# ---------------------------------------------------------------------------
section "16. PLUGIN: IntelligentManagement stanza detail + AcceptType check"
grep -A8 "IntelligentManagement" "${PLUGIN_DIR}/plugin-cfg.xml" 2>/dev/null >> "${OUT}"
echo "" >> "${OUT}"
echo "--- AcceptType present in installed plugin-cfg.xml ---" >> "${OUT}"
if grep -q 'AcceptType' "${PLUGIN_DIR}/plugin-cfg.xml" 2>/dev/null; then
    echo "YES — AcceptType found (libodr.so will send Accept: application/json)" >> "${OUT}"
    grep 'AcceptType' "${PLUGIN_DIR}/plugin-cfg.xml" >> "${OUT}"
else
    echo "NO  — AcceptType MISSING (libodr.so will omit Accept header → controller returns HTTP 500)" >> "${OUT}"
fi

# ---------------------------------------------------------------------------
section "17. PLUGIN: keystore files present"
ls -la "${PLUGIN_DIR}/plugin-key."* 2>/dev/null >> "${OUT}"
echo "" >> "${OUT}"
echo "KDB cert list:" >> "${OUT}"
"${IHS_ROOT}/bin/gskcapicmd" -cert -list \
    -pw "Liberty26ctrl!" -db "${PLUGIN_DIR}/plugin-key.kdb" 2>&1 >> "${OUT}"

# ---------------------------------------------------------------------------
section "18. PLUGIN: http_plugin.log (last 50 lines)"
tail -50 "${IHS_ROOT}/logs/webserver1/http_plugin.log" 2>/dev/null >> "${OUT}"

# ---------------------------------------------------------------------------
section "19. IHS: httpd.conf WebSpherePluginConfig line"
grep -i "WebSpherePluginConfig\|LoadModule.*was" "${IHS_ROOT}/conf/httpd.conf" 2>/dev/null >> "${OUT}"

# ---------------------------------------------------------------------------
section "20. IHS: error_log (last 20 lines)"
tail -20 "${IHS_ROOT}/logs/error_log" 2>/dev/null >> "${OUT}"

# ---------------------------------------------------------------------------
section "21. MEMBERS: direct reachability"
for port in 9081 9082 9083 9084; do
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${port}/server-info/" 2>/dev/null)
    echo "  port ${port}: HTTP ${code}" >> "${OUT}"
done

# ---------------------------------------------------------------------------
section "22. MEMBERS: collective-join.xml from member1 (live)"
MEMBER1_JOIN="${WORKSPACE_ROOT}/installs/member1/wlp/usr/servers/member1/configDropins/overrides/collective-join.xml"
cat "${MEMBER1_JOIN}" 2>/dev/null >> "${OUT}"

# ---------------------------------------------------------------------------
section "23. NETWORK: listening ports"
ss -tlnp 2>/dev/null | grep -E ":808|:904|:908|:943" >> "${OUT}"

# ---------------------------------------------------------------------------
section "24. JAVA / LIBERTY VERSIONS"
echo "Controller Liberty version:" >> "${OUT}"
cat "${WORKSPACE_ROOT}/installs/controller/wlp/lib/versions/WebSphereApplicationServer.properties" \
    2>/dev/null | grep -i "version\|product" >> "${OUT}"
echo "" >> "${OUT}"
echo "Java version:" >> "${OUT}"
java -version 2>&1 >> "${OUT}"

# ---------------------------------------------------------------------------
section "25. REPO: current git commit"
git -C "${WORKSPACE_ROOT}" log --oneline -5 2>/dev/null >> "${OUT}"

# ---------------------------------------------------------------------------
section "26. ODR TRACE: odr-trace.xml locations and content"
echo "--- find results ---" >> "${OUT}"
find "${IHS_ROOT}" -name "odr-trace.xml" 2>/dev/null >> "${OUT}"
find "${WORKSPACE_ROOT}" -name "odr-trace.xml" 2>/dev/null >> "${OUT}"
echo "" >> "${OUT}"
for f in \
    "${IHS_ROOT}/odr-trace.xml" \
    "${IHS_ROOT}/plugin/etc/odr-trace.xml" \
    "${IHS_ROOT}/properties/odr-trace.xml" \
    "${IHS_ROOT}/config/webserver1/odr-trace.xml" \
    "${PLUGIN_DIR}/odr-trace.xml"; do
    if [[ -f "${f}" ]]; then
        echo "--- ${f} ---" >> "${OUT}"
        cat "${f}" >> "${OUT}"
        echo "" >> "${OUT}"
    fi
done

# ---------------------------------------------------------------------------
section "27. ODR: IPC socket / port file"
ls -la "${IHS_ROOT}/logs/odrlibport."* 2>/dev/null >> "${OUT}" \
    || echo "(no odrlibport files found)" >> "${OUT}"

# ---------------------------------------------------------------------------
section "28. ODR: libodr.so locations"
find "${IHS_ROOT}" -name "libodr.so" 2>/dev/null >> "${OUT}" \
    || echo "(libodr.so not found)" >> "${OUT}"

# ---------------------------------------------------------------------------
section "29. CONTROLLER: static self-routing plugin-cfg.xml (for reference only)"
# This is the controller's OWN static plugin-cfg.xml — it routes traffic to
# the controller itself and has NO IntelligentManagement stanza.
# step2 uses the WORK_DIR output of dynamicRouting setup, NOT this file.
echo "--- File info ---" >> "${OUT}"
ls -la "${CTRL_SERVER}/plugin-cfg.xml" 2>/dev/null >> "${OUT}" || echo "(not found)" >> "${OUT}"
echo "" >> "${OUT}"
echo "--- logs/state/ directory (plugin-cfg.xml written here at startup) ---" >> "${OUT}"
ls -la "${CTRL_SERVER}/logs/state/" 2>/dev/null >> "${OUT}"

# ---------------------------------------------------------------------------
section "30. PLUGIN: full plugin-cfg.xml with LogLevel set to Stats (for next run)"
# Show what log level is currently set
grep -i "LogLevel\|Log " "${PLUGIN_DIR}/plugin-cfg.xml" 2>/dev/null >> "${OUT}"

# ---------------------------------------------------------------------------
section "31. CONTROLLER: dynamic-routing.xml dropin (live content)"
# This file is not in the repo but may exist on the VM from prior manual runs.
# If it contains <ssl> or <httpEndpoint> it can conflict with ports-override.xml.
if [[ -f "${CTRL_SERVER}/configDropins/overrides/dynamic-routing.xml" ]]; then
    cat "${CTRL_SERVER}/configDropins/overrides/dynamic-routing.xml" >> "${OUT}"
else
    echo "(not present)" >> "${OUT}"
fi

# ---------------------------------------------------------------------------
section "32. MEMBERS: collective registration (visible to controller)"
# Queries the collective REST API for all registered servers.
# An empty or missing member list here means dynamic routing has no targets to route to.
echo "--- /ibm/api/collective/v1/servers (registered members) ---" >> "${OUT}"
curl -k -u admin:admin -H "Accept: application/json" \
    -s -w "\nHTTP_STATUS: %{http_code}\n" \
    "https://localhost:9443/ibm/api/collective/v1/servers" 2>&1 | head -60 >> "${OUT}"
echo "" >> "${OUT}"
echo "--- /ibm/api/collective/v1/hosts (registered hosts) ---" >> "${OUT}"
curl -k -u admin:admin -H "Accept: application/json" \
    -s -w "\nHTTP_STATUS: %{http_code}\n" \
    "https://localhost:9443/ibm/api/collective/v1/hosts" 2>&1 | head -30 >> "${OUT}"

# ---------------------------------------------------------------------------
section "33. ODR: IPC socket / port file (confirms libodr.so is initialised)"
# odrlibport.<pid> is created by libodr.so when IPC is established between
# Apache worker processes and the ODR control thread. Its absence means libodr.so
# failed to initialise (auth failure, HTTP/2 307, NULL proxy abort, etc.).
IPC_FILES=$(ls "${IHS_ROOT}/logs/odrlibport."* 2>/dev/null)
if [[ -n "${IPC_FILES}" ]]; then
    echo "IPC port files found — libodr.so initialised OK:" >> "${OUT}"
    ls -la "${IHS_ROOT}/logs/odrlibport."* 2>/dev/null >> "${OUT}"
else
    echo "NO odrlibport files found — libodr.so has NOT initialised." >> "${OUT}"
    echo "Causes: HTTP/2 on controller (307), missing AcceptType (500)," >> "${OUT}"
    echo "        SSL trust failure (unknown_ca), or IHS not running." >> "${OUT}"
fi

# ---------------------------------------------------------------------------
section "34. IHS: process list + ODR state"
echo "--- httpd processes ---" >> "${OUT}"
ps -ef 2>/dev/null | grep "[h]ttpd" >> "${OUT}"
echo "" >> "${OUT}"
echo "--- IHS error_log: ODR / plugin state lines ---" >> "${OUT}"
grep -i "ODR\|odr\|libodr\|plugin\|was_ap24\|Intelligent" \
    "${IHS_ROOT}/logs/error_log" 2>/dev/null | tail -20 >> "${OUT}"

# ---------------------------------------------------------------------------
section "35. STEP2: last run output (if captured)"
# step2 writes inline diagnostics at [5/5]. Check if the user ran with tee.
# Also show the controller messages.log window around the last setup call.
echo "--- Controller log: last dynamicRouting / CWWKV lines ---" >> "${OUT}"
grep -E "dynamicRouting|CWWKV|plugin-cfg" \
    "${CTRL_SERVER}/logs/messages.log" 2>/dev/null | tail -15 >> "${OUT}"

echo ""
echo "Done. Report written to: ${OUT}"
echo ""
echo "File size: $(wc -l < "${OUT}") lines"
echo ""
echo "To view:  cat ${OUT}"
echo "To copy:  cat ${OUT} | xclip -selection clipboard"
