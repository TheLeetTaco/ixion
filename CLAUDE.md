# Ixion — claude.md

This repo develops the Ixion plugin for Claude Code and OpenCode. Source lives in `ixion/` (plugin contents); integration tests live in `tests/integration/`. Architectural philosophy: @docs/adrs/0001-skill-design-as-negotiation.md

## Planning features in this repo

When asked to plan a feature, run the `plan` skill rather than producing an ad-hoc plan. The deliverable is `spec.json` in the session dir; ExitPlanMode should summarize that spec, not restate it. (Considered wrapping the pipeline in a planner subagent; rejected because subagents can't dispatch the locator/analyzer/reviewer fan-out, consolidation needs the user's question channel, and it would create a second plan artifact competing with spec.json.)

## Running integration tests

The chain test (`tests/integration/cases/07-chain-smoke.test.sh`) drives the full pipeline against the real Anthropic API, invoking each skill as its own command (`/ixion:plan` → `/work` → `/work-review` → `/work`). Only `plan` carries the plugin prefix, because only `plan` is shadowed by a Claude Code built-in. The other three stay bare deliberately: bare is what a user types, `05-parallel-sessions` sends bare `/work feata` and would be the only case left covering that form, and prefixing them for cosmetic uniformity would buy realism in one place by deleting coverage in another. Prerequisites:

- A credential: `ANTHROPIC_API_KEY`, or `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`. A Claude subscription has no API key, and buying pay-as-you-go access purely to run tests is a tax nobody should pay — the token draws on the subscription instead.
- `tmux`, `claude`, `jq`, `bunx`, `cargo` on PATH (the fixture builds and tests a Rust crate)
- The plugin installed via `bash install_claude_code.sh < /dev/null` (non-TTY stdin skips the Context7 prompt)

A typical run takes about 10 minutes on haiku. Cost: real API tokens.

```bash
# Reinstall plugin first if any plugin file changed
bash install_claude_code.sh < /dev/null 2>&1 | tail -3

# Run chain test in background, capture output
LOG=/tmp/ixion-chain-test.log
bash tests/integration/cases/07-chain-smoke.test.sh \
  > "$LOG" 2>&1; echo "TEST EXITED: $?" >> "$LOG"
```

### Running from Windows

The suite needs a Linux userspace — it drives `claude` inside tmux and reads pane scrollback — so it cannot run natively on Windows. `tests/integration/docker-run.sh` supplies one:

```bash
tests/integration/docker-run.sh 07    # one case by filename prefix
tests/integration/docker-run.sh 08    # the branch-resolution case
tests/integration/docker-run.sh       # whole suite
IXION_TEST_SHELL=1 tests/integration/docker-run.sh   # shell inside the container, to poke around
```

It builds `tests/integration/Dockerfile` on first use, then mounts the repo at `/work`. The credential comes from `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` in the environment, or from a `claude_token=` line in a gitignored `.env` at the repo root; it is passed by `--env-file` so it never reaches `docker inspect`. Sandboxes land in the container's `/tmp`, not on the bind mount, so the Windows filesystem is not in the hot path.

Two things the container gets right by construction: `tmux new-session -d` with pinned `-x 200 -y 50` geometry makes pane capture more deterministic than a real terminal, and `.gitattributes` pins `*.sh` to LF so the scripts run under Linux without CRLF damage.

Because no orchestrator pre-answers prompts, `07` drives the skills' live `AskUserQuestion` dialogs via `wait_for_file_with_autopilot` / `autopilot_respond` (`lib/tmux.sh`). A deadlock in `07` usually means a dialog shape the autopilot doesn't recognize, not a stalled agent.

Smaller tests:
- `00-plugin-loads.test.sh` — palette discovery, no model call (~30s). `make_sandbox` gives every sandbox a resolvable origin, so this case also pays a bare-repo init, a `remote add`, a push of a one-commit repo and an `origin/HEAD` symref write — four local git calls, well under a second against a ~30s wall-clock dominated by TUI startup and the palette `sleep`s.
- `01-fly-work-resumes.test.sh` — `work` skill against seeded session (~1–3min)
- `02-fly-plan-creates-spec.test.sh` — `plan` skill end-to-end (~3–10min)
- `05-parallel-sessions.test.sh`, `06-parallel-chunks.test.sh` — concurrency behavior
- `08-branch-resolution.test.sh` — `work` branches off the integration branch, not production; two TUI runs, one two-branch repo and one single-branch (~4–8min). Topology correctness is proven offline by `tests/branch-resolution-harness.sh`, which needs no credential and runs in seconds — start there.

