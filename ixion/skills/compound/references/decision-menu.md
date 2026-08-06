# Decision Menu Reference

After successful documentation, present options and WAIT for user response.

## Menu Display

```
✓ Solution documented

File created:
- docs/solutions/[category]/[filename].md

Question: "Next: the solution is documented. What now?"
**Why you:** Preference. Promoting this to Required Reading binds every future reader of the repo, and whether one debugging session is worth that weight is a call about your team, not about the doc.
Options:
1. Continue workflow (Recommended) - Documentation is complete
2. Add to Required Reading - Promote to critical patterns
3. Link related issues - Connect to similar problems
4. "You pick what's best" - Let me decide
```

Three former options were dropped rather than converted. "View documentation" re-displayed a file whose path is printed one line above and then re-asked the same question, so it never decided anything. "Add to existing skill" and "Create new skill" wrote into `ixion/skills/` relative to the user's repo, which is not where the installed plugin is read from — the file they produced was inert.

---

## Option Handling

### Option 1: Continue workflow
- Return to calling skill/workflow
- Documentation is complete

### Option 2: Add to Required Reading

User selects when:
- System made this mistake multiple times across modules
- Solution is non-obvious but must be followed every time
- Foundational requirement (API design, database access, threading)

**Action:**
1. Extract pattern from documentation
2. Format as ❌ WRONG vs ✅ CORRECT with code examples
3. Add to `docs/solutions/patterns/critical-patterns.md`
4. Add cross-reference back to this doc
5. Confirm: "✓ Added to Required Reading"

### Option 3: Link related issues
- Prompt: "Which doc to link?"
- Search docs/solutions/ for the doc
- Add cross-reference to both docs
- Confirm: "✓ Cross-reference added"

### Option 4: "You pick what's best"
- Apply the recommendation (Option 1) and record it as a delegated decision rather than a picked one

---

## Critical Pattern Detection

If this issue has automatic indicators suggesting it might be critical:
- Severity: `critical` in YAML
- Affects multiple modules OR foundational stage
- Non-obvious solution

Then add a note in the decision menu:
```
💡 This might be worth adding to Required Reading (Option 2)
```

But **NEVER auto-promote**. User decides via Option 2.

---

## Critical Pattern Template

When user selects Option 2 (Add to Required Reading):

```markdown
## Pattern [N]: [Pattern Name]

**Problem:** [Brief description of what goes wrong]

**Why it happens:** [Root cause explanation]

❌ **WRONG:**
```[language]
// Code that causes the problem
```

✅ **CORRECT:**
```[language]
// Code that solves the problem
```

**Example:** See [link to solution doc]

**Detection:** [How to notice this is happening]

**Prevention:** [How to avoid in future code]
```

Number sequentially based on existing patterns in `docs/solutions/patterns/critical-patterns.md`.
