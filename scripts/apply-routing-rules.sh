#!/bin/bash
# Usage:
#   scripts/apply-routing-rules.sh member1   # pin to member1
#   scripts/apply-routing-rules.sh member2   # pin to member2
#   scripts/apply-routing-rules.sh all       # round-robin (default)
#
# HOW THIS WORKS
# --------------
# The live plugin-cfg.xml uses IntelligentManagement mode: the WAS plug-in
# polls the controller at /ibm/api/dynamicRouting and receives a live list
# of healthy collective members. The controller distributes across all of
# them round-robin by default.
#
# In this mode <routingRules> in server.xml dropins have NO effect —
# they only work with the older /wr-based dynamic routing.
#
# Pinning is achieved here by stopping the members we do NOT want to receive
# traffic. The controller stops advertising stopped members immediately, so
# the plug-in routes exclusively to the running one within one poll cycle.

TARGET="$1"
CONTROLLER="/home/itzuser/Liberty-VM-Labs/installs/controller/wlp/bin/server"
MEMBER1="/home/itzuser/Liberty-VM-Labs/installs/member1/wlp/bin/server"
MEMBER2="/home/itzuser/Liberty-VM-Labs/installs/member2/wlp/bin/server"

if [[ "$TARGET" != "member1" && "$TARGET" != "member2" && "$TARGET" != "all" ]]; then
    echo "Usage: $0 <member1 | member2 | all>"
    exit 1
fi

case "$TARGET" in
    member1)
        echo "Pinning to member1: stopping member2..."
        "$MEMBER2" stop member2
        echo "Done. All traffic → member1."
        ;;
    member2)
        echo "Pinning to member2: stopping member1..."
        "$MEMBER1" stop member1
        echo "Done. All traffic → member2."
        ;;
    all)
        echo "Restoring round-robin: starting both members..."
        "$MEMBER1" start member1 2>/dev/null; sleep 2
        "$MEMBER2" start member2 2>/dev/null
        echo "Done. Traffic will round-robin across member1 and member2."
        ;;
esac

echo ""
echo "Test:"
echo "  for i in \$(seq 6); do curl -s http://localhost:1080/server-info/ | grep -o 'member[0-9]*'; done"
