# Muninn — PRD & Implementation Plan

**Name:** repo **`muninn-rules`**, binary **`muninn`**. Muninn ("memory") is one of Odin's two ravens: it flies out over the world, gathers what is true, and whispers it into Odin's ear at the right moment — which is exactly what this tool does with conventions via `additionalContext`. The descriptive repo name owns search; the short binary name keeps hook config and muscle memory clean (the ripgrep/`rg` pattern). Reserved sibling concept: Huginn ("thought") if the review-agent side ever becomes its own tool.

**Status:** Draft v1 · **License:** MIT · **Language:** Crystal (target `>= 1.20`; latest stable 1.20.3 at time of writing)

---

## 1. Problem statement

The Agent Documentation Structure Standard (the normative spec, checked in at [`agent-docs-structure.md`](./agent-docs-structure.md)) replaces one large always-loaded instruction file with four layers of just-in-time guidance. The standard is tool-agnostic markdown plus YAML frontmatter, but making it *work* requires machinery: frontmatter must be compiled into a trigger index, skills must be generated, hooks must match edits against triggers and inject rules, and review agents must be able to resolve which conventions apply to a diff. Today that machinery would be ad-hoc scripts copied between repos.

Muninn is a single static binary that implements the standard's mechanics for any codebase: bootstrap, generate, trigger at edit time, and resolve for review.

## 2. Goals

1. **Bootstrap** the structure into any repo: `docs/conventions/`, `.claude/` hook wiring, root-file skeleton, cache dir.
2. **Generate** the derived artifacts from convention-doc frontmatter: `.claude/skills/*/SKILL.md` wrappers and the trigger index. Provide a `--check` mode as the CI drift gate.
3. **Serve as the hook handler** for Claude Code:
   - **PreToolUse** on Edit/Write → match the target *path* against Layer 2 rules and inject them via `hookSpecificOutput.additionalContext` *before* the edit happens.
   - **PostToolUse** on Edit/Write → match the *written content* against Layer 3 rules (respecting `paths:` AND-scoping) and inject after the edit.
4. **Resolve conventions for review**: given a file, a list of files, or a git diff range, print every matching Layer 2/3 rule so a review agent (or human) loads exactly the applicable conventions.
5. **Guard the structure's quality bar**: a `lint` command validating frontmatter, skill descriptions, root-file budget, and generated-artifact freshness.
6. Ship as a downloadable static Linux binary built by GitHub Actions; macOS and Windows on the roadmap.

## 3. Non-goals (v1)

- No Cursor `.mdc` / Copilot `.instructions.md` output. The frontmatter is designed so these are pure additional emitters later; v1 targets Claude Code only.
- No enforcement of code style — the standard is explicit that anything a linter/formatter can enforce belongs in tooling, and muninn doesn't replace that.
- No LLM calls. Muninn is deterministic; semantic triggering (Layer 4) is delegated to Claude Code's own skill mechanism via the generated wrappers.
- No daemon/watch mode. Every invocation is a fast one-shot process (hooks demand this anyway).
- No hook management beyond its own entries: muninn edits only the hook entries it owns in `.claude/settings.json`, marked and idempotent.

## 4. Users and contexts

| Actor | Uses | Latency tolerance |
| --- | --- | --- |
| Engineer adopting the standard | `init`, `generate`, `lint` | seconds |
| Claude Code (hook runtime) | `hook pre`, `hook post` | **< 50 ms** typical; hooks block the agent loop |
| Review agent / `/review` command / CI review | `match`, `review` | seconds |
| CI | `generate --check`, `lint` | seconds |

The hook latency budget is a hard product requirement and drives most implementation choices (static binary, precompiled index, no YAML parsing on the hot path).

## 5. Functional requirements

### 5.1 `muninn init`

Bootstraps a repo. Idempotent — safe to re-run; never overwrites existing content without `--force`.

Creates:

