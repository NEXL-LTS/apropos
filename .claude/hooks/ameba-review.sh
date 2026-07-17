#!/usr/bin/env bash
# PostToolUse hook: run ameba on an edited Crystal file and inject its findings
# as PURELY INFORMATIONAL context for the agent. It reports; it never gates.
#
# Like every conventions/quality hook here it FAILS OPEN: on any error, a missing
# dependency, or a non-Crystal edit it emits nothing and exits 0, so it can never
# block or break an edit. Ameba's own non-zero exit (issues found) is swallowed —
# only the text of its report is surfaced, as advice the agent may act on or not.
set -uo pipefail
export LC_ALL=C

input="$(cat 2>/dev/null || true)"

# jq parses the payload; without it we simply inject nothing.
command -v jq >/dev/null 2>&1 || exit 0

file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
[ -n "$file_path" ] || exit 0

# Only Crystal source files are linted; anything else is a no-op.
case "$file_path" in
  *.cr) ;;
  *) exit 0 ;;
esac

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
project="${CLAUDE_PROJECT_DIR:-${cwd:-$PWD}}"

# Prefer the project-local ameba (built by `make`); fall back to one on PATH.
if [ -x "$project/bin/ameba" ]; then
  ameba="$project/bin/ameba"
elif command -v ameba >/dev/null 2>&1; then
  ameba="ameba"
else
  exit 0
fi

# The edited file may still be absent (e.g. a rename); tolerate that.
[ -f "$file_path" ] || exit 0

# Run from the project root so ameba picks up .ameba.yml. flycheck gives one
# terse `file:line:col: severity: message` line per finding. Ameba exits 0 when
# clean and 1 when it raises issues, so key off the status: only a genuine issue
# (exit 1) is surfaced. Exit 0 (clean) and any other code (internal error) stay
# silent — informational hooks must add no noise when there is nothing to report.
report="$(cd "$project" 2>/dev/null && "$ameba" --format flycheck "$file_path" 2>/dev/null)"
status=$?

[ "$status" -eq 1 ] || exit 0
[ -n "$report" ] || exit 0

context="Ameba (informational — does not block the edit) for ${file_path}:

${report}

Address these if it makes sense; they are advisory lint findings, not a gate."

jq -n --arg ctx "$context" \
  '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}' 2>/dev/null || true
exit 0
