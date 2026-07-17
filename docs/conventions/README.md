# Conventions

This directory is the **single source of truth** for muninn's own scoped
guidance — the judgment calls and directional practices that a linter or
formatter cannot enforce. It dogfoods the Agent Documentation Structure Standard
(the normative spec: [`../../agent-docs-structure.md`](../../agent-docs-structure.md)).

Universal, always-apply rules live in the root [`AGENTS.md`](../../AGENTS.md), not
here. Anything a tool can enforce lives in that tool (`crystal tool format`,
`ameba`), not here.

## The four layers

| Layer | For | Trigger | Delivered by |
| --- | --- | --- | --- |
| 1 Root file | Universal rules | Always loaded | `AGENTS.md` |
| 2 Path-scoped | Guidance for a directory / file type | File **path** | PreToolUse hook |
| 3 Construct-scoped | Guidance for an API / code construct | Written **content** (regex), optionally AND path | PostToolUse hook |
| 4 Intent skills | Task-nature guidance (semantic) | Claude Code skill match | Generated `.claude/skills/*/SKILL.md` |

## Frontmatter

Each rule doc declares how it is delivered via YAML frontmatter:

```yaml
---
paths: ["src/**"]              # Layer 2: inject when editing a matching path
contents: ['\bSTDIN\b']        # Layer 3: inject when written code matches (PCRE2)
skill: true                    # Layer 4: generate a skill wrapper
description: "Use when ..."     # required iff skill: true; must start with "Use when"
---
```

Combination semantics:

- `paths` only → Layer 2 (fires on any edit to a matching path)
- `contents` only → Layer 3 (fires when written code matches, anywhere)
- `paths` + `contents` → **AND** (path-scoped Layer 3)
- `skill: true` is independent and may combine with either
- no frontmatter → reference-only: reachable by link, never triggered

## Writing a rule

- One concern per file. Keep it as short as possible — injected rules that are
  tight get read; long ones get skimmed.
- State **what** the rule is, **why** it exists (the reason is how an agent
  generalizes to edge cases), and a **verification criterion**.
- Add an optional `## Verify` heading; `muninn review` harvests it as a review
  checklist item.

> Delivery note: this repo self-hosts (PRD M6). Rules here are compiled and
> injected by `muninn` itself — Layer 2 on PreToolUse, Layer 3 on PostToolUse —
> via the hook entries in `.claude/settings.json`. Run `make install` so the
> `muninn hook pre`/`muninn hook post` commands resolve on PATH; `muninn doctor`
> checks the wiring.
