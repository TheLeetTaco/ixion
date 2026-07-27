#!/usr/bin/env bash
# Smoke: plugin loads and exposes its skills as slash commands.
#
# Spawns claude in a tmux session with the local plugin loaded via
# --plugin-dir, opens the slash-command palette by typing distinct
# ixion-skill prefixes, and asserts that the expected skills appear
# in the autocompletion list.
#
# This is the cheapest test in the suite — claude does not actually
# invoke any skill or call the model. It only confirms that
# .claude-plugin metadata + skills/ are discoverable.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$REPO_ROOT/tests/integration/lib"
. "$LIB/assert.sh"
. "$LIB/sandbox.sh"
. "$LIB/tmux.sh"

pass=0
fail=0
SESSION="ixion-int-plugin-loads"
SBOX=""

cleanup() {
  pane_save_history "$SESSION"
  tmux_kill "$SESSION"
  preserve_sandbox "$SBOX"
}
trap cleanup EXIT

SBOX=$(make_sandbox "plugin-loads")
tmux_start "$SESSION" "$SBOX"

# Wait for the welcome screen / trust prompt.
if wait_for_pane "$SESSION" "Quick safety check|Welcome back|\\? for shortcuts" 30; then
  note_pass "claude TUI started"
else
  note_fail "claude TUI did not start within 30s"
  echo "----- pane -----"; tmux_capture "$SESSION"; echo "----- end -----"
  finalize
fi

# If the trust prompt is showing, accept it (Enter selects "Yes, I trust").
if tmux_capture "$SESSION" | grep -q "Quick safety check"; then
  tmux_send_line "$SESSION" ""
  if wait_for_pane "$SESSION" "\\? for shortcuts|Welcome back" 15; then
    note_pass "trust prompt confirmed"
  else
    note_fail "trust prompt did not advance"
    finalize
  fi
fi

# Filter the palette by typing each distinct ixion-skill prefix and
# capturing the pane. Multiple filter cycles (rather than one bare "/"
# capture) avoid pane-cutoff when the palette grows past the visible
# rows. Between cycles we send Backspace several times to clear the
# typed prefix without committing it.
clear_input() {
  local n=8
  while [ $n -gt 0 ]; do
    tmux send-keys -t "$SESSION" BSpace
    n=$((n - 1))
  done
  sleep 0.3
}

assert_palette_has() {
  local palette="$1"
  local cmd="$2"
  if echo "$palette" | grep -F -q "$cmd"; then
    note_pass "palette lists $cmd"
  else
    note_fail "palette missing $cmd"
  fi
}

# /plan — multi-skill prefix; verifies the plan orchestrator and its
# three sub-skills all surface.
tmux_send "$SESSION" "/plan"
sleep 3
plan_palette="$(tmux_capture "$SESSION")"
assert_palette_has "$plan_palette" "/plan"
assert_palette_has "$plan_palette" "/plan-creation"
assert_palette_has "$plan_palette" "/plan-review"
assert_palette_has "$plan_palette" "/plan-consolidation"
clear_input

# /work — verifies the work skill and its review pair.
tmux_send "$SESSION" "/work"
sleep 3
work_palette="$(tmux_capture "$SESSION")"
assert_palette_has "$work_palette" "/work"
assert_palette_has "$work_palette" "/work-review"

# Sanity: the (ixion) source tag appears in at least one capture,
# confirming the entries come from the plugin we --plugin-dir'd in
# (not from the user-installed copy).
combined="$plan_palette
$work_palette"
if echo "$combined" | grep -F -q "(ixion)"; then
  note_pass "palette tags entries with (ixion) source"
else
  note_fail "palette did not tag any entry as (ixion)"
  echo "----- combined palette captures -----"; echo "$combined"; echo "----- end -----"
fi

finalize
