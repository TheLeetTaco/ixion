---
name: flywheel-conventions
description: Shared conventions for Flywheel subagents. Tool discipline, output format, research patterns.
user-invocable: false
---

## Elegance Discipline (BLOCKING: Apply at every stage)

**Maximize elegance.** This is the single governing principle. Every rule below describes what elegance looks like — heuristics in service of the principle, not the goal themselves. When a rule produces awkward or indirect output, break it and document why the result is more elegant.

Maximize elegance over minimizing churn. Pick the more elegant design no matter how big the refactor. Better now than months from now with more features and dependencies in place.

The output — plan or code — must read as if every decision was deliberate. A reader should never ask "why is this here?" about any line, phase, or task.

### Decision checklist (heuristics, not laws — interrogate any check that feels wrong)

| # | Check | If violated |
|---|-------|-------------|
| 1 | Is there exactly one source of truth for this data? | You're creating a copy. Read from the existing source. |
| 2 | Would deleting this code change behavior? | If not, delete it now. |
| 3 | Is this abstraction used in 2+ places? | If not, inline it — unless inlining would force the caller to do two unrelated jobs. |
| 4 | Does this wrapper add a new capability? | If not, call the underlying API directly. |
| 5 | Could a reader understand this in 30 seconds without context? | If not, the names or shape are wrong. |
| 6 | Does data flow in one direction? | If A updates B and B updates A, you have a cycle. Pick one owner. |
| 7 | Are you fighting the language or framework? | Use the idiomatic primitive. Ceremony signals the tool wants to be used differently. |
| 8 | Are you adding something speculative ("we might need…")? | Delete it. Add when the need is concrete. |

### Anti-patterns

For the canonical anti-pattern catalog (named violations to use in findings — e.g. "Shallow Wrapper", "Forwarding Chain", "Parallel State", "Premature Abstraction", "Dead Code", "God Class"), see `flywheel/agents/reviewer-elegance.md` "Anti-Pattern Catalog". Use these names so plan-consolidation can route by principle.

### Symptoms vs. structure

When you see multiple small issues clustered in one area, they usually point at one structural defect. Fix the structure; the symptoms dissolve. If you find yourself patching N findings in the same file, stop and redesign instead.

---

## Tool Discipline

**BLOCKING: Never use Bash for operations that have a dedicated tool.**

- **Content search**: Use **Grep**, not `grep`/`rg` via Bash
- **File search**: Use **Glob**, not `find`/`ls` via Bash
- **File reading**: Use **Read**, not `cat`/`head`/`tail` via Bash

Bash is only for: git commands, `bun` commands, and system operations with no dedicated tool.

---

## Output Rules

**Limits**: Locators 500 words. Analyzers 1500. Reviewers: prose findings (Title / Severity / Location / Failure / Fix per finding). The orchestrating skill (plan-review or work-review) parses your prose into `flywheel/schemas/findings.schema.json`. Do NOT emit JSON.

**Format**: Structured sections (End Goal, Key Findings, Files Identified). Paths only, never file contents. Flag ambiguities with "OPEN QUESTION:".

**Severity**: `P1` blocks merge (security, data loss, breaking change, normal-path defect). `P2` should fix (real downside — edge case, perf regression, maintainability trap). `P3` user's discretion (low-impact, narrow scope).

**References**: Always `path/to/file.ts:42-67`, never "in the auth module."

---

## False-Positive Suppression

Core rule: don't emit a finding without a concrete, named consequence. A suppressed finding beats a noisy one — when in doubt, suppress.

Suppress if:
- **Generic "consider adding" advice** — you can't name what concretely breaks
- **Speculative future-work** — "might not scale" without evidence the concern is reachable
- **Already handled** — guards, middleware, or framework defaults cover it (code-review)
- **Linter territory** — formatting, unused vars, import order (code-review)
- **Alternative approaches** without naming what breaks about the chosen one (plan-review)
- **Scope creep** — "also add Z while you're at it"; review evaluates the stated plan, not expansions (plan-review)

