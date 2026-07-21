---
paths: ["src/apropos/init.cr"]
---

# Keying a settings-merge heal by identity, not by membership

**Rule:** When healing/converging a hook group inside a per-tool settings file
(`.claude/settings.json`, `.gemini/settings.json`), find the group to update by
something that identifies *that specific group* (its matcher, or matcher +
owner check) — never by "does this group contain one of our own commands"
alone. If more than one apropos-owned group can exist in the same array (e.g.
Gemini's write group and its separate read-only group), a command-membership
check can't tell them apart and will heal whichever one it finds first,
including the wrong one.

**Why:** Group identity and command membership are different things once a
second apropos-owned group exists. `apropos hook pre` legitimately lives in
both Gemini's `write_file|replace` group and its `read_file` group; a
predicate that only asks "is one of my commands in here" is satisfied by
either. Add a specific exclusion (or a matcher check) for every other
apropos-owned group before falling back to the generic predicate — don't
assume there's only one match.

**Watch out:** the same reasoning applies to *refreshing* an already-present
command's fields (e.g. `timeout`), not just adding a missing one. An early
`return` taken once "the command is present" skips the refresh, so a stale
field — like a timeout-unit fix shipped in a later version — never converges
for that group on re-`init`. Map over the present hooks and replace matching
ones with the current shape, then append whatever's still missing; don't
short-circuit once presence is confirmed.

## Verify

- A new apropos-owned settings group introduced here excludes every other
  apropos-owned group by identity before applying a generic
  "carries-our-command" match.
- Re-running `init` against a group whose command is already present still
  refreshes that command's fields to the current shape, for every
  apropos-owned group — not just the one added most recently.
