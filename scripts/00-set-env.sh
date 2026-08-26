#!/bin/bash
# 00-set-env.sh — Shared environment for all Liberty lab scripts
# Source this file at the top of every other script: source "$(dirname "$0")/00-set-env.sh"

# ---------------------------------------------------------------------------
# Workspace root — absolute path; all other paths are derived from here.
# Update this value if the repo is cloned to a different location.
# ---------------------------------------------------------------------------
export WORKSPACE_ROOT="/home/itzuser/Liberty-VM-Labs"

# ---------------------------------------------------------------------------
# Java 17 — resolved in order:
#   1. JAVA_HOME already set in the environment → use it as-is
#   2. SDKMAN candidate (if installed)
#   3. System java on PATH → derive JAVA_HOME from it
# ---------------------------------------------------------------------------
if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME:-}/bin/java" ]]; then
  : # already set — nothing to do
elif [[ -x "${HOME}/.sdkman/candidates/java/current/bin/java" ]]; then
  export JAVA_HOME="${HOME}/.sdkman/candidates/java/current"
else
  _java_bin=$(which java 2>/dev/null)
  if [[ -z "${_java_bin}" ]]; then
    echo "[00-set-env] ERROR: java not found on PATH. Install Java 17 and set JAVA_HOME." >&2
    exit 1
  fi
  export JAVA_HOME="$(dirname $(dirname $(readlink -f ${_java_bin})))"
fi

export PATH="${JAVA_HOME}/bin:${PATH}"

# ---------------------------------------------------------------------------
# Liberty runtime — extracted once at workspace root
# ---------------------------------------------------------------------------
export WLP_HOME="${WORKSPACE_ROOT}/wlp-26"

# ---------------------------------------------------------------------------
# Quick sanity check (only when script is executed directly, not sourced)
# ---------------------------------------------------------------------------
if [[ "${ZSH_EVAL_CONTEXT}" == "toplevel" || "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "JAVA_HOME     = ${JAVA_HOME}"
  echo "JAVA version  = $("${JAVA_HOME}/bin/java" -version 2>&1 | head -1)"
  echo "WLP_HOME      = ${WLP_HOME}"
  echo "WORKSPACE_ROOT= ${WORKSPACE_ROOT}"
fi
