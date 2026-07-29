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

**The agent believed the skill was running asynchronously and that it would be told when to continue.** A second run made this explicit:

> Plan-review skill is running in the background. It will load the spec, dispatch reviewer agents, collect findings, and write review.findings.json. **I'll wait for the completion notification.**

Nothing was running. `ps` showed a single `claude` process at 3.2% CPU, no subagents, no pending work. A skill load is not a job launch — it puts instructions in context that the same agent must then execute. There is no completion notification, so the wait never ends.

`plan/SKILL.md` invites the misreading. It says "invoke the correct skill … using the Skill tool" six times, and line 72 reads **"After plan-review completes, invoke:"** — phrasing that describes the skill completing on its own while the agent waits for it. CLAUDE.md's "Common failure modes" section already names both the failure and its fix: prefer a plain "run X, then run Y" framing over "invoke X via the Skill tool," and state that the artifact on disk is what proves the skill ran.

Reproduced 2 of 2 runs on haiku, so it is deterministic at this step rather than a frequency problem. The wording is model-independent; a larger model may paper over it, which is worth measuring before assuming the defect is small.

This is also the failure mode ADR-001 Principle 12 was written to make detectable: the pane marker proves the skill was *invoked*, the on-disk artifact proves it *ran*, and the two can disagree.

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
| No marker + artifact **present** | Skill was compressed into inline reasoning — the agent did the work from memory of what the skill does, never loading it. Output looks plausible and may be wrong in ways only the skill's own steps would have caught. |
| No marker + artifact absent | Skill was never invoked — an orchestration bug, not a skill-body one. |

The fourth row was observed in the same run that produced the second: `work-review` wrote a schema-valid `review.findings.json` via direct `Write` calls with no `Skill(ixion:work-review)` anywhere in the scrollback. An artifact-only assertion passes it. A marker-only assertion passes the second row. Neither alone is sufficient, which is the whole reason ADR-001 Principle 12 asks for both.

### When the reported failure is not the real one

A chain test reports the first *wait* that expires, which can be stages downstream of the stall. Read the pane backwards from the failure to the last artifact that actually landed; the gap between them is where to look. Here the last good artifact was `spec.json`, so everything after plan-creation was suspect regardless of which wait timed out.

### If a fix is attempted

The wording is the target, not the model. Two changes CLAUDE.md already prescribes:

- Replace "invoke X using the Skill tool" with a plain imperative — "run plan-review, then run plan-consolidation." "Invoke" reads as dispatch; "run" reads as do.
- Delete phrasing that describes a skill *completing* on its own ("After plan-review completes, invoke:"). Nothing completes without the agent doing it, and that sentence is what licenses the wait.

Add the artifact as the success condition rather than the narration: *"`review.findings.json` on disk is what proves plan-review ran. If it is not there, the skill did not run — run it."* That gives the agent a falsifiable check on its own belief, which a status message cannot.

ADR-001's Principle 5 reframing is the same shape and has worked elsewhere here: make the artifact write a precondition of proceeding rather than a report of having finished.

Validating any of this needs several runs, not one — Principle 10 holds that coaxing changes are non-deterministic, and this session watched gate composition fire in run 1 and not run 2 from an unchanged prompt.

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
