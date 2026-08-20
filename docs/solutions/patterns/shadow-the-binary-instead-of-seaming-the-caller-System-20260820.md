---
module: System
date: 2026-08-20
problem_type: pattern
component: testing_framework
symptoms:
  - "A production code path carries a parameter no production caller ever sets"
  - "A guard is always false outside the test suite"
  - "A test seam reads like ordinary inter-block wiring and gets copied as such"
  - "A block containing an external command is declared untestable and left uncovered"
root_cause: missing_validation
resolution_type: workflow_improvement
severity: medium
tags: [testing, test-seam, stubs, speculative-generality, offline-testing, harness]
---

# Shadow the binary rather than seam the caller

## The pattern

When a block has to call an external binary and you want it covered offline, put a fake **binary** on `PATH` instead of adding a **bypass** to the block. The seam is the tempting move because it is smaller. The shadow is better on three counts, and the third is the one that decides it: the shadow proves *which branch ran*, while the seam only proves the ladder computes correctly once you have skipped the part that talks to the world.

## The instance

`ship`'s auto-merge resolution needs two `gh` probes. To reach the ladder offline, the block was written with pre-seeded placeholders:

```bash
ALLOWED='<allow_auto_merge, empty unless already read>'
STATE='<mergeStateStatus, empty unless already read>'

[ -n "$ALLOWED" ] || ALLOWED=$(gh api "repos/$REPO" -q '.allow_auto_merge')
[ -n "$STATE" ] || STATE=$(gh pr view "$URL" --json mergeStateStatus -q '.mergeStateStatus')
```

Two reviewers flagged it independently — `reviewer-architecture` as **Speculative Generality**, `reviewer-elegance` as **Speculative Code**. Both landed on the same observation: *nothing in the real flow ever sets either variable*, so both guards are dead in production, and their only caller is the harness. Worse, in a file whose convention is that a placeholder names a real prior block that printed the value, this one reads exactly like ordinary threading. The next person adding a rung copies a test seam thinking it is wiring.

Replacing it with a `gh` on `PATH`:

```bash
cat > "$GH_DIR/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "$1 $2" in
  'api repos/owner/repo') [ -n "${GH_ALLOWED:-}" ] || exit 1; printf '%s\n' "$GH_ALLOWED" ;;
  'pr view')              [ -n "${GH_STATE:-}" ]   || exit 1; printf '%s\n' "$GH_STATE" ;;
esac
STUB
```

## What the shadow bought that the seam could not

1. **It distinguishes two failures the seam collapsed.** With the seam, an empty `ALLOWED` was the only way to express "unread", so "setting unread, state read" and "state unread, setting read" were the same fixture. The stub answers each probe independently, so both are now separate cases — and they resolve differently.
2. **It made a previously untestable block testable.** A drift guard added later re-reads the state and arms only on a match. The seam had nothing to say about it. The stub logs every invocation to `GH_CALLS`, so `grep -c -- '--auto' "$GH_CALLS"` asserts *whether arming happened* — the block's actual effect.
3. **It deleted code from the shipped artifact.** Four lines of production text went away, paying for the drift guard's addition against a byte budget.

## When the objection "a stub would test the stub" actually applies

The same harness deliberately leaves `gh pr create` uncovered, and that is not inconsistent. The distinguishing question:

> Is the block's effect **external**, or is the block's effect **its own control flow**?

- `gh pr create`'s whole effect is the PR it opens. Faking it tests the fake. Leave it.
- The auto-merge blocks' effect *is* which rung is reached and whether `--auto` is called at all. That is exactly what a stub can prove. Cover it.

"A stub would test the stub" is a real rule with a narrow scope, and it gets over-applied to any block that mentions a network binary. Ask what you are asserting before invoking it.

## Prevention

- A parameter with no production caller is a finding, not a design. If the only way to reach a branch is from the test suite, the seam is in the wrong file.
- Before adding a bypass to production code for testability, check whether shadowing the binary reaches the same code with nothing added.
- Have the stub **log its argv**. That is what turns "the ladder computed X" into "the command was/wasn't spent", which is usually the assertion you actually wanted.
- If you keep a seam anyway, say at the declaration that it is a harness hook, so it is not copied as ordinary data flow.

## Related Issues

- `docs/solutions/patterns/break-the-check-to-prove-it-can-fail-System-20260820.md` — the companion step: having added the assertion, mutate the guard and confirm it fails.
- `tests/branch-resolution-harness.sh` — the stub and the arming assertions.

## Environment

- **Environment:** development
- **Repo:** Ixion plugin (`ixion/skills/ship/`, `tests/`)
- **Shipped in:** PR #3, session `ship-auto-merge-2026-08-20`
