#!/usr/bin/env bash
# Integration: full Flywheel pipeline driven by /yolo in a single shot.
#
# /yolo is the autonomous orchestrator. It chains:
#   plan-creation -> plan-review -> plan-consolidation
#                 -> work (plan mode) -> work-review
#                 -> work (fix-findings mode)
#
# without any AskUserQuestion calls. Auto-resolves open questions during
# consolidation using the recommendation. Stops after one fix-cycle.
#
# Pass criteria (all artifact-based, observed in flow order):
#   1. spec.json appears                              — plan-creation done
#   2. spec.json.pre-consolidation appears AND
#      review.findings.json absent                    — consolidation done
#   3. progress.json mode=plan, status=completed      — work plan-mode done
#   4. notes.py, app.py, tests/test_notes.py present  — implementation landed
#   5. review.findings.json reappears                 — work-review done
#   6. progress.json mode=fix-findings                — work fix-findings started
#
# No autopilot. /yolo's contract is "no AskUserQuestion calls." If a child
# skill triggers a prompt anyway, this test deadlocks — and that's the
# point. The deadlock surfaces the bug instead of being papered over.
#
# Real Anthropic API calls. The full pipeline against a trivial spec
# typically takes 20-40 minutes. Plan accordingly.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$REPO_ROOT/tests/integration/lib"
SCHEMAS="$REPO_ROOT/flywheel/schemas"
. "$LIB/assert.sh"
. "$LIB/sandbox.sh"
. "$LIB/tmux.sh"

pass=0
fail=0
SESSION="flywheel-int-yolo"
SBOX=""

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

AJV=(bunx ajv-cli --validate-formats=false --spec=draft2020)

# ---- Sandbox setup ---------------------------------------------------------
SBOX=$(make_sandbox "yolo")

# No seed. The plan creates a small Python notes API from scratch — file
# I/O + HTTP handler + tests. Big enough to surface several review
# findings (path traversal, missing validation, blocking I/O, error
# paths in tests, etc.) without taking too long. Stdlib-only so no
# pip install step.

ACTIVE="$SBOX/.flywheel/plugin/active.json"
SESSIONS_DIR="$SBOX/.flywheel/plugin/sessions"

# ---- Spawn claude in tmux --------------------------------------------------
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

# ---- Single /yolo invocation drives everything ----------------------------
# Single, terse prompt. The "stdlib only" hint is deliberate: it surfaces
# during plan-review as an open question (pytest vs unittest). /yolo's
# auto-resolve rule should pick the recommended option ("stdlib only —
# tests too"), and plan-consolidation Phase 4 should propagate that
# decision INTO the spec's verification commands.
PROMPT="Build a small Python notes API with two source files and tests. notes.py is the storage layer (save_note, list_notes, read_note) writing .txt files in a data/ folder relative to cwd. app.py uses stdlib http.server on port 8000 with POST /notes (body JSON {name, content}, returns 201), GET /notes (returns JSON list of names), and GET /notes/{name} (returns JSON {content} or 404). tests/test_notes.py with unittest covers the storage layer happy paths. Stdlib only — no pip install."
tmux_send_line "$SESSION" "/yolo $PROMPT"

# ---- Milestone 1: plan-creation produces a session ------------------------
# active.json appears once plan-creation has chosen a session id.
if ! wait_for_file "$ACTIVE" 600; then
  note_fail "active.json never appeared (plan-creation stalled)"
  dump_pane; finalize
fi
SESSION_ID=$(jq -r .session_id "$ACTIVE" 2>/dev/null || echo "")
if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = "null" ]; then
  note_fail "active.json missing session_id"
  dump_pane; finalize
fi
SDIR="$SESSIONS_DIR/$SESSION_ID"
note_pass "plan-creation: session_id=$SESSION_ID"

# ---- Milestone 2: consolidation completes ---------------------------------
# Two observable transitions, in order:
#   - Phase 1: spec.json.pre-consolidation sidecar appears
#   - Phase 6: review.findings.json deleted (consumed) AND spec.json rewritten
# True end-of-consolidation signal: sidecar present AND findings absent.
i=0
consolidated=false
while [ "$i" -lt 1500 ]; do
  if [ -f "$SDIR/spec.json.pre-consolidation" ] && [ ! -f "$SDIR/review.findings.json" ]; then
    consolidated=true
    break
  fi
  sleep 5
  i=$((i + 5))
done

if [ "$consolidated" = "true" ]; then
  note_pass "plan-consolidation completed: sidecar present, findings consumed"
else
  note_fail "plan-consolidation did not complete in 25min (pre-consolidation=$(test -f "$SDIR/spec.json.pre-consolidation" && echo yes || echo no), findings=$(test -f "$SDIR/review.findings.json" && echo present || echo absent))"
  dump_pane; finalize
fi

if "${AJV[@]}" validate -s "$SCHEMAS/task-list.schema.json" -d "$SDIR/spec.json" >/dev/null 2>&1; then
  note_pass "consolidated spec.json validates"
else
  note_fail "consolidated spec.json failed schema validation"
  echo "----- validation error -----"
  "${AJV[@]}" validate -s "$SCHEMAS/task-list.schema.json" -d "$SDIR/spec.json" 2>&1 | head -20
  echo "----- file content -----"
  cat "$SDIR/spec.json" 2>/dev/null || echo "(file unreadable)"
  echo "----- end -----"
fi

