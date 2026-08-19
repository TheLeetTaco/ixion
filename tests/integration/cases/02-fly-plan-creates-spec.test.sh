#!/usr/bin/env bash
# Integration: /plan creates a session with a valid spec.json.
#
# Spawns claude in tmux against an empty sandbox (no pre-existing session),
# sends `/plan <trivial feature>`, and waits for plan-creation to write
# spec.json + session.json + active.json into a fresh session dir.
#
# /plan is an orchestrator that runs plan-creation, plan-review, and
# plan-consolidation in sequence. We wait only for the plan-creation
# step (spec.json + active.json) to avoid paying for the full pipeline;
# if plan-review/consolidation also complete inside the timeout, we
# cross-check those outputs too.
#
# Real Anthropic API calls. Plan on 3-10 minutes per run.

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
SESSION="ixion-int-plan"
SBOX=""

cleanup() {
  pane_save_history "$SESSION"
  tmux_kill "$SESSION"
  preserve_sandbox "$SBOX"
}
trap cleanup EXIT

SBOX=$(make_sandbox "plan")

# Seed a target file so the planner has something concrete to plan against.
# Without a real codebase the model tends to refuse or stall.
cat > "$SBOX/hello.sh" <<'EOF'
#!/usr/bin/env bash
echo "hi"
EOF
chmod +x "$SBOX/hello.sh"
(cd "$SBOX" && git add hello.sh && git commit -q -m "seed hello.sh")

tmux_start "$SESSION" "$SBOX"

if ! wait_for_pane "$SESSION" "Quick safety check|\\? for shortcuts|Welcome back" 30; then
  note_fail "claude TUI did not start"
  finalize
fi
if tmux_capture "$SESSION" | grep -q "Quick safety check"; then
  tmux_send_line "$SESSION" ""
  wait_for_pane "$SESSION" "\\? for shortcuts|Welcome back" 15 || true
fi

# Drive: ask plan-creation to plan a trivial change to hello.sh.
# Avoid apostrophes in the prompt — tmux send-keys can mangle them and
# leave the input box stuck without ever submitting Enter.
#
# Namespaced: bare "/plan" resolves to Claude Code's own plan mode rather than
# the plugin skill, so the TUI answers "Enabled plan mode", writes a
# conversational plan, and no session dir is ever created. Observed on 2.1.220.
tmux_send_line "$SESSION" "/ixion:plan Update hello.sh to print hello world instead of hi"

ACTIVE="$SBOX/.ixion/plugin/active.json"
SESSIONS_DIR="$SBOX/.ixion/plugin/sessions"

# Wait up to 15 minutes for active.json to appear. plan-creation does
# real codebase research and drafting; the orchestrator may also chain
# plan-review/consolidation. We only need the spec to land.
if wait_for_file "$ACTIVE" 900; then
  note_pass "active.json created by plan-creation"
else
  note_fail "active.json never appeared (plan-creation never finished)"
  echo "----- pane tail -----"; tmux_capture "$SESSION"; echo "----- end -----"
  finalize
fi

SESSION_ID=$(json_field "$ACTIVE" session_id)
if [ "$SESSION_ID" = null ]; then
  note_fail "active.json has no session_id"
  finalize
else
  note_pass "active.json has session_id: $SESSION_ID"
fi

SDIR="$SESSIONS_DIR/$SESSION_ID"
if [ -d "$SDIR" ]; then
  note_pass "session dir exists at $SESSION_ID"
else
  note_fail "session dir missing at $SDIR"
  finalize
fi

# spec.json should validate against spec.schema.json.
if [ -f "$SDIR/spec.json" ]; then
  note_pass "spec.json present"
else
  note_fail "spec.json missing in session dir"
  finalize
fi

AJV=(bunx ajv-cli --validate-formats=false --spec=draft2020)
if "${AJV[@]}" validate -s "$SCHEMAS/spec.schema.json" -d "$SDIR/spec.json" >/dev/null 2>&1; then
  note_pass "spec.json validates against spec.schema.json"
else
  note_fail "spec.json failed schema validation"
  echo "----- spec.json -----"; cat "$SDIR/spec.json"; echo "----- end -----"
  echo "----- ajv error -----"
  "${AJV[@]}" validate -s "$SCHEMAS/spec.schema.json" -d "$SDIR/spec.json" 2>&1 || true
  echo "----- end -----"
fi

# summary should fall within the schema-enforced 100-5000 char range
# (a quick smoke check beyond raw schema validation).
SUMMARY=$(json_field "$SDIR/spec.json" summary)
if [ "${#SUMMARY}" -ge 100 ] && [ "${#SUMMARY}" -le 5000 ]; then
  note_pass "spec.summary length is within schema bounds"
else
  note_fail "spec.summary length is out of schema bounds"
fi

# session.json should also exist and validate.
if [ -f "$SDIR/session.json" ] && \
   "${AJV[@]}" validate -s "$SCHEMAS/session.schema.json" -d "$SDIR/session.json" >/dev/null 2>&1; then
  note_pass "session.json present and validates"
else
  note_fail "session.json missing or invalid"
fi

finalize
