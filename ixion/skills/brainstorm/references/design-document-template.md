# Design Document Template

Output format for validated designs.

## File Location

```
.ixion/plugin/designs/<topic>-design.md
```

Use kebab-case for topic.

---

## Template

```markdown
---
created: <date>
status: validated
type: design
brainstorm_session: true
---

# Design: [Feature Name]

## Overview
[What we're building and why]

## Context & Requirements

### Problem Statement
[Core problem being solved]

### Success Criteria
[How we'll know it works]

### Constraints
[Technical, business, user constraints]

### Out of Scope
[What's explicitly NOT included]

## All Explored Approaches

### Approach A: [Name] ✓ SELECTED
[Full details with pros/cons/effort]

### Approach B: [Name]
[Full details with pros/cons/effort]

### Selection Rationale
[Why selected approach was chosen]

## Selected Approach Details

### User Flows
[From validation phase]

### Architecture
[From validation phase]

### Data Model
[If applicable]

### Error Handling
[From validation phase]

## Open Questions
[Any unresolved questions]
```

---

## Approach Format

Present 2-3 approaches with explicit tradeoffs:

```markdown
### Approach A: [Name] (Recommended)

**Summary:** [2-3 sentences explaining the approach]

**Tradeoffs:**
| Pro | Con |
|-----|-----|
| [Benefit 1] | [Drawback 1] |
| [Benefit 2] | [Drawback 2] |
| [Benefit 3] | [Drawback 3] |

**When to choose this:** [Scenario where this is the best choice]
**When NOT to choose this:** [Scenario where this approach fails]

**Effort:** S / M / L

**Why recommended:** [1 sentence if this is the recommended approach]
```

**Key:** Forcing tradeoffs ensures we think about failure modes, not just benefits.

---

## Completion Summary

```
✅ Design document saved: .ixion/plugin/designs/<topic>-design.md

Summary:
- Selected approach: [Approach name]
- [N] alternative approaches documented
- [N] sections validated
```

---

## Handoff Options

Present the summary, then ask:

```markdown
Design complete: `.ixion/plugin/designs/[topic]-design.md`

The design documents:
- **Problem:** [1 sentence summary]
- **Selected approach:** [approach name]
- **Key decisions:** [3-5 bullet points]
```

**AskUserQuestion format:**
```
Question: "Next: the design is validated and saved. What now?"
**Why you:** Scope. Planning turns this design into committed work, and how much of it to build now is yours to size.
Options:
1. Create implementation plan (Recommended) - `/ixion:plan .ixion/plugin/designs/[topic]-design.md`
2. Start implementing directly - `/ixion:work`, only if the design is S effort
3. Continue refining - Revisit specific sections
4. Done for now - Save and come back later
5. "You pick what's best" - Let me decide
```
