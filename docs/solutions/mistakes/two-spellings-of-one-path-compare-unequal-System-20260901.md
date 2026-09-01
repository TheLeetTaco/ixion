---
module: System
date: 2026-09-01
problem_type: mistake
component: development_workflow
symptoms:
  - "An exclusion documented as unconditional silently never fires"
  - "Two strings naming the same directory compare unequal on one host family"
  - "The harness case written for that exact invariant passes both before and after the fix"
  - "A constraint written to prevent representation mismatch in one comparison, while the neighbouring comparison has it"
root_cause: logic_error
resolution_type: code_fix
severity: high
tags: [path-identity, representation, string-equality, windows, msys, git, fixtures, false-green]
---

# Two spellings of one path compare unequal, and the test that covered it supplied the convenient one

## Symptom

`git-branches.md`'s "Worktrees already contained in the integration branch" block states its own guarantee in prose: this session's own worktree is excluded from the report *by path, unconditionally*. It has to be — a freshly cut session branch sits at the integration tip and is therefore "contained" by the block's own test, so without the exclusion `work` names, on entry, the very tree it has just created.

The exclusion never fired on the Windows development host. `work` Phase 1 would print the session's own worktree as one "whose branch adds nothing to the integration branch", and the prose two lines away points the user at `git worktree remove`. The window is worst at exactly the moment it opens: the tree was created seconds earlier and is clean, so `git worktree remove`'s dirty-tree refusal — the safety property the whole print-don't-run design leans on — does not intervene.

Observed directly:

```
$ git worktree list --porcelain | grep '^worktree '
worktree D:/Git_Repos/ixion
worktree D:/Git_Repos/ixion-worktree-retirement-hints

$ # what session-handoff.md's "Derive the session worktree" block prints:
worktree=/d/Git_Repos/ixion-worktree-retirement-hints
```

Running the block verbatim against a synthetic repo whose own tree was contained gave `merged_count=1` where its own stated invariant requires `0`.

## Investigation

### Attempted (Failed)

1. **Reading the block.** `tree != own` reads correctly. Both variables are described in the prose as the worktree's path, both *are* the worktree's path, and nothing on the line hints that they arrived by different routes. The defect is invisible from the comparison alone.
2. **Trusting the harness.** `tests/branch-resolution-harness.sh` had a case named for this exact invariant — "own tree is the merged one: not reported" — and it was green. So was the whole suite, 107/0, on the host where the bug reproduces.

### Discovery

Three of six `work-review` reviewers found it independently, all from the same observation: the two sides are *composed differently*, so their equality is an assumption rather than a fact. `OWN` comes from `session-handoff.md`'s derive block —

```bash
WORKTREE="$(cd "$REPO_ROOT/.." && pwd)/${REPO_ROOT##*/}-$SLUG"
```

— where MSYS `pwd` yields `/d/...`, while `tree` is lifted verbatim out of `git worktree list --porcelain`, which git spells `D:/...`. The empirical gate then reproduced it against a real repo rather than arguing about it.

## Root Cause

**Path identity was never established before it was compared.** Two independently-derived strings were treated as interchangeable because they denote the same directory, when string equality asks a narrower question than denotation.

The sharpest detail is that the project had already learned this lesson *in the same block*, one comparison away. Plan review had added a constraint spelling it out for branch refs:

> Ref forms must agree before any comparison: the porcelain `branch ` line and for-each-ref's `%(refname)` both carry the full `refs/heads/<name>`, so they compare directly; `protected=` carries short names, so the block prefixes each with `refs/heads/` before testing membership. Comparing `refs/heads/dev` to `dev` never matches, the exclusion silently never fires.

That is a precise statement of this bug's mechanism, written before the code was, and applied only to the refs. The path comparison three lines below got none of it. **Anticipating a class of bug at one comparison does not transfer to the neighbouring comparison** — the constraint was filed against a *value type* (refs) rather than against the operation (`==` on strings from two producers).

### Why the test proved nothing

The harness case built its input with `git_path()` — `git -C "$1" rev-parse --show-toplevel` — git's own spelling of the path, rather than the `cd .. && pwd` composition `work` actually produces. Its helper comment even named the divergence it was routing around:

```
# The block compares <own> against paths as `git worktree list` prints them, by
# plain string equality, so <own> has to be spelled the way git spells it — on
# Windows that is `C:/Users/...` where this harness's own $WORK reads `/tmp/...`.
```

