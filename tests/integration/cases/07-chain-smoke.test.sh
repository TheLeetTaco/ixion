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
# Asserts both halves of ADR-001 Principle 12 — artifact on disk AND the
# invocation visible in the pane: a Skill(<name>) tool call for the three
# skills `plan` loads itself, the echoed command for the two this harness
# types (which emit no tool call — see lib/tmux.sh).

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$REPO_ROOT/tests/integration/lib"
SCHEMAS="$REPO_ROOT/ixion/schemas"
. "$LIB/assert.sh"
. "$LIB/sandbox.sh"
. "$LIB/tmux.sh"
. "$LIB/json.sh"

SESSION="ixion-int-chain"
SBOX=""
WORKTREE=""
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
# `--all-features` is deliberately not in this list, for the reason the
# session-tier gates below are INFO: the fixture declares no features, so the
# flag is exactly a no-op on it and language-standards now says to omit it
# there. Two live runs omitted it and were right to. `--locked` and
# `--all-targets` are not fixture-dependent — a lockfile exists and a test
# exists — so they stay hard assertions, and both were genuinely missed once
# across those same two runs.
PHASE_GATE_FLAGS=(--all-targets --locked)
CHUNK_GATE_FLAGS=(--locked)

# Session-tier gates run once from work Phase 3, never per phase.
SESSION_GATE_RE="cargo (audit|machete)"

# unflagged_gates <expression> <file> <flag>... — prints the flags that no
# command string <expression> yields carries; empty output means every flag
# reached the artifact. Both gated artifacts reduce to a list of command
# strings, so one check serves both once the caller names its tier's flags.
unflagged_gates() {
  local expression=$1 file=$2 flag commands
  shift 2
  commands=$(json_lines "$file" "$expression")
  for flag in "$@"; do
    printf '%s\n' "$commands" | grep -q -e "$flag" || printf '%s ' "$flag"
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
  json_lines "$SDIR/progress.json" 'doc["artifacts"]["commands_run"]' || echo "(unreadable)"
  echo "----- end -----"
}

cleanup() {
  pane_save_history "$SESSION"
  tmux_kill "$SESSION"
  preserve_sandbox "$SBOX"
  preserve_sandbox "$WORKTREE"
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
# The namespace is what every other invocation surface uses, so testing the
# bare form was testing a path nobody drives; `02-fly-plan-creates-spec` sends
# the namespaced form for the same reason.
tmux_send_line "$SESSION" "/ixion:plan $PROMPT"

if ! wait_for_file_with_autopilot "$SESSION" "$ACTIVE" 300; then
  note_fail "active.json never appeared (plan-creation stalled)"
  dump_pane; finalize
fi
SESSION_ID=$(json_field "$ACTIVE" session_id)
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

# Each skill writes its terminal artifact and then asks what to do next, so the
# loops above can break while a dialog still owns the input box. Clear it before
# typing, or the next slash command is swallowed as an answer.
drain_dialogs "$SESSION" || echo "INFO: a dialog was still up after consolidation"

# Coverage carried from 03: the CONSOLIDATED spec, not just a fresh one.
validate_artifact spec.schema.json "$SDIR/spec.json" "consolidated spec.json"

# A valid spec is not a gated one: plan-creation must have read the Tooling
# Gates list and chained it into the phases it wrote flags and all — not
# settled for the bare `cargo test` a schema check would accept just as
# happily, nor for the under-flagged forms the fix replaced.
UNFLAGGED=$(unflagged_gates '[p["verification"] for p in doc["phases"]]' "$SDIR/spec.json" "${PHASE_GATE_FLAGS[@]}")
if [ -z "$UNFLAGGED" ]; then
  note_pass "spec composed fully-flagged per-phase gates into phase verifications"
else
  note_fail "no phase verification carries: $UNFLAGGED"
  echo "----- phase verifications -----"
  json_lines "$SDIR/spec.json" '[p["verification"] for p in doc["phases"]]' || echo "(unreadable)"
  echo "----- end -----"
fi

# Reported, not asserted, and only meaningful on a fixture with features —
# which this one does not have. A run that starts carrying it here means the
# planner is adding the flag where it does nothing, which is the failure in
# the other direction and worth seeing.
ALLFEAT=$(json_lines "$SDIR/spec.json" '[p["verification"] for p in doc["phases"]]' | grep -c -e --all-features)
echo "INFO: phase verifications carrying --all-features: $ALLFEAT (0 is expected for this feature-less fixture)"

# Session-tier gates (cargo audit, cargo machete) belong in success_criteria[],
# which work Phase 3 checks once. This is INFO, not an assertion, and the reason
# is the fixture: it is deliberately dependency-free ("Std only — no external
# crates") so the run stays offline, and both session gates operate on a
# dependency graph. `cargo audit` scans advisories for dependencies that do not
# exist; `cargo machete` hunts unused ones in a crate with none. A planner that
# omits them here is right to, so failing on their absence would fail a correct
# run — and a gate that blocks correct work is the one that gets deleted.
#
# Making this a real gate needs a fixture with at least one dependency, which
# costs the offline property the fixture was built around. Until someone decides
# that trade, the line below reports what happened without pretending to judge it.
SESSION_CRITERIA=$(json_lines "$SDIR/spec.json" 'doc["success_criteria"]' | grep -cE "$SESSION_GATE_RE")
echo "INFO: session-tier gates in success_criteria: $SESSION_CRITERIA (0 is expected for this dependency-free fixture)"

# ---- Step 2: /work in plan mode -------------------------------------------
tmux_send_line "$SESSION" "/work"

i=0; plan_done=false; last_fire=0
while [ "$i" -lt 900 ]; do
  status=$(json_field "$SDIR/progress.json" status)
  mode=$(json_field "$SDIR/progress.json" mode)
  [ "$status" = "completed" ] && [ "$mode" = "plan" ] && { plan_done=true; break; }
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

# `work` Phase 5 marks the session completed *before* it offers the next step,
# so this poll reaches here with that prompt open by design.
drain_dialogs "$SESSION" || echo "INFO: a dialog was still up after work plan-mode"

# Phase 3 appends its gate record to THIS progress.json, and the fix-findings
# transition below renames it away — validate the shape while the file still
# carries its canonical name. The fix-findings copy validated at the end is
# written fresh with empty artifacts, so it can never cover these entries.
validate_artifact progress.schema.json "$SDIR/progress.json" "plan-mode progress.json"

# The work is in the session worktree, not the sandbox: work cuts
# `<sandbox>-<slug>` beside the repository root and commits each chunk there,
# the slug being the session id minus its date (the derivation
# session-handoff.md's "Derive the session worktree" block makes). That tree is
# a sibling of the project directory, so neither the orchestrator's cd nor a
# subagent's start there by default — a run that edited and committed in the
# sandbox instead passes every check above and builds nothing the PR would
# carry. This is the assertion that catches the dispatch losing the path.
SLUG=${SESSION_ID%-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]}
WORKTREE="$SBOX-$SLUG"
if [ -d "$WORKTREE" ] && [ "$(git -C "$WORKTREE" log --format=%b 2>/dev/null | grep -c '^Ixion-Chunk:')" -ge 1 ]; then
  note_pass "chunk commits landed in the session worktree ($WORKTREE)"
