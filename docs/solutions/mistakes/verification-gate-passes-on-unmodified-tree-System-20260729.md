---
module: System
date: 2026-07-29
problem_type: mistake
component: testing_framework
symptoms:
  - "Phase verification prints PASS against a tree where none of the work was done"
  - "A success criterion is reported as met while a file still violates it"
  - "grep-based gate matches vocabulary the file already contained before the change"
root_cause: missing_validation
resolution_type: workflow_improvement
severity: high
tags: [verification, gates, spec, false-positive, grep, plan-review]
---

# A verification gate that cannot fail is worse than no gate

## Symptom

Four separate gates in one session reported success against work that had not been done:

1. `sed -n '95,125p' work/SKILL.md | grep -qi "worktree"` — meant to prove a worktree caveat was added. That line window already contained the word "worktree" six times before any edit.
2. `grep -q "git log" ship/SKILL.md` — meant to prove a new commits-ahead probe existed. `ship/SKILL.md` already contained `git log` at three places (lines 37, 74, 89), all predating the change.
3. The same gate's command loop checked `git restore`, `git stash`, `git clean` but never `git checkout` — one of the five commands the phase existed to add. An implementation naming four of five would still print `PHASE1_OK`.
4. A later gate asserted "no unbound `<base>` placeholder in any skill" but enumerated only three `SKILL.md` files. `ixion/skills/work/references/verification-gates.md:40` still read `git diff <base>...HEAD`, so the criterion was reported met while a file the skill explicitly tells readers to open still violated it.

Cases 1–3 were written during planning and caught by review. Case 4 was written *while fixing* cases 1–3.

## Investigation

### Attempted (Failed)

1. Reading the gate and reasoning about whether it looked correct. All four read fine — each greps for something the finished work genuinely contains. The defect is invisible from the gate alone; it only appears when you know the *starting* state.
2. Trusting that a gate written alongside the task it guards will be scoped to that task. It usually is, but scope drift is silent: enumerating three files when four are in play produces no error, just a smaller check.

### Discovery

Running each gate against the untouched tree. Every vacuous gate exits 0 immediately, and the diagnostic is instant and unambiguous.

## Root Cause

A grep-based gate proves *presence*, not *change*. When the searched token already occurs in the file — because it is ordinary vocabulary for that file's subject matter, or because a related feature already used it — presence was true before the work started and remains true after. The gate is then a tautology that reads as evidence.

This is especially easy in a repo whose artifacts are prose: a file about worktrees says "worktree" constantly, and a file about git says `git log` constantly. The more on-topic the token, the more likely the gate is vacuous.

## Solution

### The rule

Run every new gate against the pre-change tree and confirm it **fails** before trusting a pass.

```bash
# before writing any of the work, run the gate you just authored:
eval "$VERIFICATION"
# expected: non-zero exit with a specific diagnostic naming what is missing
```

For the four cases above, this produced:

```
FAIL: <git checkout> appears 0 times, need >=2 (both templates)
FAIL: base_ref not added to session schema
```

### Gate design that follows from it

```bash
# BAD - matches pre-existing vocabulary
sed -n '95,125p' "$f" | grep -qi "worktree"

# GOOD - matches wording only the new work introduces
sed -n '95,125p' "$f" | grep -qE "does not protect|destructive"

# BAD - counts presence, which was already true
grep -q "git restore" "$f"

# GOOD - counts occurrences against a known starting count
n=$(grep -c -- "git restore" "$f" || true); [ "$n" -ge 2 ]
```

Record the baseline counts when authoring the gate. If a token's pre-change count is 0, `-ge 1` is meaningful; if it is 3, only `-ge 4` is.

### Guard the enumeration too

A gate that lists the files it checks will silently under-cover when the change grows. Prefer a glob over a hand-listed set when the criterion says "any":

```bash
# criterion: "no unbound <base> in any skill"
grep -rn '<base>' ixion/skills/ ; # not: three explicit SKILL.md paths
```

## Prevention

- Run every new gate against the unmodified tree; a gate that passes there is not a gate.
- Note the pre-change occurrence count for each grepped token, and set the threshold above it.
- Grep for wording the change *introduces*, not for the subject matter it discusses.
- When a criterion says "any"/"no remaining", express the check as a recursive glob rather than an enumerated file list — enumerations rot as scope grows.
- Prefer a failing diagnostic that names the missing thing (`FAIL: <git checkout> appears 0 times, need >=2`) over a bare exit code; you will read it while the work is half-done.

## Related Issues

- `docs/solutions/mistakes/markdown-embedded-shell-fails-silently-System-20260729.md` — the sibling failure mode: shell inside skill markdown is never executed at authoring time, so nothing catches it either.

## Environment

- **Environment:** development
- **Repo:** Ixion plugin (`ixion/skills/`, `ixion/schemas/`)
- **Shipped in:** `ae14cdf`