- `docs/conventions/` with a `README.md` explaining the four layers and frontmatter schema (condensed from the standard), plus `docs/conventions/workflows/`.
- `AGENTS.md` skeleton (only if absent) with the Layer 1 section headings and the one-line map to `docs/conventions/`. `--claude-symlink` also creates `CLAUDE.md → AGENTS.md`.
- `.claude/skills/` directory with a `.gitkeep` and a generated-code warning header convention.
- Hook wiring in `.claude/settings.json` (created or merged):

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Edit|Write",
        "hooks": [ { "type": "command", "command": "muninn hook pre", "timeout": 10 } ] }
    ],
    "PostToolUse": [
      { "matcher": "Edit|Write",
        "hooks": [ { "type": "command", "command": "muninn hook post", "timeout": 10 } ] }
    ]
  }
}
```

- `.gitignore` entry for `.cache/muninn/`.
- `--example` flag drops one sample Layer 2 doc, one Layer 3 doc, and one skill-enabled workflow doc so the pipeline is demonstrable immediately.

The structure matches the hooks reference exactly: each event maps to an array of matcher groups, and each group carries its own `hooks` array of `{ type, command, timeout }` entries. `timeout` is in **seconds** (10 s is a generous ceiling; the hook targets < 50 ms — §6).

Merging into an existing `settings.json` preserves unknown keys and other hooks; muninn identifies its own entries by the `muninn hook` command prefix.

### 5.2 Convention doc format (input contract)

Frontmatter schema, per the standard:

```yaml
---
paths: ["app/jobs/**"]          # Layer 2 trigger (glob, ** supported)
contents: ['\.transaction\b']   # Layer 3 trigger (PCRE2 regex)
skill: true                     # Layer 4: generate SKILL.md wrapper
description: "Use when ..."     # required iff skill: true
---
```

Semantics implemented exactly as specified: `paths` only → L2; `contents` only → L3 repo-wide; both → AND (path-scoped L3); `skill: true` independent; no frontmatter → reference-only, indexed as such but never triggered.

Muninn additionally recognizes an optional `## Verify` heading in the doc body; `review` mode extracts it as a checklist item (§5.6). Absence is fine.

### 5.3 `muninn generate`

Walks `docs/conventions/**/*.md`, parses frontmatter, and emits:

