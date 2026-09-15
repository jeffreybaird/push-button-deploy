#!/usr/bin/env bash
# Install the runner's deploy key; the workflow supplies SSH_PRIVATE_KEY and HOST.
set -euo pipefail
mkdir -p "$HOME/.ssh"
( umask 077; printf '%s\n' "${SSH_PRIVATE_KEY:?SSH_PRIVATE_KEY required}" > "$HOME/.ssh/deploy_key" )
chmod 600 "$HOME/.ssh/deploy_key"
ssh-keyscan -H "${HOST:?HOST required}" >> "$HOME/.ssh/known_hosts" 2>/dev/null
