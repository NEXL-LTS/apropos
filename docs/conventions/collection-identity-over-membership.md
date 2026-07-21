---
paths: ["src/apropos/**/*.cr"]
---

# Find-by-identity, verify-per-item: don't substitute a shared attribute

**Rule:** When a collection can hold more than one item of the same
conceptual kind, and code needs to find "the" specific item to read or
mutate, key that search on something that identifies *which* item it is —
never on an attribute several items could equally share. The same
discipline applies to checking a property that must jointly hold for one
item: evaluate it per item (`any?`/`all?`) and combine the results, never by
merging every item's attributes into one aggregate set first and checking
the aggregate.

**Why:** A search or check that only tests a shared attribute can't tell two
items apart once more than one of them has that attribute — it matches
whichever the traversal happens to reach first, which need not be the one
you meant. Aggregating first is the same mistake from the other direction:
once every item's attributes are merged into one set, you've thrown away
which item contributed which, so two items each missing half of a joint
requirement can look, in the merged set, exactly like one item that has all
of it. This class of bug shows up anywhere a collection holds several
similar containers — hook groups in a generated settings file, blocks in a
generated manifest, rows fetched from a store, sections of a document — not
just JSON, and not just this codebase.

Concretely, in this codebase: `Init` merges two independently-owned
`AfterTool` groups into Gemini's settings (a write group and a read-only
group), both of which can carry `apropos hook pre`. A search keyed on "does
this group carry one of my commands" can't distinguish them and may heal the
wrong one. `Doctor`'s wiring check had the mirror mistake: it flattened
commands across *every* group before checking that both `pre` and `post`
were present, so `pre` in one group and `post` in another summed to "wired"
even though neither group alone fired both. Both are fixed by keying the
search on the group's own identity (its matcher) and checking the joint
property inside one group at a time.

**Watch out:** the same identity discipline extends to *refreshing* an
already-matched item's fields, not just finding it. An early `return` taken
once "this item's field is present" skips refreshing that field to its
current value, so a later fix to that field's shape (a corrected default, a
unit change) never converges for that item on a re-run. Presence and
freshness are different checks — confirming one must not skip the other.

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
