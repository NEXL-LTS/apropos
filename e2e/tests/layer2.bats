#!/usr/bin/env bats
#
# Layer 2 — path-scoped rule (src/**), delivered on PreToolUse.

bats_load_library bats-support
bats_load_library bats-assert
load helpers

setup() { ensure_muninn; }

@test "Layer 2 delivery: hook pre injects the src rule + sentinel for a src/** edit" {
  new_sample with
  run muninn hook pre <<< "$(pre_payload src/util.py)"
  assert_success
  assert_output --partial '"hookEventName":"PreToolUse"'
  assert_output --partial "$SENTINEL_L2"
  assert_output --partial 'docs/conventions/src-rule.md'
}

@test "Layer 2 with muninn: claude's src edit carries the sentinel" {
  require_live_claude
  new_sample with
  run_claude "$PROMPT_L2"
  assert grep -q "$SENTINEL_L2" "$WORK/src/util.py"
}

@test "Layer 2 without muninn: the sentinel does not appear" {
  require_live_claude
  new_sample without
  run_claude "$PROMPT_L2"
  refute grep -q "$SENTINEL_L2" "$WORK/src/util.py"
}