1. **Trigger index** at `.cache/muninn/index.json` (namespaced under `muninn/`; supersedes the standard's illustrative `.cache/conventions-index.json`): doc path, doc content hash, compiled trigger metadata (globs, regex sources), layer classification, skill flag. Rebuilt only when any doc hash differs from the recorded one (or index absent/schema-version mismatch). Gitignored.
2. **Skill wrappers** at `.claude/skills/<slug>/SKILL.md` for every `skill: true` doc: frontmatter `name` + `description` verbatim, body containing only a pointer ("Read `docs/conventions/workflows/<name>.md` and follow it.") and a "GENERATED — do not edit" banner. Slug derived from filename; collision is an error. Committed to the repo.
3. Removal of orphaned wrappers whose source doc no longer exists or dropped `skill: true`.

`muninn generate --check`: exit 0 if committed wrappers byte-match what the current docs produce, exit 1 with a diff summary otherwise. This is the CI gate against stale or hand-edited generated files. `--check` never writes.

### 5.4 `muninn hook pre` (Layer 2 delivery)

Reads the PreToolUse JSON from stdin. Contract per the current Claude Code hooks reference; the exact `tool_input` field names are pinned by captured fixtures (§8.4), not this prose, since the schema evolves.

> **Refinement over the standard:** the standard's "Trigger mechanics" section delivers *both* Layer 2 and Layer 3 through a single PostToolUse hook. Muninn deliberately splits them — Layer 2 fires on **PreToolUse** because the target path is knowable before the edit, so path-scoped guidance arrives *before* the write rather than after it; Layer 3 stays on PostToolUse because the written content only exists afterward. This depends on PreToolUse supporting `additionalContext`: the current hooks reference lists `additionalContext` for PreToolUse (alongside `PostToolUse`, `UserPromptSubmit`, `SessionStart`, etc.), but this arrived after the PostToolUse path, so older CLIs may inject only on PostToolUse (see the capability note below).

A representative PreToolUse payload arriving on stdin:

```json
{
  "session_id": "abc123",
  "transcript_path": "/home/u/.claude/projects/.../session.jsonl",
  "cwd": "/repo",
  "tool_name": "Edit",
  "tool_input": { "file_path": "app/jobs/mailer_job.cr", "old_string": "...", "new_string": "..." }
}
```

- Input: `session_id`, `tool_name`, `tool_input` (with `file_path`), `cwd`, `transcript_path`.
- Match `tool_input.file_path` (relativized to repo root) against every L2 glob in the index.
- Deduplicate per session (§5.7). If nothing new matches → `exit 0`, no output.
- Otherwise print to stdout and `exit 0`:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "<concatenated rule file bodies with source-path headers>"
  }
}
```

Design rules for the injected text, following the docs' guidance:

- Rule bodies are injected as-is under a header line `Convention (docs/conventions/<file>):` — factual framing, no imperative "SYSTEM:"-style wrappers (those can trip prompt-injection defenses).
- Total output stays under the 10,000-character cap; if matched rules exceed it, inject headers + file paths + first paragraph of each and instruct reading the files, rather than letting Claude Code spill to a file.
- Muninn **never** emits `permissionDecision`. It is context-only and must not interfere with the permission flow.
- Any internal error → `exit 0` silently (log to `.cache/muninn/log` with `--verbose` honored via env). A conventions tool must fail open; it can never block an edit.

Capability note: PreToolUse `additionalContext` is available in current Claude Code, but was not in the earliest hook releases (the PostToolUse path is the older, universally-supported one). Rather than hardcode a version boundary the docs no longer state explicitly, `muninn doctor` (§5.8) checks the installed `claude --version` against a minimum recorded in the binary and warns if PreToolUse injection may be unavailable; the generated `docs/conventions/README.md` notes the requirement. If PreToolUse injection is unsupported, L2 delivery degrades to PostToolUse with no loss of correctness (path is still knowable post-write) — a documented fallback.

### 5.5 `muninn hook post` (Layer 3 delivery)

Reads the PostToolUse JSON from stdin.

- Extract written content: `tool_input.content` (Write), `tool_input.new_string` (Edit), or every `new_string` in a batch-edit input where the running Claude Code version exposes one (historically a `MultiEdit`-style tool; not present in every version). Fallback: if the content field is absent but `tool_input.file_path` exists, read the file from disk. These exact field names are the one part of the contract most exposed to schema drift, so the captured fixtures in §8.4 — not this prose — are the authoritative source; the disk-read fallback keeps L3 working even if a field is renamed upstream.
- Match content against every L3 regex; where the rule also has `paths:`, require the file path to match too (AND semantics).
- Dedup, cap, output shape, and fail-open behavior identical to `hook pre`, with `hookEventName: "PostToolUse"`. Never emits `decision: "block"`.

### 5.6 `muninn match` and `muninn review` (review-agent interface)

- `muninn match <path> [...paths]` — resolve L2 by path only (no content available), plus L3 rules whose `contents` match the file's current on-disk content. Output formats: `--format paths` (default, one rule file per line), `--format json` (rules with layer, triggers hit, verify text), `--format full` (concatenated bodies, same rendering as hook injection).
- `muninn match --stdin-content <path>` — match against content provided on stdin instead of disk (lets a review agent test a proposed patch).
- `muninn review [<git-range>]` — default `HEAD` vs merge-base with the default branch, or an explicit range like `origin/main...HEAD`. For each changed file: path-match L2; match L3 `contents` against **added lines** of the diff. Emits a review manifest — per file, the applicable rule files and their `## Verify` criteria as checklist items — in `--format md` (paste-into-prompt ready) or `--format json` (for a review agent to consume programmatically). This makes review prompts carry zero copies of conventions, exactly as the standard requires.

Both commands rebuild the index automatically if missing or stale.

### 5.7 Session deduplication

State at `.cache/muninn/sessions/<session_id>.json`: a set of rule-file paths already injected this session, plus a timestamp. Both hook subcommands consult and append. A rule is injected at most once per session (v1; a `--redup-after N` knob for "once per N edits" is a fast-follow). Files older than 7 days are pruned opportunistically on any hook invocation. Concurrent hook writes use write-to-temp + atomic rename; a lost update merely risks one duplicate injection, which is acceptable.

### 5.8 `muninn lint` and `muninn doctor`

`lint` enforces the standard's quality bar and exits non-zero on violations:

