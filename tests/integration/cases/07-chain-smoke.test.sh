#!/usr/bin/env bash
# Integration: full-chain smoke, driven skill-by-skill.
#
# Replaces the deleted 03-pipeline-end-to-end and 04-pipeline-smoke, which
# both drove the chain through /yolo in one shot. With /yolo gone the chain
# still needs coverage, so this test invokes each skill as its own command:
#
#   /plan  -> plan-creation -> plan-review -> plan-consolidation
#   /work         (plan mode)
#   /work-review
#   /work         (fix-findings mode, auto-detected from session state)
#
# That last transition is the load-bearing claim /yolo's removal rests on:
# work decides fix-findings mode from session state (completed plan-mode
# progress.json + present review.findings.json), NOT from an orchestrator.
#
# Because no orchestrator is pre-answering prompts any more, the skills'
# AskUserQuestion dialogs are live. wait_for_file_with_autopilot drives
# them (lib/tmux.sh) — without it, plan-consolidation deadlocks on open
# questions. Trivial fixture and a small model keep this cheap (~10 min).
#
# Carries forward the three schema validations that existed only in 03:
# consolidated spec.json, generated review.findings.json, and fix-findings
# progress.json. Asserts both halves of ADR-001 Principle 12 — artifact on
# disk AND Skill(<name>) marker in the pane.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$REPO_ROOT/tests/integration/lib"
SCHEMAS="$REPO_ROOT/ixion/schemas"
. "$LIB/assert.sh"
. "$LIB/sandbox.sh"
. "$LIB/tmux.sh"

SESSION="ixion-int-chain"
SBOX=""
AJV=(bunx ajv-cli --validate-formats=false --spec=draft2020)

# The per-phase Rust gates that language-standards adds beyond `cargo test`.
# Both toolchain components ship with rustup, so a spec that composes them
# produces commands that really run here.
GATE_RE="clippy|fmt"

dump_pane() {
  echo "----- pane tail -----"
  tmux_capture "$SESSION" 2>/dev/null || true
  echo "----- end -----"
}

cleanup() {
  pane_save_history "$SESSION"
  tmux_kill "$SESSION"
  preserve_sandbox "$SBOX"
}
trap cleanup EXIT

# ---- Sandbox setup ---------------------------------------------------------
SBOX=$(make_sandbox "chain")
ACTIVE="$SBOX/.ixion/plugin/active.json"
SESSIONS_DIR="$SBOX/.ixion/plugin/sessions"

# ---- Spawn claude in tmux (small model — this is a transition smoke) -------
export IXION_TEST_MODEL="${IXION_TEST_MODEL:-claude-haiku-4-5-20251001}"
tmux_start "$SESSION" "$SBOX"

if ! wait_for_pane "$SESSION" "Quick safety check|\\? for shortcuts|Welcome back" 30; then
  note_fail "claude TUI did not start"
  dump_pane; finalize
fi
if tmux_capture "$SESSION" | grep -q "Quick safety check"; then
  tmux_send_line "$SESSION" ""
  wait_for_pane "$SESSION" "\\? for shortcuts|Welcome back" 15 || true
fi
note_pass "claude TUI started"

# Trivial fixture: one function, one test, no external crates so the run stays
# offline and fast. The prompt says nothing about the toolchain, which leaves
# plan-creation free to compose the language-standards gates — the thing the
# GATE_RE assertions below are here to catch.
PROMPT="Create a Rust library with one function double(n: i64) -> i64 that returns n * 2, with a unit test in the same file. Std only — no external crates."

# ---- Step 1: /plan drives creation -> review -> consolidation --------------
# NOTE: bare "/plan" is what 02-fly-plan-creates-spec sends. If the host
# Claude Code build resolves /plan to its own built-in plan mode instead of
# the plugin skill, this and 02 fail the same way — that is a plugin-naming
# bug to fix at the source, not something to work around here.
tmux_send_line "$SESSION" "/plan $PROMPT"

if ! wait_for_file_with_autopilot "$SESSION" "$ACTIVE" 300; then
  note_fail "active.json never appeared (plan-creation stalled)"
  dump_pane; finalize
