#!/bin/bash
# Usage:
#   scripts/apply-routing-rules.sh member1   # pin to member1
#   scripts/apply-routing-rules.sh member2   # pin to member2
#   scripts/apply-routing-rules.sh all       # round-robin (remove pin)

TARGET="$1"
DROPIN="/home/itzuser/Liberty-VM-Labs/installs/controller/wlp/usr/servers/controller/configDropins/overrides/routing-rules.xml"
WLP="/home/itzuser/Liberty-VM-Labs/installs/controller/wlp/bin/server"

if [[ "$TARGET" != "member1" && "$TARGET" != "member2" && "$TARGET" != "all" ]]; then
    echo "Usage: $0 <member1 | member2 | all>"
    exit 1
fi

if [[ "$TARGET" == "all" ]]; then
    rm -f "$DROPIN"
    echo "Removed routing rule — round-robin restored."
else
    cat > "$DROPIN" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<server>
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
    echo "Written: $DROPIN"
    echo "Pinned to: $TARGET"
fi

# Notify Liberty to reload config now (no restart)
echo ""
echo "Triggering config refresh..."
"$WLP" pause controller --timeout=1 2>/dev/null; "$WLP" resume controller 2>/dev/null
# pause/resume is a soft signal — Liberty re-reads dropins on resume
# If that doesn't work, a stop/start is needed:
#   $WLP stop controller && $WLP start controller

echo ""
echo "Test:"
echo "  for i in \$(seq 6); do curl -s http://localhost:1080/server-info/ | grep -o 'member[0-9]*'; done"
