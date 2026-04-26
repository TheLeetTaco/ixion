---
name: plan-consolidation
description: Refine the active session's spec.json by merging reviewer findings.json into it. Backs up the pre-refinement spec to a .pre-consolidation sidecar. Triggers on "consolidate plan", "finalize plan".
allowed-tools:
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - Bash
  - AskUserQuestion
---

# Plan Consolidation Skill

Merge review findings into the active session's `spec.json`. Pre-refinement spec is preserved as a `.pre-consolidation` sidecar so the refinement is auditable (D7). The refined `spec.json` retains the same top-level shape as the pre-refinement spec — only the content changes. Do NOT add top-level fields like `origin`, `risks`, or `notes`; the schema rejects additional properties. Namespace: plugin uses `.flywheel/plugin/sessions/`.

## Input

No arguments. Reads the active session from `.flywheel/plugin/active.json`.

---

## Phase 0: Load Active Session

1. Read `.flywheel/plugin/active.json` to resolve `session_id`
2. Compute session directory: `.flywheel/plugin/sessions/<session_id>/`
3. Read two inputs:
   - `spec.json` (the pre-refinement spec)
   - `review.findings.json` (written by plan-review)

**Errors:**

- `active.json` missing → ask the user to run plan-creation first
- `review.findings.json` missing → ask the user to run plan-review first, or abort
- `spec.json` missing → the session is broken; ask the user to delete and restart

---

## Phase 1: Back Up to Sidecar (D7)

```bash
cp .flywheel/plugin/sessions/<id>/spec.json \
   .flywheel/plugin/sessions/<id>/spec.json.pre-consolidation
```

Cleaned on `ship`.

---

## Phase 2: No-Op Check

If `review.findings.json` has zero findings and zero open questions:

- Print: "No refinements needed — spec is already work-ready."
- Skip to Phase 6 (next-steps prompt).

---

## Phase 3: Surface Open Questions

Questions to surface:

1. `review.findings.json.open_questions` (entries the synthesizer could not resolve)
2. Inter-reviewer conflicts — findings where two or more reviewers described the same issue but assigned different severities. Surface the divergence; the user decides which severity is right rather than defaulting to the more severe.

**BLOCKING: Each AskUserQuestion call MUST contain exactly ONE question.** Never pass multiple questions to a single AskUserQuestion call (no `questions: [...]` arrays of length > 1). Make a separate call per question, await the response, then make the next call. Bundled multi-question prompts produce a confusing wizard-style "Review your answers / Submit" review flow that breaks both UX and test automation.

For each question:

```
Question: "[Topic]: [The question]"
Context: [Brief explanation of why this matters]
My recommendation: [Preferred option and why]
Options:
1. [Option A] (Recommended) - [Brief description]
2. [Option B] - [Brief description]
3. "You pick what's best" - Let me decide
```

Record: user picks option → decision logged; "You decide" → apply recommendation, note delegated; custom answer → record exactly. **BLOCKING: Never proceed with unresolved questions.**

---

## Phase 4: Propagate Decisions Into the Spec

**BLOCKING: Each resolved decision MUST be reflected in the spec's content, not just remembered in the conversation.** The implementer dispatches against the refined `spec.json`; if a decision isn't IN the spec, it won't be honored — that's a consolidation failure, not an implementer failure.

For each answered question:

1. **Identify affected tasks/phases** — the question's topic points to one or more `phases[].tasks[]`. Read the task descriptions and find the ones that would behave differently under each option.
2. **Rewrite task descriptions** to bake the decision in as a constraint. Examples:
   - "stdlib for tests too?" → "yes" → rewrite test task descriptions to mandate `unittest.TestCase` (not pytest); remove any pytest-favoring language; update `test_scenarios` if they implied pytest fixtures.
   - "Notes plain strings or structured?" → "plain strings" → rewrite storage task to specify `str` content type explicitly; remove any dataclass references.
3. **Update `verification` commands** if the decision changes them. Example: `pytest` → `python -m unittest tests.test_module`.
4. **Append the decision to `context.constraints[]`** as a one-line note that survives into the implementer dispatch. Format: `"Decision: <topic> → <answer>. <one-sentence why>."`. Example: `"Decision: stdlib only for tests → use unittest.TestCase, not pytest. Verification command runs python -m unittest."`.

The bar: a fresh implementer who reads only `spec.json` (no conversation history) must reach the same outcome the user's answer prescribed. If they could plausibly do something different, the decision wasn't propagated thoroughly enough.

---

## Phase 5: Integrate Findings by Severity

**Surface failures into context.** For every P1/P2 finding integrated into spec.json, append a one-line summary of the `failure` to `spec.context.constraints[]` so the implementer sees the reasoning during dispatch, not just the patch.

**Structural failures replace, don't patch.** If a finding's `failure` leads with a named anti-pattern from `flywheel/skills/flywheel-conventions/references/elegance.md` (e.g., Shallow Wrapper, Forwarding Chain, Premature Abstraction, Parallel State, Speculative Code, God Class) or a Universal Principle name (Single Source of Truth, Working with the Grain, Depth over Indirection, Narrow Interfaces, One-Direction Data Flow, Dead Code Is Debt), do NOT fold the `fix` into the affected task's description — that adds the patch on top of the inelegant shape. Instead, re-shape the affected phase or task to the simpler form the finding prescribes. Delete tasks made redundant by the redesign. The "Maximize elegance over minimizing churn" rule applies: pick the cleaner shape even when it means a larger refactor.

The elegance reference is the canonical name list — read it before deciding whether a finding triggers structural redesign or task-level patching.

