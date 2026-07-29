---
module: System
date: 2026-07-29
problem_type: mistake
component: testing_framework
symptoms:
  - "Skill(<name>) appears in the pane but the skill's artifact never lands on disk"
  - "Agent announces the work a skill would do, then ends its turn without doing it"
  - "Downstream step times out waiting for an artifact nobody wrote"
root_cause: missing_workflow_step
resolution_type: workflow_improvement
severity: medium
tags: [skills, silent-stop, pane-markers, artifacts, adr-001, integration-tests]
---

# A skill that loaded, announced itself, and then stopped

## Symptom

Observed live in `07-chain-smoke` on `claude-haiku-4-5-20251001`. The pane showed a clean load:

```
● Skill(ixion:plan-review)
  ⎿  Successfully loaded skill · 8 tools allowed
● Launching plan-review with your spec. This will run six reviewers in parallel to check the
  design for architecture, code quality, patterns, performance, data integrity, and elegance.
  Collecting their findings now...
✻ Baked for 1m 2s
```

Then the turn ended. Empty prompt, no spinner, `claude` sitting at 2.2% CPU eight minutes later. No reviewer was ever dispatched, and the session directory held `session.json` and `spec.json` only — no `review.findings.json`. The chain failed fifteen minutes later at the consolidation wait, naming a step three stages downstream of where it actually broke.

## Investigation

### Attempted (Failed)

1. Reading the failure message. `FAIL: consolidation did not complete in 15min` points at plan-consolidation, which never ran and was never at fault. The reported failure and the real one were separated by two stages.
2. Treating the idle prompt as a deadlock. CLAUDE.md's deadlock signature is an `AskUserQuestion` dialog stuck visible; there was none. The monitor's stall detector fired instead, which is the right signal but says nothing about cause.

### Discovery

Two checks, together:

```bash
# is the process working, or idle?
docker exec "$cid" ps -o pid,etime,pcpu,comm -C claude
#   PID  ELAPSED  %CPU COMMAND
#   229    08:24   2.2 claude          <- idle, not thinking

# did the skill leave its artifact?
ls "$SDIR"      # session.json, spec.json — no review.findings.json
```

Low CPU plus a present pane marker plus a missing artifact is the signature. Any one alone is ambiguous.

## Root Cause

The agent loaded the skill, narrated what the skill would do, and treated the narration as the doing. This is the failure mode ADR-001 Principle 12 was written to make detectable: the pane marker proves the skill was *invoked*, the on-disk artifact proves it *ran*, and the two can disagree.

The disagreement is the whole point of asserting on both. A test checking only `Skill(<name>)` markers scores this as a pass. A test checking only artifacts cannot tell "invoked but didn't execute" from "never invoked at all" — and those have different fixes: the first is a skill-body problem, the second an orchestration one.

Smaller models appear likelier to stop at a phase boundary this way. This was observed on haiku, which `07` uses deliberately for cost, so the frequency on larger models is unmeasured.

## Solution

No fix applied — this is a live finding recorded for the next person to hit it, and the diagnostic is the durable part.

### Diagnosing it in under a minute

| Signal | Reading |
|---|---|
| `Skill(<name>)` in pane + artifact present | Skill ran. Fine. |
| `Skill(<name>)` in pane + artifact absent + low CPU | **This failure.** Invoked, narrated, stopped. |
| `Skill(<name>)` in pane + artifact absent + high CPU | Still working. Wait. |
| No marker + artifact absent | Skill was never invoked — an orchestration bug, not a skill-body one. |

### When the reported failure is not the real one

A chain test reports the first *wait* that expires, which can be stages downstream of the stall. Read the pane backwards from the failure to the last artifact that actually landed; the gap between them is where to look. Here the last good artifact was `spec.json`, so everything after plan-creation was suspect regardless of which wait timed out.

### If a fix is attempted

ADR-001's levers apply: the skill's own enumeration of remaining steps needs to be concrete enough that "I have described the work" cannot be mistaken for "I have done it." Principle 5's reframing — make the artifact write a precondition of starting rather than a report of finishing — is the shape that has worked elsewhere in this repo for exactly this symptom.

## Prevention

- Assert on both signals, always. `tests/integration/lib/tmux.sh::pane_has_skill_invocation` covers the marker; the artifact check is per-case and must not be dropped as redundant.
- When a chain step times out, do not trust the step name in the failure. Find the last artifact on disk and start there.
- Check CPU before concluding an agent is stuck. Idle and busy look identical in a pane.
- Preserve pane scrollback. Without it none of the above is possible after the run — see `tests/integration/docker-run.sh`, which copies pane files and the sandbox out before the container is discarded.

## Related Issues

- `docs/solutions/mistakes/verification-gate-passes-on-unmodified-tree-System-20260729.md` — the same session's other lesson: assertions that look right and prove nothing. A marker-only assertion here would have been exactly that.

## Environment

- **Environment:** development, `tests/integration/cases/07-chain-smoke.test.sh` in the Docker harness
- **Model:** `claude-haiku-4-5-20251001`; Claude Code 2.1.220
- **Not reproduced on a larger model** — worth establishing before treating the frequency as representative.
