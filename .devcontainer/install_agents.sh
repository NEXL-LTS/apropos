#!/usr/bin/env bash

set -euo pipefail

sudo chown -R vscode /home/vscode || true
sudo chgrp -R vscode /home/vscode || true

declare -A PIDS
declare -A CMDS

CMDS[opencode]="timeout 300 bash -c 'curl -fsSL https://opencode.ai/install | bash'"
CMDS[cursor]="timeout 300 bash -c 'curl -fsS https://cursor.com/install | bash'"
CMDS[gemini]="sudo timeout 300 bash -c 'npm install -g @google/gemini-cli'"
CMDS[codex]="sudo timeout 300 bash -c 'npm install -g @openai/codex'"
CMDS[copilot]="sudo timeout 300 bash -c 'npm install -g @github/copilot'"
CMDS[claude]="timeout 300 bash -c 'curl -fsSL https://claude.ai/install.sh | bash'"

for name in "${!CMDS[@]}"; do
    bash -c "${CMDS[$name]}" &
    PIDS[$name]=$!
done

declare -A RESULTS
for name in "${!PIDS[@]}"; do
    if wait "${PIDS[$name]}"; then
        RESULTS[$name]="OK"
    else
        RESULTS[$name]="FAILED (exit $?)"
    fi
done

echo ""
echo "=== Install Results ==="
for name in "${!RESULTS[@]}"; do
    printf "  %-10s %s\n" "$name" "${RESULTS[$name]}"
done
