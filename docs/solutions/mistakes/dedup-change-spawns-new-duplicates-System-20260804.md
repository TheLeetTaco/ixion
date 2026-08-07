---
module: System
date: 2026-08-04
problem_type: mistake
component: development_workflow
symptoms:
  - "A change that consolidates duplicated text introduces fresh duplicates of its own"
  - "Two callers carry the same explanatory sentence, already differing by punctuation"
  - "Two test files implement the same four-command recipe with different flags"
root_cause: missing_workflow_step
resolution_type: workflow_improvement
severity: medium
tags: [dry, principle-8, duplication, drift, code-review, skill-authoring]
---

# A de-duplication change spawns new duplicates while you are looking at the old ones

## Symptom

Session `branch-prod-dev-resolution` existed to fix Stubborn Duplication: one `refs/remotes/origin/HEAD` lookup inlined at four sites (`work` once, `work-review` once, `ship` twice) that had already split into two incompatible micro-variants — a named `DEFAULT_BRANCH` variable in one, an inlined subshell in the others, each trailing its own near-duplicate paragraph. The change extracted the mechanism into `ixion/skills/ixion-conventions/references/git-branches.md` and cut the count to one.

Review of that same change then found two *new* duplications, both created by it:

1. **A duplicated explanatory sentence.** `ship/SKILL.md` and `work-review/SKILL.md` each grew a sentence explaining that the printed `integration=` value is what carries across a process boundary. The two copies already differed — a semicolon in one, an em dash in the other, plus a trailing clause present only in `ship`. Both files load in full on every invocation of their skill.

2. **A duplicated git recipe.** `tests/integration/lib/sandbox.sh` and `tests/branch-resolution-harness.sh` both implemented `git init --bare` → `remote add origin` → `push --all` → `remote set-head`. They too had already diverged: subshell `cd` in one versus `git -C` in the other, and only the harness pinned `core.autocrlf`.

Both were introduced inside a single session, by different subagents, in a change whose entire stated purpose was removing duplication. Neither implementer flagged either one; both were caught by review.

## Investigation

### Attempted (Failed)

1. Trusting the change's own rationale as a safeguard. Every dispatch carried the ADR Principle 8 reasoning and the observed four-sites/two-variants evidence verbatim. It did not stop the implementer creating a fifth and sixth copy of different things.
2. Relying on the per-chunk diff self-check. Its question is "is the same value stored in two places?", which each implementer answered honestly and correctly *for its own chunk*. Both new duplications spanned two files owned by two different chunks, so neither implementer could see both halves.

### Discovery

Whole-session review, reading across chunk boundaries. `reviewer-performance` found the sentence pair by comparing `ship` against `work-review`; `reviewer-patterns` found the recipe pair by comparing the harness against `sandbox.sh`. Both are comparisons no chunk-scoped reviewer or self-check is positioned to make.

## Root Cause

Two compounding causes.

**Attention is spent on the duplication being removed.** The implementer holds the old duplicate in mind as the thing to delete, and writing a fresh explanation beside the new canonical home does not feel like duplicating — it feels like explaining. The sentence in `ship` is genuinely useful prose; so is the one in `work-review`. Neither reads as a copy until you put them side by side.

**Chunk-scoped self-checks cannot see cross-chunk duplication by construction.** The elegance self-check asks each implementer about *its own diff*. A duplication whose two halves live in two chunks is invisible to both, and each answers "one source of truth" truthfully. The same applies to the wave structure: `2.0a` makes wave members file-disjoint precisely so they cannot collide, which also guarantees neither can see the other's text.

Note the shape: the duplicates had *already drifted* by the time review found them, within one session. Drift is not slow. Two copies written hours apart by two agents differ immediately.

## Solution

There is no code fix — the fix is where you look.

### For the orchestrator

`work` Phase 4's cumulative self-check is the right place, and its existing question is too narrow. It asks:

```
Is the same value stored in two places (parallel state introduced across phases)?
```

"Value" reads as data. Read it as text too, and specifically compare *sibling callers of the thing you just extracted*:

```bash
# after any extraction, diff the callers against each other, not just against the reference
git diff "$BASE_REF"..HEAD -- <caller-a> <caller-b> | grep '^+' | sort | uniq -d
```

### For the dispatch

When a chunk's stated purpose is de-duplication, name the risk in the dispatch itself. The dispatches in this session carried the Principle 8 rationale but never said "and do not create new duplicates while you are at it."

## Prevention

