#!/bin/bash
# =============================================================================
# add-member.sh — DEPRECATED
# Renamed to add-member-26.sh for naming consistency with add-member-25.sh.
# This wrapper delegates to add-member-26.sh unchanged.
# =============================================================================
echo "NOTE: add-member.sh has been renamed to add-member-26.sh."
echo "      Delegating to add-member-26.sh ..."
echo ""
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/add-member-26.sh" "$@"
