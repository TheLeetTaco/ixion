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
   <paste the "Resolve the session" block from ixion/skills/ixion-conventions/references/session-handoff.md verbatim>
   ```

   ```bash
   <paste the "Validate the resolved session" block from ixion/skills/ixion-conventions/references/session-handoff.md verbatim>
   ```

2. `via=none`, `state=missing`, `state=schema-mismatch` and `state=complete` each halt with the message that file's "Error states" table gives, verbatim. On `state=usable`, load `<dir>/spec.json`.
3. The review target (plan content or spec content) is passed inline to the reviewers.
4. Run the "Project context discovery" step from `ixion/skills/ixion-conventions/references/reviewer-dispatch.md` to collect `PROJECT_CONTEXT_PATHS`.

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
<paste the "Dispatch preamble" from ixion/skills/ixion-conventions/references/reviewer-dispatch.md verbatim>

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

For each reviewer response:

- Extract per-finding: Title, Severity, Location, Failure (paragraph), Fix.
- If a reviewer returned "No findings" or equivalent, record zero findings from this reviewer.
- If a reviewer's output is incomplete (missing one of the required elements on any finding), construct a synthetic P1 against that reviewer's agent file noting the gap, AND retain the partial finding for the user's visibility.

Synthetic P1 shape (constructed by the synthesizer, in schema):

```json
{
  "title": "Reviewer output incomplete: <reviewer-name>",
  "severity": "P1",
  "location": "ixion/agents/<reviewer-name>.md",
  "failure": "<reviewer-name> returned a finding missing one of the required elements (Title/Severity/Location/Failure/Fix). The structuring step couldn't fully ingest it; the synthesizer's review may be incomplete for this reviewer's domain. Without complete fields, downstream consolidation can't reliably integrate the finding.",
  "fix": "Investigate the reviewer's prompt or retry that reviewer. Check whether the agent file or dispatch text needs tightening."
}
```

### 2.2 Validate location format

This is plan-review context, so location must be plan-scope (`<phase_id>` or `<phase_id>/<task_id>`). If a reviewer emitted a code-scope location like `src/auth.rs:42`, that's a disambiguation failure. Construct a synthetic P1 against the reviewer:

```json
{
  "title": "Wrong location tier: <reviewer-name> emitted code-scope location in plan-review",
  "severity": "P1",
  "location": "ixion/agents/<reviewer-name>.md",
  "failure": "<reviewer-name> emitted location '<bad-location>' in a plan-review context. Plan reviews require plan-scope locations like 'phase-2' or 'phase-2/t1', not code-scope paths. The reviewer must honor the location format the dispatch specified, otherwise findings can't be matched to spec.json structure during consolidation.",
  "fix": "Update the reviewer prompt or agent file so the location format always matches the invoker's tier."
}
```

Retain the original (mistargeted) finding alongside so the user can see what was flagged.

### 2.3 Semantic dedup

Walk the findings and group those describing the same issue — reviewers may phrase a shared concern differently (e.g., "phase-2 missing fallback" and "phase-2 lacks retry logic" — same gap). Group by meaning, not by string match.

For each group:
- Take max severity (P1 > P2 > P3). Severity is not promoted by corroboration; a P3 that three reviewers flagged is still a P3.
- Merge the Failure paragraphs into a single rich paragraph that captures the union of intent + observation + reasoning. Preserve the leading principle name from the four-slot format — do not paraphrase the first token.
- Pick the strongest Fix or merge them into a single coherent proposal.

**Cross-finding pattern detection:** count findings by leading principle name. If the same name appears in 3+ distinct findings (e.g., three independent "Shallow Wrapper" findings across phases), tag the cluster as a spec-pattern issue. Plan-consolidation handles a tagged cluster as a single redesign of the relevant `context.patterns[]` entry, not N phase patches — the pattern was the source.

### 2.3a Tag contradictions with the verbatim prompt; scale findings to the spec's actual size

Two judgment calls I make as the synthesizer, in this order, before structuring the output. Both apply to findings of every severity. Both also reduce the surface plan-consolidation has to evaluate downstream — fewer findings ⇒ less consolidation reasoning ⇒ less drift risk and faster pipeline.

**Tag — don't drop — contradictions with the verbatim user prompt.**

`spec.context.constraints[0]` carries the user's exact feature description, prefixed `User feature description (verbatim, authoritative):`. Reviewers review the spec from a best-practices lens; they don't read the user's exact prompt. So when a reviewer pushes back on a user choice (e.g., suggests `uvicorn` where the user said `gunicorn`, or proposes splitting a monolithic deploy into microservices), the pushback is real information — users sometimes deviate from best practice out of laziness, not principle, and the reviewer's "you should be using X" deserves to surface so the user can confirm or revisit the decision.

I keep contradicting findings in the published list, but I tag them so plan-consolidation knows they're advisory:

- Prefix the `title` with `[Contradicts user] `
- Append one sentence to `failure`: `Deferred: contradicts constraints[0] ('<user words>'); record the pushback, do not auto-integrate.`

The contradiction shapes I tag:

- a different tool than the user named ("user said `gunicorn`, finding says switch to `uvicorn`")
- a different shape than the user specified ("user said `monolithic deploy`, finding says split into microservices")
- a different scope than the user asked for ("user said `no observability for v0`, finding says add tracing and metrics")

Findings that fill in *underspecified* hows — robustness, security, type hints, error handling, validation the user didn't speak to — pass through untagged. That's good scope growth and the reviewer's primary value.

The point of tagging instead of dropping: reviewer pushback is the value, not the noise. The tag preserves the record; plan-consolidation treats `[Contradicts user]`-tagged findings as advisory and won't rewrite the spec to accommodate them.

**Scale findings to the spec's actual size.**

If reviewers surface 20+ findings on a 3-phase 60-line spec, they're working the universal anti-pattern catalog rather than this specific plan. I trust my judgment to drop the over-eager ones:

- Generic critiques the spec doesn't earn ("phase-1 lacks rollback procedure" on a stateless transformation)
- Style preferences the schema already permits ("`test_scenarios` should be objects, not strings" — the schema accepts strings)
- Theoretical scaling concerns far below the spec's actual scope ("consider DDD bounded contexts" on a 60-line CRUD MVP; "warn about lock contention" on a single-user spec)

The published count should reflect the spec's real surface area. A small spec rarely earns more than a handful of meaningful findings; if my output is much larger than the spec's complexity warrants, I trim.

I apply both treatments (tag, then trim) after 2.3 (dedup), before 2.4 (structure into schema).

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

Atomic write to `.ixion/plugin/sessions/<session= from Phase 0>/review.findings.json`:

```bash
tmp=".ixion/plugin/sessions/<session= from Phase 0>/review.findings.json.tmp"
final=".ixion/plugin/sessions/<session= from Phase 0>/review.findings.json"
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

Findings written to: .ixion/plugin/sessions/<session= from Phase 0>/review.findings.json
```

Then the command that continues this session, so a `/clear` here costs nothing:

```bash
<paste the "Resume command" block from ixion/skills/ixion-conventions/references/session-handoff.md verbatim, with SKILLS='plan-consolidation'>
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
