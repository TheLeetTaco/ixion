---
module: System
date: 2026-07-29
problem_type: mistake
component: testing_framework
symptoms:
  - "Phase verification prints PASS against a tree where none of the work was done"
  - "A success criterion is reported as met while a file still violates it"
  - "grep-based gate matches vocabulary the file already contained before the change"
  - "Gate has a zero baseline yet still passes on a regression to the pre-fix form"
  - "Gate fails on a correct run because it demands a token no writer produces"
root_cause: missing_validation
resolution_type: workflow_improvement
severity: high
tags: [verification, gates, spec, false-positive, false-negative, grep, plan-review]
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

### Amendment (2026-07-29, session `cargo-gate-tiering`): the baseline check is necessary, not sufficient

A later session ran the baseline check faithfully and still shipped two broken gates. **A zero baseline proves the assertion was *added*. It says nothing about whether the assertion *discriminates*.** Two distinct escapes followed:

**Escape 1 — passes on a regression.** A chain test asserted `GATE_RE="clippy|fmt"` against a spec's phase `verification`. In *the test file's own source* both tokens measured a clean zero baseline, so the gate looked proven. But the change it guarded was the addition of *flags* — `--all-targets`, `--all-features`, `--locked` — and `clippy`/`fmt` were the command names the pre-fix gate list already emitted. A spec regressed all the way back to `cargo clippy -- -D warnings` satisfied the gate identically to a correct one. The baseline was measured on the wrong artifact: the file holding the assertion, not the artifact the assertion inspects.

**Escape 2 — fails on correct input.** Fixing escape 1, the same three-flag bar was applied to *two* artifacts: the spec's phase `verification` (correct — that is where the composed string lives) and `progress.artifacts.commands_run` (wrong). No documented writer puts `--all-targets` in that array: `work` 2.3 step 4 appends only the members' returned commands, the per-chunk dispatch scopes subagents to `cargo check --locked`, and Phase 3 records only `success_criteria` commands. The gate would have failed every correct run. Caught only by tracing every writer to the array — never by any baseline measurement.

### The complete check is three-way

Authoring a gate is not done until all three hold:

| Check | Question | Escape it catches |
|---|---|---|
| (a) Zero baseline | Did the token exist before the change? | The original tautology |
| (b) **Fails on regressed input** | Does it reject the *pre-fix form* of the thing it guards? | Escape 1 |
| (c) **Passes on correct input** | Does every writer to that artifact actually produce the token? | Escape 2 |

(b) and (c) are about the artifact under inspection; (a) is about the file holding the assertion. Confusing the two is what produced escape 1.

When the artifact is only produced at runtime, simulate all three inputs rather than skipping the check — a fifteen-line script that builds a regressed artifact, a correct one, and a partially-correct one costs less than one bad round.

### A gate that fails on correct input is worse than a weak one

A weak gate under-reports. A gate that blocks correct work gets **deleted by the first person it blocks** — taking its real coverage with it. This is the same dynamic that makes a tool-presence probe skip loudly rather than hard-fail on a missing binary. When the two errors are not equally cheap, bias toward the weaker assertion and say so in a comment.

### Bar the assertion at the tier the artifact belongs to

Escape 2's root shape: one bar applied to two artifacts populated by different writers. Where two artifacts carry different guarantees, name the tiers and assert each separately, with a comment saying *why* the bars differ — otherwise the next reader "tightens" the weaker one back into a false negative.

```bash
# per-phase gates are plan-creation's contract; they live in the spec
PHASE_GATE_FLAGS=(--all-targets --all-features --locked)
# commands_run holds only what subagents return, and a subagent is told to run
# just the per-chunk gate — demanding the phase flags here fails a correct run
CHUNK_GATE_FLAGS=(--locked)
```

### Guard the enumeration too

A gate that lists the files it checks will silently under-cover when the change grows. Prefer a glob over a hand-listed set when the criterion says "any":

```bash
# criterion: "no unbound <base> in any skill"
grep -rn '<base>' ixion/skills/ ; # not: three explicit SKILL.md paths
```

## Prevention

- Run every new gate against the unmodified tree; a gate that passes there is not a gate.
- Then run it against a **regressed** artifact and a **correct** one. The baseline alone has now let two gates through — see the amendment above.
- Measure the baseline on the artifact the assertion *inspects*, not on the file that *holds* the assertion.
- Ask what the change actually adds. If it adds flags, assert on the flags; the command names were there before.
- Before demanding a token from an artifact, name every writer that populates it and confirm at least one produces that token.
- Note the pre-change occurrence count for each grepped token, and set the threshold above it.
- Grep for wording the change *introduces*, not for the subject matter it discusses.
- When a criterion says "any"/"no remaining", express the check as a recursive glob rather than an enumerated file list — enumerations rot as scope grows.
- Prefer a failing diagnostic that names the missing thing (`FAIL: <git checkout> appears 0 times, need >=2`) over a bare exit code; you will read it while the work is half-done.

## Related Issues

- `docs/solutions/mistakes/markdown-embedded-shell-fails-silently-System-20260729.md` — the sibling failure mode: shell inside skill markdown is never executed at authoring time, so nothing catches it either.
- `docs/solutions/mistakes/copied-wiring-pattern-without-its-consumer-System-20260729.md` — the other habit the `cargo-gate-tiering` session surfaced: a pattern reproduced by resemblance rather than by checking what consumes it.

## Environment

- **Environment:** development
- **Repo:** Ixion plugin (`ixion/skills/`, `ixion/schemas/`)
- **Shipped in:** `ae14cdf`; amended after `7aa23b2` (session `cargo-gate-tiering`)

### Why both escapes were caught by reasoning, not by a red test

Neither the amended gate nor the original ever ran: the authoring host lacks `tmux`, `jq` and `bunx`, so `tests/integration/` cannot execute there and `bash -n` proves parse-only. Both escapes were found by tracing writers and hand-simulating inputs. That is the expensive path, and it is the one this rule exists to shorten — but note it also means the three-way check above has itself only been reasoned through, not observed failing a real run.
