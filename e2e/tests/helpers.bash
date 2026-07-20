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

# Gemini CLI is opt-in, not part of the default matrix: even when healthy it
# has been observed taking 30-60s for a bare no-tool-use round trip and well
# over 180s for a real edit-task prompt, which makes every default e2e run
# slow and its pass/fail timing unpredictable. Its require_live_gemini/
# run_gemini pair (below) is unchanged and still fully working — set
# E2E_GEMINI=1 to include it.
if [ -n "${E2E_GEMINI:-}" ]; then
  E2E_AGENTS+=("Gemini|require_live_gemini|run_gemini")
fi

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
  # The copied apropos.yml still says `conventions_dir: ../conventions` —
  # correct for the committed fixture (a fixed sibling of e2e/project/), but
  # meaningless once copied into $WORK's own throwaway tmp location. Point it
  # at an absolute path instead: the real, shared e2e/conventions/ for "with"
  # (never copied into $WORK, so a CLI agent's own auto-included directory/
  # file listing of its workspace can never reveal it — apropos's hooks are
  # the only channel that can deliver it), or a directory that doesn't exist
  # for "without" (Filesystem::Real#glob on an absent base just finds
  # nothing, so Layer 2/3 never match and the model gets no convention
  # content and no discoverable directory to explore, full stop).
  if [ "$mode" = "without" ]; then
    echo "conventions_dir: $BATS_TEST_TMPDIR/no-conventions" > "$WORK/apropos.yml"
  else
    echo "conventions_dir: $(_e2e_dir)/conventions" > "$WORK/apropos.yml"
  fi
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
    printf '{"hooks":{}}\n' > "$WORK/.gemini/settings.json"
    rm -rf "$WORK/.gemini/skills"
    # Also remove the supporting module each rule points to (the decorator,
    # exception, registry, and audit wrapper). Each is a realistic project
    # convention rather than an arbitrary token, so it's a real, discoverable
    # code artifact in its own right — leaving it in place would let a
    # sufficiently agentic model (observed with OpenCode's build agent)
    # adopt it on its own, independent of apropos.
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
gemini_ready() { command -v gemini >/dev/null 2>&1; }

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

# --- live gemini runner --------------------------------------------------------

# Skip unless a real, authenticated gemini is available. Uses a run-wide
# unusable flag so that once gemini is found unusable, later live tests skip
# immediately instead of each paying for a failed call.
#
# 60s (not 30s): a bare "reply with READY" round-trip has been observed
# taking up to ~36s on its own (cold model/connection latency, not a hang —
# confirmed by watching it eventually succeed under a longer timeout), so 30s
# was clipping genuine slow-but-working responses as "unauthenticated".
require_live_gemini() {
  gemini_ready || skip "gemini not on PATH"
  [ -f "$BATS_RUN_TMPDIR/gemini_unusable" ] && skip "gemini unusable (detected earlier)"
  if [ ! -f "$BATS_RUN_TMPDIR/gemini_auth_ok" ]; then
    local rc=0
    echo_cmd "gemini -p \"reply with the single word READY\" --approval-mode auto_edit --skip-trust"
    timeout -k 10 60 gemini -p "reply with the single word READY" --approval-mode auto_edit --skip-trust \
      >/dev/null 2>/dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
      touch "$BATS_RUN_TMPDIR/gemini_unusable"
      skip "gemini not authenticated (exit $rc)"
    fi
    touch "$BATS_RUN_TMPDIR/gemini_auth_ok"
  fi
  return 0
}

# Run gemini non-interactively in $WORK. .gemini/settings.json's AfterTool
# hooks bridge the calls into `apropos hook pre`/`apropos hook post`; apropos
# must be on PATH. --approval-mode auto_edit auto-approves edit tools so a
# headless run doesn't hang on a confirmation prompt (matching
# require_live_gemini's probe above). --skip-trust is required separately —
# it is Gemini CLI's workspace-trust gate, not a tool-approval setting, and
# every test stands up a brand-new git repo under a fresh temp dir that
# Gemini has never seen before; without it the run blocks forever waiting for
# an interactive trust prompt that never arrives, with a hard `timeout` below
# as a backstop in case a future prompt type isn't covered by either flag.
# `-k 10` forces a SIGKILL 10s after the initial SIGTERM: Node.js CLIs don't
# always exit promptly on SIGTERM (e.g. a pending network read), and a
# `timeout` that only sends one signal and then waits indefinitely for the
# child to notice defeats the whole point of wrapping it in a timeout. The
# 300s budget (not a snappier value) reflects observed reality, not a guess:
# a bare no-tool-use prompt round-trip alone has taken up to ~36s, and a real
# edit-task prompt (read + write, i.e. more model turns) exceeded a 180s
# budget outright — Gemini's current latency here is just high, not hung.
# Plain-text output only (not --output-format json): Gemini CLI has a known
# issue where JSON output mode exits early on a non-fatal tool error, and
# success here only ever depends on the exit code, never on parsing
# structured output. Stdout is written to $WORK/_gm_out.txt; per Gemini's
# documented headless exit codes (0 success, nonzero otherwise), any nonzero
# exit skips the test.
run_gemini() {  # arg: prompt
  local model_args=()
  [ -n "${E2E_MODEL:-}" ] && model_args=(--model "$E2E_MODEL")
  local rc=0
  echo_cmd "cd $WORK && gemini -p \"$1\" --approval-mode auto_edit --skip-trust ${model_args[*]}"
  (
    cd "$WORK" && timeout -k 10 300 gemini -p "$1" --approval-mode auto_edit --skip-trust "${model_args[@]}"
  ) >"$WORK/_gm_out.txt" 2>"$WORK/_gm_err.txt" || rc=$?
  if [ "$rc" -ne 0 ]; then
    touch "$BATS_RUN_TMPDIR/gemini_unusable"
    skip "gemini exited $rc"
  fi
}
