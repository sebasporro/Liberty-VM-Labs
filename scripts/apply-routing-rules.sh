#!/bin/bash
# Controls how IHS routes requests across collective members.
#
# Usage:
#   scripts/apply-routing-rules.sh all       # round-robin across all members
#   scripts/apply-routing-rules.sh member1   # member1 answers; member2 on standby
#   scripts/apply-routing-rules.sh member2   # member2 answers; member1 on standby
#
# How it works:
#   The WAS plug-in uses IntelligentManagement mode — it polls the controller
#   at /ibm/api/dynamicRouting and receives the list of currently running
#   members. Stopping a member removes it from that list within one poll
#   cycle. If the active member goes down, the controller re-advertises the
#   standby member and the plug-in fails over automatically.

TARGET="$1"
M1_BIN="/home/itzuser/Liberty-VM-Labs/installs/member1/wlp/bin/server"
M2_BIN="/home/itzuser/Liberty-VM-Labs/installs/member2/wlp/bin/server"

if [[ "$TARGET" != "member1" && "$TARGET" != "member2" && "$TARGET" != "all" ]]; then
    echo "Usage: $0 <all | member1 | member2>"
    exit 1
fi

case "$TARGET" in
    all)
        echo "Starting both members — round-robin active..."
        "$M1_BIN" start member1 2>/dev/null
        "$M2_BIN" start member2 2>/dev/null
        ;;
    member1)
        echo "Stopping member2 — member1 will answer all requests..."
        "$M2_BIN" stop member2
        ;;
    member2)
        echo "Stopping member1 — member2 will answer all requests..."
        "$M1_BIN" stop member1
        ;;
esac

echo ""
echo "Test: for i in \$(seq 6); do curl -s http://localhost:1080/server-info/ | grep -o 'member[0-9]*'; done"
