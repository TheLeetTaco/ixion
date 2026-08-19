---
name: plan-review
description: Run ALL reviewer agents in parallel against a plan. Deduplicates findings semantically and writes review.findings.json to the active session. Triggers on "review plan", "check plan".
allowed-tools:
  - Read
  - Write
  - Grep
  - Glob
  - Bash
  - Task
  - Skill
  - AskUserQuestion
---

# Plan Reviewing Skill

Run ALL available reviewer agents in parallel, collect their prose findings, structure them into the schema, dedup semantically, and write a merged `review.findings.json` into the active session directory.

**Philosophy:** Each reviewer represents a different stakeholder perspective. These perspectives legitimately conflict. We do NOT resolve conflicts — we preserve them as distinct findings and surface disagreements for the user to decide.

**Architecture:** Reviewers return natural-language prose; the synthesizer (this skill) is the single schema enforcer. Reviewers focus on finding issues; structuring is the synthesizer's job.

## Input

`$ARGUMENTS` is either a path to a standalone plan document or a session locator — a full session id, or a bare slug. Empty falls back to the active pointer.

---

## Phase 0: Load Target & Project Context

1. A `$ARGUMENTS` that is a readable path is the review target directly; skip to step 3. Otherwise it is the `LOCATOR`, and the session's `spec.json` is the target:

   ```bash
   <paste the "Resolve the session root" block from ${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/session-handoff.md verbatim>
   ```

   ```bash
   <paste the "Resolve the session" block from ${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/session-handoff.md verbatim>
   ```

   ```bash
   <paste the "Validate the resolved session" block from ${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/session-handoff.md verbatim>
   ```

2. An empty `repo_root=`, `via=none`, `state=missing`, `state=schema-mismatch` and `state=complete` each halt with the message that file's "Error states" table gives, verbatim. On `state=usable`, load `<dir>/spec.json`.
3. The review target (plan content or spec content) is passed inline to the reviewers.
4. Run the "Project context discovery" step from `${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/reviewer-dispatch.md` to collect `PROJECT_CONTEXT_PATHS`.

**Plan reviewers:** reviewer-architecture, reviewer-code-quality, reviewer-patterns, reviewer-performance, reviewer-data-integrity, reviewer-elegance.

Reviewers may catch external claim issues (version mismatches, anti-patterns, security concerns) as part of their normal review. There is no separate enrichment step — plan-creation handles initial validation; reviewers provide a second check from their respective perspectives.

---

## Phase 1: Dispatch ALL Reviewers in Parallel

Launch Task for every reviewer in a SINGLE message. Each Task prompt MUST include:

1. The plan content inline
2. Plan-scope location format: `<phase_id>` or `<phase_id>/<task_id>`
3. The no-file-write constraint (reviewers return prose; synthesizer handles all file writes)

**Standard reviewer prompt shape:**

```
<paste the "Dispatch preamble" from ${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/reviewer-dispatch.md verbatim>

Review this plan.

PLAN:
[full plan content or spec.json content]

PROJECT CONTEXT PATHS (read these for the project's grain — do not re-discover):
[list of paths from Phase 0, or "none" if no docs exist]

The plan's `context.constraints[0]` is the user's verbatim feature description, marked `(authoritative)`. The user's exact words are immutable constraints. **If the user explicitly chose a tool, library, framework, or approach** (e.g., `Auth0`, `terraform`, `Helm`, `htmx — no React`), do not propose alternatives — propose only where the user was silent. Read the user's words literally, not charitably: if they said "no Docker," that excludes Docker from dev, test, CI, and production — even if a reviewer thinks containerization is the obvious choice. Don't reinterpret scope.

The rest of `context.constraints[]` documents the planner's design rationale, including alternatives explicitly considered and rejected. Findings that contradict a documented rejection should explain why the rejection no longer holds — otherwise suppress them.

Use plan-scope locations: `<phase_id>` or `<phase_id>/<task_id>` (e.g., "phase-2" or "phase-2/t1"). Do NOT emit JSON; the synthesizer structures your output.

Do NOT write to any files. The synthesizer owns all file writes.
```