fi
SESSION_ID=$(jq -r .session_id "$ACTIVE" 2>/dev/null || echo "")
SDIR="$SESSIONS_DIR/$SESSION_ID"
if wait_for_file_with_autopilot "$SESSION" "$SDIR/spec.json" 180; then
  note_pass "plan-creation wrote spec.json"
else
  note_fail "spec.json missing after plan-creation"
  dump_pane; finalize
fi

# Consolidation is done when the sidecar exists AND findings were consumed.
# Autopilot keeps firing throughout — this is the stretch that deadlocks
# without it, since consolidation asks about open questions.
i=0; consolidated=false; last_fire=0
while [ "$i" -lt 900 ]; do
  if [ -f "$SDIR/spec.json.pre-consolidation" ] && [ ! -f "$SDIR/review.findings.json" ]; then
    consolidated=true; break
  fi
  now=$(date +%s)
  if [ $((now - last_fire)) -ge "$AUTOPILOT_COOLDOWN" ]; then
    if autopilot_respond "$SESSION"; then last_fire="$now"; fi
  fi
  sleep 5; i=$((i + 5))
done
if [ "$consolidated" = "true" ]; then
  note_pass "plan-review + plan-consolidation completed"
else
  note_fail "consolidation did not complete in 15min"
  dump_pane; finalize
fi

# Coverage carried from 03: the CONSOLIDATED spec, not just a fresh one.
if "${AJV[@]}" validate -s "$SCHEMAS/spec.schema.json" -d "$SDIR/spec.json" >/dev/null 2>&1; then
  note_pass "consolidated spec.json validates"
else
  note_fail "consolidated spec.json failed schema validation"
  echo "----- validation error -----"
  "${AJV[@]}" validate -s "$SCHEMAS/spec.schema.json" -d "$SDIR/spec.json" 2>&1 | head -20
  echo "----- file content -----"
  cat "$SDIR/spec.json" 2>/dev/null || echo "(file unreadable)"
  echo "----- end -----"
fi

# A valid spec is not a gated one: plan-creation must have read the Tooling
# Gates list and chained it into the phases it wrote, not settled for the bare
# `cargo test` a schema check would accept just as happily.
GATED_PHASES=$(jq --arg re "$GATE_RE" '[.phases[] | select(.verification | test($re))] | length' "$SDIR/spec.json" 2>/dev/null || echo 0)
if [ "$GATED_PHASES" -gt 0 ]; then
  note_pass "spec composed a lint/format gate into $GATED_PHASES phase verification(s)"
else
  note_fail "no phase verification names a gate beyond cargo test"
  echo "----- phase verifications -----"
  jq -r '.phases[].verification' "$SDIR/spec.json" 2>/dev/null || echo "(unreadable)"
  echo "----- end -----"
fi

# ---- Step 2: /work in plan mode -------------------------------------------
tmux_send_line "$SESSION" "/work"

i=0; plan_done=false; last_fire=0
while [ "$i" -lt 900 ]; do
  if [ -f "$SDIR/progress.json" ]; then
    status=$(jq -r '.status // ""' "$SDIR/progress.json" 2>/dev/null || echo "")
    mode=$(jq -r '.mode // ""' "$SDIR/progress.json" 2>/dev/null || echo "")
    [ "$status" = "completed" ] && [ "$mode" = "plan" ] && { plan_done=true; break; }
  fi
  now=$(date +%s)
  if [ $((now - last_fire)) -ge "$AUTOPILOT_COOLDOWN" ]; then
    if autopilot_respond "$SESSION"; then last_fire="$now"; fi
  fi
  sleep 5; i=$((i + 5))
done
if [ "$plan_done" = "true" ]; then
  note_pass "work plan-mode completed"
else
  note_fail "work plan-mode did not complete in 15min"
  dump_pane; finalize
fi

# Composing a gate is not running one. work records every verification and
# success_criteria command it ran as a commands_run entry, so a gate that
# actually executed leaves its command text here. Entries are ceremony and may
# be objects or bare strings, hence tostring before matching.
GATE_RUNS=$(jq --arg re "$GATE_RE" '[.artifacts.commands_run[]? | tostring | select(test($re))] | length' "$SDIR/progress.json" 2>/dev/null || echo 0)
if [ "$GATE_RUNS" -gt 0 ]; then
  note_pass "work ran $GATE_RUNS gated command(s) beyond cargo test"
