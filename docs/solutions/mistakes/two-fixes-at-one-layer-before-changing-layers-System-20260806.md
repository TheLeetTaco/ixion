---
module: System
date: 2026-08-06
problem_type: mistake
component: development_workflow
symptoms:
  - "A reviewer contract defect survives two consecutive fixes and reappears as P1 in the next review round"
  - "Three of six reviewers omit a required finding element; the three that comply are not the three the fix targeted"
  - "Each fix reworded the same shared dispatch text, which every reviewer already received verbatim"
root_cause: missing_workflow_step
resolution_type: workflow_improvement
severity: medium
tags: [coaxing, principle-1, reviewer-contract, severity, skill-authoring, agent-files, diagnosis]
---

# Two fixes at the same layer, when the layer was never the variable

## Symptom

`finding-format.md` lists Severity as one of five required elements, and the synthesizer needs it to rank and route. Across three consecutive review rounds, reviewers kept returning findings with no `P1`/`P2`/`P3` label:

| Round | Fix applied before it | Reviewers omitting Severity |
|---|---|---|
| 1 | (the original contract) | documented in `reviewer-dispatch.md:35`, a different cause |
| 2 | wording change to shared dispatch text | 1 of 6 |
| 3 | commit `69fae43` added a preamble naming all five elements at the last point a reviewer reads | **3 of 6** |

The round-3 preamble was specific and well-placed — *"Every finding you return carries all five of Title, Severity, Location, Failure and Fix ... Severity is a literal P1, P2 or P3"* — and it made things measurably worse, not better. `reviewer-elegance` (2 findings), `reviewer-performance` (2) and `reviewer-data-integrity` (3) returned prose with no label on any finding.

The downstream cost is quiet and total: every severity published for those three reviewers was assigned by the synthesizer. Ranking on 7 of 12 real findings was one agent's judgement wearing six agents' authority.

## Investigation

### Attempted (Failed)

1. **Rewording the shared dispatch text.** Twice. Both times the reasoning was sound and the placement was better than the last. Neither moved the three failing reviewers.
2. **Suspecting the citation had drifted between agent files.** It had not — the citation is byte-identical across all six `ixion/agents/reviewer-*.md`, and the preamble reached every reviewer verbatim in the same position. Both candidate explanations at the shared layer were eliminated by inspection.

### Discovery

Comparing the three that complied against the three that failed, rather than re-reading the text all six received. `reviewer-code-quality.md:36-43` carries its own severity rubric in its own domain terms (*"Flag as P1 if: New code with zero tests"*). `reviewer-elegance.md` contained no occurrence of `P1`, `P2`, `P3` or `severity` anywhere in the file.

The variable was never the dispatch text. It was whether the reviewer's **own domain rules** already spoke in P-labels.

## Root Cause

Shared dispatch text is *identical by construction*, so it cannot explain a split outcome. Two fixes were spent varying the one input that was provably constant across the compliant and non-compliant groups alike.

Underneath that: a label applied after the fact is a second task, and the agent is done reasoning by the time it reads the instruction to add one. An agent whose domain rules are written in P-labels forms the severity *while forming the finding* — one task, not two. The compliant reviewer wasn't obeying the contract harder; it was never doing the extra step.

## Solution

Move the fix to the layer that actually varies. Each of the three failing agent files gained a rubric on an axis it already reasons along — deliberately **not** one gloss pasted three times, which would be Stubborn Duplication and would belong back in the shared file that had already failed twice:

```markdown
<!-- ixion/agents/reviewer-elegance.md:131 -->
## Severity By Blast Radius Of The Shape
- **P1** — the shape itself is wrong and everything built on it inherits the flaw...
- **P2** — the inelegance is contained to what you're looking at...

<!-- ixion/agents/reviewer-performance.md:52 -->
## Severity By The Scale That Breaks It
- **P1** — degrades at the volume the code sees today or at 10x...

<!-- ixion/agents/reviewer-data-integrity.md:111 -->
## Severity By Recoverability
- **P1** — data ends up lost or silently wrong with no way to reconstruct it...
```

Each reuses a question the agent already asks: performance already projects to 10x/100x; data-integrity already asks "what breaks if this fails halfway through". No two rubrics share a sentence, which is the test that they are domain rules rather than a copied gloss.

`reviewer-performance.md:50`'s existing *"Prioritize by impact."* was deleted — the rubric **is** the prioritization by impact, and keeping both would be two rankings for one decision.

## Prevention

- **When a fix at one layer fails twice, stop rewording and go find what differs between the cases that pass and the cases that fail.** Two failed attempts is the signal that the layer is wrong, not that the wording is.
- **Text every agent receives identically cannot explain a split outcome.** If 3 of 6 comply, the cause is in the 3 files that differ, not in the file they share. This is diagnosable by inspection before spending a fix.
- **Prefer making the right output a by-product of work the agent already does** over instructing it to add a step afterward. A label formed with the finding survives; a label requested after it does not.
- ADR-001 Principle 1 puts structural enforcement behind coaxing that has *demonstrably* failed across multiple runs. That bar is now met for this channel specifically — but the rubric is a coaxing attempt that had never been tried, so it goes first. A synthesizer-side reject-and-redispatch gate is the justified next step **only if the rubric also fails**, not a fourth wording change.
- Record which fix was tried at which layer. Two of these three attempts were plausible precisely because the previous one's failure had not been written down as *"the shared layer was already ruled out."*

## Related Issues

- `docs/solutions/patterns/a-findings-fix-is-a-hypothesis-not-an-instruction-System-20260806.md` — the same discipline one level down: a reviewer's proposed fix is a hypothesis about a symptom, and diagnosing before applying is what separates the two.
- `docs/solutions/mistakes/verified-a-proxy-instead-of-the-outcome-System-20260804.md` — the sibling failure: rounds 2 and 3 each verified that the text *said* the right thing, never that a reviewer's output *carried* a label.
- `docs/adrs/0001-skill-design-as-negotiation.md` — Principle 1 (coax, don't block) and Principle 10 (coaxing is non-deterministic). This is the evidentiary bar for escalation being reached in a real channel.

## Environment

- **Environment:** development
- **Repo:** Ixion plugin (`ixion/agents/`, `ixion/skills/ixion-conventions/references/`)
- **Shipped in:** branch `question-why-you-slot`, merged to `main` at `73658cb`