# Skill-invocation assertions: each step's skill should appear in the pane
# as "Skill(<name>)". Catches the failure mode where the agent does the
# skill's work inline instead of invoking the skill (run 4) or invokes
# the skill but doesn't act on its instructions (run 5). Pane shows the
# truth; artifacts on disk only confirm the skill ran AND completed.
for skill in plan-creation plan-review plan-consolidation; do
  if pane_has_skill_invocation "$SESSION" "$skill"; then
    note_pass "pane shows Skill($skill) was invoked"
  else
    note_fail "Skill($skill) marker not found in pane — agent may have compressed the skill"
  fi
done

# Decision-propagation assertion: plan-review surfaces an open question
# about whether 'stdlib only' applies to tests (pytest vs unittest). /yolo's
# auto-resolve rule picks the recommended answer ("stdlib only — tests too").
# Plan-consolidation Phase 4 must propagate that decision INTO the spec —
# verification commands and task descriptions should reflect unittest, NOT
# pytest. If pytest still appears in verification commands after consolidation,
# the decision evaporated into conversation history and the implementer will
# produce wrong output.
verifications=$(jq -r '.phases[].verification' "$SDIR/spec.json" 2>/dev/null)
if echo "$verifications" | grep -qi "pytest"; then
  note_fail "consolidated spec verification uses pytest — 'stdlib only' decision not propagated into spec"
  echo "----- verification commands -----"
  echo "$verifications"
  echo "----- end -----"
elif echo "$verifications" | grep -qi "unittest"; then
  note_pass "consolidated spec verification uses unittest (decision propagated)"
else
  note_fail "consolidated spec verification uses neither pytest nor unittest — propagation unclear"
  echo "----- verification commands -----"
  echo "$verifications"
  echo "----- end -----"
fi

# ---- Milestone 3: work plan-mode completes --------------------------------
# /yolo flows directly into work after consolidation. Wait for status=completed
# AND mode=plan.
i=0
plan_done=false
while [ "$i" -lt 1500 ]; do
  if [ -f "$SDIR/progress.json" ]; then
    status=$(jq -r '.status // ""' "$SDIR/progress.json" 2>/dev/null || echo "")
    mode=$(jq -r '.mode // ""' "$SDIR/progress.json" 2>/dev/null || echo "")
    if [ "$status" = "completed" ] && [ "$mode" = "plan" ]; then
      plan_done=true
      break
    fi
  fi
  sleep 5
  i=$((i + 5))
done

if [ "$plan_done" = "true" ]; then
  note_pass "/yolo work plan-mode: status=completed, mode=plan"
else
  note_fail "/yolo did not finish work plan-mode within 25min"
  echo "----- progress.json -----"; cat "$SDIR/progress.json" 2>/dev/null; echo "----- end -----"
  dump_pane; finalize
fi

if pane_has_skill_invocation "$SESSION" "work"; then
  note_pass "pane shows Skill(work) was invoked"
else
  note_fail "Skill(work) marker not found in pane — agent may have compressed work plan-mode"
fi

# Implementation should have created the notes API. The plan enumerates
# notes.py, app.py, and tests/test_notes.py — the executor should produce
# all three.
if [ -f "$SBOX/notes.py" ]; then
  note_pass "notes.py was created"
else
  note_fail "notes.py was NOT created"
fi
if [ -f "$SBOX/app.py" ]; then
  note_pass "app.py was created"
else
  note_fail "app.py was NOT created"
fi
if [ -f "$SBOX/tests/test_notes.py" ]; then
  note_pass "tests/test_notes.py was created"
else
  note_fail "tests/test_notes.py was NOT created"
fi

# ---- Milestone 4: work-review writes findings -----------------------------
# /yolo proceeds to work-review automatically. Wait for review.findings.json
# to reappear (it was consumed earlier by plan-consolidation; this is the
# work-review output, not the plan-review output).
i=0
review_done=false
while [ "$i" -lt 1500 ]; do
  if [ -f "$SDIR/review.findings.json" ]; then
    review_done=true
    break
  fi
  sleep 5
  i=$((i + 5))
done

if [ "$review_done" = "true" ]; then
  note_pass "/yolo work-review: review.findings.json produced"
else
  note_fail "/yolo did not produce work-review findings within 25min"
  dump_pane; finalize
fi

if pane_has_skill_invocation "$SESSION" "work-review"; then
  note_pass "pane shows Skill(work-review) was invoked"
else
  note_fail "Skill(work-review) marker not found in pane — agent may have compressed work-review"
fi

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

# ---- Milestone 5: work transitions to fix-findings mode -------------------
# /yolo's last step is the fix-cycle: invoke work again, which auto-detects
# fix-findings mode (progress.json.mode=plan, status=completed,
# review.findings.json present). The transition rewrites progress.json
# to mode=fix-findings and (canonically) archives the plan-mode progress
# to progress.json.plan-mode.
i=0
transitioned=false
while [ "$i" -lt 1200 ]; do
  if [ -f "$SDIR/progress.json" ]; then
    mode=$(jq -r '.mode // ""' "$SDIR/progress.json" 2>/dev/null || echo "")
    if [ "$mode" = "fix-findings" ]; then transitioned=true; break; fi
  fi
  sleep 5
  i=$((i + 5))
done

if [ "$transitioned" = "true" ]; then
  note_pass "/yolo work fix-findings: progress.json transitioned to mode=fix-findings"
else
  note_fail "progress.json.mode never became fix-findings within 20min"
  echo "----- progress.json -----"; cat "$SDIR/progress.json" 2>/dev/null; echo "----- end -----"
  dump_pane; finalize
fi

if [ -f "$SDIR/progress.json.plan-mode" ]; then
  note_pass "plan-mode progress was archived (canonical transition path)"
else
  echo "INFO: progress.json.plan-mode absent — model transitioned without archiving plan-mode history"
fi

# Validate the fix-findings progress.json against the schema.
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

finalize