### Consistency check (run before integrating any finding)

The user's verbatim feature description lives in `context.constraints[0]`, marked `(authoritative)`. **The user's exact words are immutable.** Reviewers don't see the original prompt and may suggest alternatives in good faith — but the user's authority overrides reviewer suggestions every time.

For each finding, before applying its `fix`:

1. **Does the finding propose changing or replacing something the user named explicitly?** If the user wrote "with unittest" and a finding suggests pytest, defer it. Rationale: `Deferred: <finding-title> contradicts user's verbatim description ('<user words>')`.

2. **Does the finding's fix add capabilities the user did not request?** Concurrency, caching, body-size limits, pagination, an extra endpoint — if the user's verbatim description doesn't mention them, defer with rationale: `Deferred: <finding-title> adds <feature> not requested by user`.

3. **Does the finding contradict an existing `success_criteria` entry derived from the user's words?** Defer.

**Do not reinterpret the user's words to accommodate the finding.** "Stdlib only — no pip install" means *no pip install of any kind* — runtime, dev, test framework. The user said what they said. Honor it literally; do not charitably re-scope it. Do NOT rewrite the existing `success_criteria` or `summary` to make room for the finding — that's how drift sneaks into the spec. If the existing content conflicts with the finding, the existing content wins.

Only integrate findings whose fix is consistent with the user's verbatim description AND the existing spec content. The result is an internally-coherent spec that honors the user's exact words, not one that says "X" in success_criteria and "not-X" in verification commands.

For each remaining finding in `review.findings.json.findings`:

### P1 — Integrate (after consistency check)

- Fold `fix` language into the affected task's `description`
- Add test scenarios that cover the failure described in `failure`
- If the finding does not map to an existing task: add a new task to the relevant phase

### P2 — Integrate by default; defer only when the finding adds a new *what*

Users describe *what* to build and the *hows* they care about (specific tools, libraries, frameworks, ports, file layouts). They generally underspecify the rest. Reviewers fill in the underspecified *hows* — robustness, correctness, polish — and that's their job. **Adding "how" to underspecified areas is good scope growth.** Integrate these like a P1.

Defer only when a finding adds a new *what* — a capability, endpoint, or feature the user didn't describe at all:

| Finding shape | Verdict |
|---|---|
| Adds atomic writes (temp file + `os.replace`) to existing `save_note` | Integrate — how |
| Adds `threading.RLock` to serialize concurrent writes | Integrate — how |
| Adds name-validation rejecting `/`, `\`, `..`, null bytes | Integrate — how |
| Adds `Content-Type: application/json` header to JSON responses | Integrate — how |
| Adds type hints to existing functions | Integrate — how |
| Adds pagination on `GET /notes` (user described simple list) | Defer — new what |
| Adds an admin auth layer (user described open API) | Defer — new what |
| Adds a new endpoint or function not in the user's spec | Defer — new what |
| Adds caching/LRU infrastructure (user didn't mention performance) | Defer — new what |

If you defer, record `Deferred: <finding-title> — adds new <feature> not described by user` as a one-line task note.

The consistency check above is the strict gate (catches contradictions with explicit user wording). This P2 check is the secondary gate (catches new-what additions). Default is integrate — most P2 findings are reviewers filling in *how*, which is what they're for.

### P3 — Default Include

P3 findings are nice-to-have, low-impact suggestions. Integrate them by default — fold the `fix` into the affected task's description and append the `failure` summary to `constraints[]`, just like P2.

Apply the same consistency check as above: if a P3 contradicts an existing `summary`, `success_criteria`, or `constraints` entry, defer it with a one-line rationale. Otherwise, integrate.

This is the path of least resistance for the common case — most users approve most P3s, and removing the triage prompt also unblocks autonomous orchestrators (`/yolo`). If the user wants to drop a P3 after seeing it integrated, they can edit the spec or remove it before `/work`.

---

## Phase 6: Write Refined Spec & Hand Off

1. Validate the refined spec against `flywheel/schemas/task-list.schema.json`.
2. Atomic write `.flywheel/plugin/sessions/<id>/spec.json` (`.tmp` → `mv`).
3. **Delete `review.findings.json`** — it has been consumed. This is the signal to `/work` that no unhandled review remains.
   ```bash
   rm .flywheel/plugin/sessions/<id>/review.findings.json
   ```
4. Print summary:
   ```
   Spec refined — <id>
   Integrated: N P1, N P2, N P3
   Deferred: N
   ```
5. **AskUserQuestion:** "Spec consolidated and ready. What next?"
   - Start `/work` (Recommended)
   - Done for now

---

## Error Handling

- **Active session missing:** Prompt user to run plan-creation first
- **Findings missing:** Prompt user to run plan-review first, or abort
- **Schema validation failure on write:** Restore from `spec.json.pre-consolidation`; report which field failed; do not leave a half-merged spec on disk
- **User rejects every option on an open question:** Abort consolidation; spec stays in pre-refinement state (sidecar was created but the main spec.json was not overwritten)

---

## Anti-Patterns

- **Skip open-question resolution** — Don't refine with unresolved questions
- **Multiple questions at once** — One at a time
- **BLOCKING: Auto-drop a P1** — P1s integrate; only the user may downgrade to follow-up
- **Resolve a question without rewriting the spec** — Decisions must propagate into task descriptions, verification commands, and `context.constraints[]`. A decision that lives only in the conversation history is invisible to the implementer (Phase 4).
- **Fold structural failures into existing tasks** — Replace the affected phase or task with the simpler shape, don't patch the original. Surface the `failure` into `context.constraints[]`.
