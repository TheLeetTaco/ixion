# Flywheel — claude.md

This repo develops the Flywheel plugin for Claude Code and OpenCode. Source lives in `flywheel/` (plugin contents); integration tests live in `tests/integration/`. Architectural philosophy: see `docs/adrs/0001-skill-design-as-negotiation.md`.

## Running integration tests

The end-to-end test (`tests/integration/cases/03-pipeline-end-to-end.test.sh`) drives the full `/yolo` autonomous flow against the real Anthropic API. Prerequisites:

- `ANTHROPIC_API_KEY` set
- `tmux`, `claude`, `jq`, `bunx` on PATH
- The plugin installed via `bash install_claude_code.sh < /dev/null` (stdin redirected to skip the Context7 prompt)

A typical run takes 25–45 minutes. Cost: real API tokens.

```bash
# Reinstall plugin first if any plugin file changed
bash install_claude_code.sh < /dev/null 2>&1 | tail -3

# Run e2e test in background, capture output
bash tests/integration/cases/03-pipeline-end-to-end.test.sh \
  > /tmp/yolo-test.log 2>&1; echo "TEST EXITED: $?" >> /tmp/yolo-test.log
```

Smaller tests:
- `00-plugin-loads.test.sh` — palette discovery, no model call (~30s)
- `01-fly-work-resumes.test.sh` — `work` skill against seeded session (~1–3min)
- `02-fly-plan-creates-spec.test.sh` — `plan` skill end-to-end (~3–10min)

## Monitoring a long-running test

Don't sit and watch the log. Use the Monitor tool with a script that emits events on milestones, deadlocks, and silent stops. Skeleton:

```bash
last_log=0; last_prompt=0; last_log_time=$(date +%s); stall_warned=0
while true; do
  now=$(date +%s)

  # 1. Test progress: emit each new PASS/FAIL/INFO line
  cur_log=$(wc -l < /tmp/yolo-test.log 2>/dev/null || echo 0)
  if [ "$cur_log" -gt "$last_log" ]; then
    tail -n $((cur_log - last_log)) /tmp/yolo-test.log \
      | grep --line-buffered -E "^(PASS|FAIL|INFO|Summary|TEST EXITED):" || true
    last_log=$cur_log
    last_log_time=$now
    stall_warned=0
  fi

  # 2. Deadlock detection: AskUserQuestion prompt visible in tmux
  pane=$(tmux capture-pane -t flywheel-int-yolo -p 2>/dev/null || echo "")
  prompt=$(echo "$pane" | grep -cE "Enter to select|Submit answers|Ready to submit" 2>/dev/null || echo 0)
  if [ "$prompt" -gt 0 ] && [ "$last_prompt" -eq 0 ]; then
    echo "DEADLOCK_DETECTED: AskUserQuestion in pane"
    echo "$pane" | tail -12
  fi
  last_prompt=$prompt

  # 3. Silent-stop detection: log idle >5min while test still running
  log_idle=$((now - last_log_time))
  if [ "$log_idle" -gt 300 ] && [ "$stall_warned" -eq 0 ] && [ "$last_log" -gt 0 ]; then
    echo "STALL_DETECTED: log idle ${log_idle}s — agent may have silent-stopped"
    echo "$pane" | tail -10
    stall_warned=1
  fi

  # 4. Completion: break on test exit (Summary OR TEST EXITED)
  if grep -q "^Summary:\|^TEST EXITED:" /tmp/yolo-test.log 2>/dev/null; then
    grep "^Summary:\|^TEST EXITED:" /tmp/yolo-test.log | tail -3
    break
  fi
  sleep 30
done
```

This catches three failure shapes:
- **Test progresses normally:** PASS/FAIL lines emitted as they land.
- **Deadlock:** an `AskUserQuestion` is visible (`Enter to select` / `Submit answers`). Common when an autonomous override fails to suppress an end-of-skill prompt.
- **Silent stop:** log hasn't grown in 5+ min but test is still running. Common when the agent stopped reasoning without surfacing a visible prompt — distinct from deadlock because there's no question to answer.

Why the dual signal: in earlier runs an AskUserQuestion-pattern monitor missed silent stops (run 3) because the agent was idle at an empty prompt with no question visible. Combine both signals.

## Debugging a failed run

**Test runs preserve their sandboxes and pane history automatically.** Each test's cleanup trap captures the full pane scrollback to `/tmp/flywheel-int-<session>-<timestamp>-<label>.pane.txt` before killing tmux, then prints the sandbox path so you can inspect session state. Nothing is auto-deleted — run `bash tests/cleanup.sh --apply` when you're done debugging.