- Frontmatter parses; unknown keys warned; `skill: true` without `description` is an error; `description` not starting with `"Use when"` is an error.
- Every regex compiles (PCRE2); every glob is syntactically valid.
- Layer 2/3 files declare at least one trigger; docs with triggers but empty bodies are errors.
- Root file budget: `AGENTS.md`/`CLAUDE.md` over 150 lines is a warning (`--strict` promotes to error).
- Skill-enabled docs over 500 lines: warning.
- Generated `SKILL.md` files that don't match generator output (same check as `generate --check`).

`doctor` checks the environment: hooks present in `.claude/settings.json` and pointing at a resolvable `muninn`, a Claude Code version new enough to support PreToolUse `additionalContext` (§5.4) if `claude` is on PATH, index freshness, cache writability.

### 5.9 `muninn help` (dual-audience explainer)

A first-class command, distinct from `--help` flag output. `--help` on any command prints terse flag/usage reference (for someone who already knows the tool); `muninn help` prints the **mental model** — why the tool exists, what the four layers are, where things live, and how the pieces connect. It is written to be equally readable by a human skimming a terminal and by an agent that has just encountered `muninn` in a hook and wants to understand what injected the context it's seeing.

**Why dual-audience matters:** when a PreToolUse/PostToolUse hook injects a rule, the agent sees convention text arriving from `muninn`. An agent that then runs `muninn help` should come away understanding that muninn is a deterministic delivery mechanism for human-authored conventions — not another agent, not a linter — so it treats the injected text as project context rather than something to argue with or route around. This directly supports the standard's guidance that injected text read as factual project information.

**Structure of the output** (plain prose with light headers, no ANSI-art, wraps at 80 cols, degrades cleanly when piped):

- **What muninn is** — one paragraph: a single binary that delivers the right documentation to the right moment, compiled from `docs/conventions/` frontmatter. Deterministic, no LLM calls.
- **Why it exists** — the problem it solves: one giant always-loaded instruction file gets skimmed and forgotten; muninn delivers guidance just-in-time, scoped to the file or construct being touched.
- **The four layers** — a compact table: Layer 1 root file (always), Layer 2 path-scoped (PreToolUse), Layer 3 construct-scoped (PostToolUse), Layer 4 intent skills (semantic). One line each on trigger and mechanism.
- **Where things live** — the canonical paths: `docs/conventions/` (source of truth), `.claude/skills/` (generated, do not edit), `.claude/settings.json` (hook wiring), `.cache/muninn/` (index + session state, gitignored).
- **How to use it** — the four entry points grouped by audience: *authoring* (`init`, edit docs, `generate`, `lint`), *runtime* (the `hook pre`/`hook post` entries Claude Code calls automatically — "you don't run these by hand"), *review* (`match`, `review`), *diagnostics* (`doctor`).
- **If you're an AI agent reading this** — an explicit short addressed block: muninn injected context because a rule matched the file you touched; the guidance is human-authored project convention; follow it or explain why in your response; the source doc path is cited in each injection so you can read the full rule.
- **Learn more** — pointer to `docs/conventions/README.md` and the standard.

**Sub-forms:**

