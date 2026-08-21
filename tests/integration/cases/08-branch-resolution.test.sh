#!/usr/bin/env bash
# Integration: work branches from the integration branch, not from production.
#
# Topology correctness is already proven offline by
# tests/branch-resolution-harness.sh, which builds every git shape the
# resolution ladder can meet and asserts what it resolves to — for free, with
# no credential. This case does not re-enumerate any of that. It asserts the
# one claim a harness cannot reach: that `work` at runtime actually follows
# the citation in its Phase 1 instead of resolving a branch its own way.
#
# Two runs, because "the two-branch path works" and "the single-branch path is
# untouched" are different claims and the second is what every existing user
# is standing on:
#
#   1. Two-branch sandbox (main + develop), HEAD starting on main.
#      The session branch must fork from develop's tip.
#   2. Single-branch sandbox, the shape cases 00/01/05/06/07 run in.
#      integration_branch must come back as production.
#
# Why this cannot pass against the pre-change plugin: the discriminating
# assertion is `git merge-base <session-branch> develop == <develop tip>`.
# The old skills resolved one default branch from refs/remotes/origin/HEAD,
# which make_sandbox points at main, and branched where HEAD stood — on main.
# make_sandbox gives develop a commit main does not carry, so a branch forked
# from main meets develop only back at the fork point. merge-base is then the
# init commit, never develop's tip, and the assertion fails. Recording
# integration_branch at all is likewise new; the pre-change work skill has no
# writer for that field, so run 2 times out on it.
#
# Real API calls, two TUI sessions. Plan on ~4-8 minutes.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$REPO_ROOT/tests/integration/lib"
. "$LIB/assert.sh"
. "$LIB/sandbox.sh"
. "$LIB/tmux.sh"
. "$LIB/json.sh"

SESSION_ID="branchcheck-2026-08-04"
INTEGRATION="develop"

# `work` runs every session in a worktree of its own at `<repo>-<slug>` beside
# the repository root, and never switches the checkout it was invoked from. The
# session branch and its commits are therefore in the worktree, not the sandbox,
# and every branch assertion below has to look there. The slug is session_id
# minus its date, the same derivation
# ixion/skills/ixion-conventions/references/session-handoff.md's "Derive the
# session worktree" block makes.
SLUG=${SESSION_ID%-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]}
session_worktree() {
  printf '%s/%s-%s\n' "$(dirname "$1")" "$(basename "$1")" "$SLUG"
}

TWO_SESSION="ixion-int-branch-two"
ONE_SESSION="ixion-int-branch-one"
TWO_SBOX=""
ONE_SBOX=""

# Small model by default, as in 07 — this exercises one decision in work's
# Phase 1, not a full pipeline. Override with IXION_TEST_MODEL to retry a
# suspicious failure on a larger one before believing it.
export IXION_TEST_MODEL="${IXION_TEST_MODEL:-claude-haiku-4-5-20251001}"

cleanup() {
  for s in "$TWO_SESSION" "$ONE_SESSION"; do
    pane_save_history "$s"
    tmux_kill "$s"
  done
  for sbox in "$TWO_SBOX" "$ONE_SBOX"; do
    [ -n "$sbox" ] || continue
    preserve_sandbox "$sbox"
    preserve_sandbox "$(session_worktree "$sbox")"
  done
}
trap cleanup EXIT

