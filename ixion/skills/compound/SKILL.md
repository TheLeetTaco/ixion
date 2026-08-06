---
name: compound
description: Document solved problems to compound team knowledge. Creates categorized docs with YAML frontmatter. Triggers on "that worked", "it's fixed", "compound".
allowed-tools:
  - Read
  - Write
  - Bash
  - Grep
  - Task
  - AskUserQuestion
---

# Compound Skill

Document solved problems to build searchable institutional knowledge.

**Why "compound"?** Each documented solution compounds your team's knowledge like compound interest. First time solving a problem takes research. Document it, and the next occurrence takes minutes.

**Compounding vs Compaction:** Ixion uses two strategies (see README):
- **Compaction** = Reduce context mid-work (atomic `progress.json` checkpoints, structured `spec.json.context` arrays)
- **Compounding** = Accumulate knowledge post-work (this skill)

**Preconditions:**
- Problem has been solved (not in-progress)
- Solution has been verified working

**Organization:** Single-file per problem in category directory (e.g., `docs/solutions/performance-issues/n-plus-one-query.md`).

Read `ixion/skills/ixion-conventions/references/question-format.md` before proceeding — it contains the question template, the mandatory Why-you slot, and the four reasons that gate whether to ask at all.

---

## Step 1: Detect Confirmation

**Auto-invoke after:** "that worked", "it's fixed", "working now", "problem solved"

**OR manual:** `/compound` command

**Non-trivial problems only:**
- Multiple investigation attempts needed
- Tricky debugging
- Non-obvious solution

**Skip:** Simple typos, obvious syntax errors, trivial fixes.

**Additional categories:**
- `pattern` = Successful approach worth reusing → `docs/solutions/patterns/`
- `mistake` = Failed approach with prevention guidance → `docs/solutions/mistakes/`

---

## Step 1.5: 3-Strike Integration

**When invoked after 3-Strike escalation** (error resolved with user help), capture:

- **What failed**: All 3 attempts (sanitized - remove credentials, API keys, PII, internal URLs)
- **Why it failed**: Root cause analysis
- **What worked**: User-provided solution
- **How to prevent**: Future guidance

This creates institutional memory from hard-won debugging sessions.

---

## Step 2: Gather Context

Extract from conversation history:

- **Module** - Which component had the problem
- **Symptom** - Exact error messages, observable behavior
- **Investigation** - What was tried, what didn't work
- **Root cause** - Technical explanation
- **Solution** - Code/config changes that fixed it
- **Prevention** - How to avoid in future

**When invoked from `ship` Phase 5**, a second source arrives alongside the conversation: the session harvest (what plan review reshaped, which principle names recurred in `review.findings.json`, what the fix pass undid). Treat it the same as conversation context — it fills the same slots:

| Harvest signal | Slot it fills |
|---|---|
| Phase deleted or restructured by plan review | Symptom + Root cause — the design that didn't survive |
| Principle name recurring across sessions | Category `pattern` or `mistake`; feeds Step 5.5 |
| Fix pass fighting the original structure | Investigation — the approach that was tried and cost something |

Session-sourced entries are usually `pattern`, `mistake`, `best_practice`, or `workflow_issue` rather than the error-shaped types. The "verified solution" precondition still holds: the PR is the verification.

**If critical context missing**, ask user, in this order:

1. "Module: which component had the problem?" — **Why you:** Missing fact. The conversation is my only record of this session, and when it never named the component, nothing in the repo says which one you were standing in.
2. "Symptom: what was the exact error text?" — **Why you:** Missing fact. The error printed in your terminal, and a doc filed under my paraphrase of it is a doc the next person's grep will miss.
3. "Environment: where did it happen (OS, version, config)?" — **Why you:** Missing fact. The repo records the environments it supports, not the one you were actually running.

---

## Step 2.5: First-Use Discoverability Check

On first compound creation in a repo, add a one-line pointer to `docs/solutions/` so future agents find the knowledge store: `` Past solutions & compound learnings live in `docs/solutions/`. ``

