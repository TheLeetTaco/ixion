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
# progress.json — plus the plan-mode progress.json, the one work Phase 3
# appends its gate record to and the one the transition renames away.
# Asserts both halves of ADR-001 Principle 12 — artifact on disk AND
# Skill(<name>) marker in the pane.

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

# Gates are asserted by the flags language-standards adds, not by command
# name: `clippy` and `fmt` both predate the fix, so a spec regressed to
# `cargo clippy -- -D warnings` plus a bare `cargo test` would satisfy a
# name-keyed check identically to a correct one. Every flag below has a zero
# baseline in the pre-fix gate list.
#
# The bar differs by artifact because the tiers do. The per-phase set is
# plan-creation's contract and must appear in the spec's phase verifications;
# clippy and rustfmt ship with rustup, so those commands really run here. But
# `progress.commands_run` holds only what subagents return (work 2.3 step 4),
# and a subagent is told to run just the gate language-standards tags
# per-chunk — `cargo check --locked`. The orchestrator's own verification run
# is captured as an exit code, not as an entry, so demanding the per-phase
# flags there would fail a correct run.
PHASE_GATE_FLAGS=(--all-targets --all-features --locked)
CHUNK_GATE_FLAGS=(--locked)

# Session-tier gates run once from work Phase 3, never per phase.
SESSION_GATE_RE="cargo (audit|machete)"

# unflagged_gates <jq-filter> <file> <flag>... — prints the flags that no
# command string produced by <jq-filter> carries; empty output means every
# flag reached the artifact. Both gated artifacts reduce to a list of command
# strings, so one check serves both once the caller names its tier's flags.
unflagged_gates() {
  local jq_filter=$1 file=$2 flag hits
  shift 2
  for flag in "$@"; do
    hits=$(jq --arg f "$flag" "$jq_filter | map(select(test(\$f))) | length" "$file" 2>/dev/null || echo 0)
    [ "$hits" -gt 0 ] || printf '%s ' "$flag"
  done
}

# A failing artifact is unreadable from an exit code, so dump the ajv
# complaint and the file alongside the verdict.
validate_artifact() {
  local schema=$1 file=$2 label=$3
  if "${AJV[@]}" validate -s "$SCHEMAS/$schema" -d "$file" >/dev/null 2>&1; then
    note_pass "$label validates"
    return
  fi
  note_fail "$label failed schema validation"
  echo "----- validation error -----"
  "${AJV[@]}" validate -s "$SCHEMAS/$schema" -d "$file" 2>&1 | head -20
  echo "----- file content -----"
  cat "$file" 2>/dev/null || echo "(file unreadable)"
  echo "----- end -----"
}

dump_pane() {
  echo "----- pane tail -----"
  tmux_capture "$SESSION" 2>/dev/null || true
  echo "----- end -----"
}

