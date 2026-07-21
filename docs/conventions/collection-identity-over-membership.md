---
paths: ["src/apropos/**/*.cr"]
contents: ['\.index\s*\{\s*\|\w+\|', '\.flat_map\b[\s\S]*?\.includes\?']
---

# Find-by-identity, verify-per-item

**Rule:** When a collection can hold more than one item of the same
conceptual kind, don't find "the" item to mutate by a shared attribute, and
don't check a property that must hold for one item by aggregating across
all of them first. Both throw away which item is which.

## Finding an item to mutate

**Bad** — picks whichever item happens to match a shared attribute, not
necessarily the one meant:

```crystal
target = groups.index { |group| group.commands.includes?("notify") }
groups[target].commands << "retry" if target
```

If two groups both already run `"notify"` (plausible — it's a shared
attribute, not an identifier), this silently amends whichever one `.index`
reaches first. That might not be the group the caller meant to change.

**Good** — keys the search on something that identifies *that* group:

```crystal
target = groups.index { |group| group.name == "primary" }
groups[target].commands << "retry" if target
```

## Checking a property that must hold for one item

**Bad** — flattens every item's attributes into one set before checking:

```crystal
commands = groups.flat_map(&.commands)
commands.includes?("pre") && commands.includes?("post")
```

Two groups, each missing one of `"pre"`/`"post"`, pass this: the flattened
set has both, even though no single group does. The check no longer knows
which group contributed which command.

**Good** — checks the pair inside one item at a time:

```crystal
groups.any? { |group| group.commands.includes?("pre") && group.commands.includes?("post") }
```

## Refreshing an item that's already found

**Bad** — stops once the field exists, so a later fix to its value never
lands on a re-run:

```crystal
return hooks if hooks.any? { |hook| hook.name == "pre" }
hooks + [Hook.new("pre", timeout: CURRENT_TIMEOUT)]
```

A hook added before `CURRENT_TIMEOUT` changed keeps its stale value
forever — "the field exists" and "the field is current" are different
questions, and this only asks the first one.

**Good** — refreshes matching items in place, then appends what's still
missing:

```crystal
refreshed = hooks.map { |hook| hook.name == "pre" ? Hook.new("pre", timeout: CURRENT_TIMEOUT) : hook }
refreshed.any? { |hook| hook.name == "pre" } ? refreshed : refreshed + [Hook.new("pre", timeout: CURRENT_TIMEOUT)]
```

**Why:** This class of bug shows up anywhere a collection holds several
similar containers — hook groups in a generated settings file, blocks in a
manifest, rows fetched from a store — not just the examples above. A search
or check that only tests a shared attribute can't tell two items apart once
more than one of them has it; aggregating first is the same mistake from the
other direction, since the aggregate can satisfy a joint check through
contributions from different items.

In this codebase, `Init#ensure_gemini_group` merges Gemini's write-file
group and its separate read-only group, both of which can carry
`apropos hook pre` — a search keyed on "carries one of my commands" can't
tell them apart and may heal the wrong one. `Doctor#gemini_wired?` had the
aggregate mistake: it flattened commands across every `AfterTool` group
before checking that both `pre` and `post` were present, so `pre` in one
group and `post` in another summed to "wired" even though neither group
alone fired both.

## Verify

- A collection search meant to find "the" item to update excludes every
  other item that could satisfy the same shared-attribute check, using
  something specific to the intended item's identity — not the attribute
  the search is looking for.
- A property meant to hold jointly within one item is checked per item,
  never by merging every item's attributes into one set first.
- Re-running a convergent/idempotent operation against an item whose field
  already exists still refreshes that field to the current shape, not just
  adds whatever's missing.
