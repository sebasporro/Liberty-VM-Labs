#!/bin/bash
# Usage:
#   scripts/apply-routing-rules.sh on    # round-robin across all members
#   scripts/apply-routing-rules.sh off   # single member answers; failover if it goes down
#
# Round-robin requires IgnoreAffinityRequests="true" in plugin-cfg.xml so the
# plug-in does not pin clients to the same member via JSESSIONID cookie.
# This script patches that attribute and manages member start/stop accordingly.

TARGET="$1"
PLUGIN_CFG="/home/itzuser/usr/IBM/IHS/plugin/config/webserver1/plugin-cfg.xml"
M1_BIN="/home/itzuser/Liberty-VM-Labs/installs/member1/wlp/bin/server"
M2_BIN="/home/itzuser/Liberty-VM-Labs/installs/member2/wlp/bin/server"
APACHECTL="/home/itzuser/usr/IBM/IHS/bin/apachectl"

if [[ "$TARGET" != "on" && "$TARGET" != "off" ]]; then
    echo "Usage: $0 <on | off>"
    exit 1
fi

# Patch IgnoreAffinityRequests in plugin-cfg.xml
# on  → true  (plug-in ignores JSESSIONID cookie → genuine round-robin)
# off → false (plug-in pins client to first member via cookie → single server)
AFFINITY_VAL="false"
[[ "$TARGET" == "on" ]] && AFFINITY_VAL="true"

sed -i "s/IgnoreAffinityRequests=\"[^\"]*\"/IgnoreAffinityRequests=\"${AFFINITY_VAL}\"/" "$PLUGIN_CFG"
echo "IgnoreAffinityRequests → ${AFFINITY_VAL} (patched in plugin-cfg.xml)"

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

# Graceful restart so IHS re-reads the patched plugin-cfg.xml immediately
"$APACHECTL" graceful

echo ""
echo "Test: for i in \$(seq 6); do curl -s http://localhost:1080/server-info/ | grep -o 'member[0-9]*'; done"
