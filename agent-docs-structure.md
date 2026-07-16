# Agent Documentation Structure Standard

This document defines the target structure for AI agent instruction documentation in this repository. Use it as the specification when restructuring existing documentation (CLAUDE.md, AGENTS.md, convention docs, best-practice guides).

## Goal

Replace one large, always-loaded instruction file with a layered system where each piece of guidance is delivered by the cheapest mechanism that reliably triggers it. Guidance should arrive just-in-time, scoped to the moment it applies, instead of being front-loaded and forgotten.

## Scope: complements enforcement, does not replace it

This system is not a substitute for linters, formatters, type checkers, or CI. Anything those tools can enforce deterministically belongs in them, not in convention docs. This structure exists for guidance that is hard to enforce mechanically — judgment calls, trade-offs, directional practices, workflow knowledge.

A convention doc can also serve as an incubator: a practice starts here as prose, and once it is well understood and its violations recognizable, it graduates into a lint rule, formatter setting, or generator, and the prose is deleted. Movement should be one-directional — from docs into tooling, never the reverse.

## The four layers

Every existing instruction, convention, or practice must be classified into exactly one of these layers.

### Layer 1: Root file (always loaded)

**File:** `CLAUDE.md` / `AGENTS.md` at repo root.

**Contains only:**
- A short project description (2-4 sentences)
- Exact build, test, and lint commands
- Universal rules that apply to every task regardless of file or context
- A map: one line explaining that scoped guidance lives in `docs/conventions/` and skills, and is surfaced automatically

**Constraints:**
- Hard budget: keep well under 150 lines. Shorter is better.
- Every line must pass the test: "Would removing this cause the agent to make a mistake on a typical task?" If not, remove it.
- Imperative voice. Pair every prohibition with the alternative ("Never X; do Y instead").
- No formatting/style rules that a linter or formatter enforces. Delete those; the tooling is the documentation.
- No domain-specific or context-specific guidance. That belongs in Layers 2-3.

### Layer 2: Path-scoped rules (deterministic trigger by location)

**For:** guidance that applies when working in a specific directory or file type. The context is knowable from the file path.

**Structure:**
- One markdown file per concern in a tool-agnostic location, e.g. `docs/conventions/` (e.g. `background-jobs.md`, `controllers.md`, `migrations.md`)
- Each file declares the path patterns it applies to in its YAML frontmatter (see Frontmatter and the generation pipeline)

**Constraints per rule file:**
- One concern per file
- As short as possible while covering the concern. It will be injected into context at edit time; tight files get attention, long files get skimmed.
- Structure: what the rule is, why it exists (the reason is how the agent generalizes to edge cases), and a verification criterion (how the agent can check it complied)

### Layer 3: Construct-scoped rules (deterministic trigger by code content)

**For:** guidance tied to a specific code construct, API, or pattern that can appear anywhere in the codebase. The context is knowable from what the code contains, not where it lives.

**Structure:**
- One markdown file per construct in `docs/conventions/` (same directory and format as Layer 2)
- Each file declares the content patterns (regex) it applies to in its YAML frontmatter, optionally combined with `paths:` to restrict where the content match applies (e.g. only flag `update_all` in `app/**`, not in one-off scripts)
- Where a lint rule can detect the construct but the right response requires judgment, an advisory (warn-level) lint rule with a teaching message pointing to the rule file is preferred

**Same per-file constraints as Layer 2.**

### Layer 4: Intent-scoped skills (semantic trigger)

**For:** guidance that cannot be triggered by path or content — it depends on the nature of the task ("doing a data migration", "touching billing logic", "writing a public API").

**Structure:**
- The actual documentation lives in `docs/conventions/` (e.g. `docs/conventions/workflows/<name>.md`), same tool-agnostic location as Layers 2-3
- A convention doc opts into being a skill via its frontmatter: `skill: true` plus a `description:` field. The description must be precise and start with "Use when...". Test: if a reader can't tell from the description alone exactly when it fires, rewrite it.
- Skills are **generated, not hand-written**: a generator walks `docs/conventions/`, and for each doc with `skill: true` emits a thin `.claude/skills/<name>/SKILL.md` wrapper containing only the frontmatter description and a pointer to the source doc. Generated skills are never edited directly — single source of truth stays in `docs/conventions/`.
- Referenced convention docs under 500 lines each; split large workflows into multiple files referenced from the same doc

**Accept:** semantic triggering has a miss rate. Anything that *must* always apply cannot live only in this layer.

## Frontmatter and the generation pipeline

Every convention doc carries YAML frontmatter (`---` delimited, same convention Claude uses for its own files) declaring how it is delivered:

```yaml
---
paths: ["app/jobs/**"]              # Layer 2: inject when editing matching paths
contents: ['\.transaction\b']       # Layer 3: inject when written code matches
skill: true                         # Layer 4: generate a skill wrapper
description: "Use when ..."         # required if skill: true
---
```

