---
module: System
date: 2026-08-04
problem_type: mistake
component: development_workflow
symptoms:
  - "A finding is reported unfixed although it was fixed by a different means"
  - "A grep for one specific implementation returns zero and is read as 'not done'"
  - "A proposed security guard is trusted without being run against the hostile input"
root_cause: missing_validation
resolution_type: workflow_improvement
severity: high
tags: [verification, false-negative, code-review, security, git, evidence]
---

# Checking for the fix you imagined instead of the outcome you wanted

## Symptom

Two failures in one session, the same shape from opposite directions.

**False negative on a completed fix.** Two subagents were killed mid-run by an API session limit, leaving partial work in the tree and no `files_modified` report. The orchestrator reconstructed what had landed by grepping, and reported two of six findings as not done:

```bash
grep -qn 'check-ref-format' ixion/skills/ixion-conventions/references/git-branches.md   # -> no match, reported "NOT DONE"
grep -n '^5\.\|^6\.\|^7\.' ixion/skills/work/SKILL.md                                   # -> step 5 still spans 96-147, reported "NOT DONE"
```

Both were wrong. The finding proposing `check-ref-format` had been resolved by **single-quoting the splice points** instead. The step-5 restructure had been done **in place as sub-cases**, without renumbering — which is what the orchestrator had itself requested as the lower-risk shape. The follow-up agent found both already complete by reading the files.

**False confidence in a proposed guard.** A reviewer proposed `git check-ref-format --branch` to stop branch-name injection through spliced placeholders. Run against the actual hostile input:

```
$ git check-ref-format --branch "dev';id;'" && echo LEGAL
LEGAL
$ git branch "dev';id;'"     # creates fine — no spaces, so git accepts it
```

The proposed guard **accepts** the string that breaks out of single quotes. It would have closed nothing while reading as a fix.

## Investigation

### Attempted (Failed)

1. Grepping for a distinctive token of the expected fix. This is fast and usually right, which is what makes it dangerous — it silently encodes an assumption about *how* the fix would be written.
2. Reading the reviewer's severity and reasoning as sufficient warrant for its proposed remedy. The reasoning about the injection vector was sound; the remedy attached to it was not, and the two travel together in a finding.

### Discovery

For the false negative: a fresh agent instructed to "verify by reading, then leave alone" read the files and reported both already complete.

For the guard: running `git check-ref-format --branch` against three candidate names in a throwaway repo. The matrix is what settled it — space-containing names like `dev$(touch /tmp/x)` are rejected by git and were never a vector; backtick names like `` dev`id` `` are legal and *are* neutralized by single quotes; quote-containing names like `dev';id;'` are legal, are **not** neutralized, and pass `check-ref-format`.

## Root Cause

Both are the same error: **verifying a proxy for the outcome rather than the outcome.**

A grep for `check-ref-format` asks "was the fix I pictured applied?" The question that mattered was "is a spliced branch name safe?" Those coincide only when there is one way to fix it. Here there were three (validate, quote, or carry values in a file), and the implementer picked a different one than the reviewer proposed — a *better* one, as it turned out.

The guard failure is the same substitution one level up. `check-ref-format` is a proxy for "is this branch name safe to splice", and it is the wrong proxy: it validates *git ref syntax*, which permits `'`, `` ` `` and `$` — only spaces and a short list of sequences are forbidden. Shell safety and ref-name validity are different predicates that look adjacent.

This repo has recorded the same class three times already, under `verification-gate-passes-on-unmodified-tree`: leg (c) of the three-way gate check — "does every writer to that artifact actually produce the token?" — is the one that keeps getting skipped, and it is the leg about the outcome rather than the assertion.

## Solution

### Check the outcome, and enumerate the ways it could have been reached

```bash
# BAD - encodes one implementation
grep -q 'check-ref-format' "$REFERENCE"

# GOOD - asks the actual question, and admits several answers
#   is any splice point unquoted?
grep -nE "git (switch|merge-base HEAD|worktree add[^']*) *\"?<" "$REFERENCE"
#   ...and if the answer is "none", read the file to see which shape was used
```

For a restructure, do not grep at all — the shape of a valid fix is not enumerable. Read it.

### Run a proposed guard against the hostile input before trusting it

```bash
# the three-line check that would have caught the weak guard
for n in 'dev`id`' "dev';id;'" 'dev$(id)'; do
  printf '%-12s ' "$n"
  git check-ref-format --branch "$n" >/dev/null 2>&1 && echo "PASSES the guard" || echo "rejected"
done
```

Anything printing `PASSES the guard` for a string you consider hostile means the guard is not the guard.

## Prevention

- When verifying whether a finding is fixed, ask what outcome the finding wanted, then enumerate the shapes that satisfy it. If more than one shape does, a grep for any single one is a false-negative generator.
- A restructure has no distinctive token. Read the file; do not grep for renumbering.
- Never accept a proposed guard without running it against the input it is meant to reject. A finding's reasoning and its remedy are separable, and a correct diagnosis can carry an ineffective fix.
- Distinguish adjacent predicates. "Valid git ref name" and "safe to interpolate into a shell command" are not the same set, and the difference is exactly the characters an attacker wants.
- After an interrupted run leaves partial work, prefer having an agent *read and report* over reconstructing state by pattern-matching. The reconstruction is where the false negatives enter.

## Related Issues

- `docs/solutions/mistakes/verification-gate-passes-on-unmodified-tree-System-20260729.md` — the same substitution in gate authoring; its leg (c) is this lesson stated for assertions.
- `docs/solutions/mistakes/dedup-change-spawns-new-duplicates-System-20260804.md` — the other lesson from this session.
- `ixion/skills/work-review/SKILL.md` 2.3c — the empirical gate that killed an unrelated P1 in the same round by running its Evidence command; the discipline that worked here is the same one.

## Environment

- **Environment:** development
- **Repo:** Ixion plugin
- **Shipped in:** branch `branch-prod-dev-resolution`
- **Residual:** the quote-breakout vector is recorded as accepted-unguarded in that session's `progress.json.error_log`; reachability requires a repo with no `origin/HEAD`, no local `main`, no local `master`, and HEAD on a hostile branch name.
