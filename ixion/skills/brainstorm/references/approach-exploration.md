# Approach Exploration Templates

Detailed format templates for Phase 5 (Explore Approaches).

---

## Approach Presentation Format

Present each approach with explicit tradeoffs:

```markdown
## Approach: [Name] (Recommended)

**Summary:** [2-3 sentences]

**Tradeoffs:**
| Pro | Con |
|-----|-----|
| [Benefit 1] | [Drawback 1] |
| [Benefit 2] | [Drawback 2] |

**When to choose this:** [Scenario where this is best]
**When NOT to choose this:** [Scenario where this fails]

**Effort:** S/M/L
```

This forces thinking about failure modes, not just benefits.

---

## Selection Process

Ask the user to select, recommended approach first:

```
Question: "Approach: which of these should the design follow?"
**Why you:** Preference. The approaches trade against each other -- speed against flexibility, less code now against less rework later -- and which trade is right is taste no amount of reading the codebase settles.
Options:
1. [Recommended approach name] - [one-line summary]
2. [Alternative name] - [one-line summary]
3. "You pick what's best" - Let me decide
```

If user wants to combine approaches:
1. Clarify which aspects from each
2. Present the hybrid as a new approach using the same format
3. Confirm the hybrid before proceeding