# run_work <tmux-session> <sandbox> — seed a session, drive /work, and return 0
# once work has recorded the branch point.
#
# The wait condition is session.json.integration_branch, not progress.json:
# work writes progress.json in Phase 1 step 2, three steps before it resolves
# branches at all, so waiting on it would sample the repo mid-decision.
#
# The fixture is deliberately one phase over one file, so the plan is cheap; it
# is never expected to finish, because the branch point is recorded long before
# the work is. Its size no longer selects a code path — every session gets a
# worktree — it just keeps the run short.
run_work() {
  local session="$1" sbox="$2"
  local sdir="$sbox/.ixion/plugin/sessions/$SESSION_ID"
  mkdir -p "$sdir"

  cat > "$sdir/spec.json" <<'EOF'
{
  "schema_version": 1,
  "summary": "Fixture for the branch-resolution integration case. One phase over one file. The plan is never expected to finish — the case reads the session worktree's branch state as soon as work Phase 1 has recorded where it branched from.",
  "context": { "key_files": ["hello.sh"], "patterns": [], "constraints": [] },
  "phases": [
    {
      "id": "phase-1",
      "goal": "Print hello.",
      "files": ["hello.sh"],
      "tasks": [
        {
          "id": "t1",
          "description": "Create hello.sh that echoes 'hello'.",
          "files": ["hello.sh"],
          "test_scenarios": ["bash hello.sh outputs 'hello'"]
        }
      ],
      "verification": "bash hello.sh | grep -q hello",
      "manual_verification": null,
      "depends_on": []
    }
  ],
  "success_criteria": ["hello.sh prints hello"]
}
EOF

  cat > "$sdir/session.json" <<EOF
{
  "schema_version": 1,
  "session_id": "$SESSION_ID",
  "slug": "branchcheck",
  "status": "active",
  "started_at": "2026-08-04T12:00:00Z",
  "last_checkpoint_at": null,
  "active_skill": null
}
EOF

  printf '{ "schema_version": 1, "session_id": "%s" }\n' "$SESSION_ID" \
    > "$sbox/.ixion/plugin/active.json"

  tmux_start "$session" "$sbox"
  if ! wait_for_pane "$session" "Quick safety check|\\? for shortcuts|Welcome back" 30; then
    note_fail "claude TUI did not start ($session)"
    return 1
  fi
  if tmux_capture "$session" | grep -q "Quick safety check"; then
    tmux_send_line "$session" ""
    wait_for_pane "$session" "\\? for shortcuts|Welcome back" 15 || true
  fi

  tmux_send_line "$session" "/work"

  local i=0 last_fire=0 now
  while [ "$i" -lt 420 ]; do
    if [ "$(json_field "$sdir/session.json" integration_branch)" != null ]; then
      return 0
    fi
    now=$(date +%s)
    if [ $((now - last_fire)) -ge "$AUTOPILOT_COOLDOWN" ]; then
      if autopilot_respond "$session"; then last_fire="$now"; fi
    fi
    sleep 5
    i=$((i + 5))
  done
  return 1
}

# ---- Run 1: two-branch repo, starting on production ------------------------
TWO_SBOX=$(make_sandbox "branch-two" "$INTEGRATION")
TWO_SDIR="$TWO_SBOX/.ixion/plugin/sessions/$SESSION_ID"

