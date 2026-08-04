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

SESSION_ID="branchcheck-2026-08-04"
INTEGRATION="develop"

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
  preserve_sandbox "$TWO_SBOX"
  preserve_sandbox "$ONE_SBOX"
}
trap cleanup EXIT

# run_work <tmux-session> <sandbox> — seed a session, drive /work, and return 0
# once work has recorded the branch point.
#
# The wait condition is session.json.integration_branch, not progress.json:
# work writes progress.json in Phase 1 step 2, three steps before it resolves
# branches at all, so waiting on it would sample the repo mid-decision.
#
# The fixture is deliberately one phase over one file. work offers a worktree
# above ten files or three phases, and taking that path would put the session
# branch in a sibling directory where none of the assertions below are looking.
run_work() {
  local session="$1" sbox="$2"
  local sdir="$sbox/.ixion/plugin/sessions/$SESSION_ID"
  mkdir -p "$sdir"

  cat > "$sdir/spec.json" <<'EOF'
{
  "schema_version": 1,
  "summary": "Fixture for the branch-resolution integration case. One phase over one file, small enough that work takes its in-place branch path rather than offering a worktree. The plan is never expected to finish — the case reads the repo's branch state as soon as work Phase 1 has recorded where it branched from.",
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
    if jq -e '.integration_branch // empty' "$sdir/session.json" >/dev/null 2>&1; then
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

SESSION_BRANCH=$(git -C "$TWO_SBOX" branch --show-current)
if [ -n "$SESSION_BRANCH" ] && [ "$SESSION_BRANCH" != "$PRODUCTION" ] && [ "$SESSION_BRANCH" != "$INTEGRATION" ]; then
  note_pass "work left HEAD on a session branch ($SESSION_BRANCH)"
else
  note_fail "HEAD is on '$SESSION_BRANCH' — work did not create a session branch"
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

RECORDED=$(jq -r '.integration_branch // ""' "$TWO_SDIR/session.json" 2>/dev/null || echo "")
if [ "$RECORDED" = "$INTEGRATION" ]; then
  note_pass "session.json records integration_branch=$INTEGRATION"
else
  note_fail "session.json integration_branch is '$RECORDED', expected $INTEGRATION"
fi

# base_ref and integration_branch have to describe one branch point, so the
# check is equality with develop's tip rather than mere resolvability — that
# also rules out the literal string "null" reaching the field.
BASE_REF=$(jq -r '.base_ref // ""' "$TWO_SDIR/session.json" 2>/dev/null || echo "")
if [ "$BASE_REF" = "$INTEGRATION_TIP" ]; then
  note_pass "base_ref is $INTEGRATION's tip"
else
  note_fail "base_ref is '$BASE_REF', expected $INTEGRATION's tip $INTEGRATION_TIP"
fi

if pane_has_skill_invocation "$TWO_SESSION" "work"; then
  note_pass "pane shows Skill(work) was invoked"
else
  note_fail "Skill(work) marker not found in pane — agent may have compressed the skill"
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

RECORDED=$(jq -r '.integration_branch // ""' "$ONE_SDIR/session.json" 2>/dev/null || echo "")
if [ "$RECORDED" = "$ONE_PRODUCTION" ]; then
  note_pass "single-branch repo records integration_branch=$ONE_PRODUCTION (collapses to production)"
else
  note_fail "single-branch repo recorded integration_branch='$RECORDED', expected $ONE_PRODUCTION"
fi

SESSION_BRANCH=$(git -C "$ONE_SBOX" branch --show-current)
if [ -n "$SESSION_BRANCH" ] && [ "$SESSION_BRANCH" != "$ONE_PRODUCTION" ]; then
  note_pass "single-branch repo still branches off production ($SESSION_BRANCH)"
else
  note_fail "single-branch repo left HEAD on '$SESSION_BRANCH' — work stopped branching"
fi

finalize
