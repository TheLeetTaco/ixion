# Research Dispatch Templates

Detailed dispatch templates for Phase 1 (Silent Research) and Phase 2 (Research Review).

---

## Phase 1: Canonical Research Workflow

Brainstorm runs the canonical research workflow (see `flywheel/skills/flywheel-conventions/references/research-workflow.md`) — all four locators, consolidate, all four analyzers. Substitute `<topic>` with `<feature_idea>`. Apply a 15s soft timeout to locator-web for fast exploration.

**Extract for internal use** (map the canonical analyzer outputs to brainstorm's approach-selection inputs):

- analyzer-codebase findings → "Similar implementations" + "Naming conventions"
- analyzer-patterns findings → "Relevant existing patterns" (named, with file:line)
- analyzer-docs findings → "Technical constraints" (decisions, ADR limits)
- analyzer-web findings → "Best practices" (external references)

The canonical analyzers emit observation flags (`EXISTING_SOLUTION`, `DRY_VIOLATION`, `PATTERN_CONFLICT`, `INTEGRATION_RISK`, `OPEN_QUESTION`, `CLAIM_INVALID`, `VERSION_ISSUE`). Brainstorm uses these to inform the approach options it presents to the user; if `EXISTING_SOLUTION` fires, surface it explicitly so the user can choose to reuse rather than build.

---

## Phase 2: Research Review Presentation Format

Present a summary (NOT raw findings) to the user:

```
Research Summary for: [Feature]

Scope Identified: [3-5 bullets]
Key Files: [paths with purpose]
Patterns Discovered: [pattern: description]
Potential Concerns: [risks]
```

**AskUserQuestion options:**
- Approve and proceed
- Add focus area - Need more investigation
- Redirect research - Wrong direction

Maximum 2 re-research cycles.

---

## Phase 3: Understanding Confirmation Template

Before exploring approaches, confirm understanding:

```
I understand we're solving:

**Problem:** [1-2 sentences]
**For:** [audience]
**Success looks like:** [outcome]
**Out of scope:** [explicit boundaries]

Is this accurate?
```

---

## Phase 4: Past Solutions Lookup

Check `docs/solutions/` for relevant past solutions:

```bash
grep -l "<keyword>" docs/solutions/**/*.md 2>/dev/null
```

**If matches found (max 3-5):**

```
Relevant Past Solutions:

1. **[Title]** (path)
   - Symptom: [from frontmatter]
   - Why relevant: [connection to problem]
```

Ask if learnings should inform approach selection.

**If no matches:** Proceed silently.
