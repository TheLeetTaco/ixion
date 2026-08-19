#!/usr/bin/env bash
# Integration: /work executes a depends_on spec to completion (wave dispatch).
#
# Fixture spec: phase-1 is the foundation; phase-2 and phase-3 both declare
# depends_on ["phase-1"] and touch disjoint files, so the work skill's wave
# computation may run them concurrently after phase-1 lands. The hard
# assertions are completion-shaped (all three ids in completed[]); the
# parallel Task dispatch itself is asserted best-effort from the pane.
#
# Pass criteria:
#   - progress.json reaches status=completed with all three phase ids.
#   - progress.json validates against the schema.
#   - fixture spec (with depends_on) validates against spec.schema.json.
#   - best-effort (non-fatal): pane shows evidence of wave dispatch.
#
# Real API calls; trivial fixture on a cheap model. Plan on ~4-5 minutes.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$REPO_ROOT/tests/integration/lib"
SCHEMAS="$REPO_ROOT/ixion/schemas"
. "$LIB/assert.sh"
. "$LIB/sandbox.sh"
. "$LIB/tmux.sh"
. "$LIB/json.sh"

pass=0
fail=0
SESSION="ixion-int-parchunk"
SBOX=""

export IXION_TEST_MODEL="${IXION_TEST_MODEL:-claude-haiku-4-5-20251001}"

cleanup() {
  pane_save_history "$SESSION"
  tmux_kill "$SESSION"
  preserve_sandbox "$SBOX"
}
trap cleanup EXIT

SBOX=$(make_sandbox "parchunk")
SESSION_ID="wavetask-2026-04-24"
SDIR="$SBOX/.ixion/plugin/sessions/$SESSION_ID"
mkdir -p "$SDIR"

cat > "$SDIR/spec.json" <<'EOF'
{
  "schema_version": 1,
  "summary": "Pre-seeded fixture for the parallel-chunks integration test. Phase-1 creates a shared lib.sh defining a greet function. Phase-2 and phase-3 each create an independent script sourcing lib.sh — they declare depends_on on phase-1 only and touch disjoint files, so the work skill may execute them as a concurrent wave after the foundation lands. The test asserts all three phases complete and checkpoint correctly.",
  "context": {
    "key_files": ["lib.sh", "alpha.sh", "beta.sh"],
    "patterns": [],
    "constraints": []
  },
  "phases": [
    {
      "id": "phase-1",
      "goal": "Create the shared lib.",
      "files": ["lib.sh"],
      "tasks": [
        {
          "id": "t1",
          "description": "Create lib.sh defining greet() { echo \"hello $1\"; }.",
          "files": ["lib.sh"],
          "test_scenarios": ["sourcing lib.sh and calling greet world outputs 'hello world'"]
        }
      ],
      "verification": "bash -c '. ./lib.sh && greet world | grep -q \"hello world\"'",
      "manual_verification": null,
      "depends_on": []
    },
    {
      "id": "phase-2",
      "goal": "Create alpha.sh using the lib.",
      "files": ["alpha.sh"],
      "tasks": [
        {
          "id": "t1",
          "description": "Create alpha.sh that sources lib.sh and runs greet alpha.",
          "files": ["alpha.sh"],
          "test_scenarios": ["bash alpha.sh outputs 'hello alpha'"]
        }
      ],
      "verification": "bash alpha.sh | grep -q 'hello alpha'",
      "manual_verification": null,
      "depends_on": ["phase-1"]
    },
    {
      "id": "phase-3",
      "goal": "Create beta.sh using the lib.",
      "files": ["beta.sh"],
      "tasks": [
        {
          "id": "t1",
          "description": "Create beta.sh that sources lib.sh and runs greet beta.",
          "files": ["beta.sh"],
          "test_scenarios": ["bash beta.sh outputs 'hello beta'"]
        }
      ],
      "verification": "bash beta.sh | grep -q 'hello beta'",
      "manual_verification": null,
      "depends_on": ["phase-1"]
    }
  ],
  "success_criteria": ["alpha.sh prints hello alpha", "beta.sh prints hello beta"]
}
EOF

