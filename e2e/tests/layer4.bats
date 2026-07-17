#!/usr/bin/env bats
#
# Layer 4 — intent skill, delivered as a generated SKILL.md wrapper.

bats_load_library bats-support
bats_load_library bats-assert
load helpers

setup() { ensure_muninn; }

@test "Layer 4 delivery: generate emits the add-operation skill wrapper" {
  new_sample with
  assert [ -f "$WORK/.claude/skills/add-operation/SKILL.md" ]
  run cat "$WORK/.claude/skills/add-operation/SKILL.md"
  assert_output --partial 'add-operation.md'
}

@test "Layer 4 with muninn: the new arithmetic op carries the sentinel" {
  require_live_claude
  new_sample with
  run_claude "$PROMPT_L4"
  assert grep -q "$SENTINEL_L4" "$WORK/lib/calc.py"
}

@test "Layer 4 without muninn: the sentinel does not appear" {
  require_live_claude
  new_sample without
  run_claude "$PROMPT_L4"
  refute grep -q "$SENTINEL_L4" "$WORK/lib/calc.py"
}
