# Shared helpers for the apropos e2e bats suite.
#
# Loaded by each *.bats file via `load helpers`. Provides the sample-repo
# scaffolding, the apropos-on-PATH bootstrap, the live CLI runners, and the
# agent-agnostic live test matrix (register_live_tests). The per-layer
# expected artifacts and prompts live in layers.bats so each layer's
# expectations stay self-contained.
#
# Deterministic delivery checks (hook payload -> injected rule, generate ->
# skill wrapper) live in the Crystal spec suite (spec/apropos/hook_spec.cr,
# spec/integration/hook_spec.cr, spec/apropos/generate_spec.cr,
# spec/integration/generate_spec.cr), not here — this suite only proves a
# real CLI agent's own output is actually steered.

# Registered CLI agents for the live matrix: "name|require_live_fn|run_fn".
# Adding a CLI agent means adding one entry here plus its require_live_<x>/
# run_<x> pair below — no per-layer test to write.
E2E_AGENTS=(
  "Claude|require_live_claude|run_claude"
  "OpenCode|require_live_opencode|run_opencode"
)

# Register the live with/without pair of tests for one layer, once per agent
# in E2E_AGENTS. Equivalent to what `@test "..." { ... }` expands to (see
# bats-preprocess) but driven from a loop, so the layer files stay agent-count
# agnostic.
#
# Args: layer label (e.g. "Layer 2", "Layer 3 (path+content)"), expected-
# artifact var name, prompt var name, target file (repo-relative, e.g.
# src/util.py).
register_live_tests() {
  local layer="$1" expect_var="$2" prompt_var="$3" target="$4"
  # Sanitize to a valid bash identifier fragment — labels (and, below, agent
  # display names) may contain spaces or punctuation (e.g.
  # "Layer 3 (path+content)", or a future "GitHub Copilot" entry).
  local slug="${layer//[^A-Za-z0-9]/_}"
  local entry name require_fn run_fn fn name_slug

  for entry in "${E2E_AGENTS[@]}"; do
    IFS='|' read -r name require_fn run_fn <<<"$entry"
    name_slug="${name//[^A-Za-z0-9]/_}"

    fn="test_${slug}_with_${name_slug}"
    eval "$fn() {
      $require_fn
      new_sample with
      $run_fn \"\$$prompt_var\"
      assert grep -q \"\$$expect_var\" \"\$WORK/$target\"
    }"
    bats_test_function --description "$layer with apropos ($name): the expected pattern lands" --tags "" -- "$fn"

    fn="test_${slug}_without_${name_slug}"
    eval "$fn() {
      $require_fn
      new_sample without
      $run_fn \"\$$prompt_var\"
      refute grep -q \"\$$expect_var\" \"\$WORK/$target\"
    }"
    bats_test_function --description "$layer without apropos ($name): the expected pattern does not appear" --tags "" -- "$fn"
  done
}

_e2e_dir()    { cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd; }
_repo_root()  { cd "$(_e2e_dir)/.." && pwd; }

# Ensure the apropos binary is built and resolves on PATH as the bare command
# `apropos` (the sample's hooks call `apropos hook pre|post`). Idempotent: builds
# only when bin/apropos is missing, then symlinks it into a stable gitignored dir.
ensure_apropos() {
  local repo bin bindir
  repo="$(_repo_root)"
  bin="$repo/bin/apropos"
  [ -x "$bin" ] || ( cd "$repo" && make release >/dev/null )
  # Symlink into a run-scoped temp dir (auto-cleaned by bats, outside the repo)
  # so the sample's bare `apropos hook ...` commands resolve without polluting
  # the tree or the user's ~/.local/bin.
  bindir="$BATS_RUN_TMPDIR/bin"
  mkdir -p "$bindir"
  ln -sf "$bin" "$bindir/apropos"
  export PATH="$bindir:$PATH"
}

