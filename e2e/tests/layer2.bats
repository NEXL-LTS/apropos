#!/usr/bin/env bats
#
# Layer 2 — path-scoped rule (src/**).
#
# Claude Code delivers via PreToolUse; OpenCode delivers via tool.execute.before
# + client.session.prompt(noReply:true) from the generated plugin.

bats_load_library bats-support
bats_load_library bats-assert
load helpers

setup() { ensure_muninn; }

@test "Layer 2 delivery (Claude): hook pre injects the src rule + sentinel for a src/** edit" {
  new_sample with
  run muninn hook pre <<< "$(pre_payload src/util.py)"
  assert_success
  assert_output --partial '"hookEventName":"PreToolUse"'
  assert_output --partial "$SENTINEL_L2"
  assert_output --partial 'docs/conventions/src-rule.md'
}

@test "Layer 2 with muninn (Claude): src edit carries the sentinel" {
  require_live_claude
  new_sample with
  run_claude "$PROMPT_L2"
  assert grep -q "$SENTINEL_L2" "$WORK/src/util.py"
}

@test "Layer 2 without muninn (Claude): the sentinel does not appear" {
  require_live_claude
  new_sample without
  run_claude "$PROMPT_L2"
  refute grep -q "$SENTINEL_L2" "$WORK/src/util.py"
}

@test "Layer 2 delivery (OpenCode): plugin payload format produces L2 context via muninn hook pre" {
  # Simulate what the plugin does: call muninn hook pre with the payload format
  # the plugin constructs (snake_case fields, null session_id).
  new_sample with
  local payload
  payload="$(printf '{"session_id":null,"cwd":"%s","tool_name":"edit","tool_input":{"file_path":"%s/src/util.py"}}' "$WORK" "$WORK")"
  run muninn hook pre --repo-root "$WORK" <<< "$payload"
  assert_success
  assert_output --partial '"hookEventName":"PreToolUse"'
  assert_output --partial "$SENTINEL_L2"
  assert_output --partial 'docs/conventions/src-rule.md'
}

@test "Layer 2 with plugin (OpenCode): src edit carries the sentinel" {
  require_live_opencode
  new_sample with
  run_opencode "$PROMPT_L2"
  assert grep -q "$SENTINEL_L2" "$WORK/src/util.py"
}

@test "Layer 2 without plugin (OpenCode): the sentinel does not appear" {
  require_live_opencode
  new_sample without
  run_opencode "$PROMPT_L2"
  refute grep -q "$SENTINEL_L2" "$WORK/src/util.py"
}
