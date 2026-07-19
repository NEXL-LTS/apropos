---
paths: ["src/**"]
---
# Source marker (Layer 2 — path-scoped)

**Rule:** Every new function you add under `src/` MUST be immediately preceded,
on its own line directly above the `def`, by this exact marker comment:

```python
# apropos-rule:L2-7Q2X
```

**Why:** This project audits which functions in `src/` were written under
governance. The token `L2-7Q2X` is a build-traceable tag a reviewer greps for;
omitting it fails review. Delivery is path-scoped, so it arrives whenever a file
under `src/` is edited — regardless of what the code does.

## Verify

- Each newly added function in `src/` has `# apropos-rule:L2-7Q2X` on the line
  immediately above its `def`.