---

## Finding Quality: Lead with the Failure

The `failure` field is the implementer's primary input. It must contain everything needed to understand the full scope of the problem in one read. **Three components, typically a paragraph (2-4 sentences):**

1. **Intent** — what the code or plan was trying to achieve.
2. **Observation** — what's specifically wrong (the discrepancy from intent).
3. **Reasoning** — why this discrepancy matters: consequences for users, the system, or design integrity.

Failure is broad: an **observable failure** (something doesn't work for someone) OR a **principle violation** (a design rule like SRP, DRY, or Single Source of Truth is broken). Both are failures; both are reasons the code or plan needs to change.

**Strong (observable):**
> "parseDate is supposed to accept the common date formats users actually submit. It only handles YYYY-MM-DD and returns null for DD/MM/YYYY. The caller at line 78 treats null as 'expired' and logs the user out, so DD/MM/YYYY input becomes a silent logout — wrong outcome and confusing UX."

**Strong (principle):**
> "Violates SRP. AuthService should expose only orchestration concerns; it currently imports React components and renders login forms inline. Every UI tweak forces re-testing auth logic, and headless contexts can't use the service."

**Weak (either flavor)** — names absence or is too terse:
- "parseDate doesn't validate input format." ← describes absence; no intent, no consequence.
- "AuthService is doing too much." ← vague; no specific intent or violation named.

If you can write the failure in one sentence, you're probably missing the intent or the reasoning. If you cannot articulate intent + observation + reasoning, the finding is advisory — mark P3 or suppress.

---

## Spec Quality Bar

Before emitting `spec.json`, verify each phase contains:

- Clear goal and success criterion
- Repo-relative file paths (never absolute)
- Enumerated test scenarios specific enough that the implementer doesn't invent coverage
- Explicit verification command

A spec is ready when an implementer can start confidently without needing to infer.

If any phase fails the bar, loop back: read the codebase, ask the user, or defer the phase explicitly as `status: deferred` with rationale.

---

## Research Agent Behavior

**Documentarian mode** (locators + analyzers): Document what IS, not what SHOULD BE. No suggestions, critiques, or recommendations.

**Read files fully**: Use Read WITHOUT limit/offset. Partial reads cause hallucination.

---

## Dispatch Patterns (for orchestrators)

### Locator → Analyzer (two-pass research)

1. **Locators first** — run in parallel
   - `locator-codebase`, `locator-patterns`, `locator-docs` (haiku)
   - `locator-web` (sonnet — query crafting needs stronger reasoning)
   - No Read tool — return paths/URLs only
   - Pass search context inline (locators can't read files)

2. **Analyzers second** — targeted, use sonnet
   - `analyzer-codebase`, `analyzer-patterns`, `analyzer-docs`
   - Feed only the top 15 findings from locators
   - Pass file paths, not content (analyzers have Read)
   - Documentarian mode — no suggestions

### Model inheritance

Implementation subagents (`general-purpose`, `Explore`, `Plan`) inherit the parent model — never set `model`. Only research agents (locators, analyzers) use explicit models.

### Input context

Pass file paths (not content) to Read-capable agents. Content inline to locators. Phase-only plan excerpts, not full plans. Under 100 lines where possible.

---

## Error Protocol

3 strikes then escalate:
1. **Diagnose** — read error, identify root cause, targeted fix
2. **Alternative** — different method/tool/approach. Never repeat same failing action.
3. **Rethink** — question assumptions, search for solutions
4. **Escalate** — log attempts, explain to user, ask for guidance

---

## Rationale Discipline

Every line in a SKILL.md loads on every invocation. Include rationale only when it changes what the agent does at runtime. If behavior would not differ without the sentence, cut it. Extract conditional/late-sequence content to `references/` and load on demand.

