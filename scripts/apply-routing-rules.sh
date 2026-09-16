#!/bin/bash
# =============================================================================
# apply-routing-rules.sh
# Pins /server-info/* to a collective member, or restores default dynamic routing.
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-set-env.sh"

usage() {
  echo "Usage: $0 -s <member1|member2|member3|member4|all>"
  echo "  member1-member4: route /server-info/* to that member"
  echo "  all: restore routing across all available members"
}

if [[ "$#" -ne 2 || "$1" != "-s" ]]; then
  usage >&2
  exit 1
fi

TARGET="$2"
case "${TARGET}" in
  member1|member2|member3|member4|all) ;;
  *)
    usage >&2
    exit 1
    ;;
esac

CONTROLLER_DROPIN_DIR="${WORKSPACE_ROOT}/installs/controller/wlp/usr/servers/controller/configDropins/overrides"
ROUTING_RULES_FILE="${CONTROLLER_DROPIN_DIR}/routing-rules.xml"

if [[ ! -d "${CONTROLLER_DROPIN_DIR}" ]]; then
  echo "ERROR: Controller overrides directory does not exist: ${CONTROLLER_DROPIN_DIR}" >&2
  exit 1
fi

if [[ "${TARGET}" == "all" ]]; then
  rm -f "${ROUTING_RULES_FILE}"
  echo "Removed routing rule; /server-info/* uses the default dynamic-routing member set."
  exit 0
fi

cat > "${ROUTING_RULES_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<server description="Dynamic Routing Rules">
    <dynamicRouting>
        <routingRules webServers="webserver1">
            <routingRule order="100" matchExpression="URI LIKE '/server-info%'">
                <permitAction>
                    <loadBalanceEndPoints>
                        <endpoint destination="server=*,*,*,${TARGET}"/>
                    </loadBalanceEndPoints>
                </permitAction>
            </routingRule>
        </routingRules>
    </dynamicRouting>
</server>
EOF

echo "Pinned /server-info/* to ${TARGET}."
echo "Liberty applies the routing-rule change dynamically; no IHS or controller restart is needed."
echo ""
echo "Verify:"
echo "  for i in \$(seq 6); do curl -s -c /dev/null http://localhost:1080/server-info/api/health | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"server\"][\"port\"])'; done"
