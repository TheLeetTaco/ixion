#!/usr/bin/env bash
# Integration: /work <slug> targets the named session, not active.json.
#
# Two pre-seeded sessions (A and B) coexist in one sandbox. active.json
# points at B — simulating a second Claude Code session having claimed
# the pointer. We send `/work <slug-A>` and assert the run lands its
# artifacts in A's session dir while B's dir stays untouched.
#
# Pass criteria:
#   - progress.json appears in session A's dir.
#   - session B's dir gains no progress.json (pointer was not followed).
#   - pane shows Skill(work) — the skill actually ran (Principle 12).
#
# Real API calls; single skill on a trivial fixture. Plan on ~3-4 minutes.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$REPO_ROOT/tests/integration/lib"
SCHEMAS="$REPO_ROOT/ixion/schemas"
. "$LIB/assert.sh"
. "$LIB/sandbox.sh"
. "$LIB/tmux.sh"

pass=0
fail=0
SESSION="ixion-int-parsess"
SBOX=""

# Cheap model — this test exercises session addressability, not code quality.
export IXION_TEST_MODEL="${IXION_TEST_MODEL:-claude-haiku-4-5-20251001}"

cleanup() {
  pane_save_history "$SESSION"
  tmux_kill "$SESSION"
  preserve_sandbox "$SBOX"
}
trap cleanup EXIT

SBOX=$(make_sandbox "parsess")

SESSION_A="feata-2026-04-24"
SESSION_B="featb-2026-04-24"
DIR_A="$SBOX/.ixion/plugin/sessions/$SESSION_A"
DIR_B="$SBOX/.ixion/plugin/sessions/$SESSION_B"
mkdir -p "$DIR_A" "$DIR_B"

# seed_session <dir> <session-id> <slug> <target-file>
seed_session() {
  local dir="$1" sid="$2" slug="$3" target="$4"
  cat > "$dir/spec.json" <<EOF
{
  "schema_version": 1,
  "summary": "Pre-seeded fixture for the parallel-sessions integration test. One trivial phase creates $target which echoes its own name. The spec content only needs to be valid enough for the work skill to bootstrap progress.json in the correct session directory — that directory choice is what the test asserts.",
  "context": { "key_files": ["$target"], "patterns": [], "constraints": [] },
  "phases": [
    {
      "id": "phase-1",
      "goal": "Create $target.",
      "files": ["$target"],
      "tasks": [
        {
          "id": "t1",
          "description": "Create $target that echoes '$slug'.",
          "files": ["$target"],
          "test_scenarios": ["bash $target outputs '$slug'"]
        }
      ],
      "verification": "bash $target | grep -q $slug",
      "manual_verification": null,
      "depends_on": []
    }
  ],
  "success_criteria": ["$target prints $slug"]
}
EOF
  cat > "$dir/session.json" <<EOF
{
  "schema_version": 1,
  "session_id": "$sid",
  "slug": "$slug",
  "status": "active",
  "started_at": "2026-04-24T12:00:00Z",
  "last_checkpoint_at": null,
  "active_skill": null
}
EOF
}

seed_session "$DIR_A" "$SESSION_A" "feata" "feata.sh"
seed_session "$DIR_B" "$SESSION_B" "featb" "featb.sh"

# The pointer names B — the session we are NOT targeting.
cat > "$SBOX/.ixion/plugin/active.json" <<EOF
{ "schema_version": 1, "session_id": "$SESSION_B" }
EOF

# Validate fixtures before driving, so later failures are skill bugs.
AJV=(bunx ajv-cli --validate-formats=false --spec=draft2020)
for d in "$DIR_A" "$DIR_B"; do
  if "${AJV[@]}" validate -s "$SCHEMAS/spec.schema.json" -d "$d/spec.json" >/dev/null 2>&1 \
     && "${AJV[@]}" validate -s "$SCHEMAS/session.schema.json" -d "$d/session.json" >/dev/null 2>&1; then
    note_pass "seed artifacts validate: $(basename "$d")"
  else
    note_fail "seed artifacts did not validate in $(basename "$d") (test bug, not skill bug)"
    finalize
  fi
done

tmux_start "$SESSION" "$SBOX"

if ! wait_for_pane "$SESSION" "Quick safety check|\\? for shortcuts|Welcome back" 30; then
  note_fail "claude TUI did not start"
  finalize
fi
if tmux_capture "$SESSION" | grep -q "Quick safety check"; then
  tmux_send_line "$SESSION" ""
  wait_for_pane "$SESSION" "\\? for shortcuts|Welcome back" 15 || true
fi

# Drive: target session A by slug while active.json points at B.
tmux_send_line "$SESSION" "/work feata"

if wait_for_file "$DIR_A/progress.json" 240; then
  note_pass "progress.json landed in session A (slug-addressed, not pointer-addressed)"
else
  note_fail "progress.json did not appear in session A within 240s"
  echo "----- pane tail -----"; tmux_capture "$SESSION"; echo "----- end -----"
  finalize
fi

if [ ! -e "$DIR_B/progress.json" ]; then
  note_pass "session B untouched (no progress.json)"
else
  note_fail "session B gained a progress.json — the run followed active.json instead of the slug"
fi

if "${AJV[@]}" validate -s "$SCHEMAS/progress.schema.json" -d "$DIR_A/progress.json" >/dev/null 2>&1; then
  note_pass "session A progress.json validates against progress.schema.json"
else
  note_fail "session A progress.json failed schema validation"
  echo "----- progress.json -----"; cat "$DIR_A/progress.json"; echo "----- end -----"
fi

if pane_has_skill_invocation "$SESSION" "work"; then
  note_pass "pane shows Skill(work) invocation"
else
  note_fail "no Skill(work) marker in pane — skill may have been compressed inline"
fi

finalize