Combination semantics:

- `paths` only → fires on any edit to a matching path (Layer 2)
- `contents` only → fires when the written code matches, anywhere in the repo (Layer 3)
- `paths` + `contents` → **AND**: fires only when the written code matches *and* the edited file is within a matching path (path-scoped Layer 3)
- `skill: true` is independent of the above and may be combined with either

Docs with no delivery frontmatter are reference material, reachable only by link from other docs.

A **generator** walks `docs/conventions/` and compiles the frontmatter into tool-specific artifacts:

- A cached **trigger index** (e.g. `.cache/conventions-index.json`) mapping path/content patterns to rule files, so per-edit matching is a single lookup rather than a scan. Rebuilt only when a doc's hash changes.
- Generated **`.claude/skills/<name>/SKILL.md`** wrappers for every doc with `skill: true` (description + pointer, nothing else)
- Optionally, other tools' native formats (Cursor `.mdc`, Copilot `.instructions.md`) from the same frontmatter

The generator runs locally (manually or via pre-commit) and its output for skills is **committed to the repository**. A **CI check** re-runs the generator and fails if the committed artifacts differ from what the current docs produce — stale or hand-edited generated files block the merge. The trigger index is a local build artifact (gitignored); the injection hook rebuilds it on first use when missing or stale.

## Trigger mechanics

Rules in Layers 2 and 3 are delivered by hooks, not by hoping the agent reads them:

- A **PostToolUse hook** on Edit/Write matches the edited path and content against the compiled trigger index and injects the matching rule file(s) as additional context immediately after the edit
- The hook **dedupes per session**: each rule file is injected at most once per session (or once per N edits) to avoid context bloat
- Advisory lint rules (warn-level) surface through the existing lint hook; their messages reference the rule file

## Code review reuses the same structure

The trigger frontmatter doubles as a review manifest. A code review agent (or a human reviewer) resolves which conventions apply to a change set the same way the edit-time hook does:

- For each file in the diff, match its **path** against the rule files' `paths:` patterns (via the compiled index) to load the relevant Layer 2 rule files
- Match the **diff content** against the `contents:` patterns to load the relevant Layer 3 rule files
- Review the change against exactly those conventions — each rule file's verification criterion becomes a review checklist item

This means review prompts (e.g. a PR review agent, a `/review` command, or CI-driven AI review) should not carry their own copy of the conventions. They resolve rules from the same frontmatter/index, load only what the diff touches, and cite the rule file when flagging a violation. One source of truth serves authoring, editing, and reviewing.

## Classification procedure for restructuring

For each instruction in the existing documentation, ask in order:

1. **Can tooling enforce it deterministically** (formatter, linter, type checker, hook that blocks)? → Move it to tooling. Delete the prose.
2. **Is it universal** — applies to every task in the repo? → Layer 1 root file, subject to the budget.
3. **Is it determined by file location?** → Layer 2 path-scoped rule.
4. **Is it determined by a code construct or API usage?** → Layer 3 construct-scoped rule + trigger pattern (and an advisory lint rule if detection is feasible).
5. **Is it determined only by task intent?** → Layer 4 skill.
6. **None of the above / stale / describes the project as it used to be?** → Delete it.

If an instruction seems to belong in multiple layers, choose the most deterministic trigger available (tooling > path > content > intent > always-loaded).

## Output structure

```
repo/
├── AGENTS.md                     # Layer 1 (CLAUDE.md symlinked to it)
├── docs/
│   └── conventions/
│       ├── <concern>.md          # Layer 2/3 rule files, one concern each, triggers in frontmatter
│       └── workflows/
│           └── <workflow>.md     # Layer 4 content, skill: true + description in frontmatter
├── .claude/
│   ├── skills/                   # GENERATED from frontmatter — do not edit
│   │   └── <workflow>/
│   │       └── SKILL.md          # description + pointer to source doc
│   └── hooks/
│       └── inject-rules.<ext>          # PostToolUse: match index, inject rule files
└── .cache/
    └── conventions-index.json    # GENERATED trigger index (gitignored)
```

## Quality bar for the restructured output

- Root file under budget and containing zero rules that tooling enforces
- Every rule file: one concern, as short as possible, includes the why and a verification criterion
- Every Layer 2/3 rule file declares at least one path or content trigger in its frontmatter
- Every skill-enabled doc's description passes the "Use when..." precision test; all SKILL.md files are generator output, never hand-edited, with no guidance content duplicated from `docs/conventions/`
- A CI check regenerates from `docs/conventions/` and fails on any diff against the committed generated artifacts
- Nothing was silently dropped: instructions that were deleted are listed in the restructuring summary with the reason (moved to tooling, stale, duplicate, etc.)
