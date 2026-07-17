# Mutation testing

Mutation testing hardens muninn's pure logic modules — the places where a
surviving mutant means a real correctness gap: `matcher`, `frontmatter`,
`index`, `session_state`, and `review` diff parsing.

It is **advisory-only and never gates CI.** The actual quality floor is the 100%
coverage gate plus ameba. Crytic is disposable: if a Crystal upgrade ever breaks
it, drop it with no effect on build, release, or correctness.

## Spike outcome (2026-07-16, Crystal 1.20.3)

Crytic v9.0.0 (`hanneskaeufler/crytic`) **builds and runs against Crystal
1.20.3.** Its `shard.yml` nominally targets Crystal 1.12.1 (constraint
`>= 1.0, < 2.0`), but it compiled cleanly via its `make bin` postinstall and ran
a full mutation session on `src/muninn/cli.cr`: **10 mutations, 10 killed, MSI
100%.** So `make mutate` is wired to run crytic for real.

Maintenance note: crytic is single-maintainer and effectively dormant (last
tagged release v9.0.0, May 2024; an unreleased master commit bumps it toward
Crystal 1.18.2). Expect it to trail the latest Crystal. Re-run this spike on
each Crystal upgrade.

## Running it

Crytic is installed on demand into the gitignored `.crytic/` directory, kept out
of the main dependency graph so CI never builds it.

```sh
make mutate SUBJECT=src/muninn/matcher.cr   # mutate one module
make mutate                                  # list recommended targets
```

Workflow: run crytic on the module you touched; **kill every survivor or
consciously justify it in the PR description.** A survivor is a mutation your
specs failed to catch — usually a missing assertion or an untested branch.

## Fallback: manual mutation

If crytic fails to build against the target Crystal (the `make mutate` target
prints this and exits non-zero), run a manual mutation session on the same
modules — deliberately flip operators and boundaries by hand and confirm a spec
fails for each. Checklist:

- Flip boolean operators (`&&` ↔ `||`) and comparisons (`<` ↔ `<=`, `==` ↔ `!=`).
- Change numeric and string literals (off-by-one, empty vs non-empty).
- Negate conditionals (`if x` → `if !x`) and swap early-return branches.
- Remove a guard clause and confirm a spec catches the regression.

Each flip must make at least one spec fail. Any that doesn't is a coverage gap —
add the assertion, then revert the flip.
