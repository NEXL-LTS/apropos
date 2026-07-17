# muninn end-to-end test

A true end-to-end proof that muninn delivers the right documentation to Claude
Code at edit time — and that it changes what the model actually writes. The test
is organized **by layer**: for each layer it shows the same with-muninn /
without-muninn contrast.

It is a [bats-core](https://github.com/bats-core/bats-core) suite. The three
`@test`-per-layer files live in [`tests/`](./tests):

```
tests/
  helpers.bash   # sample scaffolding, muninn-on-PATH, the claude runner
  layer2.bats    # path-scoped (src/**)
  layer3.bats    # construct-scoped (NotImplementedError)
  layer4.bats    # intent skill
```

Run it:

```sh
make e2e          # or: bash e2e/run.sh
```

`bats` and its `bats-support`/`bats-assert` libraries are installed in the
devcontainer image (`.devcontainer/Dockerfile`, resolved via `BATS_LIB_PATH`),
so no fetching happens at run time. `run.sh` just invokes `bats` on
[`tests/`](./tests); extra flags pass through, e.g.
`bash e2e/run.sh --filter 'Layer 2'`.

## What it sets up

[`project/`](./project) is a self-contained sample codebase with a convention
document on **every layer** of the standard, each carrying its own unique,
unguessable **sentinel token**. Because a token is arbitrary, a model can only
emit it if muninn actually delivered that convention — which makes the sentinel a
reliable signal of influence despite LLM nondeterminism.

| Layer | Convention | Trigger | Sentinel | Target file |
| --- | --- | --- | --- | --- |
| 1 Root file | `AGENTS.md` | always loaded | — | — |
| 2 Path-scoped | `docs/conventions/src-rule.md` | editing `src/**` (PreToolUse) | `muninn-rule:L2-7Q2X` | `src/util.py` |
| 3 Construct-scoped | `docs/conventions/stub-rule.md` | code raising `NotImplementedError` (PostToolUse) | `muninn-rule:L3-K9F4` | `scripts/jobs.py` |
| 4 Intent skill | `docs/conventions/workflows/add-operation.md` | "add an arithmetic operation" (skill match) | `muninn-rule:L4-Q7X2` | `lib/calc.py` |

The layers are placed on **non-overlapping** paths/constructs/intents so their
triggers never cross-fire: Layer 2 is scoped to `src/**`, while Layers 3 and 4
edit files *outside* `src/` (`scripts/` and `lib/`), and only Layer 4's task is
arithmetic. So each layer's sentinel is attributable to exactly one convention.

The sample's `.claude/settings.json` wires muninn's hooks exactly as a real
consumer would (`muninn hook pre` on PreToolUse, `muninn hook post` on
PostToolUse); `muninn generate` produces the committed Layer-4 `SKILL.md`.

## What it proves — per layer

Each test copies the sample into an isolated temp git repo (bats'
`BATS_TEST_TMPDIR`, outside this repository, so muninn resolves the *sample's*
conventions, not muninn's own) and puts a freshly built `muninn` on PATH. For
**each layer** there are three tests:

1. **delivery (deterministic, no LLM, no network).** Proves muninn *delivers*
   the layer's guidance: pipe a real hook payload into `muninn hook pre` (L2) /
   `muninn hook post` (L3) and assert the rule + sentinel come back, or assert
   `muninn generate` emitted the L4 skill wrapper. Always runs.
2. **with muninn (live).** Run `claude -p` against the wired sample and assert
   the layer's sentinel lands in the edited file — muninn steered the model.
3. **without muninn (live control).** Run the same prompt with muninn removed
   (`{"hooks":{}}` and no generated skills) while auth, `AGENTS.md`, and memory
   stay intact, and assert the sentinel does **not** appear. Since only muninn
   changes between checks 2 and 3, the marker is attributable to muninn alone
   (and not to `AGENTS.md`/memory, which are present in both).

## CI-safety

The live checks require the `claude` CLI and valid credentials. When `claude` is
absent or cannot authenticate, they **skip cleanly** and the script still exits
`0`; the deterministic delivery checks always run. This is why the e2e is not
wired into `make check` or the CI gate — it is a local, opt-in confidence check.

## Hermeticity

The live run is kept clean of ambient state: it runs in a throwaway git repo
outside this project and unsets the inherited `CLAUDE_CODE_*` session vars so the
nested `claude` starts fresh. Claude Code 2.1.212 has no supported way to disable
`CLAUDE.md`/`AGENTS.md` memory loading without also disabling hooks (`--bare` and
`--setting-sources` both drop hooks, and `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` was
observed to suppress hook firing too). That does not weaken the proof: each
sentinel only ever reaches the model through muninn, never through a memory file
— which the without-muninn controls confirm.

## Options

- `E2E_MODEL=<model>` — pass a specific model to `claude --model` (default: the
  CLI's configured model). Use a small model (e.g. `E2E_MODEL=claude-haiku-4-5`)
  for cheaper runs.
- `E2E_KEEP=1` — keep the temp working directories for inspection instead of
  deleting them on exit.