# Stand up an isolated sample repo in this test's temp dir and set $WORK.
# Arg 1: "with" (apropos wired) or "without" (hooks + generated skills removed).
# It is a git repo OUTSIDE this project so apropos's root resolution stops here
# and resolves the sample's conventions, not apropos's own.
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
  apropos generate --repo-root "$WORK" >/dev/null 2>&1
  if [ "$mode" = "without" ]; then
    printf '{"hooks":{}}\n' > "$WORK/.claude/settings.json"
    rm -rf "$WORK/.claude/skills"
    rm -f "$WORK/.opencode/plugins/apropos.js"
    # Remove the convention docs themselves, not just the delivery mechanism.
    # Without this, a sufficiently agentic model (observed with OpenCode's
    # build agent, which readily runs `cat docs/conventions/...` on its own
    # initiative after reading AGENTS.md's pointer to that directory) can
    # discover the convention by direct exploration — a path that has nothing
    # to do with apropos and would falsely fail the without-apropos control.
    rm -f "$WORK/docs/conventions/src-rule.md" \
          "$WORK/docs/conventions/stub-rule.md" \
          "$WORK/docs/conventions/db-audit-rule.md" \
          "$WORK/docs/conventions/workflows/add-operation.md"
    # Also remove the supporting module each rule points to (the decorator,
    # exception, registry, and audit wrapper). Each is a realistic project
    # convention rather than an arbitrary token, so it's a real, discoverable
    # code artifact in its own right — leaving it in place would let the same
    # exploration path above adopt it on its own, independent of apropos.
    rm -f "$WORK/src/telemetry.py" \
          "$WORK/scripts/errors.py" \
          "$WORK/lib/registry.py" \
          "$WORK/db/audit.py"
  fi
  export WORK
}

# --- live claude runner -------------------------------------------------------
claude_ready() { command -v claude >/dev/null 2>&1; }
opencode_ready() { command -v opencode >/dev/null 2>&1; }

# Echo the exact live command a runner is about to execute, so it can be copied
# and run by hand to reproduce a failure.
#
# Default: write to stdout, which bats captures and surfaces only when the test
# fails — the standard bats idiom, and exactly when you need the reproduction.
# Set DEBUG=1 to instead stream it live via fd 3, which bats shows during every
# test (passing ones included).
echo_cmd() {  # arg: command string
  if [ -n "${DEBUG:-}" ] && { true >&3; } 2>/dev/null; then
    printf '\n    # run this to reproduce:\n    %s\n\n' "$1" >&3
  else
    printf '\n    # run this to reproduce:\n    %s\n\n' "$1"
  fi
}

# Skip the current test unless a real, authenticated claude is available. Uses a
# run-wide flag so that once claude is found unusable, later live tests skip
# immediately instead of each paying for a failed call.
require_live_claude() {
  claude_ready || skip "claude not on PATH"
  [ -f "$BATS_RUN_TMPDIR/claude_unusable" ] && skip "claude unusable (detected earlier)"
  return 0
}

# Skip unless a real, authenticated opencode is available. Uses a run-wide
# unusable flag so that once opencode is found unusable, later live tests
# skip immediately instead of each paying for a failed call.
require_live_opencode() {
  opencode_ready || skip "opencode not on PATH"
  [ -f "$BATS_RUN_TMPDIR/opencode_unusable" ] && skip "opencode unusable (detected earlier)"
  # Quick auth probe: opencode run with an empty prompt exits 0 only when the
  # CLI is properly configured. Any non-zero exit marks it unusable.
  if [ ! -f "$BATS_RUN_TMPDIR/opencode_auth_ok" ]; then
    local rc=0
    echo_cmd "opencode run \"reply with the single word READY\""
    timeout 15 opencode run "reply with the single word READY" \
      >/dev/null 2>/dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
      touch "$BATS_RUN_TMPDIR/opencode_unusable"
      skip "opencode not authenticated (exit $rc)"
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
# Only a clean run (exit 0, is_error false) returns, so a genuine "apropos did not
# influence the output" still fails loudly at the assertion.
run_claude() {  # arg: prompt
  local dbg="$BATS_TEST_TMPDIR/hooks.log"
  local out="$WORK/_out.json" err="$WORK/_err.txt"
  local model_args=()
  [ -n "${E2E_MODEL:-}" ] && model_args=(--model "$E2E_MODEL")
  local rc=0
  echo_cmd "cd $WORK && \\
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID \\
      -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SSE_PORT -u CLAUDE_CODE_EXECPATH \\
  claude -p \"$1\" --output-format json --permission-mode auto ${model_args[*]}"
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
# .opencode/plugins/apropos.js bridges the hook calls; apropos must be on PATH.
# Stdout is written to $WORK/_oc_out.txt; a nonzero exit skips the test.
run_opencode() {  # arg: prompt
  local model_args=()
  [ -n "${E2E_MODEL:-}" ] && model_args=(--model "$E2E_MODEL")
  local rc=0
  echo_cmd "cd $WORK && opencode run \"$1\" ${model_args[*]}"
  (
    cd "$WORK" && opencode run "$1" "${model_args[@]}"
  ) >"$WORK/_oc_out.txt" 2>"$WORK/_oc_err.txt" || rc=$?
  if [ "$rc" -ne 0 ]; then
    touch "$BATS_RUN_TMPDIR/opencode_unusable"
    skip "opencode exited $rc"
  fi
}
