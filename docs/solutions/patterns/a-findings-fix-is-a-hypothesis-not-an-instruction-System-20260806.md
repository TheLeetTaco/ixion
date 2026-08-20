---
module: System
date: 2026-08-06
problem_type: pattern
component: development_workflow
symptoms:
  - "A finding's Fix names the right file but the wrong cause, and applying it verbatim would add code instead of removing it"
  - "A proposed shared helper would need three switches to serve its three callers"
  - "The implementer's diagnosis contradicts the reviewer's, and the implementer is right"
root_cause: missing_workflow_step
resolution_type: workflow_improvement
severity: medium
tags: [code-review, findings, diagnosis, fix-findings, subagent-dispatch, principle-8]
---

# A finding's Fix is a hypothesis; the implementer should diagnose before applying it

## Symptom

In a fix pass over five reviewed findings, **two of four dispatched chunks rejected the Fix written into the finding** — and were right to. Both findings had correctly identified *that* something was wrong and *where*. Both had the cause wrong, and applying the proposed Fix verbatim would have made the codebase worse in the specific way the finding was complaining about.

1. **"reviewer-data-integrity omitted Severity from every finding."** The Fix said: the agent file never states the element contract, so add it, and audit the other five for the same gap. The implementer checked first and found all six agent files already pointed at a complete `finding-format.md` with a byte-identical sentence. The real cause was a *competing* four-item element list living only in that one agent file, fifty-five lines above the pointer, omitting exactly Title and Severity — which matches the observed output precisely. **The fix was deleting five lines, not adding any.** Applying the proposed Fix would have created a seventh copy of an element list, in a repo whose ADR names duplicated contract text as its worked example of drift.

2. **"The new git fixture re-types identity boilerplate that has already drifted twice."** The Fix said: move `new_repo` into `sandbox.sh`, parameterised on seed-file vs `--allow-empty`. The implementer compared the three fixtures and found they differ on four axes — location, initial branch, first commit, and extras (bare origin / integration branch / linked worktree). A shared `new_repo` needs three switches plus a return-convention decision, to save each call site one line: Config Soup traded for Stubborn Duplication. It extracted **only the identity block** — the unit that had actually drifted — and used `git log -S` to establish that the `"Ixion Test"` / `"Ixion Harness"` split was accidental rather than assuming it.

## Investigation

### Attempted (Failed)

Dispatching a fix chunk with the finding's Fix as the instruction. This is the natural reading of the fix-findings contract — the finding says what to do, the subagent does it — and it is how a patch-pile-on happens. The two findings above would have produced a duplicated contract and an over-parameterised helper, each of which is a *new* finding for the next review round.

### Discovery

Both correct diagnoses came from dispatches that explicitly told the subagent the Fix was a proposal and named what would make it wrong:

> That fix is my proposal, not a spec. Weigh it yourself: … If the shared thing has to grow flags to serve three callers with different needs, that is Config Soup and the duplication may be the lesser evil — say so and stop, with reasons.

> The obvious move is to paste the element list into six files. Consider whether that is the right one before doing it: … **Check whether that is actually true of all six agent files.** … Diagnose first. Report what you found across all six files before saying what you changed.

The pattern is not "subagents are smarter than reviewers." It is that the reviewer had `Read, Grep, Glob` and one domain lens over a diff, while the implementer reads the whole file, its siblings, and its history. The implementer is simply better positioned to find the cause — but only takes the trouble if the dispatch makes clear that finding a different cause is a success, not a deviation.

## Root Cause

The finding contract already says this and it was not reaching the implementer. `ixion/skills/ixion-conventions/references/finding-format.md` defines the Fix slot as:

> **Fix** — a concrete proposed change. The Failure paragraph is binding; the Fix is your best guess — the implementer may find a more elegant resolution.

The **Failure** is the finding's load-bearing claim; the **Fix** is a guess by the party with the least context. Dispatching the Fix as an instruction inverts that, and nothing in the default dispatch template restated the distinction where the implementer would read it.

## Solution

Carry the Failure/Fix asymmetry into the dispatch itself. Three things made it work:

1. **Say the Fix is a proposal, in those words.** "That fix is my proposal, not a spec. Weigh it yourself."
2. **Name the failure mode of your own proposal.** Give the implementer the specific anti-pattern your Fix would produce if the diagnosis is wrong — "if the shared thing needs three switches, that is Config Soup and the duplication is the lesser evil." A generic "use your judgment" does not survive contact with a concrete instruction.
3. **Require the diagnosis before the change.** "Report what you found across all six files before saying what you changed." This makes a contradicting diagnosis a deliverable rather than an act of insubordination.

And accept the outcome when it comes back: both chunks returned `outcomes` explaining why they had not done what was asked. That is the mechanism working.

## Amendment (2026-08-20, session `ship-auto-merge`): the Failure's *reason* is checkable too

A third instance, and it moves the line. This pattern says the Failure is binding and the Fix is a guess. That is right about the *conclusion* — but a Failure paragraph carries a conclusion **and the reason offered for it**, and the reason can be false while the conclusion holds.

A P3 said the CHANGELOG's 4.2.0 entry sat under `## Unreleased` while the manifests bumped, and gave as its reason that "the 4.0.0 and 4.1.0 entries share the same heading and would have to move together." There are no such entries: `git show --stat 7180f37 1b2a054` shows both release commits touched `CHANGELOG.md` not at all. The synthesizer propagated the false premise into the dispatch prompt verbatim. The subagent checked git history, contradicted both the finding and the prompt, and was right — and the conclusion survived for a *stronger* reason than the one given: cutting the block requires first authoring two missing entries from history, which is harder than a retitle, not easier.

What this adds:

- **Verify the reason, not just the conclusion.** A fix pass that inherits a Failure's supporting facts inherits its errors. The reason is usually one command away — this one was a `git show --stat`.
- **The orchestrator is a propagation path.** Composing a dispatch from a finding means re-asserting its premises in your own voice, where they read as instructions rather than as claims. That is a second place for a wrong reason to harden.
- **Invite the contradiction explicitly, about the premises.** The dispatch that caught this carried: *"If your reading of the history contradicts my instruction here … do the correct thing instead and say so in `outcomes`."* Without that sentence the subagent had a direct instruction and a plausible reason to follow it.

Same mechanism as the two original cases, one layer up: the party with more context finds the real cause, but only takes the trouble when contradicting is framed as a deliverable.

## Prevention

- Dispatch the **Failure**, not the Fix. The Fix rides along as context.
- Check the Failure's stated reason before repeating it in a dispatch — and tell the subagent it may contradict your premises, not just your proposed fix.
- Before writing a Fix into a finding, ask what it would cost if the cause is something else. If the answer is "adds a duplicate" or "adds a parameter," say so in the finding.
- Treat a subagent's contradicting diagnosis as signal. Two for two here; both survived independent verification.
- When a finding's Fix says "add X to N files," check first whether N files already have a pointer to one X. In this repo that is usually the case, and adding is usually wrong.

## Related Issues

- `docs/solutions/mistakes/dedup-change-spawns-new-duplicates-System-20260804.md` — what applying a duplication Fix without diagnosing produces.
- `ixion/skills/ixion-conventions/references/finding-format.md` — the Failure-binding / Fix-is-a-guess definition this pattern operationalises.
- `docs/adrs/0001-skill-design-as-negotiation.md` Principle 8 — one source of truth for shared text.

## Environment

- **Environment:** development
