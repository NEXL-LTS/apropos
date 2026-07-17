# muninn

**Deliver the right documentation to the right moment.**

Muninn ("memory") is one of Odin's two ravens: it flies out over the world,
gathers what is true, and whispers it into Odin's ear at the right moment — which
is what this tool does with your conventions. It is a single deterministic binary
that keeps a layered documentation structure working: it compiles convention-doc
frontmatter into a trigger index, generates skill wrappers, serves as a Claude
Code hook handler that injects path- and construct-scoped rules at edit time, and
resolves the conventions that apply to a diff for review.

One large always-loaded instruction file gets skimmed and forgotten. Muninn keeps
the guidance small and just-in-time: rules live in
[`docs/conventions/`](./docs/conventions/) as markdown with YAML frontmatter, and
muninn delivers each one exactly when the file or construct it governs is being
touched. It makes no LLM calls — triggering is deterministic — and ships as a
static Linux binary.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/NEXL-LTS/muninn-rules/main/install.sh | sh
```

The installer resolves the latest release, verifies its SHA256 checksum, and
installs `muninn` to `$HOME/.local/bin` (override with `MUNINN_BIN_DIR`; pin a tag
with `MUNINN_VERSION`). v1 ships a fully static Linux x86_64 binary; macOS and
Windows are on the roadmap.

From source (requires [Crystal](https://crystal-lang.org) ≥ 1.20):

```sh
make install          # builds the release binary and drops it on your PATH
```

## Quickstart

```sh
muninn init                # bootstrap docs/conventions/, hook wiring, .gitignore
$EDITOR docs/conventions/  # write rules (see docs/conventions/README.md)
muninn generate            # compile the index + skill wrappers
muninn lint                # validate the structure
muninn doctor              # check the environment and hook wiring
```

`muninn init` wires two Claude Code hooks into `.claude/settings.json`:
`muninn hook pre` (PreToolUse → Layer 2, path-scoped) and `muninn hook post`
(PostToolUse → Layer 3, construct-scoped). You never run these by hand — Claude
Code calls them, and they inject the matching conventions as context.

Run `muninn help` for the full mental model (also `muninn help --format json` for
the machine-readable form, or `muninn help <command>`).

## How it works

Guidance is organized into four layers, each triggered by the cheapest mechanism
that reliably fires it — see [`docs/conventions/README.md`](./docs/conventions/README.md)
for the full model:

| Layer | For | Trigger | Delivered by |
| --- | --- | --- | --- |
| 1 Root file | Universal rules | Always loaded | `AGENTS.md` |
| 2 Path-scoped | A directory / file type | File **path** | PreToolUse hook |
| 3 Construct-scoped | An API / code construct | Written **content** (regex) | PostToolUse hook |
| 4 Intent skills | Task-nature guidance | Semantic skill match | Generated `SKILL.md` |

`muninn generate` compiles the frontmatter in `docs/conventions/` into a cached
trigger index and committed skill wrappers. At edit time, the hooks look up the
matching rules and inject them. For review, the same frontmatter resolves which
conventions apply to a diff, so review prompts carry zero copies of the rules.

## Claude Code version requirement

Layer 2 delivery fires on **PreToolUse**, which depends on Claude Code supporting
`hookSpecificOutput.additionalContext` for that event. This arrived after the
PostToolUse path, so **older Claude Code releases may not inject Layer 2 context.**

- `muninn doctor` checks the installed `claude --version` and warns if PreToolUse
  injection may be unavailable.
- If it is unavailable, Layer 2 delivery **degrades gracefully to PostToolUse**
  with no loss of correctness — the path is still knowable after the write — so
  Layer 3 (already PostToolUse) is unaffected. This is a documented fallback, not
  a failure mode.

## Commands

| Command | Purpose |
| --- | --- |
| `muninn init` | Bootstrap the convention structure into a repo (idempotent; `--force`, `--example`, `--claude-symlink`, `--dry-run`). |
| `muninn generate` | Compile frontmatter into the trigger index and skill wrappers. `--check` is the CI drift gate. |
| `muninn hook pre` / `hook post` | Claude Code hook handlers (Layer 2 / Layer 3). Fail open — never block an edit. |
| `muninn match <paths>` | Resolve the conventions applying to given files (`--format paths\|json\|full`). |
| `muninn review [range]` | Resolve conventions for a git diff range as a review manifest (`--format md\|json`). |
| `muninn lint` | Validate frontmatter, skill descriptions, root-file budget, and generated-artifact freshness (`--strict`). |
| `muninn doctor` | Check hook wiring, Claude Code version, index freshness, and cache writability. |
| `muninn help` | The dual-audience mental model (human and agent), single-sourced with `--format json`. |

Every command takes `--help`, `--repo-root <dir>` (default: walk up to the nearest
`.git`), and documents its exit codes.

## Design guarantees

- **Fast hooks.** `hook pre`/`hook post` complete in well under 50 ms warm (index
  present); the hot path never parses YAML. A benchmark spec guards the budget.
- **Deterministic output.** `generate` is byte-stable across runs and platforms
  (sorted walks, LF endings, no timestamps) — the prerequisite for `--check`.
- **Fail-open hooks, fail-closed CI.** A hook never blocks or breaks an edit; on
  any internal error it exits 0 and emits nothing. `generate --check` and `lint`
  exit non-zero on any violation.
- **No runtime dependencies.** A fully static musl binary; the only shell-out off
  the hook path is optional `git` for `review`.

## Non-goals (v1)

- No Cursor `.mdc` / Copilot `.instructions.md` output — the frontmatter is
  designed so these are pure additional emitters later.
- No enforcement of code style — that belongs in linters/formatters, which muninn
  does not replace.
- No LLM calls; no daemon/watch mode (every invocation is a fast one-shot).
- No hook management beyond its own entries: muninn edits only the hook entries it
  owns in `.claude/settings.json`, marked and idempotent.

## Roadmap

macOS (arm64/x86_64) and Windows release legs; `--redup-after N` for re-injecting
a rule every N edits; Cursor/Copilot emitters from the same frontmatter; advisory
lint-rule linkage (teaching messages that cite rule files); a `review` posting mode
for CI (GitHub PR comments).

## Development

This repo dogfoods the standard on itself — `docs/conventions/` holds muninn's own
scoped guidance, delivered by muninn's own hooks. Use `make`:

- `make deps` — install shard dependencies
- `make build` — build the debug binary; `make release` for the release build
- `make install` — build and install to `$PREFIX/bin` (default `$HOME/.local`)
- `make check` — lint + spec (the fast local gate)
- `make coverage` — specs under kcov with the 100% line-coverage gate

Development is spec-first, coverage is 100%, and ameba runs zero-findings. See
[`AGENTS.md`](./AGENTS.md) and [`docs/conventions/`](./docs/conventions/).

## License

[MIT](./LICENSE).
