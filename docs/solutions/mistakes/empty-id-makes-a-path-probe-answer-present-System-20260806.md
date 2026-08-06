---
module: System
date: 2026-08-06
problem_type: mistake
component: development_workflow
symptoms:
  - "An absent-session check reports the session present, because the path it probes is the sessions directory itself"
  - "A first-contact repo is told 'Unsupported schema version .' instead of 'No active session'"
  - "An ad-hoc run writes a zero-byte session.json directly into the sessions directory, beside real sessions"
  - "The same defect is fixed, re-introduced by the fix, and found again in review"
root_cause: logic_error
resolution_type: code_fix
severity: high
tags: [empty-string, path-interpolation, guard-clause, bash, session-resolution, recurring]
---

# An empty id makes every path probe answer "present"

## Symptom

`"$SESSIONS/$SESSION_ID"` with an empty `SESSION_ID` is not an invalid path. It is `.ixion/plugin/sessions/` — the sessions directory itself, which **exists in any repo that has ever planned a session**. Every existence check derived from it therefore answers "present" for exactly the absent case it was written to catch:

```bash
SESSION_ID=""
SDIR=".ixion/plugin/sessions/$SESSION_ID"
[ -d "$SDIR" ]   # true
ls "$SDIR"       # lists every real session
```

This shape appeared **four times in one session**, twice as fresh bugs and twice as regressions in the fix for it:

1. **Shared `Validate the resolved session` block.** With no id resolved it ran its schema lookup against `<sessions>/session.json`, so a fresh repo with no session and no pointer was told `Unsupported schema version .` instead of the `No active session.` message written for it.
2. **A fix pass restoring `ship`'s ad-hoc path** keyed the ad-hoc case on `[ -d "$SDIR" ]`. Reproduced as wrong with one prior session on disk; sent back a round.
3. **`ship` Phase 4 step 3** declared `SDIR` *outside* its `[ -n "$SESSION_ID" ]` guard, leaving a sessions-directory-shaped value in scope for later steps to inherit.
4. **`ship` Phase 4 step 7** had no guard and no `SDIR` assignment at all. On an ad-hoc ship it wrote a stray zero-byte `session.json` **into the sessions directory**, sibling to real session subdirectories — or, in a fresh shell, to `/session.json`. Four of six reviewers found it independently.

## Investigation

### Attempted (Failed)

1. **Guard on directory existence.** The natural reading of "no session" is "no session directory," so `[ -d "$SDIR" ]` looks like the test. It is the one test that cannot work, because the failure mode *is* that the derived path is a directory that exists.
2. **Assert the property in prose.** After the first two instances, `ship/SKILL.md` gained a sentence claiming four named sites all guarded on `[ -n "$SESSION_ID" ]`. Three did. The fourth (step 7) never had the guard, and the sentence made it *less* likely to be found — a reader who checks the claim stops checking the code. The prose was added by the same fix pass that made step 7 reachable.

### Discovery

The empty-string case is only visible when a *real* session already exists on disk. Every scratch reproduction built a fresh empty tree, where `.ixion/plugin/sessions/` does not exist and `[ -d ]` correctly answers false. Seeding one unrelated session directory first is what made all four instances reproduce:

```bash
mkdir -p .ixion/plugin/sessions/old-feat-2026-01-01
SESSION_ID=""; SDIR=".ixion/plugin/sessions/$SESSION_ID"
[ -d "$SDIR" ] && echo "probe says session present"   # fires
```

## Root Cause

String interpolation of an empty variable into a path yields the parent directory, not an error and not an absent path. `"$PARENT/$CHILD"` with an empty `CHILD` is `"$PARENT/"`. Any predicate about the *child* that is actually evaluated against the *parent* inverts precisely when the child is missing.

The state "no session was resolved" is a fact the resolution step already knows and already prints. Re-deriving it downstream from a filesystem probe throws that fact away and asks a question that cannot distinguish the two cases.

## Solution

Test the fact, never a path derived from it. The empty id *is* the signal.

```bash
# ixion/skills/ship/SKILL.md — every block that reads session state
SESSION_ID='<session= from Phase 0>'
if [ -n "$SESSION_ID" ]; then
  SDIR=".ixion/plugin/sessions/$SESSION_ID"
  jq '.status = "completed" | .active_skill = null' "$SDIR/session.json" > "$SDIR/session.json.tmp"
  mv "$SDIR/session.json.tmp" "$SDIR/session.json"
fi
```

Two details that carry the fix:

- **`SDIR` is derived inside the guard.** Assigning it outside leaves a sessions-directory-shaped value in scope for any later block that forgets its own guard — instance 3 is exactly that, and instance 4 was inheriting it.
- **The rule is stated once, and the code is the proof.** `ship/SKILL.md:53` now says *"every block below that reads session state interpolates `SESSION_ID=…` and branches on `[ -n "$SESSION_ID" ]`, so each block's own code is the proof rather than a list kept here."* The enumerated list it replaced was wrong about one of the four sites it named.

In the shared reference, the same rule is the *first* rung rather than a downstream guard:

```bash
# ixion/skills/ixion-conventions/references/session-handoff.md
if [ -z "$SESSION_ID" ]; then
  printf 'via=none\n'
elif [ ! -d "$SDIR" ]; then
  ...
```

## Prevention

- **When a variable can be empty, the guard tests the variable — never a path built from it.** `[ -n "$ID" ]`, not `[ -d "$DIR/$ID" ]`.
- **Derive the path inside the guard.** A path variable that exists in a scope where the id is empty is a loaded gun for the next block.
- **Reproduce absent-case bugs in a tree that already has real data.** An empty fixture directory hides every instance of this class. Seed one unrelated sibling first.
- **Don't assert a cross-site property in prose.** A sentence claiming "all N sites do X" is unverifiable by the reader and rots silently; it also suppresses the checking that would find the exception. State the rule and let each site's code carry its own proof.
- **A fix that makes a latent path reachable owns that path.** Step 7's missing guard predated the session. Restoring `ship`'s ad-hoc flow removed the Phase 0 halt that had made it unreachable — the fix didn't create the bug, it armed it.

## Related Issues

- `docs/solutions/mistakes/verification-gate-passes-on-unmodified-tree-System-20260729.md` — same family: a check whose subject and object diverge, so it passes on the state it exists to reject.
- `docs/solutions/patterns/cross-invocation-state-needs-a-persisted-home-System-20260729.md` — why these blocks re-declare every variable they read.
- `ixion/skills/ixion-conventions/references/session-handoff.md` — the empty-id rung and its rationale.

## Environment

- **Environment:** development
- **OS:** Windows (Git Bash); blocks are POSIX sh and run under Linux in CI