`tests/session-resolution-harness.sh` is the same idea for session handoff: it extracts `session-handoff.md`'s own fenced blocks and runs them against throwaway session trees, then lints `ixion/` for the `/ixion:` spelling `install_opencode.py`'s rewrite matches on. Credential-free, seconds long, and it substitutes a python-backed `jq -r .key file` shim on hosts without `jq` so the reference's text runs unchanged — run it before spending API tokens on anything session-resolution shaped.

`tests/finding-synthesis-harness.sh` does the same for `references/finding-synthesis.md`: it catches a re-authored copy of the shared synthesis text left behind in one review skill, and the retired `Deferred` tier vocabulary coming back. Credential-free and seconds long — run it after any edit to `finding-synthesis.md` or to either review skill's Phase 2.

## Monitoring a long-running test

Don't sit and watch the log. Use the Monitor tool with a script that emits events on milestones, deadlocks, and silent stops. Skeleton:

```bash
LOG=/tmp/ixion-chain-test.log; PANE_SESSION=ixion-int-chain
last_log=0; last_prompt=0; last_log_time=$(date +%s); stall_warned=0
while true; do
  now=$(date +%s)

  # 1. Test progress: emit each new PASS/FAIL/INFO line
  cur_log=$(wc -l < "$LOG" 2>/dev/null || echo 0)
  if [ "$cur_log" -gt "$last_log" ]; then
    tail -n $((cur_log - last_log)) "$LOG" \
      | grep --line-buffered -E "^(PASS|FAIL|INFO|Summary|TEST EXITED):" || true
    last_log=$cur_log
    last_log_time=$now
    stall_warned=0
  fi

  # 2. Deadlock detection: AskUserQuestion prompt visible in tmux
  pane=$(tmux capture-pane -t "$PANE_SESSION" -p 2>/dev/null || echo "")
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
  if grep -q "^Summary:\|^TEST EXITED:" "$LOG" 2>/dev/null; then
    grep "^Summary:\|^TEST EXITED:" "$LOG" | tail -3
    break
  fi
  sleep 30
done
```

This catches three failure shapes:
- **Test progresses normally:** PASS/FAIL lines emitted as they land.
- **Deadlock:** an `AskUserQuestion` is visible (`Enter to select` / `Submit answers`) and stays visible. The test's autopilot should be answering these, so a persistent dialog means `autopilot_respond` didn't recognize its shape — capture the pane and compare against the radio/checkbox patterns it matches on.
- **Silent stop:** log hasn't grown in 5+ min but test is still running. Common when the agent stopped reasoning without surfacing a visible prompt — distinct from deadlock because there's no question to answer.

Why the dual signal: an AskUserQuestion-pattern monitor alone misses silent stops, because the agent sits idle at an empty prompt with no question visible. Combine both signals.

## Auditing artifacts as the test progresses

The monitor catches *failure shapes* (PASS/FAIL/INFO, deadlock, silent stop). It does not tell you whether the artifacts are any good. **That's your job.** Each `PASS:` milestone is a ping to read the artifact that just landed and audit it against the bar — surface concerns immediately, don't wait for the test to finish. A spec missing an elegance criterion, or a findings.json missing the 4-slot Failure format, is a real signal about the prompt tuning, and the earliest place to catch it is the milestone where it lands.

Find the active session: `find ${TMPDIR:-/tmp} -maxdepth 2 -type d -name 'ixion-int-chain*' ! -name '*.git'`, then `<sbox>/.ixion/plugin/sessions/<session_id>/`. The exclusion skips the bare origin `make_sandbox` parks beside each sandbox — it matches the same glob and holds no session state.

