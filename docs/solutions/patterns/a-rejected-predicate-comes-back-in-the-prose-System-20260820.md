---
module: System
date: 2026-08-20
problem_type: pattern
component: development_workflow
symptoms:
  - "A design correctly refuses to assert what it cannot know, then asserts it in the message built from that data"
  - "The same anti-pattern name is rejected twice at plan review and found a third time at code review"
  - "A confirmation names a specific cause for a state the tool explicitly cannot attribute"
  - "Data model and user-facing copy disagree about how much is known"
root_cause: missing_validation
resolution_type: workflow_improvement
severity: high
tags: [code-review, half-truth-predicate, plan-review, user-facing-copy, irreversible, anti-patterns]
---

# Rejecting a Half-Truth Predicate in the data does not stop it reappearing in the prose

## The pattern

When a design's whole point is *refusing to claim more than it established*, the refusal has to hold at every layer that speaks to the user — not just in the variable that holds the value. The layer that gets missed is the message assembled from that variable, and it is the worst one to miss, because the message is what a human reads before authorizing something irreversible.

## The instance

Teaching `ship` to arm GitHub auto-merge required knowing whether arming would defer or merge instantly. Plan review killed two designs by name, both **Half-Truth Predicate**:

1. *Probe only `allow_auto_merge`.* The flag answers whether arming is **permitted**, not whether it will **defer**. With the setting on and nothing gating the PR, arming merges instantly.
2. *Probe `statusCheckRollup` or `reviewDecision`.* Each answers one half of the gate; a PR can be blocked by the other half while that half reads clean.

The shipped design got the data right. `gates=` carries the raw `mergeStateStatus` and nothing more, precisely because cli/cli#10775 says `gh` cannot expose *which* requirement blocks a `BLOCKED` PR. The skill even says so inline.

Then the confirmation line, one layer up, read:

> "The PR is `BLOCKED`, so arming it squashes and merges it unattended the moment that clears — and an approval you cannot give your own PR never clears"

That is the same Half-Truth Predicate, third instance. The clause is **flatly false for `BEHIND`** — which the ladder also maps to `deferred`, and which clears by updating the branch, not by any approval — and **unknowable for `BLOCKED`**, since the block may be a required check that will pass on its own. Two reviewers (`reviewer-code-quality`, `reviewer-data-integrity`) found it independently and named the same principle.

## Why the prose is where it survives

The data-level rejections happened at plan review, where the question on the table was *which field to read*. That framing makes the predicate visible: you are choosing a source, and "does this source answer the whole question" is the obvious challenge.

The message is written later, usually while implementing, and it is not experienced as choosing a predicate at all — it is experienced as *wording*. Nobody re-asks "how much does this sentence claim to know" about a sentence they are writing to be helpful. The helpfulness is the trap: naming a specific cause is more useful than naming a state, so the copy drifts toward the specific, and specificity is exactly the thing the data layer refused.

The asymmetry that makes it expensive: the data layer's over-claim would have produced a wrong `automerge=` value and a wrong branch. The prose layer's over-claim produces a *correct* action described by a *false* reason, which no test catches and which the user cannot check.

## The discipline

When a design records "we cannot know X" as a decision, grep for X in the copy before shipping:

- List every state the coarse value can hold. The bug lives in the state you did *not* have in mind when writing the sentence — here, `BEHIND`, while thinking about `BLOCKED`.
- A message built from a bucket may only assert what is true of **every member** of that bucket. One outcome line covering two states must be true of both, or it must split.
- Prefer the honest hedge to the split when the tool cannot attribute the cause anyway. The fix here was not per-state wording; it was saying `gh` cannot say what would clear it, *including* an approval you cannot give your own PR — true for both states, and it still lets a solo-repo user recognise the deadlock.

## Prevention

- Treat "this value is deliberately coarse" as a claim about the **copy**, not just the variable. Write it next to the message, not only next to the assignment.
- When plan review rejects a predicate for answering half a question, add a success criterion about what the user is *told*, not only about what is *read*. This spec had "no message asserts a repository setting the probe did not read" and it held — the gap was that no criterion covered asserting a *cause* the tool cannot attribute.
- At review time, read the user-facing strings against the enum they are selected by. A one-line outcome table covering a two-member bucket is the shape to distrust.
- An `Irreversible` confirmation deserves a specific pass of its own: it is the one message whose inaccuracy the user cannot recover from.

## Related Issues

- `docs/adrs/0001-skill-design-as-negotiation.md` — the auto-merge amendment records all three rejections and the final wording.
- `ixion/skills/ixion-conventions/references/question-format.md` — the Irreversible reason and why it is exempt from the ask-gate.
- `docs/solutions/patterns/a-findings-fix-is-a-hypothesis-not-an-instruction-System-20260806.md` — the sibling discipline for the layer below: what to do once a reviewer has named the failure.

## Environment

- **Environment:** development
- **Repo:** Ixion plugin (`ixion/skills/ship/`)
- **Shipped in:** PR #3, session `ship-auto-merge-2026-08-20`
