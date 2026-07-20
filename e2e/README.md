# apropos end-to-end test

A [bats-core](https://github.com/bats-core/bats-core) suite that runs apropos
against live Claude Code and OpenCode by default (Gemini CLI is supported but
opt-in — see [Options](#options) — since even a healthy Gemini call has been
observed taking 30-60s, and a real edit-task prompt over 180s) and asserts
what the model actually writes. It is organized **by layer**; each layer runs
the same with-apropos / without-apropos contrast for every enabled CLI.

## Structure

```
tests/
  helpers.bash  # sample scaffolding, apropos-on-PATH, agent registry, live runners
  layers.bats   # all layers, each grouped with its expected artifact/prompt/target
```

`layers.bats` holds every layer's expected artifact, prompt, target file, and
the `register_live_tests` call that generates its tests — grouped together so
a layer's full intent reads in one place instead of hopping between files.
Each layer registers a with/without pair of live tests **per CLI agent** in
`E2E_AGENTS` (`helpers.bash`); adding a new CLI agent means adding one entry
to that registry plus a `require_live_<x>`/`run_<x>` helper pair, not a new
per-layer test.

[`project/`](./project) is a sample codebase with a convention document on
every layer. Each convention is a realistic project rule — a tracing
decorator, a custom exception, a registry call, an audit wrapper — naming a
specific module/symbol that only exists because the rule said so. A model
can't produce it by chance, but unlike an arbitrary marker token it's not
inert either: a pass proves the convention's *behavior* landed, not just that
a string got copied. The layers sit on non-overlapping paths so each expected
artifact is attributable to exactly one convention.

The rule docs themselves live in [`conventions/`](./conventions), a sibling
of `project/` — outside the sample's own git repo entirely, pointed at via
`project/apropos.yml`'s `conventions_dir`. That's not incidental: a CLI
agent's own auto-included directory/file listing of its workspace can only
ever show what's inside the workspace, so if the docs lived under
`project/` a sufficiently curious model could discover them (and the fact
that it's being tested) by exploring its own file tree — regardless of
whether apropos's hooks are wired at all. Keeping them external means the
*only* channel that can deliver a rule's content into a live run is apropos's
hooks. `new_sample()` (`tests/helpers.bash`) points the copied sample's
`apropos.yml` at the real `conventions/` for "with" and at a directory that
doesn't exist for "without" — Layer 2/3 then simply have nothing to match,
and there's nothing to find by exploring either. The module each rule points
to (the decorator, exception, registry, audit wrapper) is still stripped
from `project/` in the without-apropos control, since that one *is* reachable
by exploring the sample's own tree.

| Layer | Trigger | Convention | Expected artifact | Target file |
| --- | --- | --- | --- | --- |
| 2 Path-scoped | editing `src/**` | new functions wrapped in `@trace_call` | `@trace_call` | `src/util.py` |
| 3 Construct-scoped | writing `NotImplementedError` | stubs raise `StubNotImplemented` instead | `StubNotImplemented(` | `scripts/jobs.py` |
| 3 Path+content (AND) | editing `db/**` AND writing `conn.execute(` | queries go through the audit wrapper | `audited_query(` | `db/queries.py` |
| 4 Intent skill | "add an arithmetic operation" | new ops register in the dispatch table | `register_operation(` | `lib/calc.py` |

## Running

```sh
make e2e          # or: bash e2e/run.sh
```

**Authenticate with each CLI first.** The live tests need a working, logged-in
`claude`, `opencode`, and `gemini` — see [CI-safety and credentials](#ci-safety-and-credentials)
below for how. Skip this and the corresponding live tests don't fail; they
just skip cleanly, which can look like a pass at a glance.

`bats` and its `bats-support`/`bats-assert` libraries ship in the devcontainer
image (resolved via `BATS_LIB_PATH`), so nothing is fetched at run time.
Before invoking `bats`, `run.sh` runs `apropos init --tool claude --tool
opencode --tool gemini` and `apropos generate` against `project/` itself, so
its hook wiring (`.claude/`, `.opencode/`, `.gemini/`) is always freshly
generated rather than committed (see `project/.gitignore`) — that way the
fixture is fully wired regardless of which agents happen to be installed on
the machine running the suite. `run.sh` invokes `bats` on [`tests/`](./tests);
extra flags pass through, e.g. `bash e2e/run.sh --filter 'Layer 2'`.

## The two tests per layer, per agent

Each test copies the sample into an isolated temp git repo (bats'
`BATS_TEST_TMPDIR`, outside this repo) with a freshly built `apropos` on PATH.
For each layer, every agent in `E2E_AGENTS` runs the same live pair:

1. **with apropos (live).** Run the CLI against the wired sample and assert the
   expected artifact lands in the edited file.
2. **without apropos (live control).** Run the same prompt with apropos removed
   and assert the expected artifact does **not** appear.

Deterministic delivery — that a hook payload maps to the right rule, or that
`generate` writes the right skill wrapper — is covered by the Crystal spec
suite (`spec/apropos/hook_spec.cr`, `spec/integration/hook_spec.cr`,
`spec/apropos/generate_spec.cr`, `spec/integration/generate_spec.cr`), not
here. This suite only exists to prove a real CLI agent's own output is
actually steered.

## CI-safety and credentials

The live checks require the `claude` / `opencode` / `gemini` CLI and valid
credentials. When one is absent or unauthenticated, its tests **skip
cleanly** and the run still exits `0`; the deterministic checks always run.
This is why the e2e is not wired into `make check` or CI — it is a local,
opt-in confidence check.

In the devcontainer, Claude's credentials arrive via the `${HOME}/.claude.json`
bind mount. OpenCode's credential lives in a named volume (`opencode-data`), so
authenticate once per container:

```sh
opencode auth login
```

It then persists across rebuilds. Until you do, the live OpenCode tests skip.

Gemini CLI (opt-in — see below) keeps its OAuth credential under `~/.gemini`,
bind-mounted as the `gemini-data` volume — run `gemini` once in the container
and complete its browser OAuth flow on first prompt; it then persists across
rebuilds the same way.

## Options

- `E2E_GEMINI=1` — include Gemini CLI in the live matrix. Off by default:
  even a healthy round trip has been observed taking 30-60s for a bare
  no-tool-use prompt and well over 180s for a real edit-task prompt, which
  makes default e2e runs slow and unpredictable. `require_live_gemini`/
  `run_gemini` (`helpers.bash`) are otherwise unchanged and fully working —
  set this when you deliberately want Gemini coverage.
- `E2E_MODEL=<model>` — pass a specific model to `claude -p --model` /
  `opencode run --model` / `gemini -p --model` (default: each CLI's configured
  model). Use a small model (e.g. `E2E_MODEL=claude-haiku-4-5`) for cheaper runs.
- `bash e2e/run.sh --no-tempdir-cleanup` — keep the per-test temp dirs for
  inspection.
