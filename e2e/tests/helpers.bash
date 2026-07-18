# Shared helpers for the muninn e2e bats suite.
#
# Loaded by each *.bats file via `load helpers`. Provides the sample-repo
# scaffolding, the muninn-on-PATH bootstrap, and the `claude -p` runner. The
# per-layer sentinels and prompts live here so the test files stay declarative.

# --- per-layer sentinels (each appears in exactly one convention doc) ----------
export SENTINEL_L2="muninn-rule:L2-7Q2X"
export SENTINEL_L3="muninn-rule:L3-K9F4"
export SENTINEL_L4="muninn-rule:L4-Q7X2"

export PROMPT_L2="Add a function shout_twice(text) to src/util.py that returns text uppercased and repeated twice."
export PROMPT_L3="Add a stub function sync() to scripts/jobs.py that raises NotImplementedError."
export PROMPT_L4="Add a new arithmetic operation divide(a, b) to the calc library in lib/calc.py."

_e2e_dir()    { cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd; }
_repo_root()  { cd "$(_e2e_dir)/.." && pwd; }

# Ensure the muninn binary is built and resolves on PATH as the bare command
# `muninn` (the sample's hooks call `muninn hook pre|post`). Idempotent: builds
# only when bin/muninn is missing, then symlinks it into a stable gitignored dir.
ensure_muninn() {
  local repo bin bindir
  repo="$(_repo_root)"
  bin="$repo/bin/muninn"
  [ -x "$bin" ] || ( cd "$repo" && make release >/dev/null )
  # Symlink into a run-scoped temp dir (auto-cleaned by bats, outside the repo)
  # so the sample's bare `muninn hook ...` commands resolve without polluting
  # the tree or the user's ~/.local/bin.
  bindir="$BATS_RUN_TMPDIR/bin"
  mkdir -p "$bindir"
  ln -sf "$bin" "$bindir/muninn"
  export PATH="$bindir:$PATH"
}

# Stand up an isolated sample repo in this test's temp dir and set $WORK.
# Arg 1: "with" (muninn wired) or "without" (hooks + generated skills removed).
# It is a git repo OUTSIDE this project so muninn's root resolution stops here
# and resolves the sample's conventions, not muninn's own.
new_sample() {
  local mode="${1:-with}"
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK"
  cp -r "$(_e2e_dir)/project/." "$WORK"/
  (
    cd "$WORK" \
      && git init -q . \
      && git config user.email e2e@example.com \
      && git config user.name e2e \
      && git add -A \
      && git commit -qm sample
  ) >/dev/null
  muninn generate --repo-root "$WORK" >/dev/null 2>&1
  if [ "$mode" = "without" ]; then
    printf '{"hooks":{}}\n' > "$WORK/.claude/settings.json"
    rm -rf "$WORK/.claude/skills"
    rm -f "$WORK/.opencode/plugins/muninn.js"
    # Remove the sentinel-bearing convention docs themselves, not just the
    # delivery mechanism. Without this, a sufficiently agentic model (observed
    # with OpenCode's build agent, which readily runs `cat docs/conventions/...`
    # on its own initiative after reading AGENTS.md's pointer to that
    # directory) can discover the sentinel by direct exploration — a path that
    # has nothing to do with muninn and would falsely fail the without-muninn
    # control.
    rm -f "$WORK/docs/conventions/src-rule.md" \
          "$WORK/docs/conventions/stub-rule.md" \
          "$WORK/docs/conventions/workflows/add-operation.md"
  fi
  export WORK
}

# Hook payloads for the deterministic delivery checks.
pre_payload() {  # arg: repo-relative file path
  printf '{"session_id":"det","tool_name":"Edit","cwd":"%s","tool_input":{"file_path":"%s/%s","new_string":"def helper():\\n    return 1\\n"}}' "$WORK" "$WORK" "$1"
}
post_payload() {  # arg: repo-relative file path (content raises NotImplementedError)
  printf '{"session_id":"det","tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s/%s","content":"def x():\\n    raise NotImplementedError\\n"}}' "$WORK" "$WORK" "$1"
}

# --- live claude runner -------------------------------------------------------
claude_ready() { command -v claude >/dev/null 2>&1; }
opencode_ready() { command -v opencode >/dev/null 2>&1; }

# Skip the current test unless a real, authenticated claude is available. Uses a
# run-wide flag so that once claude is found unusable, later live tests skip
# immediately instead of each paying for a failed call.
require_live_claude() {
  claude_ready || skip "claude not on PATH"
  [ -f "$BATS_RUN_TMPDIR/claude_unusable" ] && skip "claude unusable (detected earlier)"
  return 0
}

# Strip ANSI escape codes (opencode's TUI-style banner/formatting) so a log
# excerpt is readable as plain text in a one-line skip reason.
_strip_ansi() { sed -E $'s/\x1b\\[[0-9;]*[a-zA-Z]//g'; }

