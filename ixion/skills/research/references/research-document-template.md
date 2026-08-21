# Research Document Template

The output format for Phase 3: Synthesize & Persist. Write this document to `docs/research/YYYY-MM-DD-<topic-slug>.md`.

---

## Output Path

- If `docs/research/` exists, use it
- Otherwise, create `docs/research/` directory

---

## Document Template

```markdown
---
date: [ISO timestamp]
topic: "[Research Question]"
status: complete
tags: [research, <relevant-tags>]
---

# Research: [Topic]

## Research Question

[Original user query]

## Summary

[High-level findings - 3-5 sentences synthesizing all agent outputs]

## Detailed Findings

### [Component/Area 1]

[Findings with file:line references from analyzer-codebase]

### [Component/Area 2]

[Findings from analyzer-patterns]

### [Additional Areas...]

## Code References

| File | Lines | Description |
|------|-------|-------------|
| `path/to/file.rs` | 42-67 | [what it does] |
| `path/to/other.rs` | 15-30 | [what it does] |

## Patterns Identified

- **[Pattern Name]**: `file.rs:42-67` - [description]
- **[Pattern Name]**: `other.rs:89-120` - [description]

## External References (if applicable)

- [Source Title](URL) - [key takeaway]

## Open Questions

- [Question needing further investigation]
- [Uncertainty about scope or behavior]
```

---

## Integration: Called by Other Skills

Other skills check for existing research before starting work:

```bash
# Check for recent research on topic (within 14 days)
RESEARCH=$(find docs/research -name "*<topic-slug>*" -mtime -14 2>/dev/null | head -1)

if [ -n "$RESEARCH" ]; then
  # Recent research exists — read YAML frontmatter to check topic match
  # Offer to user: "Recent research found on [topic]. Reuse or refresh?"
else
  # No recent research — proceed with new research or ask user
fi
```

**Freshness heuristic:** by file mtime:
- `-mtime -14` (2 weeks): Fresh — offer to reuse
- `-mtime -30` (1 month): Stale — offer to refresh or reuse
- Older: Treat as reference only, recommend new research

---

## Present & Offer Next Steps

Display summary to user (not the full document).

**AskUserQuestion:**

```
Question: "Next: research is saved to docs/research/[filename]. What now?"
**Why you:** Preference. The question you asked is answered and on disk, so whether to build on that, dig further, or stop here is a judgment about what you need next rather than anything the document settles.
Options:
1. Create plan from research (Recommended) - Invoke plan-creation with research path
2. Continue researching - Ask follow-up question, re-run locate-then-analyze, append to document
3. Done for now - Exit
4. "You pick what's best" - Let me decide
```
