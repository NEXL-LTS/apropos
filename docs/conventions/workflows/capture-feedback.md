---
skill: true
description: "Use when you receive corrective feedback — a PR/code review comment, or the user directly saying to do something differently — to check whether it generalizes into a new or updated convention doc."
---

# Capturing feedback as conventions

**Rule:** When corrected — a GitHub review comment, a user telling you mid-task
to do something differently, a repeated nudge — don't just apply the fix and
move on. Ask whether the correction generalizes beyond this one instance. If it
does, classify it with the layer-classification steps in
[`docs/conventions/README.md`](../README.md) and add or update a convention doc
(or, if tooling can enforce it, a lint/formatter rule) so the next task gets the
guidance without repeating the mistake.

**Why:** Feedback that lives only in a conversation or a PR thread is
invisible to the next session and the next agent — the same correction recurs,
costing another review cycle. A correction is also the highest-signal source of
a new convention: it is an empirically verified mistake, not a speculative rule
someone guessed might matter.

**Watch out:** Not every correction generalizes. A true one-off (rename this
local variable, fix this typo) is not a convention — capturing it would just add
noise that gets skimmed. Capture instructions that would plausibly recur: a
missed edge case, a violated project assumption, a pattern corrected more than
once. If the correction is something a linter or formatter could catch
mechanically, route it to tooling instead of prose — conventions move
one-directionally from docs into tooling, never the reverse.

## Verify

- Feedback that reflects a generalizable rule has a corresponding convention
  doc (new or updated), correctly classified per the layer table.
- One-off, non-generalizable feedback is applied to the immediate change only,
  without spawning a new convention doc.
- Feedback a linter/formatter could enforce is routed to tooling config, not
  captured as prose.
