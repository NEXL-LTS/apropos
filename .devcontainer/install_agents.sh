#!/usr/bin/env bash

set -euo pipefail

sudo chown -R vscode /home/vscode || true
sudo chgrp -R vscode /home/vscode || true

declare -A CMDS
CMDS[claude]="timeout 300 bash -c 'curl -fsSL https://claude.ai/install.sh | bash'"
CMDS[opencode]="timeout 300 bash -c 'curl -fsSL https://opencode.ai/install | bash'"
CMDS[cursor]="timeout 300 bash -c 'curl -fsS https://cursor.com/install | bash'"
CMDS[gemini]="sudo timeout 300 bash -c 'npm install -g @google/gemini-cli'"
CMDS[codex]="sudo timeout 300 bash -c 'npm install -g @openai/codex'"
CMDS[copilot]="sudo timeout 300 bash -c 'npm install -g @github/copilot'"

ORDER=(claude opencode cursor gemini codex copilot)

declare -A RESULTS
for name in "${ORDER[@]}"; do
    if bash -c "${CMDS[$name]}"; then
        RESULTS[$name]="OK"
    else
        RESULTS[$name]="FAILED (exit $?)"
    fi
done

echo ""
echo "=== Install Results ==="
for name in "${ORDER[@]}"; do
    printf "  %-10s %s\n" "$name" "${RESULTS[$name]}"
done