- `muninn help` — the full explainer above.
- `muninn help --format json` — the same content as structured fields (`what`, `why`, `layers[]`, `paths{}`, `commands[]`, `agent_note`), so an agent can consume it programmatically or a downstream tool can render it. This is the machine-first path and should be kept in lockstep with the prose.
- `muninn help <command>` — the mental-model context for one command (when you'd reach for it and how it fits the layers), then defers to `muninn <command> --help` for exact flags.

**Constraints:** the content is a single source in the binary rendered to both prose and JSON (no drift between the two); a spec asserts the JSON form contains every command the CLI actually exposes, so `help` can't silently omit a command. Same fail-fast rules don't apply — `help` never touches the filesystem or index and always exits 0.

### 5.10 CLI conventions

`muninn <command> [args]`, `--help` everywhere, `--version`, `--repo-root <dir>` override (default: walk up to nearest `.git`), `--format` where applicable, machine-readable exit codes documented in `--help`. No config file in v1 — the frontmatter *is* the configuration.

## 6. Non-functional requirements

- **Performance:** `hook pre`/`hook post` complete in < 50 ms warm (index present) on a repo with 200 convention docs; < 500 ms cold including index rebuild. Enforced by a benchmark spec in CI (generous 4× threshold to absorb runner noise).
- **Zero runtime dependencies:** fully static Linux binary (musl). No shelling out on the hook path except optional git calls in `review`.
- **Deterministic output:** `generate` is byte-stable across runs and platforms (sorted walks, LF endings, no timestamps) — a prerequisite for the `--check` drift gate.
- **Fail-open hooks, fail-closed CI:** hook subcommands never exit non-zero on internal errors; `generate --check` and `lint` always do.
- **Windows-aware from day one in code** (path handling via `Path`, no hardcoded `/`), even though the Windows binary ships later.

## 7. Repository & distribution

### 7.1 Repo layout

```
muninn-rules/
├── AGENTS.md                     # Layer 1 (CLAUDE.md symlink) — dogfooding
├── LICENSE                       # MIT
├── shard.yml
├── src/
│   ├── muninn.cr               # CLI entry
│   └── muninn/
│       ├── cli.cr                # command routing (OptionParser)
│       ├── frontmatter.cr        # YAML frontmatter extraction + schema
│       ├── conventions.cr        # doc model, walking, hashing
│       ├── index.cr              # trigger index build/load/staleness
│       ├── matcher.cr            # glob + regex matching engine
│       ├── hooks/
│       │   ├── payload.cr        # Claude Code JSON in/out contracts
│       │   ├── pre.cr            # Layer 2 handler
│       │   └── post.cr           # Layer 3 handler
│       ├── session_state.cr      # dedup store
│       ├── skills.cr             # SKILL.md generation + check
│       ├── review.cr             # match/review resolution, diff parsing
│       ├── lint.cr
│       ├── doctor.cr
│       ├── help.cr               # dual-audience explainer (prose + json from one source)
│       └── init.cr               # bootstrap + settings.json merge
├── spec/                         # mirrors src/, plus integration/
├── docs/conventions/             # this repo's own rules
├── .claude/
│   ├── skills/                   # generated (committed)
│   └── hooks/                    # interim scripts during bootstrap (Phase 0 only)
└── .github/workflows/
    ├── ci.yml                    # specs, coverage, ameba, generate --check, lint
    └── release.yml               # tagged static binary builds
```

### 7.2 Dogfooding and the bootstrap ladder

This repo uses the structure on itself, with a deliberate self-hosting ladder:

- **Phase 0 (pre-binary):** `docs/conventions/` exists from day one; `.claude/hooks/inject-rules.sh` is a small interim script doing naive path matching (no index, no dedup) wired via PostToolUse only. Good enough to keep conventions in front of Claude Code while building.
- **Self-host milestone:** once `generate` + `hook pre|post` pass their specs, `muninn init --force` replaces the interim scripts with its own hook entries, the scripts are deleted, and CI adds `muninn generate --check` on the repo itself. From this point every muninn feature is exercised by muninn's own development.

### 7.3 Build & release (GitHub Actions)

- **CI (`ci.yml`,** push + PR): runs in the official `crystallang/crystal:1.20-alpine` container → `shards install`, `crystal spec`, `ameba` (zero findings required; pin the version deliberately — master is active but the newest tagged stable release lags), coverage via `kcov` following the community approach (Käufler's kcov guide / the `crystal-kcov` shard) with a **100% line-coverage gate** — enforced either by `crystal-kcov`'s `--fail-below-high 100` flag or a small check script reading kcov's `coverage.json`/`cobertura.xml` (plain `kcov` has no threshold flag of its own) — then a `crystal build --release` smoke build, then self-check: `bin/muninn generate --check && bin/muninn lint`.
- **Release (`release.yml`,** on `v*` tag): builds `crystal build --release --static` in the alpine container → `muninn-linux-x86_64` (statically linked, verified with `ldd`), attaches to a GitHub Release with SHA256 checksums. An `install.sh` (curl-pipe installer resolving latest release) ships in the repo root.
- **Roadmap targets:** macOS arm64/x86_64 via `macos-latest` runners (dynamic against system libs; macOS ships no static libc, so full-static is a Linux+musl capability only) and Windows x86_64 via `windows-latest` (Crystal's Windows support is officially **Preview** — the least mature tier — so it's gated on its own CI job going green and carries no production-readiness promise). The release workflow is written as a matrix from day one with only the Linux leg enabled.

## 8. Quality strategy

### 8.1 TDD + mutation testing

Development is spec-first: every module lands as a failing spec, then implementation. **Crytic** drives mutation-hardening of the pure logic modules (`matcher`, `frontmatter`, `index`, `session_state`, `review` diff parsing) — the places where a surviving mutant means a real correctness gap.

Per your call, crytic is **local/advisory only**: a `make mutate` target and a documented workflow ("run crytic on the module you touched; kill or consciously justify survivors in the PR description"), not a CI gate. Rationale recorded in the repo: crytic is single-maintainer and effectively dormant — its last tagged release (v9.0.0, May 2024) targets Crystal 1.12.1, and the only bump toward a modern Crystal (1.18.2) exists as an unreleased master commit (Nov 2025), never tagged — so it trails the latest Crystal release substantially; if it fails to build against the target Crystal at spike time, the fallback is documented manual mutation sessions (deliberate operator flips guided by a checklist) for the same modules, and the make target prints that instruction instead. (Note: this is `hanneskaeufler/crytic`, the Crystal mutation-testing tool — not the unrelated Solidity `crytic` tooling of the same name.)

**Crytic is disposable.** Because it is advisory-only and never gates CI, it can be dropped at any point — at the M0 spike or later, if a Crystal upgrade breaks it — with no effect on the build, release, or correctness guarantees; the 100% coverage gate and ameba are the actual quality floor. To drop it: remove the `make mutate` target (or leave it printing the manual-mutation checklist), delete the dev-dependency, and note it in the changelog.

### 8.2 Coverage

100% line coverage enforced in CI via kcov, as required. Two honest costs, accepted upfront: (a) OS-error branches (unwritable cache, malformed stdin) need spec plumbing — the design isolates all I/O behind small adapters so error paths are unit-testable; (b) the CLI entry glue is covered by integration specs that shell out to the built binary with fixture repos, which also double as the end-to-end tests for hook payload contracts.

**Caveat — kcov-on-Crystal is imperfect.** kcov reads DWARF debug info from the compiled binary, so two LLVM behaviors distort the number: **inlining** can make simple method bodies vanish from the report (under-count), and **dead-code elimination** strips unused code before it is ever instrumented, which can *inflate* the percentage (an untested-but-unused method disappears rather than showing as a miss). We keep the 100% target — it is the right forcing function — but treat it honestly: any exclusion is documented and reviewed rather than silently `# :nodoc:`'d away, and CI pairs the gate with `crystal tool unreachable` to catch code that was stripped-then-uncounted. A clean 100% here means "no *reachable* line went untested," not a naive line ratio.

### 8.3 Linting

Ameba as a dev dependency, zero-findings CI gate, config committed. Muninn's own `docs/conventions/` carries the judgment-call guidance that ameba can't enforce — the standard's incubator principle, applied to itself.

### 8.4 Contract tests against Claude Code

Fixture JSON payloads for PreToolUse/PostToolUse captured from a real Claude Code session (Edit, Write, and any batch-edit shape the running version exposes) live in `spec/fixtures/hook_payloads/`. These captures — not any prose in §5.4/§5.5 — are the authoritative record of the `tool_input` field names (`file_path`, `content`, `new_string`, …); when the schema drifts, the re-captured fixture is the single place the truth is updated and the parser follows. A quarterly (and on-report) task re-captures them, since the hooks schema is actively evolving. Output-side assertions verify the exact `hookSpecificOutput` envelope and the 10k cap behavior.

## 9. Implementation plan

Each milestone ends green: specs pass, coverage 100%, ameba clean.

**M0 — Repo bootstrap (½ day):** shard init, MIT license, ameba + kcov CI, AGENTS.md, `docs/conventions/` with the standard checked in as the spec, interim Phase 0 hook script. Crytic spike: attempt build against 1.20; record outcome and wire `make mutate` accordingly.

**M1 — Core model (2–3 days):** `frontmatter` (extraction, schema validation, error types), `conventions` (walk, hash, classify into layers), `matcher` (glob with `**`; PCRE2 content matching; AND semantics). Heaviest crytic target — mutation-harden here.

**M2 — Index + generate (2 days):** index build/load/staleness by content hash; deterministic `SKILL.md` emission; orphan cleanup; `generate --check` diff gate. Integration spec: fixture repo → generate → byte-compare golden files.

**M3 — Hook runtime (2–3 days):** payload parsing for both events, `hook pre` (path→L2), `hook post` (content→L3 with AND), session dedup store, 10k cap strategy, fail-open error handling, `--verbose` env logging. Integration specs shell the real binary with fixture stdin. Benchmark spec for the 50 ms budget.

**M4 — Review interface (2 days):** `match` (path/content, three formats, `--stdin-content`), `review` (git range resolution, added-line extraction from unified diff, `## Verify` harvesting, md/json manifests).

**M5 — init, lint, doctor, help (2 days):** settings.json merge (preserve foreign keys/hooks, idempotent), scaffolding with `--example`, full lint rule set, doctor checks, and `muninn help` (single-source prose + JSON explainer with the agent-addressed block; spec asserts JSON lists every exposed command).

**M6 — Self-host + release (1–2 days):** replace Phase 0 scripts via `muninn init --force`; add self-check to CI; release workflow, static build verification, install.sh; README with the version-requirement callout (a recent-enough Claude Code for PreToolUse context injection; §5.4).

**Post-v1 backlog:** macOS/Windows release legs; `--redup-after N`; Cursor/Copilot emitters from the same frontmatter; advisory-lint-rule linkage (teaching messages that reference rule files); `review` posting mode for CI (GitHub PR comments).

Total: roughly **2–2.5 focused weeks** to a self-hosting v1.

## 10. Risks & mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Crytic won't build on Crystal 1.20 | Loses automated mutation testing | Spiked at M0; advisory-only, never a CI gate; documented manual fallback, or drop crytic entirely with no impact on build/release/correctness |
| Claude Code hooks schema drift | Hook payloads stop parsing | Tolerant parsing (ignore unknown fields, required-fields-only), fixture re-capture cadence, fail-open |
| PreToolUse `additionalContext` unsupported on old CLIs | L2 silently not delivered | `doctor` capability check; README callout; documented degrade to PostToolUse delivery for L2 (§5.4); L3/PostToolUse path unaffected |
| 100% coverage friction on I/O edges | Slower iteration | I/O behind thin injectable adapters from M1 onward |
| kcov mis-counts (inlining / dead-code elimination) | 100% gate becomes misleading or brittle | Documented reviewed exclusions; pair gate with `crystal tool unreachable`; treat as "no reachable line untested" (§8.2) |
| Regex cost on large writes (L3) | Hook latency blowout | Index precompiles; benchmark spec; bound cost with a pre-match input-size cap (Crystal's `Regex` API does **not** expose PCRE2's `match_limit`/`heap_limit` — confirmed, see §11.4 — so the input-size cap, plus PCRE2's JIT keeping matches fast, is the available lever) |
| `settings.json` merge corrupting user config | Breaks someone's setup | Merge is additive + marked entries only; writes via temp+rename; `--dry-run` prints the diff |
| Crystal Windows maturity | Windows target slips | Explicitly tier 2; matrix pre-wired, enabled only when its CI is green |

## 11. Open questions (non-blocking, decide during M1)

1. Should `hook pre` also read the *proposed* content from `tool_input` and pre-fire L3 rules before the write? Technically possible (Write/Edit inputs carry the new content) and would make L3 preventive rather than corrective — but it doubles L3 evaluation and deviates further from the spec doc. Default: no in v1; revisit with usage data.
2. Dedup key granularity: per rule file (current design) vs per rule-file@hash, so an edited rule re-injects within the same session. Default: per file; hash-aware is a small follow-up.
3. `review` merge-base default branch detection (`origin/HEAD` vs `main|master` probing) — pick during M4 with fixtures for both.
4. **(Resolved.)** Crystal's `Regex` API does **not** expose PCRE2's `match_limit`/`heap_limit` (the public surface is limited to compile/match options like `IGNORE_CASE`/`MULTILINE`; upstream issue crystal-lang/crystal#15321 tracks the gap). Per-match bounding therefore relies on the pre-match input-size cap (§10), with PCRE2 JIT keeping matches fast. Revisit only if the stdlib later surfaces the limit.
