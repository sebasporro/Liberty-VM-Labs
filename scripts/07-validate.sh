#!/bin/bash
# =============================================================================
# 07-validate.sh — Liberty Collective Lab Readiness Report
#
# Runs checks covering:
#   - Java 17
#   - Both Liberty runtimes (26.0.0.8 + 25.0.0.1)
#   - Both golden packages
#   - Controller (directory, port, Admin Center, configDropins)
#   - All 4 members (directory, port, app response, configDropins)
#   - Apache HTTP front-end (:8080)
#
# Exit 0 = all pass | Exit 1 = one or more failures
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

# ---------------------------------------------------------------------------
# Result tracking
# ---------------------------------------------------------------------------
check_count=0
pass_count=0
fail_count=0

typeset -a CHECK_LABELS
typeset -a CHECK_RESULTS
typeset -a CHECK_HINTS

run_check() {
    local label="$1"
    local hint="$2"
    shift 2
    "$@" &>/dev/null
    local rc=$?
    (( check_count++ ))
    CHECK_LABELS[check_count]="${label}"
    CHECK_HINTS[check_count]="${hint}"
    if [[ $rc -eq 0 ]]; then
        CHECK_RESULTS[check_count]="PASS"
        (( pass_count++ ))
    else
        CHECK_RESULTS[check_count]="FAIL"
        (( fail_count++ ))
    fi
}

# ---------------------------------------------------------------------------
# Check functions
# ---------------------------------------------------------------------------

check_java17() {
    java -version 2>&1 | grep -q "17\."
}

check_runtime_26() {
    test -x "${WORKSPACE_ROOT}/wlp-26/bin/server"
}

check_runtime_25() {
    test -x "${WORKSPACE_ROOT}/wlp-25/bin/server"
}

check_package_26() {
    test -f "${WORKSPACE_ROOT}/packages/liberty-package-26.0.0.8.zip"
}

check_package_25() {
    test -f "${WORKSPACE_ROOT}/packages/liberty-package-25.0.0.1.zip"
}

check_controller_dir() {
    test -d "${WORKSPACE_ROOT}/installs/controller/wlp/usr/servers/controller"
}

check_member_dir() {
    local name="$1"
    test -d "${WORKSPACE_ROOT}/installs/${name}/wlp/usr/servers/${name}"
}

check_port() {
    local port="$1"
    ss -tlnp 2>/dev/null | grep -q ":${port} "
}

check_app() {
    local port="$1"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${port}/server-info/")
    [[ "${code}" == "200" ]]
}

check_admin_center() {
    local code
    code=$(curl -k -s -o /dev/null -w "%{http_code}" https://localhost:9443/adminCenter)
    [[ "${code}" == "200" || "${code}" == "302" ]]
}

check_apache() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:8080/server-info/")
    [[ "${code}" == "200" ]]
}

check_dropins() {
    local path="$1"
    test -f "${WORKSPACE_ROOT}/installs/${path}/configDropins/overrides/role-override.xml"
}

# ---------------------------------------------------------------------------
# Run all checks
# ---------------------------------------------------------------------------

echo ""
echo "Running Liberty Collective Lab validation checks..."
echo ""

# --- Environment ---
run_check "Java 17 available" \
    "Fix: export JAVA_HOME=<path-to-java17>  e.g. /usr/lib/jvm/java-17" \
    check_java17

run_check "Liberty 26.0.0.8 runtime installed (wlp/)" \
    "Fix: scripts/01-install-runtime.sh" \
    check_runtime_26

run_check "Liberty 25.0.0.1 runtime installed (wlp-25/)" \
    "Fix: scripts/01-install-runtime-25.sh" \
    check_runtime_25

run_check "Golden package exists: liberty-package-26.0.0.8.zip" \
    "Fix: scripts/03-build-package.sh" \
    check_package_26

run_check "Golden package exists: liberty-package-25.0.0.1.zip" \
    "Fix: scripts/03-build-package-25.sh" \
    check_package_25

# --- Controller ---
run_check "Controller server directory exists" \
    "Fix: scripts/install-controller.sh" \
    check_controller_dir

run_check "Controller running on port 9443" \
    "Fix: installs/controller/wlp/bin/server start controller" \
    check_port 9443

run_check "Admin Center reachable (:9443/adminCenter)" \
    "Fix: check controller messages.log; ensure adminCenter-1.0 in role-override.xml" \
    check_admin_center