dump_commands_run() {
  echo "----- commands_run -----"
  jq -r '.artifacts.commands_run' "$SDIR/progress.json" 2>/dev/null || echo "(unreadable)"
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
# gate assertions below are here to catch.
PROMPT="Create a Rust library with one function double(n: i64) -> i64 that returns n * 2, with a unit test in the same file. Std only — no external crates."

# ---- Step 1: /plan drives creation -> review -> consolidation --------------
# Namespaced because bare "/plan" resolves to Claude Code's own plan mode, not
# the plugin skill: the TUI answers "Enabled plan mode" and writes a
# conversational plan, so no session dir is ever created and the run fails at
# the active.json wait with nothing to show for it. Observed on 2.1.220.
#
# This file used to say the shadowing was a plugin-naming bug to fix at the
# source rather than route around here, and that is still the better fix. The
# namespace is what every other invocation surface uses, though, so testing the
# bare form was testing a path nobody drives. `02-fly-plan-creates-spec` still
# sends bare "/plan" and still fails this way.
tmux_send_line "$SESSION" "/ixion:plan $PROMPT"

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
validate_artifact spec.schema.json "$SDIR/spec.json" "consolidated spec.json"

# A valid spec is not a gated one: plan-creation must have read the Tooling
# Gates list and chained it into the phases it wrote flags and all — not
# settled for the bare `cargo test` a schema check would accept just as
# happily, nor for the under-flagged forms the fix replaced.
UNFLAGGED=$(unflagged_gates '[.phases[].verification]' "$SDIR/spec.json" "${PHASE_GATE_FLAGS[@]}")
if [ -z "$UNFLAGGED" ]; then
  note_pass "spec composed fully-flagged per-phase gates into phase verifications"
else
  note_fail "no phase verification carries: $UNFLAGGED"
  echo "----- phase verifications -----"
  jq -r '.phases[].verification' "$SDIR/spec.json" 2>/dev/null || echo "(unreadable)"
  echo "----- end -----"
fi

# The session tier lives in success_criteria[], which work Phase 3 checks
# once — a spec that scattered `cargo audit` across phase verifications, or
# dropped it, fails here.
SESSION_CRITERIA=$(jq --arg re "$SESSION_GATE_RE" '[.success_criteria[] | select(test($re))] | length' "$SDIR/spec.json" 2>/dev/null || echo 0)
if [ "$SESSION_CRITERIA" -gt 0 ]; then
  note_pass "spec routed $SESSION_CRITERIA session-tier gate(s) into success_criteria"
else
  note_fail "success_criteria names no session-tier gate (cargo audit / cargo machete)"
  echo "----- success_criteria -----"
  jq -r '.success_criteria[]' "$SDIR/spec.json" 2>/dev/null || echo "(unreadable)"
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

# Phase 3 appends its gate record to THIS progress.json, and the fix-findings
# transition below renames it away — validate the shape while the file still
# carries its canonical name. The fix-findings copy validated at the end is
# written fresh with empty artifacts, so it can never cover these entries.
validate_artifact progress.schema.json "$SDIR/progress.json" "plan-mode progress.json"

# Composing a gate is not running one. A subagent that loaded the per-chunk
# gate as written leaves its flagged command text here; one that settled for a
# bare `cargo check` does not. Entries are ceremony and may be objects or bare
# strings, hence tostring before matching.
UNFLAGGED=$(unflagged_gates '[.artifacts.commands_run[]? | tostring]' "$SDIR/progress.json" "${CHUNK_GATE_FLAGS[@]}")
if [ -z "$UNFLAGGED" ]; then
  note_pass "work ran the per-chunk gate with its flags"
else
  note_fail "commands_run[] records no per-chunk gate carrying: $UNFLAGGED"
  dump_commands_run
fi

# The session tier's payoff: Phase 3 runs it once and quotes the output.
# cargo-audit and cargo-machete are absent from the test host, so what should
# land is the presence probe's `SKIPPED:` line — recorded verbatim, since a
# paraphrased "clean" is indistinguishable from a real pass.
SESSION_RUNS=$(jq --arg re "$SESSION_GATE_RE" '[.artifacts.commands_run[]? | tostring | select(test($re))] | length' "$SDIR/progress.json" 2>/dev/null || echo 0)
if [ "$SESSION_RUNS" -gt 0 ]; then
  note_pass "work Phase 3 recorded $SESSION_RUNS session-tier gate result(s)"
else
  note_fail "commands_run[] records no session-tier gate (ran or SKIPPED:)"
  dump_commands_run
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
validate_artifact findings.schema.json "$SDIR/review.findings.json" "work-review findings"

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
validate_artifact progress.schema.json "$SDIR/progress.json" "fix-findings progress.json"

# ---- Pane markers: every skill actually invoked (not compressed inline) ----
for skill in plan-creation plan-review plan-consolidation work work-review; do
  if pane_has_skill_invocation "$SESSION" "$skill"; then
    note_pass "pane shows Skill($skill) was invoked"
  else
    note_fail "Skill($skill) marker not found in pane — agent may have compressed the skill"
  fi
done

finalize