else
  note_fail "no session worktree holding Ixion-Chunk commits at $WORKTREE — work committed somewhere else"
  echo "----- worktrees -----"; git -C "$SBOX" worktree list 2>/dev/null || true; echo "----- end -----"
fi

# That tree outlives the session and only the user retires it, so `work` has to
# hand the command over — a user who merges the branch directly and never runs
# `ship` is otherwise never offered it. The path is what makes the assertion
# mean something: a block still carrying its `<worktree=...>` placeholder has
# the words and names no tree. Full scrollback (-S -) the way pane_ran_command
# reads it, since the closing block is long since scrolled past; the path is
# looked for in the surrounding lines because the block may assign it above the
# command rather than spell it inside.
if tmux capture-pane -t "$SESSION" -p -S - 2>/dev/null \
     | grep -F -B 6 -A 2 'git worktree remove' | grep -Fq "$WORKTREE"; then
  note_pass "work printed the command that retires $WORKTREE"
else
  note_fail "no 'git worktree remove' naming $WORKTREE in the pane — work's closing block never handed the retirement command over"
fi

# Composing a gate is not running one. A subagent that loaded the per-chunk
# gate as written leaves its flagged command text here; one that settled for a
# bare `cargo check` does not. Entries are ceremony and may be objects or bare
# strings, so the flag is matched against whichever one the entry renders as.
UNFLAGGED=$(unflagged_gates 'doc["artifacts"]["commands_run"]' "$SDIR/progress.json" "${CHUNK_GATE_FLAGS[@]}")
if [ -z "$UNFLAGGED" ]; then
  note_pass "work ran the per-chunk gate with its flags"
else
  note_fail "commands_run[] records no per-chunk gate carrying: $UNFLAGGED"
  dump_commands_run
fi

# Downstream of the criteria above, so it inherits their limitation: with no
# session-tier gate in success_criteria there is nothing for Phase 3 to run, and
# an empty result here is correct rather than a defect. INFO for the same reason.
SESSION_RUNS=$(json_lines "$SDIR/progress.json" 'doc["artifacts"]["commands_run"]' | grep -cE "$SESSION_GATE_RE")
echo "INFO: session-tier gate results in commands_run: $SESSION_RUNS"

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

FINDING_COUNT=$(json_lines "$SDIR/review.findings.json" 'doc["findings"]' | wc -l)
echo "INFO: work-review surfaced $FINDING_COUNT findings"

drain_dialogs "$SESSION" || echo "INFO: a dialog was still up after work-review"

# ---- Step 4: /work again -> fix-findings mode, auto-detected --------------
# THE load-bearing assertion. work must switch modes from session state
# alone. If this fails, removing /yolo broke something real.
tmux_send_line "$SESSION" "/work"

i=0; fix_mode=false; last_fire=0
while [ "$i" -lt 900 ]; do
  mode=$(json_field "$SDIR/progress.json" mode)
  [ "$mode" = "fix-findings" ] && { fix_mode=true; break; }
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
# Split by who invokes it. The three below are loaded by `plan` on the agent's
# own initiative, so a missing Skill() marker means it compressed the skill
# into inline reasoning — the failure Principle 12 exists to catch.
for skill in plan-creation plan-review plan-consolidation; do
  if pane_has_skill_invocation "$SESSION" "$skill"; then
    note_pass "pane shows Skill($skill) was invoked"
  else
    note_fail "Skill($skill) marker not found in pane — agent may have compressed the skill"
  fi
done

# These two the harness types, so the command loads the skill and no tool call
# is emitted; asserting a Skill() marker for them fails on a correct run. What
# is worth asserting is that each command reached the prompt — the dialog-race
# drain_dialogs above exists to prevent.
for skill in work work-review; do
  if pane_ran_command "$SESSION" "$skill"; then
    note_pass "pane shows the $skill command reached the prompt"
  else
    note_fail "no /$skill command echoed in pane — the keystroke never landed"
  fi
done

finalize
