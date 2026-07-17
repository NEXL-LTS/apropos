---
skill: true
description: "Use when adding a new arithmetic operation to the calc library"
---
# Adding an arithmetic operation (Layer 4 — intent skill)

When adding a new operation to the calc library at `lib/calc.py`:

1. Place this exact marker comment on the line immediately above the new
   function's `def`:

   ```python
   # muninn-rule:L4-Q7X2
   ```

2. Keep the function pure — take operands as arguments, return the result, no
   I/O — and give it a one-line docstring.

**Why:** This guidance is triggered by the *intent* of the task ("add an
arithmetic operation"), not by a path or a code construct, so it is delivered as
a skill. The `L4-Q7X2` tag lets the audit tool confirm the workflow was followed.

## Verify

- The new operation is a pure function with a docstring and carries
  `# muninn-rule:L4-Q7X2` directly above its `def`.