Detection: `ls docs/solutions/ 2>/dev/null | wc -l` returns 0 AND neither AGENTS.md nor CLAUDE.md has a grep hit for `docs/solutions`.

Destination: `test -f AGENTS.md` and `test -f CLAUDE.md`. Which of the two exist settles it in two of the three cases:

- **Neither exists** — create AGENTS.md and say so; both Claude Code and OpenCode read it, so there is no competing candidate.
- **Exactly one exists** — append to it and say so; the alternative is a file that isn't there.
- **Both exist** — the choice is genuinely yours, so ask:

```
Question: "Discoverability: put the `docs/solutions/` pointer in AGENTS.md or CLAUDE.md?"
**Why you:** Preference. Both files are here and both get read; which one your team actually keeps current is a habit the repo doesn't record, and the pointer is worthless in the file nobody reads.
Options:
1. AGENTS.md (Recommended) - read by both Claude Code and OpenCode
2. CLAUDE.md - read by Claude Code only
3. "You pick what's best" - Let me decide
```

---

## Step 3: Check Existing Docs

```bash
grep -r "exact error phrase" docs/solutions/
```

**If similar found:**

```
Question: "Existing doc: `[path]` covers a similar problem. Extend it, or write a new one?"
**Why you:** Preference. Whether these are two faces of one problem or two problems that happen to share an error string is a judgement about your system, and the grep hit alone doesn't settle it.
Options:
1. Update the existing doc (Recommended) - Keeps one place to look
2. New doc with a cross-reference - Different root cause, same symptom
3. "You pick what's best" - Let me decide
```

**If none:** Proceed.

---

## Step 4: Sanitize & Validate

**Before documenting, sanitize sensitive data:**
- Remove credentials, API keys, secrets
- Remove PII (names, emails, IDs)
- Replace internal URLs with `[internal-url]`
- Generalize environment-specific paths

Then validate against `references/yaml-schema.md`:
- All required fields present
- Enum values match exactly
- symptoms is array (1-5 items)

Determine category from problem_type, create file:

```bash
mkdir -p "docs/solutions/${CATEGORY}"
```

Write using template from `references/resolution-template.md`.

---

## Step 5: Optional Specialized Review

For complex issues, invoke relevant reviewer:

| Problem Type | Reviewer |
|-------------|----------|
| performance_issue | reviewer-performance |
| database_issue | reviewer-data-integrity |

**Only if** the problem was particularly tricky or affects critical systems.

---

## Step 5.5: Standards Inference

After documenting the solution, check if this pattern generalizes:

```bash
# Search for solutions with similar tags or problem types
grep -rl "<root-cause-keyword>" docs/solutions/ | head -5
```

If 2+ solutions share the same root cause type or pattern (e.g., same type of fix in the same component area), suggest creating a standard:

```
Question: "Standard: this pattern appears in [N] solutions ([list filenames]). Capture it as a reusable standard?"
**Why you:** Scope. A standard binds code nobody has written yet, so adopting one is a commitment well past documenting the fix you just made.
Options:
1. Skip (Recommended) - Continue without creating a standard
2. Yes - Draft the standard from the shared pattern into `docs/standards/<pattern-name>.md` per `docs/standards/README.md`, then confirm the content with you
3. "You pick what's best" - Let me decide
```

Only suggest when the pattern is clearly reusable, not when solutions happen to touch the same file.

---

## Step 6: Present Results

Read `references/decision-menu.md` before proceeding — it contains the completion message, the menu and what each option does.

---

## Error Handling

- **Missing context:** Ask user, wait
- **YAML validation failure:** Show errors, block until valid
- **Similar issue found:** Present options

---

## Anti-Patterns

- Document trivial fixes
- Document without verified solution
- Vague docs without code examples
- Skip cross-references

---

## Detailed References

- `references/yaml-schema.md` - YAML fields, enums, category mapping
- `references/resolution-template.md` - File template, filename rules
- `references/decision-menu.md` - Post-documentation options