# Read production from the sandbox's own origin rather than restating `main`
# here. That keeps one source of truth for the name and makes the read itself
# the check that make_sandbox's origin/HEAD symref resolves at all.
PRODUCTION=$(git -C "$TWO_SBOX" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
if [ -n "$PRODUCTION" ]; then
  note_pass "sandbox origin/HEAD resolves (production=$PRODUCTION)"
else
  note_fail "sandbox origin/HEAD did not resolve — make_sandbox did not create the remote"
  finalize
fi

INTEGRATION_TIP=$(git -C "$TWO_SBOX" rev-parse "$INTEGRATION")

if ! run_work "$TWO_SESSION" "$TWO_SBOX"; then
  note_fail "work never recorded integration_branch on the two-branch repo in 7min"
  echo "----- pane tail -----"; tmux_capture "$TWO_SESSION"; echo "----- end -----"
  finalize
fi
note_pass "work recorded a branch point on the two-branch repo"

TWO_WORKTREE=$(session_worktree "$TWO_SBOX")
SESSION_BRANCH=$(git -C "$TWO_WORKTREE" branch --show-current 2>/dev/null)
if [ -n "$SESSION_BRANCH" ] && [ "$SESSION_BRANCH" != "$PRODUCTION" ] && [ "$SESSION_BRANCH" != "$INTEGRATION" ]; then
  note_pass "work checked a session branch out in its own worktree ($SESSION_BRANCH at $TWO_WORKTREE)"
else
  note_fail "no session branch at $TWO_WORKTREE — work did not create the session worktree"
fi

# The other half of the same claim: the tree work was invoked from is never
# touched, which is what lets a session start while it is dirty.
INVOKED_ON=$(git -C "$TWO_SBOX" branch --show-current)
if [ "$INVOKED_ON" = "$PRODUCTION" ]; then
  note_pass "the invoking checkout is still on $PRODUCTION — work never switched it"
else
  note_fail "the invoking checkout is on '$INVOKED_ON' — work switched the tree it was invoked from"
fi

# The load-bearing assertion. A branch forked from production meets develop
# only at their fork point, which make_sandbox placed one commit behind
# develop's tip; equality here is reachable only by forking from develop.
MERGE_BASE=$(git -C "$TWO_SBOX" merge-base "$SESSION_BRANCH" "$INTEGRATION" 2>/dev/null || echo "")
if [ "$MERGE_BASE" = "$INTEGRATION_TIP" ]; then
  note_pass "session branch forks from $INTEGRATION's tip, not $PRODUCTION"
else
  note_fail "merge-base($SESSION_BRANCH, $INTEGRATION) is '$MERGE_BASE', expected $INTEGRATION's tip $INTEGRATION_TIP"
  echo "----- branch graph -----"
  git -C "$TWO_SBOX" log --oneline --graph --all | head -20
  echo "----- end -----"
fi

RECORDED=$(json_field "$TWO_SDIR/session.json" integration_branch)
if [ "$RECORDED" = "$INTEGRATION" ]; then
  note_pass "session.json records integration_branch=$INTEGRATION"
else
  note_fail "session.json integration_branch is '$RECORDED', expected $INTEGRATION"
fi

# base_ref and integration_branch have to describe one branch point, so the
# check is equality with develop's tip rather than mere resolvability — that
# also rules out the literal string "null" reaching the field.
BASE_REF=$(json_field "$TWO_SDIR/session.json" base_ref)
if [ "$BASE_REF" = "$INTEGRATION_TIP" ]; then
  note_pass "base_ref is $INTEGRATION's tip"
else
  note_fail "base_ref is '$BASE_REF', expected $INTEGRATION's tip $INTEGRATION_TIP"
fi

# The harness types this one, so there is no Skill() tool call to look for —
# see pane_has_skill_invocation's note. What the pane can still prove is that
# the command reached the prompt rather than being swallowed by a dialog.
if pane_ran_command "$TWO_SESSION" "work"; then
  note_pass "pane shows the work command reached the prompt"
else
  note_fail "no /work command echoed in pane — the keystroke never landed"
fi

# ---- Run 2: single-branch repo, the shape every other case runs in ---------
# Existing cases assert nothing about branches, so without this run nothing
# would notice the two-branch change breaking the repos everyone actually has.
ONE_SBOX=$(make_sandbox "branch-one")
ONE_SDIR="$ONE_SBOX/.ixion/plugin/sessions/$SESSION_ID"
# Read from this sandbox's own origin rather than reusing run 1's value: the
# claim under test is what work resolved in *this* repo, and the read is also
# what confirms the second sandbox got a remote too.
ONE_PRODUCTION=$(git -C "$ONE_SBOX" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')

if ! run_work "$ONE_SESSION" "$ONE_SBOX"; then
  note_fail "work never recorded integration_branch on the single-branch repo in 7min"
  echo "----- pane tail -----"; tmux_capture "$ONE_SESSION"; echo "----- end -----"
  finalize
fi

RECORDED=$(json_field "$ONE_SDIR/session.json" integration_branch)
if [ "$RECORDED" = "$ONE_PRODUCTION" ]; then
  note_pass "single-branch repo records integration_branch=$ONE_PRODUCTION (collapses to production)"
else
  note_fail "single-branch repo recorded integration_branch='$RECORDED', expected $ONE_PRODUCTION"
fi

ONE_WORKTREE=$(session_worktree "$ONE_SBOX")
SESSION_BRANCH=$(git -C "$ONE_WORKTREE" branch --show-current 2>/dev/null)
if [ -n "$SESSION_BRANCH" ] && [ "$SESSION_BRANCH" != "$ONE_PRODUCTION" ]; then
  note_pass "single-branch repo still branches off production ($SESSION_BRANCH at $ONE_WORKTREE)"
else
  note_fail "no session branch at $ONE_WORKTREE — work stopped branching in the single-branch shape"
fi

finalize
