# calc

A small Python utility codebase: string helpers, arithmetic operations,
background jobs, and a data-access layer.

## Layout

- `lib/calc.py` — arithmetic operations.
- `src/` — string utilities.
- `scripts/` — background jobs.
- `db/` — data-access layer.

## Commands

- None — no build, lint, or test tooling

## Universal rules

- Keep functions small and pure; no side effects in `lib/`.
- There is no testing framework in this codebase. Make changes directly;
  do not write or run tests.
