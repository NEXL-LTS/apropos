---
contents: ['\bNotImplementedError\b']
---
# Stub marker (Layer 3 — construct-scoped)

**Rule:** Any function that raises `NotImplementedError` MUST have this exact
marker comment on the line immediately above its `def`:

```python
# muninn-rule:L3-K9F4
```

**Why:** Unfinished stubs are tracked by an audit tool that greps for the
`L3-K9F4` tag. Delivery is content-scoped: it fires from the *written code*
matching `NotImplementedError`, anywhere in the tree, not from the file's path.

## Verify

- Every function raising `NotImplementedError` has `# muninn-rule:L3-K9F4`
  directly above its `def`.
