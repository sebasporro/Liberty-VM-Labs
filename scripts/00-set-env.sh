#!/bin/zsh
# 00-set-env.sh — Shared environment for all Liberty lab scripts
# Source this file at the top of every other script: source "$(dirname "$0")/00-set-env.sh"

# ---------------------------------------------------------------------------
# Java 17 — resolved via SDKMAN (canonical path, avoids macOS java_home quirk)
# /usr/libexec/java_home -v 17 returns the wrong JDK on this machine because
# the Java 17 install is managed by SDKMAN and not registered in the macOS
# JavaVirtualMachines registry.
# ---------------------------------------------------------------------------
SDKMAN_JAVA17="/Users/sebastianporro/.sdkman/candidates/java/17.0.15-sem"

if [[ -x "${SDKMAN_JAVA17}/bin/java" ]]; then
  export JAVA_HOME="${SDKMAN_JAVA17}"
else
  # Fallback: try macOS java_home for 17, then use whatever is on PATH
  _jhome=$(/usr/libexec/java_home -v 17 2>/dev/null)
  if [[ -n "${_jhome}" && -x "${_jhome}/bin/java" ]]; then
    export JAVA_HOME="${_jhome}"
  else
    echo "[00-set-env] WARNING: Java 17 not found via SDKMAN or java_home." >&2
    echo "[00-set-env] Falling back to system java: $(which java)" >&2
    export JAVA_HOME="$(dirname $(dirname $(which java)))"
  fi
fi

export PATH="${JAVA_HOME}/bin:${PATH}"

# ---------------------------------------------------------------------------
# Workspace root — absolute path; all other paths are derived from here
# ---------------------------------------------------------------------------
export WORKSPACE_ROOT="/Users/sebastianporro/Documents/2026/ITZ/Liberty-VM-Labs"

# ---------------------------------------------------------------------------
# Liberty runtime — extracted once at workspace root
# ---------------------------------------------------------------------------
export WLP_HOME="${WORKSPACE_ROOT}/wlp-26"

# ---------------------------------------------------------------------------
# Quick sanity check (only when script is executed directly, not sourced)
# ---------------------------------------------------------------------------
if [[ "${ZSH_EVAL_CONTEXT}" == "toplevel" ]]; then
  echo "JAVA_HOME     = ${JAVA_HOME}"
  echo "JAVA version  = $("${JAVA_HOME}/bin/java" -version 2>&1 | head -1)"
  echo "WLP_HOME      = ${WLP_HOME}"
  echo "WORKSPACE_ROOT= ${WORKSPACE_ROOT}"
fi
