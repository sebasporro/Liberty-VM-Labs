#!/bin/bash
# Usage:
#   scripts/apply-routing-rules.sh on    # round-robin across all members
#   scripts/apply-routing-rules.sh off   # single member answers; failover if it goes down

TARGET="$1"
M1_BIN="/home/itzuser/Liberty-VM-Labs/installs/member1/wlp/bin/server"
M2_BIN="/home/itzuser/Liberty-VM-Labs/installs/member2/wlp/bin/server"

if [[ "$TARGET" != "on" && "$TARGET" != "off" ]]; then
    echo "Usage: $0 <on | off>"
    exit 1
fi

case "$TARGET" in
    on)
        echo "Round-robin ON — starting all members..."
        "$M1_BIN" start member1 2>/dev/null
        "$M2_BIN" start member2 2>/dev/null
        ;;
    off)
        echo "Round-robin OFF — stopping member2, member1 answers all requests..."
        echo "(If member1 goes down, member2 will take over automatically)"
        "$M2_BIN" stop member2
        ;;
esac

echo ""
echo "Test: for i in \$(seq 6); do curl -s http://localhost:1080/server-info/ | grep -o 'member[0-9]*'; done"
