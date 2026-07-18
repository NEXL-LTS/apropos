# Conventions

Scoped guidance for this sample repo, delivered just-in-time by muninn.

| Layer | For | Trigger | Delivered by |
| --- | --- | --- | --- |
| 1 Root file | Universal rules | Always loaded | `AGENTS.md` |
| 2 Path-scoped | A directory / file type | File **path** | PreToolUse hook |
| 3 Construct-scoped | An API / code construct | Written **content** (regex) | PostToolUse hook |
| 4 Intent skills | Task-nature guidance | Semantic skill match | Generated `SKILL.md` |

Each rule doc declares how it is delivered via YAML frontmatter:

```yaml
---
paths: ["src/**"]                    # Layer 2
contents: ['\bNotImplementedError\b'] # Layer 3 (PCRE2)
skill: true                          # Layer 4
description: "Use when ..."          # required iff skill: true
---
```

The docs in this directory demonstrate one convention per layer:

- `src-rule.md` — Layer 2, fires on edits under `src/**`.
- `stub-rule.md` — Layer 3, fires when written code raises `NotImplementedError`.
- `workflows/add-operation.md` — Layer 4 skill, matched by task intent.
