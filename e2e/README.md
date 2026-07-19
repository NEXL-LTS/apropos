# muninn end-to-end test

A [bats-core](https://github.com/bats-core/bats-core) suite that runs muninn
against live Claude Code and OpenCode and asserts what the model actually writes.
It is organized **by layer**; each layer runs the same with-muninn /
without-muninn contrast for both CLIs.

## Structure

```
tests/
  helpers.bash  # sample scaffolding, muninn-on-PATH, claude/opencode runners
  layer2.bats   # path-scoped (src/**) — 3 Claude + 3 OpenCode tests
  layer3.bats   # construct-scoped (NotImplementedError) — 3 Claude + 3 OpenCode tests
  layer4.bats   # intent skill (.claude/skills/) — 3 Claude + 3 OpenCode tests
```

[`project/`](./project) is a self-contained sample codebase with a convention
document on every layer, each carrying a unique **sentinel token**. A sentinel
is arbitrary, so the model can only emit it when muninn delivered that
convention — making it a reliable signal despite LLM nondeterminism. The layers
sit on non-overlapping paths so each sentinel is attributable to exactly one
convention.

| Layer | Trigger | Sentinel | Target file |
| --- | --- | --- | --- |
| 2 Path-scoped | editing `src/**` | `muninn-rule:L2-7Q2X` | `src/util.py` |
| 3 Construct-scoped | `NotImplementedError` | `muninn-rule:L3-K9F4` | `scripts/jobs.py` |
| 4 Intent skill | "add an arithmetic operation" | `muninn-rule:L4-Q7X2` | `lib/calc.py` |

## Running

```sh
make e2e          # or: bash e2e/run.sh
```

`bats` and its `bats-support`/`bats-assert` libraries ship in the devcontainer
image (resolved via `BATS_LIB_PATH`), so nothing is fetched at run time.
`run.sh` invokes `bats` on [`tests/`](./tests); extra flags pass through, e.g.
`bash e2e/run.sh --filter 'Layer 2'`.

## The three tests per layer

Each test copies the sample into an isolated temp git repo (bats'
`BATS_TEST_TMPDIR`, outside this repo) with a freshly built `muninn` on PATH.
For each layer, both Claude Code and OpenCode run the same three tests:

1. **delivery (deterministic, no LLM, no network).** Pipe a real hook payload
   into `muninn hook pre`/`post` and assert the rule + sentinel come back (or,
   for L4, that the skill wrapper and source doc exist). Always runs.
2. **with muninn (live).** Run the CLI against the wired sample and assert the
   sentinel lands in the edited file.
3. **without muninn (live control).** Run the same prompt with muninn removed
   and assert the sentinel does **not** appear.

## CI-safety and credentials

The live checks require the `claude` / `opencode` CLI and valid credentials.
When either is absent or unauthenticated, its tests **skip cleanly** and the run
still exits `0`; the deterministic checks always run. This is why the e2e is not
wired into `make check` or CI — it is a local, opt-in confidence check.

In the devcontainer, Claude's credentials arrive via the `${HOME}/.claude.json`
bind mount. OpenCode's credential lives in a named volume (`opencode-data`), so
authenticate once per container:

```sh
opencode auth login
```

It then persists across rebuilds. Until you do, the live OpenCode tests skip.

## Options

- `E2E_MODEL=<model>` — pass a specific model to `claude -p --model` /
  `opencode run --model` (default: each CLI's configured model). Use a small
  model (e.g. `E2E_MODEL=claude-haiku-4-5`) for cheaper runs.
- `bash e2e/run.sh --no-tempdir-cleanup` — keep the per-test temp dirs for
  inspection.
