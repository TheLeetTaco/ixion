# Research Dispatch Templates

Detailed dispatch templates for Phase 1 (Silent Research) and Phase 2 (Research Review).

---

## Phase 1: Canonical Research Workflow

Brainstorm runs the canonical research workflow (see `${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/research-workflow.md`) — all four locators, consolidate, all four analyzers. Substitute `<topic>` with `<feature_idea>`. Apply a 15s soft timeout to locator-web for fast exploration.

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

**AskUserQuestion:**

```
Question: "Research: does this cover the ground the design needs?"
**Why you:** Scope. Redirecting the research changes which part of the system the design ends up being about, and I cannot tell "I looked in the wrong place" from "that area is genuinely thin".
Options:
1. Approve and proceed (Recommended) - The summary covers it
2. Add focus area - Needs more investigation somewhere specific
3. Redirect research - Wrong direction entirely
4. "You pick what's best" - Let me decide
```

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

**Why you:** Missing fact. This is your description played back through my reading of the codebase, and only you can say whether it survived the round trip.

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

Then ask:

```
Question: "Past solutions: should these inform the approaches I present?"
**Why you:** Preference. The keyword match says they touch the same area; whether the lesson still applies to what you're building is your judgement of the resemblance, not the grep's.
Options:
1. Yes, factor them in (Recommended) - Approaches account for what was learned
2. No, start clean - The resemblance is superficial
3. "You pick what's best" - Let me decide
```

**If no matches:** Proceed silently.