else
  note_fail "commands_run[] records no gate beyond cargo test"
  echo "----- commands_run -----"
  jq -r '.artifacts.commands_run' "$SDIR/progress.json" 2>/dev/null || echo "(unreadable)"
  echo "----- end -----"
fi

# ---- Step 3: /work-review -------------------------------------------------
tmux_send_line "$SESSION" "/work-review"

if wait_for_file_with_autopilot "$SESSION" "$SDIR/review.findings.json" 900; then
  note_pass "work-review wrote review.findings.json"
else
  note_fail "work-review findings did not appear in 15min"
  dump_pane; finalize
fi

# Coverage carried from 03: the only validation of a GENERATED findings file
# anywhere in the suite (CI validates only the static example).
if "${AJV[@]}" validate -s "$SCHEMAS/findings.schema.json" -d "$SDIR/review.findings.json" >/dev/null 2>&1; then
  note_pass "work-review findings validate"
else
  note_fail "work-review findings failed schema validation"
  echo "----- validation error -----"
  "${AJV[@]}" validate -s "$SCHEMAS/findings.schema.json" -d "$SDIR/review.findings.json" 2>&1 | head -20
  echo "----- file content -----"
  cat "$SDIR/review.findings.json" 2>/dev/null || echo "(file unreadable)"
  echo "----- end -----"
fi

FINDING_COUNT=$(jq '.findings | length' "$SDIR/review.findings.json" 2>/dev/null || echo 0)
echo "INFO: work-review surfaced $FINDING_COUNT findings"

# ---- Step 4: /work again -> fix-findings mode, auto-detected --------------
# THE load-bearing assertion. work must switch modes from session state
# alone. If this fails, removing /yolo broke something real.
tmux_send_line "$SESSION" "/work"

i=0; fix_mode=false; last_fire=0
while [ "$i" -lt 900 ]; do
  if [ -f "$SDIR/progress.json" ]; then
    mode=$(jq -r '.mode // ""' "$SDIR/progress.json" 2>/dev/null || echo "")
    [ "$mode" = "fix-findings" ] && { fix_mode=true; break; }
  fi
  now=$(date +%s)
  if [ $((now - last_fire)) -ge "$AUTOPILOT_COOLDOWN" ]; then
    if autopilot_respond "$SESSION"; then last_fire="$now"; fi
  fi
  sleep 5; i=$((i + 5))
done
if [ "$fix_mode" = "true" ]; then
  note_pass "work auto-detected fix-findings mode from session state"
else
  note_fail "work did not enter fix-findings mode in 15min — mode detection may be broken"
  dump_pane; finalize
fi

if [ -f "$SDIR/progress.json.plan-mode" ]; then
  note_pass "plan-mode progress was archived (canonical transition path)"
else
  echo "INFO: progress.json.plan-mode absent — model transitioned without archiving plan-mode history"
fi

# Coverage carried from 03: fix-findings progress, not just plan-mode.
if "${AJV[@]}" validate -s "$SCHEMAS/progress.schema.json" -d "$SDIR/progress.json" >/dev/null 2>&1; then
  note_pass "fix-findings progress.json validates"
else
  note_fail "fix-findings progress.json failed schema validation"
  echo "----- validation error -----"
  "${AJV[@]}" validate -s "$SCHEMAS/progress.schema.json" -d "$SDIR/progress.json" 2>&1 | head -20
  echo "----- file content -----"
  cat "$SDIR/progress.json" 2>/dev/null || echo "(file unreadable)"
  echo "----- end -----"
fi

# ---- Pane markers: every skill actually invoked (not compressed inline) ----
for skill in plan-creation plan-review plan-consolidation work work-review; do
  if pane_has_skill_invocation "$SESSION" "$skill"; then
    note_pass "pane shows Skill($skill) was invoked"
  else
    note_fail "Skill($skill) marker not found in pane — agent may have compressed the skill"
  fi
done

finalize