| Milestone | Artifact to read | What to audit |
|---|---|---|
| `plan-creation: session_id=<id>` | `spec.json` | Verbatim user prompt at `context.constraints[0]` with the authoritative-prefix. Phase-3 alternatives recorded with anti-pattern reasoning ("Considered: X. Rejected because: Y."). `success_criteria[]` includes at least one elegance criterion. Schema discipline (no extra top-level fields). Test scenarios are concrete and behavioral, not implementation-detail. |
| `plan-review` | `review.findings.json` | Each finding has a 4-slot Failure leading with a recognizable principle name (elegance catalog / SOLID / DRY / domain-canonical). Contradictions with `constraints[0]` are tagged `[Contradicts user]`. Synthetic P1s exist for any incomplete reviewer output or wrong-tier locations. Findings count is proportional to spec size. |
| `plan-consolidation` | `spec.json` (refined) + `spec.json.pre-consolidation` (sidecar) | Structural findings (Shallow Wrapper, Forwarding Chain, Premature Abstraction, etc.) reshaped phases — deleted tasks, replaced shapes — rather than folding fixes on top of inelegant scaffolding. Every non-contradicting finding integrated; contradictions carry a one-line `Rejected:` rationale. Sidecar exists; `review.findings.json` is gone (consumed). |
| `work` plan-mode complete | `progress.json` + source files | Diff is small and reads with intent. The cumulative diff self-check fired (Phase 4). No single-consumer helpers, no defensive guards on impossible cases, no Shallow Wrappers. |
| `work-review` | `review.findings.json` | Findings reflect what's actually in the diff (read the diff and corroborate). Failure paragraphs lead with principle names. `[Contradicts user]` tags on any finding that pushes back on an explicit user choice. Surviving runtime claims at any severity carry the command that reproduced them appended to `failure`; the summary reports the checked/reproduced/refuted/unproven counts plus how many went unattempted at the budget. A round where every runtime claim reproduced is suspicious — the gate is meant to kill some. A high unattempted count with the checks bunched at one severity means the round-robin didn't happen. `open_questions[]` carries one `Refuted and dropped:` record per refutation the summary counted. |
| `work` fix-findings complete | `progress.json` (mode=fix-findings) + `progress.json.plan-mode` (archive) + diff | Fixes addressed structural causes via theme grouping, not patch-pile-on. The plan-mode archive exists. Tests still pass. |

The audit is *evidence-based*: cite file paths, line numbers, or specific JSON paths in your assessment. Don't trust the milestone string — read the file. The milestone says the skill ran; the file tells you whether it ran well.

## Debugging a failed run

**Test runs preserve their sandboxes and pane history automatically.** Each test's cleanup trap captures the full pane scrollback to `/tmp/ixion-int-<session>-<timestamp>-<label>.pane.txt` before killing tmux, then prints the sandbox path so you can inspect session state. Nothing is auto-deleted — run `bash tests/cleanup.sh --apply` when you're done debugging.

After a failed run:

```bash
# Find the sandbox the failed test left behind
SBOX=$(find ${TMPDIR:-/tmp} -maxdepth 2 -type d -name 'ixion-int-chain*' ! -name '*.git' | head -1)
SDIR="$SBOX/.ixion/plugin/sessions/<session-id>"

# Session artifacts
ls -la "$SDIR"
jq '.' "$SDIR/spec.json"
jq '.' "$SDIR/progress.json"
jq '.findings | length' "$SDIR/review.findings.json"

# Implementation files
find "$SBOX" -name "*.py" -not -path "*/.git/*" -not -path "*/.ixion/*"

# Pane history (auto-saved on test exit)
ls -la /tmp/ixion-int-*.pane.txt | tail -1
PANE=$(ls -t /tmp/ixion-int-*.pane.txt | head -1)

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

**Silent stop mid-skill.** Agent reaches a phase boundary inside a skill, doesn't continue, just sits idle. No prompt visible. Common when the agent's mental model of "this is done" diverges from the skill's remaining phases. Fix: make the skill's enumeration of remaining steps and their preconditions/postconditions explicit and concrete, so there's no ambiguity about whether work remains.

**Test bash exits without `Summary:` or `FAIL:` line.** Indicates abnormal termination — possibly SIGKILL, possibly an uncaught error in the polling loop under `set -u`. Trap may or may not have run (check whether sandbox was cleaned). Less informative; gather pane history if available.

## Reinstall workflow

When you change any file in `ixion/`:

```bash
bash install_claude_code.sh < /dev/null 2>&1 | tail -3
```

The integration test loads the plugin via `--plugin-dir` pointing at the source tree directly, so technically it picks up changes without reinstall. But `claude` may cache parts of the plugin between sessions. When in doubt, reinstall.

Schema changes affect both the plugin AND the test (which validates artifacts via `bunx ajv-cli`). After a schema change: reinstall plugin AND recheck test assertions still match the schema.

## Past solutions

Compound learnings from previous sessions live in `docs/solutions/`. Grep it before re-deriving a fix.

## Don't do

- **Don't clean up before debugging.** `rm -rf` the sandbox and log in the next-run setup; the previous run's evidence is gone forever.
- **Don't trust the bash exit code alone.** "TEST EXITED: 1" without a `Summary:` line means the test died before `finalize` ran. Capture pane + sandbox state to figure out where.
- **Don't run the chain test casually.** It's real API tokens per run. Each run should answer a specific question. Plan the diagnostics you'll add before launching.
- **Don't add validators/BLOCKING gates as the first instinct when a coaxing fix fails.** Read `docs/adrs/0001-skill-design-as-negotiation.md`. Coaxing is non-deterministic but works at the seams that matter; structural enforcement only earns its keep where coaxing has demonstrably failed across multiple runs.