Dispatch the same prompt shape (adapted to each reviewer's focus) to the chosen reviewers in one message with parallel Task calls.

### Reviewer set selection (cost vs. coverage)

- **Default — all six** for specs with 3+ phases, refactors, or anything touching migration/auth/payment territory.
- **Slim — four (architecture, code-quality, patterns, elegance)** for specs with ≤2 phases and no migration/auth/payment keywords. Skip `reviewer-performance` and `reviewer-data-integrity` (they rarely fire on small specs). `reviewer-elegance` STAYS in the slim set: small specs are where elegance findings are precise.

When in doubt, run the default set. The slim set exists only to cut latency on small specs — coverage matters more than speed for design-impacting work.

**Rules:**

- Do NOT filter below the gate's floor — the slim set is four, never fewer
- Every prompt MUST specify plan-scope location format and the no-file-write constraint
- Launch the chosen set in a single message

---

## Phase 2: Synthesize Findings

The synthesizer reads each reviewer's prose output and structures it into `ixion/schemas/findings.schema.json` shape. Reviewers do NOT emit JSON; the synthesizer is the single schema enforcer.

### 2.1 Read each reviewer's prose output

Run the "Read each reviewer's prose output" step from `${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/finding-synthesis.md`.

### 2.2 Validate location format

Run the "Validate the location tier" step from `${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/finding-synthesis.md`. This is plan-review context, so plan-scope is the required tier and a code-scope location is the violation.

### 2.3 Semantic dedup

Run the "Semantic dedup" step from `${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/finding-synthesis.md`.

### 2.3a Tag contradictions with the verbatim prompt; scale findings to the spec's actual size

Run the "Tag contradictions, then scale findings to the target's actual size" step from `${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/finding-synthesis.md`, after 2.3 (dedup) and before 2.4 (structure into schema).

### 2.4 Structure into schema

Compose the final JSON, conforming to `ixion/schemas/findings.schema.json`:

```json
{
  "schema_version": 1,
  "findings": [ /* deduped findings + synthetic P1s for incomplete reviewers + synthetic P1s for wrong location tier */ ],
  "open_questions": [ /* union of any open questions reviewers raised */ ]
}
```

### 2.5 Validate and write

Validate the structured JSON against `ixion/schemas/findings.schema.json`. If validation fails, the synthesizer's structuring step had a bug — fix and retry. Reviewers are not at fault for synthesizer bugs.

Atomic write to `<dir= from Phase 0>/review.findings.json`:

```bash
final='<dir= from Phase 0>/review.findings.json'
tmp="$final.tmp"
# write JSON to $tmp
mv "$tmp" "$final"
```

---

## Phase 3: Summary & Next Steps

Print a condensed summary to the user (NOT the full review.findings.json):

```
Plan Review — <slug>

Reviewers: N ran (<list>)
Findings: M total → K dedup groups
Severity: P1=<count>, P2=<count>, P3=<count>
Wrong-location-tier violations: <count>
Incomplete reviewer outputs: <count>

Top findings:
- <title> (P1)
- <title> (P1)
- <title> (P2)

Findings written to: <dir= from Phase 0>/review.findings.json
```

Then the command that continues this session, so a `/clear` here costs nothing:

```bash
<paste the "Resume command" block from ${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/session-handoff.md verbatim, with SKILLS='plan-consolidation'>
```

The "Top findings" list shows 3-5 highest-severity finding titles, ordered by severity then by appearance.

No markdown write outside the session dir. The durable artifact is `review.findings.json` in the session dir.

---

## Error Handling

- **Session resolution failures**: Phase 0 halts on them with the `session-handoff.md` "Error states" messages.
- **Reviewer timeout**: treat as incomplete output → synthetic P1 against that reviewer.
- **Reviewer returns empty or unparseable prose**: synthetic P1 against that reviewer.
- **50% of reviewers fail**: surface in chat summary but still write review.findings.json with whatever did parse.

---

## Anti-Patterns

- **Filter reviewers below the gate's floor** — the slim set (four) is the minimum; the default is all six
- **Silently drop wrong-tier locations** — surface the violation as a P1
- **Fail the whole synthesis when one reviewer is malformed** — continue with remaining reviewers
- **Ask reviewers to emit JSON** — they emit prose; the synthesizer structures
- **Write review summaries as markdown anywhere** — the markdown append was removed in the rigor-gradient refactor; `review.findings.json` in the session dir is the durable artifact
- **Resolve disagreements by picking winners** — the user decides; surface conflicts as distinct findings

---

## Detailed References

- `references/conflict-handling.md` — philosophy, detection patterns, Open Question conversion
