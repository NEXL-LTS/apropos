#!/usr/bin/env bash
# Phase 0 interim rule-injection hook (PRD §7.2). Naive path matching only —
# no trigger index, no session dedup, PostToolUse only, inline-array `paths:`
# frontmatter only (no Layer 3 `contents:`). muninn's own binary replaces this
# at the self-host milestone (PRD M6), after which this script is deleted.
#
# A conventions tool must FAIL OPEN: on any error it emits nothing and exits 0,
# so it can never block or break an edit. Every step below tolerates failure.
set -uo pipefail
export LC_ALL=C  # silence locale warnings from perl/awk in minimal environments

input="$(cat 2>/dev/null || true)"

# Dependencies are best-effort; absence means "inject nothing", never an error.
command -v jq >/dev/null 2>&1 || exit 0
command -v perl >/dev/null 2>&1 || exit 0

file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
[ -n "$file_path" ] || exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$cwd" ] || cwd="$PWD"

# Relativize the edited path to the repo root.
rel="${file_path#"$cwd"/}"

conv_dir="$cwd/docs/conventions"
[ -d "$conv_dir" ] || exit 0

# Translate a path glob (with ** and *) to an anchored regex.
glob_to_regex() {
  printf '%s' "$1" | perl -pe '
    s/([.+(){}\[\]^\$|\\])/\\$1/g;   # escape regex specials
    s/\*\*/\x00/g;                    # ** -> placeholder
    s/\*/[^\/]*/g;                    # * -> non-slash run
    s/\x00/.*/g;                      # ** -> anything
    s/\?/[^\/]/g;                     # ? -> single non-slash
  '
}

matched=""
while IFS= read -r -d '' file; do
  first="$(head -n1 "$file" 2>/dev/null || true)"
  [ "$first" = "---" ] || continue

  # Extract the inline-array `paths:` line from the frontmatter block.
  paths_line="$(awk 'NR==1&&$0=="---"{f=1;next} f&&/^---/{exit} f&&/^paths:/{print;exit}' "$file" 2>/dev/null || true)"
  [ -n "$paths_line" ] || continue

  hit=0
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    re="^$(glob_to_regex "$pat")\$"
    if [[ "$rel" =~ $re ]]; then hit=1; break; fi
  done < <(printf '%s' "$paths_line" | grep -oE '"[^"]*"' | tr -d '"')

  [ "$hit" -eq 1 ] || continue

  name="${file#"$cwd"/}"
  body="$(awk 'NR==1&&$0=="---"{infm=1;next} infm&&/^---/{infm=0;next} {if(!infm)print}' "$file" 2>/dev/null || true)"
  block="Convention (${name}):

${body}"
  if [ -z "$matched" ]; then matched="$block"; else matched="$matched

---

$block"; fi
done < <(find "$conv_dir" -type f -name '*.md' -print0 2>/dev/null | sort -z)

[ -n "$matched" ] || exit 0

# 10k-char safety cap (PRD §5.4).
if [ "${#matched}" -gt 9000 ]; then
  matched="${matched:0:9000}

[...truncated; read the cited files]"
fi

jq -n --arg ctx "$matched" \
  '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}' 2>/dev/null || true
exit 0
