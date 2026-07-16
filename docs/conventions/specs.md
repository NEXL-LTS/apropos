---
paths: ["spec/**"]
---

# Writing specs

**Rule:** Specs are written before the implementation they cover, and every
example is deterministic and self-contained. Drive logic through injected IO
(`IO::Memory`), not real `STDIN`/`STDOUT`. Cover the compiled binary's entry
glue with an integration spec that builds the binary once and runs it as a
subprocess — unit specs cannot reach `exit`-at-top-level code.

**Why:** The coverage gate is 100% of reachable lines (PRD §8.2). Logic that
touches real IO or the process boundary is untestable in a unit spec and shows
up as an uncovered line or a flaky example. Injecting IO makes error paths
(unwritable cache, malformed stdin) unit-testable, and a single built-binary
integration spec covers the entry point honestly instead of excluding it blindly.

**Watch out:** `out` is a reserved keyword in Crystal (it marks C `out`
parameters) — name capture buffers `stdout`/`stderr`/`io`, never `out`.

## Verify

- The behavior has a spec that fails without the implementation.
- No logic module references `STDIN`/`STDOUT`/`File` directly; IO is a parameter.
- Any code that only runs when the binary is invoked is exercised by an
  integration spec, not excluded from coverage without a recorded reason.
