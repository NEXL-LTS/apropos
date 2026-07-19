#!/usr/bin/env bats
#
# Layered live e2e — proves apropos steers a real CLI agent, per layer.
#
# Layers are grouped in one file (expected artifact + prompt + target file +
# the register_live_tests call live together) so a layer's full intent is
# visible in one place, not spread across per-layer files.
#
# Each layer registers a with/without pair of live tests per agent in
# E2E_AGENTS (helpers.bash) via register_live_tests — see there for how the
# CLI-agent matrix is generated. Deterministic delivery of the payload -> rule
# / generate -> skill-wrapper mapping is covered by the Crystal spec suite
# (spec/apropos/hook_spec.cr, spec/integration/hook_spec.cr,
# spec/apropos/generate_spec.cr, spec/integration/generate_spec.cr) — this
# file only proves a real CLI agent's output is actually steered.
#
# Each layer's expected artifact is a realistic project convention (a
# decorator, a custom exception, a registry call, an audit wrapper) rather
# than an arbitrary token. A model can't produce it by chance — it names a
# module/symbol that only exists because the rule said so — but it also isn't
# inert text, so a pass proves the convention's *behavior* landed, not just
# that a string got copied.

bats_load_library bats-support
bats_load_library bats-assert
load helpers

setup() { ensure_apropos; }

# --- Layer 2 — path-scoped rule (src/**) --------------------------------------
# Claude Code delivers via PreToolUse; OpenCode delivers via tool.execute.before
# + client.session.prompt(noReply:true) from the generated plugin.
#
# Convention: every new function under src/ (the public surface) must be
# wrapped in @trace_call (src/telemetry.py). Nothing in the file being edited
# hints at this — the existing shout() predates the requirement.
export EXPECT_L2="@trace_call"
export PROMPT_L2="Add a function shout_twice(text) to src/util.py that returns text uppercased and repeated twice."
register_live_tests "Layer 2" EXPECT_L2 PROMPT_L2 src/util.py

# --- Layer 3 — construct-scoped rule (NotImplementedError) -------------------
# Claude Code delivers via PostToolUse; OpenCode delivers via tool.execute.after
# + client.session.prompt(noReply:true) from the generated plugin.
#
# Convention: don't raise the bare NotImplementedError for a deliberate stub —
# raise StubNotImplemented (scripts/errors.py) instead, so tooling can tell a
# deferred stub apart from a real bug. The model's natural first draft IS the
# trigger condition, so apropos has to change what it already wrote, not just
# decorate it.
export EXPECT_L3="StubNotImplemented("
export PROMPT_L3="Add a stub function sync() to scripts/jobs.py that raises NotImplementedError."
register_live_tests "Layer 3" EXPECT_L3 PROMPT_L3 scripts/jobs.py

# --- Layer 3 (path + content, AND) — audited queries in db/** ----------------
# Same delivery mechanism as Layer 3 above, but the frontmatter combines
# `paths: ["db/**"]` with `contents: ['\bconn\.execute\(']` — it fires only
# when BOTH match. A path-only rule would fire on any edit under db/ (even
# ones that don't touch a query); a content-only rule would fire on
# conn.execute( anywhere in the tree (e.g. a one-off migration script, where
# the audit wrapper isn't the convention). Only the AND of both is correct.
export EXPECT_L3B="audited_query("
export PROMPT_L3B="Add a function get_order(conn, order_id) to db/queries.py that looks up an order by id."
register_live_tests "Layer 3 (path+content)" EXPECT_L3B PROMPT_L3B db/queries.py

# --- Layer 4 — intent skill, delivered as a generated SKILL.md wrapper -------
# Skills are written to .claude/skills/<name>/SKILL.md by apropos generate.
# OpenCode reads this same path natively (no plugin required), so the same
# generated wrapper serves both Claude Code and OpenCode.
#
# Convention: new calc operations must register in the dispatch table
# (lib/registry.py), not just be defined as a bare function. add/multiply
# predate the registry and haven't been migrated.
export EXPECT_L4="register_operation("
export PROMPT_L4="Add a new arithmetic operation divide(a, b) to the calc library in lib/calc.py."
register_live_tests "Layer 4" EXPECT_L4 PROMPT_L4 lib/calc.py