run_check "Controller configDropins/overrides populated" \
    "Fix: scripts/install-controller.sh" \
    check_dropins "controller/wlp/usr/servers/controller"

# --- Member1 (26.0.0.8) ---
run_check "Member1 server directory exists" \
    "Fix: scripts/add-member-26.sh member1" \
    check_member_dir member1

run_check "Member1 running on port 9081" \
    "Fix: installs/member1/wlp/bin/server start member1" \
    check_port 9081

run_check "Member1 app reachable (:9081/server-info/)" \
    "Fix: check member1 messages.log" \
    check_app 9081

run_check "Member1 configDropins/overrides populated" \
    "Fix: scripts/add-member-26.sh member1" \
    check_dropins "member1/wlp/usr/servers/member1"

# --- Member2 (26.0.0.8) ---
run_check "Member2 server directory exists" \
    "Fix: scripts/add-member-26.sh member2" \
    check_member_dir member2

run_check "Member2 running on port 9082" \
    "Fix: installs/member2/wlp/bin/server start member2" \
    check_port 9082

run_check "Member2 app reachable (:9082/server-info/)" \
    "Fix: check member2 messages.log" \
    check_app 9082

run_check "Member2 configDropins/overrides populated" \
    "Fix: scripts/add-member-26.sh member2" \
    check_dropins "member2/wlp/usr/servers/member2"

# --- Member3 (25.0.0.1) ---
run_check "Member3 server directory exists" \
    "Fix: scripts/add-member-25.sh member3" \
    check_member_dir member3

run_check "Member3 running on port 9083" \
    "Fix: installs/member3/wlp/bin/server start member3" \
    check_port 9083

run_check "Member3 app reachable (:9083/server-info/)" \
    "Fix: check member3 messages.log" \
    check_app 9083

run_check "Member3 configDropins/overrides populated" \
    "Fix: scripts/add-member-25.sh member3" \
    check_dropins "member3/wlp/usr/servers/member3"

# --- Member4 (25.0.0.1) ---
run_check "Member4 server directory exists" \
    "Fix: scripts/add-member-25.sh member4" \
    check_member_dir member4

run_check "Member4 running on port 9084" \
    "Fix: installs/member4/wlp/bin/server start member4" \
    check_port 9084

run_check "Member4 app reachable (:9084/server-info/)" \
    "Fix: check member4 messages.log" \
    check_app 9084

run_check "Member4 configDropins/overrides populated" \
    "Fix: scripts/add-member-25.sh member4" \
    check_dropins "member4/wlp/usr/servers/member4"

# --- Apache front-end ---
run_check "IHS/Apache front-end reachable (:8080/server-info/)" \
    "Fix: scripts/start-apache.sh then apachectl graceful" \
    check_apache

# ---------------------------------------------------------------------------
# Print Lab Readiness Report
# ---------------------------------------------------------------------------

echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║              Liberty Collective — Lab Readiness Report              ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""
printf "  %-52s  %s\n" "Check" "Result"
printf "  %-52s  %s\n" "$(printf '%.0s─' {1..52})" "──────"

for (( i=1; i<=check_count; i++ )); do
    label="${CHECK_LABELS[$i]}"
    result="${CHECK_RESULTS[$i]}"
    if [[ "${result}" == "PASS" ]]; then
        printf "  %-52s  \033[0;32m%-6s\033[0m\n" "${label}" "${result}"
    else
        printf "  %-52s  \033[0;31m%-6s\033[0m\n" "${label}" "${result}"
        printf "  \033[0;33m  → %s\033[0m\n" "${CHECK_HINTS[$i]}"
    fi
done

echo ""
printf "  %-52s  %d PASS  /  %d FAIL\n" "TOTAL (${check_count} checks)" "${pass_count}" "${fail_count}"
echo ""

if [[ "${fail_count}" -eq 0 ]]; then
    echo "  ✅  All checks passed — lab is ready!"
    echo ""
    echo "  Access points:"
    echo "    Admin Center:  https://localhost:9443/adminCenter  (admin / admin)"
    echo "    Member1:       http://localhost:9081/server-info/"
    echo "    Member2:       http://localhost:9082/server-info/"
    echo "    Member3:       http://localhost:9083/server-info/"
    echo "    Member4:       http://localhost:9084/server-info/"
    echo "    Apache LB:     http://localhost:8080/server-info/"
    echo ""
    exit 0
else
    echo "  ❌  ${fail_count} check(s) failed — see hints above to resolve."
    echo ""
    exit 1
fi