The comment is correct about the mechanism and wrong about whose problem it is. It reads the constraint as something the *test* must satisfy, when it is the thing the *code* was failing to. Having noticed the divergence, the harness fed the code the one spelling under which the bug is invisible.

This is a distinct failure from a vacuous assertion, and mutation testing does not catch it. Break `tree != own` and the original case fails, so the assertion demonstrably discriminates — it is the *input* that is unrepresentative, not the check. A fixture constructed the way the code wants tests the code against itself.

## Solution

Normalize both sides through one producer before comparing. Both are then in git's spelling, which is the one the porcelain listing is going to use whatever the host:

```bash
# ixion/skills/ixion-conventions/references/git-branches.md
OWN='<worktree= from the "Derive the session worktree" block>'

OWN=$(git -C "$OWN" rev-parse --show-toplevel 2>/dev/null)
```

Fixed in the block rather than in the derive block it reads from: every *other* consumer of `worktree=` uses it as a `cd` target, where the MSYS spelling is correct. Only the consumer that compares against git's output needs git's spelling, so that is where the conversion belongs.

No `|| printf '%s' "$OWN"` fallback. A path that is not a worktree resolves to empty, empty matches no tree, and nothing is excluded — which is the same outcome the fallback's un-normalized spelling would produce against git-spelled paths. It would be a guard on a case it cannot change.

And the harness case now feeds the shipped composition:

```bash
# before — git's spelling, which the bug is invisible under
out=$(merged_worktrees "$repo" main main "$(git_path "$wt")")
# after — the derive block's own composition, which is what work passes
out=$(merged_worktrees "$repo" main main "$(cd "$repo/.." && pwd)/${repo##*/}-feata")
```

Mutation-tested both ways: with the normalization line deleted, the reworked case fails 3 assertions on Windows; the original case passed either way.

## Prevention

- **Before comparing two strings for equality, name the producer of each.** One producer means the comparison is sound. Two producers means the comparison is an assumption, and it needs a normalizing step or a note saying why the two agree.
- **File the lesson against the operation, not the value type.** "Refs must agree in form before comparison" left the adjacent path comparison unguarded. "Two strings from different producers must be normalized before `==`" would have covered both.
- **Prefer converting through the tool that will produce the other side.** `git rev-parse --show-toplevel` yields git's spelling, which is what any later `git worktree list` output will carry. Normalizing toward the *shell's* spelling would have to be redone at every git boundary.
- **A test's input must come from the shipped producer, not from whatever is convenient.** Where a fixture composes an input by hand, it is testing the code against its own assumptions. Ask, for each input: *what code produces this value in production, and did I run it?*
- **When a comment explains why the test has to spell something a particular way, treat it as a defect report.** A constraint the test has to satisfy in order to pass is usually a constraint the code failed to. That comment was in the tree, correct, and load-bearing in the wrong direction.
- **Cross-platform path handling is a producer question, not a formatting question.** On Windows, MSYS `pwd` and `git.exe` disagree by construction; the fix is to pick one producer, not to normalize slashes.

## Related Issues

- `docs/solutions/patterns/break-the-check-to-prove-it-can-fail-System-20260820.md` — mutation testing proves an assertion *discriminates*. This case shows that is not sufficient: the assertion discriminated fine, and the input never exercised the failing condition.
- `docs/solutions/mistakes/verification-gate-passes-on-unmodified-tree-System-20260729.md` — its three-way check (zero baseline / fails on regressed input / passes on correct input) is about the *artifact under inspection*. This adds a fourth question about the *input*: was it built by the shipped producer?
- `docs/solutions/mistakes/empty-id-makes-a-path-probe-answer-present-System-20260806.md` — the sibling path-handling failure: a probe answering "present" for a path composed from an empty variable. Same family — a path string that looks valid and denotes nothing anyone meant.

## Environment

- **Environment:** development
- **OS:** Windows 11, Git-for-Windows / MSYS bash — the host where the two spellings diverge. On Linux and macOS both derivations agree, so the defect is invisible there and the offline suite (which runs in Docker) would have stayed green indefinitely.
- **Repo:** Ixion plugin (`ixion/skills/ixion-conventions/references/git-branches.md`, `tests/branch-resolution-harness.sh`)
- **Session:** `worktree-retirement-hints-2026-09-01`; found by `work-review`, gate 3 checked → 3 reproduced, 0 refuted