# A compact, single-line excerpt of a log file's *last* ~300 characters
# (after stripping ANSI codes and blank lines) — usually where the actual
# error message is. Empty string if the file is missing or empty.
_oc_excerpt() {  # arg: log file path
  local text
  text="$(_strip_ansi <"$1" 2>/dev/null | sed '/^[[:space:]]*$/d' | tr '\n' ' ' | sed 's/  */ /g')"
  if [ "${#text}" -gt 300 ]; then
    text="...${text: -300}"
  fi
  printf '%s' "$text"
}

# Skip unless a real, authenticated opencode is available. Uses a run-wide
# unusable flag (holding the *reason*, not just a marker) so that once
# opencode is found unusable, later live tests skip immediately with the same
# diagnostic instead of each re-probing and re-discovering it independently.
require_live_opencode() {
  opencode_ready || skip "opencode not on PATH"
  if [ -f "$BATS_RUN_TMPDIR/opencode_unusable" ]; then
    skip "opencode unusable (detected earlier): $(cat "$BATS_RUN_TMPDIR/opencode_unusable")"
  fi
  # Quick auth probe: `opencode run` exits 0 only when the CLI is properly
  # configured (a provider is authenticated). Any non-zero exit marks it
  # unusable for the rest of the run. Output is captured (not discarded) so a
  # failure's actual cause — not just an exit code — is visible in the skip
  # reason. Common cause: no provider authenticated — run `opencode auth
  # login` (see e2e/README.md's CI-safety section).
  if [ ! -f "$BATS_RUN_TMPDIR/opencode_auth_ok" ]; then
    local log="$BATS_RUN_TMPDIR/opencode_auth_probe.log" rc=0
    timeout 30 opencode run "reply with the single word READY" >"$log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      local reason="exit $rc: $(_oc_excerpt "$log")"
      printf '%s' "$reason" >"$BATS_RUN_TMPDIR/opencode_unusable"
      skip "opencode auth probe failed ($reason) — full output: $log"
    fi
    touch "$BATS_RUN_TMPDIR/opencode_auth_ok"
  fi
  return 0
}

# Run claude non-interactively in $WORK on the DEFAULT config (so real auth
# applies) with the sample's own project hooks. Inherited CLAUDE_CODE_* session
# vars are unset for a clean nested session; --permission-mode auto lets the edit
# through. Result JSON is written to $WORK/_out.json and stderr to $WORK/_err.txt.
#
# Any run that did not complete cleanly — a nonzero exit (CLI / connectivity
# error), or a result flagged `is_error` (e.g. not logged in, rate limited) — is
# treated as "claude could not run" and SKIPs the test (and marks claude unusable
# so later live tests skip immediately instead of each paying for a failed call).
# Only a clean run (exit 0, is_error false) returns, so a genuine "muninn did not
# influence the output" still fails loudly at the assertion.
run_claude() {  # arg: prompt
  local dbg="$BATS_TEST_TMPDIR/hooks.log"
  local out="$WORK/_out.json" err="$WORK/_err.txt"
  local model_args=()
  [ -n "${E2E_MODEL:-}" ] && model_args=(--model "$E2E_MODEL")
  local rc=0
  (
    cd "$WORK" && env \
      -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SSE_PORT -u CLAUDE_CODE_EXECPATH \
      claude \
        -p "$1" \
        --output-format json \
        --permission-mode auto \
        --debug hooks --debug-file "$dbg" \
        "${model_args[@]}"
  ) >"$out" 2>"$err" || rc=$?

  local reason=""
  if [ "$rc" -ne 0 ]; then
    reason="claude exited $rc"
  elif ! jq -e '.is_error == false' "$out" >/dev/null 2>&1; then
    reason="claude reported an error or produced no JSON result"
  fi
  if [ -n "$reason" ]; then
    touch "$BATS_RUN_TMPDIR/claude_unusable"
    skip "$reason"
  fi
}

# Run opencode non-interactively in $WORK. The plugin at
# .opencode/plugins/muninn.js bridges the hook calls; muninn must be on PATH.
# Output is written to $WORK/_oc_out.txt / _oc_err.txt; a nonzero exit skips
# the test with an excerpt of that output in the skip reason (not just the
# exit code) so the actual cause is visible without opening the log files.
run_opencode() {  # arg: prompt
  local model_args=()
  [ -n "${E2E_MODEL:-}" ] && model_args=(--model "$E2E_MODEL")
  local rc=0
  (
    cd "$WORK" && opencode run "$1" "${model_args[@]}"
  ) >"$WORK/_oc_out.txt" 2>"$WORK/_oc_err.txt" || rc=$?
  if [ "$rc" -ne 0 ]; then
    local reason="exit $rc: $(_oc_excerpt "$WORK/_oc_err.txt")"
    [ -z "$(_oc_excerpt "$WORK/_oc_err.txt")" ] && reason="exit $rc: $(_oc_excerpt "$WORK/_oc_out.txt")"
    printf '%s' "$reason" >"$BATS_RUN_TMPDIR/opencode_unusable"
    skip "opencode run failed ($reason) — full output: $WORK/_oc_out.txt / $WORK/_oc_err.txt"
  fi
}
