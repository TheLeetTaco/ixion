---
module: System
date: 2026-08-20
problem_type: pattern
component: documentation
symptoms:
  - "An ADR describes behavior a later chunk in the same session changed"
  - "A CHANGELOG entry documents the pre-fix design of the feature it announces"
  - "Reviewers pass a diff clean and the design record is wrong anyway"
  - "A doc claims a block is untestable after the same session made it testable"
root_cause: missing_workflow_step
resolution_type: workflow_improvement
severity: medium
tags: [adr, changelog, fix-findings, cumulative-diff, self-check, cross-phase-drift]
---

# A fix pass falsifies the design record its own session wrote

## The pattern

When one session both **writes the design record** and later **runs a fix pass**, the record is a standing candidate for staleness — and no reviewer can catch it, because the drift did not exist when they ran. The cumulative-diff self-check is the only gate positioned to see it.

## The instance

Session `ship-auto-merge-2026-08-20` ran the full pipeline. Phase 3 wrote an ADR amendment and a CHANGELOG entry describing the auto-merge design. `work-review` then reviewed the diff and found six findings; the fix pass changed behavior in ways the amendment had already committed to prose. Three statements became false:

| Location | Said | Became true |
|---|---|---|
| ADR `:285` | the unread-setting rung "resolves to `unknown` **carrying the raw state**" | it carries an **empty** `gates=` — and that emptiness *is* the invariant the fix installed |
| ADR `:303` | "`gh api` and `gh pr merge --auto` are not faked either … a stub would test the stub" | both are now exercised through a `PATH`-shadowed `gh` |
| ADR `:303` | "the two probes that feed it and the one command that spends it are **not** [covered]" | all three are covered |

The CHANGELOG entry had the same shape: it described `unknown` as reporting "the raw state" (now only half true) and did not mention the drift guard at all.

Every reviewer had passed the diff. They were not wrong — at review time the ADR was accurate. It is the *fix* that made it false, and the fix happens after review by construction.

## Why the self-check is the right gate

`work` Phase 4 asks four questions of the whole-session diff, including:

> Did phase N add a wrapper, helper, or abstraction that a later phase made unnecessary?

That question generalises, and the general form is the one that catches this:

> **Did a later phase falsify what an earlier phase wrote down?**

The original wording looks for *code* a later phase orphaned. The same relationship holds for *claims*: phase 3 asserted something true of phase 1's code, the fix pass changed phase 1's code, and the assertion is now orphaned in exactly the way an unused helper is — still present, no longer earning its place, and actively misleading rather than merely dead.

In this session the check fired on both readings at once. The literal reading found the two probe-bypass placeholders phase 1 added and the fix pass deleted. The general reading found the three sentences documenting them.

## The discipline

When a session's file list includes both an implementation file and a design record (`docs/adrs/`, `CHANGELOG.md`, a README section):

- After any fix pass, diff the record against the implementation, not against the findings. The findings describe what was wrong; the record describes what *was*, and only the code says what *is*.
- Grep the record for the specific vocabulary the fix changed. Here, `carrying the raw state`, `not faked`, `unexercised` — each was one `grep -n` away.
- Fix the record **coherently**, not by appending a correction. A "note: this changed" paragraph beneath a wrong sentence leaves both standing, and the next reader has to adjudicate. Edit the wrong sentences so the amendment reads as one account by someone who knew the whole story.
- Watch for the numbers. A measured figure quoted in prose (`Phase 4 grew 3,986 bytes`) is falsified by any later edit to the thing measured; this one became 3,970.

## Prevention

- Treat "this session wrote the ADR *and* ran a fix pass" as an automatic polish-chunk trigger. It is cheap to check and invisible if skipped.
- Put the record's files in a separate theme from the code's, so the polish chunk can read the finished code rather than racing it.
- Give that chunk the *implementation* as the source of truth and tell it explicitly not to edit the implementation — its job is to make the record true, not to re-litigate the fix.
- Do not rely on review for this class. Reviewers see a snapshot; this defect is created after the snapshot by definition.

## Related Issues

- `ixion/skills/work/SKILL.md` Phase 4 — the cumulative-diff self-check and its four questions.
- `docs/adrs/0001-skill-design-as-negotiation.md` — the amendment that was corrected, and Principle 8 on one source of truth.

## Environment

- **Environment:** development
- **Repo:** Ixion plugin
- **Shipped in:** PR #3, session `ship-auto-merge-2026-08-20`
