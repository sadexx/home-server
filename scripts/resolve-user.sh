#!/usr/bin/env bash

resolve_target_user() {
  TARGET_USER="${SUDO_USER:-$(whoami)}"
  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  
  if [[ -z "$TARGET_HOME" ]]; then
    echo "ERROR: could not resolve home directory for user '${TARGET_USER}'"
    exit 1
  fi

  export TARGET_USER TARGET_HOME
}