- After extracting shared text, diff the *callers against each other*. The canonical home is not where the next duplicate appears — the callers are.
- Treat "explanatory prose added beside a citation" as duplication-prone. If two callers need the same explanation, it belongs in the thing they cite.
- Do not rely on per-chunk self-checks for cross-chunk duplication. They are structurally blind to it, and file-disjoint waves guarantee that blindness.
- When a shared recipe is reimplemented for dependency reasons (as the offline harness reimplemented the sandbox's bare-origin setup), that can be the right call — but record the reasoning in a comment, or the next reader re-derives it or "fixes" it wrongly.
- Expect drift to be immediate, not gradual. Two copies written in the same session already differed in punctuation and flags.

## Recurrence — 2026-08-06, same file pair, one copy later

Session `resume-command-in-handoff` hit this a third time, in the *same two files* item 2 above names. The harness that session added needed a throwaway git repo, and re-typed the identity block (`user.email`, `user.name`, `commit.gpgsign`) inline rather than reusing `branch-resolution-harness.sh`'s `new_repo` — which is itself a copy of `sandbox.sh`'s `make_sandbox`. Three copies, and they had already drifted exactly as this entry predicts: `sandbox.sh` said `"Ixion Test"` where both harnesses said `"Ixion Harness"`, and the newest copy silently dropped the `core.autocrlf false` its sibling carries.

Two things this recurrence teaches that the original entry did not:

- **The prevention above did not fire, because the new harness followed this file's own precedent for structure and not for sharing.** Its header comment says it "follows `tests/branch-resolution-harness.sh`" — and the branch harness carries a comment justifying *selective reuse* of `sandbox.sh`. The author copied the shape and skipped the sentence explaining it. A comment recording why sharing was chosen is weaker than the sharing itself being the obvious path.
- **The right unit to extract was smaller than the obvious one.** The review finding proposed moving `new_repo` wholesale into `sandbox.sh`. The implementer showed the three fixtures differ on location, initial branch, first commit and extras, so a shared `new_repo` needs three switches — Config Soup traded for duplication. Only the identity block had actually drifted, so only the identity block was extracted, as `fixture_git_config <repo>` with three callers. **Extract the unit that drifted, not the unit that looks shared.**

## Recurrence — 2026-08-06, drifting from the template the same commit was writing

Session `question-why-you-slot` is the fourth instance and the sharpest, because the change *was* the de-duplication: it replaced ~25 independently-authored question sites across nine skills and seven reference templates with one canonical shape in `ixion/skills/ixion-conventions/references/question-format.md`. Review of that change found two fresh duplicates it had created:

1. **A second approximation of the template being created.** `compound/SKILL.md:185-191` kept a free-form em-dash bullet list — no `Question:` label, no `Options:` header, no numbering — while carrying the *new* `**Why you:**` line and the *new* delegation option. The same commit converted the file's three other questions to the fenced block. So it was not a missed leftover; it was a freshly-authored rival shape, written in the commit whose stated purpose was ending rival shapes. Three reviewers flagged it independently.
2. **The canonical rule restated beside its own citation.** `compound/SKILL.md:29` cites `question-format.md`, which states the one-question-per-call rule at its line 5. Line 86 then restated it anyway — *"one question per call, in this order, each carrying its own reason"* — duplicating both that rule and the Why-you requirement the same citation introduces. Caught only by `work` Phase 4's whole-session check; a repo-wide grep then confirmed it was the last such restatement outside the reference.

What this recurrence adds to the entry above:

- **The canonical home existing does not stop the next copy — it changes what the copy looks like.** The earlier instances duplicated *text that had no home yet*. Here the home was being built in the same commit, and the duplicate still appeared, wearing the new home's own vocabulary (`**Why you:**`, the delegation option). A partially-adopted template reads as compliance and passes a skim; item 1 was three reviewers' work to catch.
- **"Did every site adopt the shape?" is a different question from "does every site cite the reference?"** The session's Phase 3 verification checked that every reason came from the four-entry catalog and that no file stated the catalog inline. Both passed while item 1 sat there, because neither asks whether the *rendering* matches. The check that would have caught it is comparing sibling sites in one file against each other — the same "diff the callers against each other" prevention this entry already prescribes, applied to shape rather than to text.
- ADR-001's Principle 14 paragraph records `brainstorm/SKILL.md` having restated the one-question-per-call rule in three separate places before extraction. Item 2 is that same rule, restated a fourth time, *after* extraction — so the extraction did not end it either.

## Related Issues

- `docs/solutions/mistakes/two-fixes-at-one-layer-before-changing-layers-System-20260806.md` — from the same session: the other half of what review caught, where two fixes at a shared layer failed because the shared layer could not explain a split outcome.
- `docs/solutions/patterns/a-findings-fix-is-a-hypothesis-not-an-instruction-System-20260806.md` — the recurrence above is one of its two worked examples.
- `docs/adrs/0001-skill-design-as-negotiation.md` — Principle 8 (one source of truth for shared text). This session supplied its evidence and then violated it twice.
- `docs/solutions/mistakes/copied-wiring-pattern-without-its-consumer-System-20260729.md` — the sibling habit: reproducing a pattern by resemblance rather than by checking what consumes it.
- `docs/solutions/mistakes/verified-a-proxy-instead-of-the-outcome-System-20260804.md` — the verification failure from the same session.

## Environment

- **Environment:** development
- **Repo:** Ixion plugin (`ixion/skills/`, `tests/`)
- **Shipped in:** branch `branch-prod-dev-resolution`
