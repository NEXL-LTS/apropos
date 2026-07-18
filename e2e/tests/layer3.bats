#!/usr/bin/env bats
#
# Layer 3 — construct-scoped rule (NotImplementedError), delivered on PostToolUse.

bats_load_library bats-support
bats_load_library bats-assert
load helpers

setup() { ensure_muninn; }

@test "Layer 3 delivery: hook post injects the stub rule for NotImplementedError content" {
  new_sample with
  run muninn hook post <<< "$(post_payload scripts/jobs.py)"
  assert_success
  assert_output --partial '"hookEventName":"PostToolUse"'
  assert_output --partial "$SENTINEL_L3"
  assert_output --partial 'docs/conventions/stub-rule.md'
}

@test "Layer 3 with muninn: the NotImplementedError stub carries the sentinel" {
  require_live_claude
  new_sample with
  run_claude "$PROMPT_L3"
  assert grep -q "$SENTINEL_L3" "$WORK/scripts/jobs.py"
}

@test "Layer 3 without muninn: the sentinel does not appear" {
  require_live_claude
  new_sample without
  run_claude "$PROMPT_L3"
  refute grep -q "$SENTINEL_L3" "$WORK/scripts/jobs.py"
}