After a failed run:

```bash
# Find the sandbox the failed test left behind
SBOX=$(find ${TMPDIR:-/tmp} -maxdepth 2 -type d -name 'flywheel-int-yolo*' | head -1)
SDIR="$SBOX/.flywheel/plugin/sessions/<session-id>"

# Session artifacts
ls -la "$SDIR"
jq '.' "$SDIR/spec.json"
jq '.' "$SDIR/progress.json"
jq '.findings | length' "$SDIR/review.findings.json"

# Implementation files
find "$SBOX" -name "*.py" -not -path "*/.git/*" -not -path "*/.flywheel/*"

# Pane history (auto-saved on test exit)
ls -la /tmp/flywheel-int-*.pane.txt | tail -1
PANE=$(ls -t /tmp/flywheel-int-*.pane.txt | head -1)

# Skill-invocation markers — proves which skills actually ran
grep -oE "Skill\([a-z-]+\)" "$PANE" | sort -u

# Subagent dispatch markers (Task with subagent_type)
grep -oE "[a-z][a-z-]+\([A-Z][^)]+\)" "$PANE" | sort -u | head -20
```

The pane scrollback is the most informative artifact. It shows what the agent actually did between log milestones, including which skills it loaded (`Skill(<name>)`) and which subagents it dispatched.

When you're done with a debugging session, `bash tests/cleanup.sh` lists what would be deleted, `bash tests/cleanup.sh --apply` actually deletes.

## Common failure modes

**Agent invokes a skill but doesn't execute its instructions.** TUI shows the skill's `SKILL.md` content echoed in the pane; no artifact lands. Pane has `Skill(<name>)` marker but the skill's expected output file is missing. Caused by overly literal interpretation of "invoke via Skill tool" — agent treats Skill invocation as "load and report" rather than "load and execute." Fix: simpler "run X, then run Y" framing in the orchestrator skill, not "invoke X via the Skill tool."

**Agent compresses a skill into inline reasoning.** Pane shows the agent doing the work the skill would have done (e.g., emitting findings text directly), no `Skill(<name>)` marker, no artifact on disk. Caused by the orchestrator skill's prose reading like "perform these activities" rather than "actually run these skills." Fix: explicit "the artifact on disk is proof the skill ran; if no artifact, the skill didn't run."

**End-of-skill `AskUserQuestion` deadlock under autonomous orchestration.** Agent finishes a skill, hits its Phase-N "what next?" prompt, calls `AskUserQuestion`, deadlocks. /yolo's general "don't ask user" override fails to catch the specific call site. Fix: enumerate the specific prompts in /yolo's prose so the agent has a pre-loaded handler when it encounters each one.

**Silent stop after a skill completes.** Agent reaches the end of a skill, doesn't enter the next one, just sits idle. No prompt visible. Common when the agent's mental model of "the run is done" differs from the orchestrator's "five more skills to go." Fix: make /yolo's enumeration of remaining steps and their preconditions/postconditions explicit and concrete.

**Test bash exits without `Summary:` or `FAIL:` line.** Indicates abnormal termination — possibly SIGKILL, possibly an uncaught error in the polling loop under `set -u`. Trap may or may not have run (check whether sandbox was cleaned). Less informative; gather pane history if available.

## Reinstall workflow

When you change any file in `flywheel/`:

```bash
bash install_claude_code.sh < /dev/null 2>&1 | tail -3
```

The integration test loads the plugin via `--plugin-dir` pointing at the source tree directly, so technically it picks up changes without reinstall. But `claude` may cache parts of the plugin between sessions. When in doubt, reinstall.

Schema changes affect both the plugin AND the test (which validates artifacts via `bunx ajv-cli`). After a schema change: reinstall plugin AND recheck test assertions still match the schema.

## Don't do

- **Don't clean up before debugging.** `rm -rf` the sandbox and log in the next-run setup; the previous run's evidence is gone forever.
- **Don't trust the bash exit code alone.** "TEST EXITED: 1" without a `Summary:` line means the test died before `finalize` ran. Capture pane + sandbox state to figure out where.
- **Don't run the e2e test more than once an hour casually.** It's expensive (25–45 min real API per run, ~150K tokens). Each run should answer a specific question. Plan the diagnostics you'll add before launching.
- **Don't add validators/BLOCKING gates as the first instinct when a coaxing fix fails.** Read `docs/adrs/0001-skill-design-as-negotiation.md`. Coaxing is non-deterministic but works at the seams that matter; structural enforcement only earns its keep where coaxing has demonstrably failed across multiple runs.
