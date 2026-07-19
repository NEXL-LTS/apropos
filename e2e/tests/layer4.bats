#!/usr/bin/env bats
#
# Layer 4 — intent skill, delivered as a generated SKILL.md wrapper.
#
# Skills are written to .claude/skills/<name>/SKILL.md by muninn generate.
# OpenCode reads this same path natively (no plugin required), so the same
# generated wrapper serves both Claude Code and OpenCode.

export SENTINEL_L4="muninn-rule:L4-Q7X2"
export PROMPT_L4="Add a new arithmetic operation divide(a, b) to the calc library in lib/calc.py."

bats_load_library bats-support
bats_load_library bats-assert
load helpers

setup() { ensure_muninn; }

@test "Layer 4 delivery (Claude): generate emits the add-operation skill wrapper" {
  new_sample with
  assert [ -f "$WORK/.claude/skills/add-operation/SKILL.md" ]
  run cat "$WORK/.claude/skills/add-operation/SKILL.md"
  assert_output --partial 'add-operation.md'
}

@test "Layer 4 with muninn (Claude): the new arithmetic op carries the sentinel" {
  require_live_claude
  new_sample with
  run_claude "$PROMPT_L4"
  assert grep -q "$SENTINEL_L4" "$WORK/lib/calc.py"
}

@test "Layer 4 without muninn (Claude): the sentinel does not appear" {
  require_live_claude
  new_sample without
  run_claude "$PROMPT_L4"
  refute grep -q "$SENTINEL_L4" "$WORK/lib/calc.py"
}

@test "Layer 4 delivery (OpenCode): .claude/skills/ is read natively — same wrapper, no plugin needed" {
  # OpenCode discovers skills in .claude/skills/<name>/SKILL.md without any
  # additional configuration. The sentinel lives in the source doc the wrapper
  # points to; the wrapper itself just redirects the agent there.
  new_sample with
  assert [ -f "$WORK/.claude/skills/add-operation/SKILL.md" ]
  run cat "$WORK/docs/conventions/workflows/add-operation.md"
  assert_output --partial "$SENTINEL_L4"
}

@test "Layer 4 with muninn (OpenCode): the new arithmetic op carries the sentinel" {
  require_live_opencode
  new_sample with
  run_opencode "$PROMPT_L4"
  assert grep -q "$SENTINEL_L4" "$WORK/lib/calc.py"
}

@test "Layer 4 without muninn (OpenCode): the sentinel does not appear" {
  require_live_opencode
  new_sample without
  run_opencode "$PROMPT_L4"
  refute grep -q "$SENTINEL_L4" "$WORK/lib/calc.py"
}
