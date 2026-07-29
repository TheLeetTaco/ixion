---
module: System
date: 2026-07-29
problem_type: pattern
component: development_workflow
symptoms:
  - "A placeholder like <base> is referenced by three skills and assigned by none"
  - "Each consumer recomputes the value with its own heuristic, agreeing only in simple cases"
  - "A diff measured against the placeholder comes back empty and the check silently inspects nothing"
root_cause: missing_workflow_step
resolution_type: workflow_improvement
severity: high
tags: [session-state, schema, pipeline, single-source-of-truth, plan-review, adr-principle-4]
---

# A value two skills must agree on needs a persisted home, not a placeholder

## Symptom

`<base>` appeared in three skills as `git diff <base>...HEAD`:

- `ixion/skills/work/SKILL.md:313` (Phase 3 success-criteria check)
- `ixion/skills/work/SKILL.md:321` (Phase 4 cumulative self-check, marked **BLOCKING**)
- `ixion/skills/work-review/SKILL.md:108` (reviewer-set sizing)

It was assigned nowhere. `work/SKILL.md:119` said outright: "No baseline. No hash."

Because `work` also never committed anything, `HEAD` still equalled the branch point, so the three-dot diff resolved to **empty**. The BLOCKING self-check had been inspecting nothing, silently, for as long as the instruction existed.

## Investigation

### Attempted (Failed)

1. Treating `<base>` as an ordinary angle-bracket placeholder — the repo's normal convention for "the agent fills this in." That works for a value one skill uses locally. It fails here because three *separate* skill invocations must fill it in with the *same* answer.
2. Planning to resolve the base once in `work` Phase 1 and reference it downstream. This was the first plan, and it is wrong for the same reason: `work`, `work-review` and `ship` are separate invocations with separate contexts. A value living in one skill's reasoning cannot be read by the other two, so each would recompute from its own heuristic — three independent guesses that coincide only when the branch topology is simple.
3. Rejecting a schema change on ADR Principle 4 "ceremony" grounds. The rejection was written for the checkpoint SHA and was sound there. It was then applied by inference to the base ref, which has three programmatic readers — making it load-bearing by that same principle's own test.

### Discovery

Plan review. Reviewers asked what happens on the paths that don't go through the happy case: an ad-hoc `ship` with no session, a session predating the field, `work-review` run before any chunk committed. Every one of those questions is unanswerable unless the value has a home.

The spec's phase-2 grew from 5 tasks / 2 files to 7 tasks / 5 files as a result — the largest single reshape in the session.

## Root Cause

Ixion's pipeline stages are separate skill invocations connected only by JSON artifacts in `.ixion/plugin/sessions/<id>/`. They share no shell state, no variables, no memory. So the question "where does this value live?" has exactly two answers:

- **Recomputed independently by each consumer** — correct only if the computation is deterministic and total. `git merge-base HEAD <default>` is neither: it moves forward once the default branch advances and is merged in, which empties every diff measured against it.
- **Persisted in a session artifact** — one writer, N readers, stable across invocations and across resume.

ADR Principle 4 splits artifacts into load-bearing (strict schema) and ceremony (accept any shape). Its test is whether anything downstream reads the field *programmatically*. A value that three skills branch on is load-bearing by definition, and the ceremony exemption never applied to it.

## Solution

### Schema

```json
// ixion/schemas/session.schema.json
"base_ref": {
  "type": ["string", "null"],
  "description": "Commit this session's work is measured from. Resolved once by work Phase 1 (the branch point) and read by work Phase 3/4, work-review, and ship, which are separate invocations with no shared variable. Absent on sessions that predate checkpoint commits."
}
```

Optional, so artifacts written before the field existed still validate.

### One resolution shape, applied at every consumer

```bash
BASE_REF=$(jq -r .base_ref .ixion/plugin/sessions/<session-id>/session.json)
[ -z "$BASE_REF" ] || [ "$BASE_REF" = null ] && BASE_REF=$(git merge-base HEAD "$DEFAULT_BRANCH")
```

Read the recorded value **first**; only fall back when there is nothing recorded to trust. Reversing that order reintroduces the drift the field exists to prevent.

The guard is not optional ceremony. `jq -r` prints the four-character string `null` — not an empty string — for an absent key, so the unguarded form composes `git diff null..HEAD`:

```
fatal: ambiguous argument 'null..HEAD': unknown revision or path not in the working tree
```

Both arms are load-bearing: `= null` covers the absent field, `-z` covers an ad-hoc invocation where `jq` reads no file at all.

## Prevention

Before writing a placeholder into a pipeline skill, ask: **does any other skill invocation need the same answer?**

- **No** → an angle-bracket placeholder is right, and is safer than a variable because it cannot silently expand to empty.
- **Yes** → it is session state. Give it a schema field with one writer and explicit readers, and give every reader the same guarded resolution.

Further checks:

- When applying a recorded "this is ceremony, don't add a field" decision, confirm it was made about *this* value. A rejection written for one field does not transfer to another with different readers.
- Count the programmatic readers. Two or more is the threshold that makes something load-bearing under ADR Principle 4.
- A recomputed value must be stable across resume. If the computation can move forward while the session is in flight, recomputation is a bug even when it looks deterministic.
- Make the new field optional so pre-existing artifacts keep validating, then guard for its absence at every consumer.

## Related Issues

- `docs/adrs/0001-skill-design-as-negotiation.md` — Principle 4 (load-bearing vs ceremony), Principle 8 (one source of truth for shared text).
- `docs/solutions/mistakes/markdown-embedded-shell-fails-silently-System-20260729.md` — the `$SESSION_DIR` defect introduced while implementing this.

## Environment

- **Environment:** development
- **Repo:** Ixion plugin (`ixion/skills/`, `ixion/schemas/`)
- **Shipped in:** `ae14cdf`