cat > "$SDIR/session.json" <<EOF
{
  "schema_version": 1,
  "session_id": "$SESSION_ID",
  "slug": "wavetask",
  "status": "active",
  "started_at": "2026-04-24T12:00:00Z",
  "last_checkpoint_at": null,
  "active_skill": null
}
EOF

cat > "$SBOX/.ixion/plugin/active.json" <<EOF
{ "schema_version": 1, "session_id": "$SESSION_ID" }
EOF

AJV=(bunx ajv-cli --validate-formats=false --spec=draft2020)
if "${AJV[@]}" validate -s "$SCHEMAS/spec.schema.json" -d "$SDIR/spec.json" >/dev/null 2>&1; then
  note_pass "seed spec.json (with depends_on) validates"
else
  note_fail "seed spec.json did not validate (test bug, not skill bug)"
  finalize
fi

tmux_start "$SESSION" "$SBOX"

if ! wait_for_pane "$SESSION" "Quick safety check|\\? for shortcuts|Welcome back" 30; then
  note_fail "claude TUI did not start"
  finalize
fi
if tmux_capture "$SESSION" | grep -q "Quick safety check"; then
  tmux_send_line "$SESSION" ""
  wait_for_pane "$SESSION" "\\? for shortcuts|Welcome back" 15 || true
fi

tmux_send_line "$SESSION" "/work"

# Wait for progress.json to reach status=completed with all three phase ids.
# Autopilot drives the end-of-skill "Review / Ship" prompt if it appears
# before the final checkpoint lands.
deadline=420
elapsed=0
last_fire=0
done_flag=0
while [ "$elapsed" -lt "$deadline" ]; do
  if [ "$(json_field "$SDIR/progress.json" status)" = completed ] \
     && [ "$(json_lines "$SDIR/progress.json" \
               'set(doc["completed"]) & {"phase-1", "phase-2", "phase-3"}' | wc -l)" -eq 3 ]; then
    done_flag=1
    break
  fi
  now=$(date +%s)
  if [ $((now - last_fire)) -ge "$AUTOPILOT_COOLDOWN" ]; then
    if autopilot_respond "$SESSION"; then
      last_fire="$now"
    fi
  fi
  sleep 2
  elapsed=$((elapsed + 2))
done

if [ "$done_flag" = "1" ]; then
  note_pass "all three phases completed and checkpointed"
else
  note_fail "progress.json did not reach completed with all three phases within ${deadline}s"
  echo "----- progress.json -----"; cat "$SDIR/progress.json" 2>/dev/null || echo "(missing)"; echo "----- end -----"
  echo "----- pane tail -----"; tmux_capture "$SESSION"; echo "----- end -----"
  finalize
fi

if "${AJV[@]}" validate -s "$SCHEMAS/progress.schema.json" -d "$SDIR/progress.json" >/dev/null 2>&1; then
  note_pass "progress.json validates against progress.schema.json"
else
  note_fail "progress.json failed schema validation"
  echo "----- progress.json -----"; cat "$SDIR/progress.json"; echo "----- end -----"
fi

# The implementation artifacts should exist and work.
if bash -c "cd '$SBOX' && bash alpha.sh | grep -q 'hello alpha' && bash beta.sh | grep -q 'hello beta'" 2>/dev/null; then
  note_pass "alpha.sh and beta.sh both run correctly"
else
  note_fail "implementation artifacts missing or broken in sandbox"
fi

# Best-effort, non-fatal: look for wave evidence — two Task dispatches for
# phase-2/phase-3 visible in the scrollback. Model behavior is
# non-deterministic (ADR Principle 10); serial execution still passes.
if tmux capture-pane -t "$SESSION" -p -S - 2>/dev/null | grep -qiE "wave|phase-2.*phase-3|phase-3.*phase-2"; then
  echo "INFO: pane shows wave/concurrent dispatch evidence"
else
  echo "INFO: no wave evidence in pane (serial execution — acceptable, non-fatal)"
fi

finalize
