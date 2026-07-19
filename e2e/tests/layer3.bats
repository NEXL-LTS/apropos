#!/usr/bin/env bats
#
# Layer 3 — construct-scoped rule (NotImplementedError).
#
# Claude Code delivers via PostToolUse; OpenCode delivers via tool.execute.after
# + client.session.prompt(noReply:true) from the generated plugin.

export SENTINEL_L3="apropos-rule:L3-K9F4"
export PROMPT_L3="Add a stub function sync() to scripts/jobs.py that raises NotImplementedError."

bats_load_library bats-support
bats_load_library bats-assert
load helpers

setup() { ensure_apropos; }

@test "Layer 3 delivery (Claude): hook post injects the stub rule for NotImplementedError content" {
  new_sample with
  run apropos hook post <<< "$(post_payload scripts/jobs.py)"
  assert_success
  assert_output --partial '"hookEventName":"PostToolUse"'
  assert_output --partial "$SENTINEL_L3"
  assert_output --partial 'docs/conventions/stub-rule.md'
}

@test "Layer 3 with apropos (Claude): the NotImplementedError stub carries the sentinel" {
  require_live_claude
  new_sample with
  run_claude "$PROMPT_L3"
  assert grep -q "$SENTINEL_L3" "$WORK/scripts/jobs.py"
}

@test "Layer 3 without apropos (Claude): the sentinel does not appear" {
  require_live_claude
  new_sample without
  run_claude "$PROMPT_L3"
  refute grep -q "$SENTINEL_L3" "$WORK/scripts/jobs.py"
}

@test "Layer 3 delivery (OpenCode): plugin payload format produces L3 context via apropos hook post" {
  # Simulate what the plugin does: call apropos hook post with the payload format
  # the plugin constructs (snake_case fields, null session_id).
  # Use \\n so printf emits the JSON escape \n rather than a literal newline —
  # a bare newline inside a JSON string is invalid.
  new_sample with
  local payload
  payload="$(printf '{"session_id":null,"cwd":"%s","tool_name":"write","tool_input":{"file_path":"%s/scripts/jobs.py","content":"def x():\\n    raise NotImplementedError\\n"}}' "$WORK" "$WORK")"
  run apropos hook post --repo-root "$WORK" <<< "$payload"
  assert_success
  assert_output --partial '"hookEventName":"PostToolUse"'
  assert_output --partial "$SENTINEL_L3"
  assert_output --partial 'docs/conventions/stub-rule.md'
}

@test "Layer 3 with plugin (OpenCode): the NotImplementedError stub carries the sentinel" {
  require_live_opencode
  new_sample with
  run_opencode "$PROMPT_L3"
  assert grep -q "$SENTINEL_L3" "$WORK/scripts/jobs.py"
}

@test "Layer 3 without plugin (OpenCode): the sentinel does not appear" {
  require_live_opencode
  new_sample without
  run_opencode "$PROMPT_L3"
  refute grep -q "$SENTINEL_L3" "$WORK/scripts/jobs.py"
}
