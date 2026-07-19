# calc

A tiny sample codebase for apropos's end-to-end test. It exists so a real Claude
Code run can be observed picking up scoped conventions that apropos injects at
edit time — one convention per layer of the standard.

## Layout

- `lib/calc.py` — the arithmetic library (Layer 4 skill target).
- `src/` — governed source (Layer 2 path-scoped rule).
- `scripts/` — helper scripts.

## Commands

- `python -m pytest` — run the tests (none required for the e2e).

## Universal rules

- Keep functions small and pure; no side effects in `lib/`.

## Where scoped guidance lives

Path- and construct-scoped conventions live in `docs/conventions/` and are
delivered automatically at edit time by apropos's hooks (see
`docs/conventions/README.md`). Do not restate them here.
