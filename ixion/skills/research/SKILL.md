---
name: research
description: "Conduct comprehensive codebase research producing a persistent document. Use when you need to understand something BEFORE planning, or for pure exploration. Triggers on \"research\", \"investigate\", \"explore codebase\"."
allowed-tools:
  - Read
  - Write
  - Grep
  - Glob
  - Bash
  - Task
  - WebFetch
  - AskUserQuestion
---

# Codebase Research Skill

Conduct comprehensive research using a two-phase locate-then-analyze approach that reduces context usage by 40-60%.

## Philosophy: Documentarian Mode

- Document what IS, not what SHOULD BE
- No suggestions, critiques, or recommendations
- Pure technical mapping of the existing system
- Focus on paths and references, not full file contents

---

## Input

Read `${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/question-format.md` before proceeding — it contains the question template, the mandatory Why-you slot, and the four reasons that gate whether to ask at all.

Research question via `$ARGUMENTS`. If empty, ask what to research.

**Why you:** Missing fact. Nothing in the repo says which corner of it you are trying to understand today.

---

## Phase 0: Check for Existing Research

Before starting new research, check if recent research already covers this topic:

```bash
find docs/research -name "*<topic-slug>*" -mtime -14 2>/dev/null | head -3
```

If matches found, read the YAML frontmatter (`topic`, `tags`) to assess relevance. If a strong match exists:

**AskUserQuestion:** "Existing research: found `[filename]` ([N] days old). Reuse, refresh, or start new?"

**Why you:** Preference. The file's age is all I can measure; whether it is still true depends on how fast this area has moved since, which you know and the mtime does not say.

- **Reuse (Recommended)** — Read existing doc, skip to Phase 3 (summary)
- **Refresh** — Use existing doc as starting point, re-run locate/analyze to update
- **Start new** — Proceed normally
- **"You pick what's best"** — Let me decide

If no matches or no `docs/research/` directory, proceed to Phase 1.

---

## Phase 1: Research Workflow

Run the canonical research workflow: all four locators in parallel → consolidate → all four analyzers in parallel.

Read `${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/research-workflow.md` before proceeding — it contains locator templates, the consolidation rule (top-N selection per analyzer), and analyzer templates.

---

## Phase 2: Synthesize & Persist

Map the canonical analyzer outputs to research-doc sections:

- **analyzer-codebase findings** → "Codebase Map" (file structure, components, interactions; file:line refs).
- **analyzer-patterns findings** → "Patterns" (named patterns with code examples and locations).
- **analyzer-docs findings** → "Decisions & Constraints" (extracted ADR / doc content).
- **analyzer-web findings** → "External References" (URL citations with extracted content).

The canonical analyzers' flags fold into a "Concerns & Open Questions" section:

- `EXISTING_SOLUTION`, `DRY_VIOLATION`, `PATTERN_CONFLICT`, `INTEGRATION_RISK` → "Concerns" subsection with file:line citations.
- `OPEN_QUESTION`, `CLAIM_INVALID`, `VERSION_ISSUE` → "Open Questions" subsection.

These are documentarian observations (not recommendations) so they belong in the persisted research even though research doesn't act on them — downstream consumers (plan-creation, brainstorm) read the doc and act.

Write to `docs/research/YYYY-MM-DD-<topic-slug>.md`. Optionally git-commit the research document.

Read `references/research-document-template.md` before proceeding — it contains the full output document format with YAML frontmatter, all required sections, and the git commit template.

---

## Phase 3: Summary & Next Steps

Display a summary to the user (not the full document). Offer three options: create a plan from the research, continue researching, or exit.

Read `references/research-document-template.md` before proceeding — the "Present & Offer Next Steps" section contains the AskUserQuestion format and option-action mapping.

---

## Integration: Called by Other Skills

Other skills can check for recent research before starting work, and invoke this skill if none exists.

Read `references/research-document-template.md` before proceeding — the "Integration" section contains the bash lookup pattern for finding existing research.

---

## Context Budget

This skill is context-heavy. Monitor usage:

- **Within Phase 1, after locators**: If >30 locator results, consolidate aggressively before dispatching analyzers
- **After Phase 1 completes**: Write findings immediately in Phase 2; don't hold in context
- **Always**: Prefer file:line references over quoting code

---

## 2-Action Rule for Visual Content

After ANY 2 of these operations:
- WebFetch
- Browser tool use
- Image viewing
- Search results review

**IMMEDIATELY** persist findings to the research document as text.

Visual/multimodal content doesn't persist well in context. Capture it as text before it's lost.

---

## Anti-Patterns

- **Skip locator phase** — Don't go straight to analyzers
- **Analyze everything** — Only analyze top findings from locators
- **Make suggestions** — This is documentation, not consultation
- **Return file contents** — Paths and references only
- **Forget to persist** — Always write research document
- **Hold in context** — Write to file, reference by path
