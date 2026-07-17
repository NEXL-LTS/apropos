# muninn

**Deliver the right documentation to the right moment.**

Muninn is a single deterministic binary that implements the [Agent Documentation
Structure Standard](./agent-docs-structure.md): it compiles convention-doc
frontmatter into a trigger index, generates skill wrappers, serves as a Claude
Code hook handler that injects path- and construct-scoped rules at edit time, and
resolves the conventions that apply to a diff for review.

One large always-loaded instruction file gets skimmed and forgotten. Muninn keeps
the guidance small and just-in-time: rules live in `docs/conventions/` as markdown
with YAML frontmatter, and muninn delivers each one exactly when the file or
construct it governs is being touched. It makes no LLM calls — triggering is
deterministic — and ships as a static Linux binary. See [`PRD.md`](./PRD.md) for
the full specification.

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
