---
name: work
description: Execute spec.json (plan mode) or review.findings.json (fix-findings mode) by dispatching subagents per chunk. Triggers on "work on", "implement", "execute plan", "carry on", "continue".
allowed-tools:
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - Bash
  - Task
  - TaskCreate
  - TaskUpdate
  - TaskList
  - Skill
  - AskUserQuestion
---

# Work Implementation Skill

Execute the active session's plan or review findings via probe → dispatch → checkpoint. Namespace: plugin uses `.ixion/plugin/sessions/`.

## Input

No required arguments. Optional `$ARGUMENTS`:

- empty → use the active session from `.ixion/plugin/active.json`
- slug (`^[a-z0-9-]+$`) → prefix-scan `.ixion/plugin/sessions/<slug>-*`; tiebreak by most-recent date

Mode is detected from session contents — never set explicitly.

---

## Phase 0: Session Detection

Active pointer lives at `.ixion/plugin/active.json` (`{ "schema_version": 1, "session_id": "<id>" }`); sessions live at `.ixion/plugin/sessions/<session-id>/`.

Decision tree:

1. **No args, active.json missing** → error: `"No active session. Run /plan or /work <slug>."` Exit.
2. **No args, active.json points to missing session dir** → error: `"Session <id> not found. Clearing active pointer."` `rm -f .ixion/plugin/active.json`. Exit.
3. **No args, active.json present** → `SESSION_ID=$(jq -r .session_id .ixion/plugin/active.json)`; use it.
4. **Slug arg** → prefix-scan: `find .ixion/plugin/sessions -maxdepth 1 -type d -name "${SLUG}-*" | sort -r`. ISO-date suffix sorts lexically = chronologically; first result wins. Update `active.json` atomically (write `active.json.tmp.$$` → `mv`; the PID suffix keeps concurrent sessions from clobbering each other's in-flight write) to the winner.

**Identity check before writing anything:** if this conversation already established a session id (plan-creation ran earlier, or an orchestrator passed one), that remembered id is authoritative — not active.json. If active.json names a different session, another Claude Code session claimed the pointer since this run started; use the remembered id directly and don't touch active.json.

Stale-tmp cleanup: if `progress.json.tmp` or `session.json.tmp` exist from an interrupted prior write, delete them. The authoritative file is the un-suffixed one; partial writes never persist past a crash because `.tmp` → `mv` is atomic on local POSIX.

Validate `session.json.schema_version == 1`. Mismatch → `"Unsupported schema version <N>. Re-run the producing skill to regenerate."`

---

## Phase 1: Mode Detection & Load

`progress.json` is the file the rest of the pipeline reads to know what's happening. `work-review` reads it to see what files you touched. Future `/work` invocations read it to resume — and to detect the fix-findings transition, which is decided from this file plus the presence of `review.findings.json`, not from any caller. **Without `progress.json`, the rest of the pipeline can't see your work** — even if the code is correct, nothing downstream knows you ran. Treat writing it as the *first* thing you do, not the last.

Procedure:

1. **Detect mode** from session contents:
   - `progress.json` exists with `mode: "fix-findings"` → resume fix-findings.
   - `progress.json` exists with `mode: "plan"` AND `status: "completed"` AND `review.findings.json` exists → **fix-findings transition**: rename `progress.json` → `progress.json.plan-mode` to preserve the audit trail, then continue to step 2.
   - `progress.json` exists with `mode: "plan"` → resume plan mode.
   - `progress.json` missing AND `review.findings.json` exists AND `spec.json` exists → error: `"Run /plan-consolidation to merge review findings before starting work."`
   - `progress.json` missing AND `spec.json` exists → start fresh plan mode.
   - else → error: `"No spec.json or review.findings.json in session."`

2. **Declare you've started — write `progress.json` immediately.** Before reading the spec, before dispatching any subagent, before opening any source file, write the initial `progress.json`. This is your declaration to the rest of the pipeline that work has begun.

   ```json
   {
     "schema_version": 1,
     "mode": "<plan|fix-findings>",
     "status": "pending",
     "completed": [],
     "in_progress": null,
     "artifacts": { "files_modified": [], "commands_run": [] },
     "error_log": []
   }
   ```

   Atomic write (`.tmp` → `mv`). Same shape for both modes — only `mode` differs. Resume path skips this step (file already exists).

3. **Session update**: `active_skill = "work"`, `last_checkpoint_at = <now>`. Atomic write.

4. **Skill-exit trap** to clear `active_skill`:

   ```bash
   cleanup_active_skill() {
     if [ -f "$SESSION_DIR/session.json" ]; then
       jq '.active_skill = null' "$SESSION_DIR/session.json" \
         > "$SESSION_DIR/session.json.tmp"
       mv "$SESSION_DIR/session.json.tmp" "$SESSION_DIR/session.json"
     fi
   }
   trap cleanup_active_skill EXIT
   ```

5. **Worktree assessment** (advisory): if `spec.json` modifies >10 files, has >3 phases, or any phase touches high-risk paths (auth, payments, migrations), prompt:

   ```
   Ready to execute.
   Scope: N files, M phases.

   1. Current branch (Recommended for small changes)
   2. Create worktree (Recommended for >10 files or high-risk paths)
   ```

   If worktree: `git worktree add`, then make the worktree a self-contained pipeline home — the session artifacts must travel with the code they describe:

   ```bash
   git worktree add ../<repo>-<slug> -b <slug>
   mkdir -p ../<repo>-<slug>/.ixion/plugin/sessions
   cp -r .ixion/plugin/sessions/<session-id> ../<repo>-<slug>/.ixion/plugin/sessions/
   printf '{ "schema_version": 1, "session_id": "%s" }\n' "<session-id>" > ../<repo>-<slug>/.ixion/plugin/active.json
   ```

   Then remind about dependency install + `/init`, and continue the session from inside the worktree. The copy in the main checkout is stale from this moment — run `work-review` and `ship` from the worktree; `ship` copies the final session dir back before `git worktree remove`. This is also the strong-isolation answer for running two features in parallel: each gets its own worktree, its own branch, and its own `.ixion/plugin/` state.

No baseline. No hash. No BC coverage check. No TaskList synthesis.

---

## Phase 2: Execute (Per-Chunk Loop)

The chunk unit depends on mode. In both modes, a chunk is a **phase + bullets** structure: one logical unit of work containing several related items the subagent works through in a single dispatch.

- **Plan mode**: chunk = phase from `spec.json.phases[]`. ID = `phase.id`. Bullets = `phase.tasks[]`.
- **Fix-findings mode**: chunk = **theme group** of findings — a logical cluster (e.g. one design refactor, one shared-helper simplification, one polish pass) that one subagent can address in a single dispatch. ID = `theme-<slug>` (e.g. `theme-scaffolding-redesign`, `theme-polish`). Bullets = the findings in that theme. **Every finding gets fixed** — P1 through P3 — with one exception: findings whose title starts with `[Contradicts user]` are advisory pushback against the user's explicit choice; skip them and list them in `outcomes` so the user sees the pushback without it being auto-applied.

  **Theme grouping (the synthesizer's job):**
  - Cluster findings whose suggested fixes share a structural change (same file or same coordinated cross-file edit).
  - Group all small unrelated polish (1-line comment fixes, import merges, single-finding files) into one `theme-polish` chunk; do NOT dispatch one subagent per single-finding file.
  - Aim for 1-5 themes regardless of finding count. 17 findings → ~4 themes is right; 17 findings → 17 themes is wrong.
  - Themes don't have to be balanced. A scaffolding redesign with 3 findings is a theme; a polish pass with 9 P3s is also a theme.
  - Theme name should describe the change (e.g. `theme-loadmd-simplify`), not the file (e.g. `theme-load-step-markdown-ts`).

### 2.0 Read the Elegance Dispatch Bar (once per session)

Before entering the per-chunk loop, Read `ixion/skills/ixion-conventions/references/elegance.md` and extract the "Elegance Dispatch Bar" section. Hold the verbatim text for use in every dispatch this session — do not re-read on each chunk. Same bar applies to plan mode and fix-findings mode.

### 2.0a Compute the Next Wave

Chunks that don't depend on each other and don't touch the same files run **concurrently** — one Task per chunk, all in a single message. The structure that makes this safe already exists: every chunk runs in a subagent, and the main agent is the sole writer of `progress.json`, so N parallel returns land in one context that checkpoints once per wave.

From the chunks whose IDs are NOT in `progress.completed[]`:

1. **Ready set** (plan mode): phases whose `depends_on[]` ids are all in `completed[]`. A phase with no `depends_on` field depends on the phase written before it in `spec.phases[]` — the serial fallback; only an explicit `depends_on` (including `[]`) opts a phase into running earlier.
2. **Wave**: within the ready set, pick phases with pairwise-disjoint `files[]` (compare both `phase.files[]` and their tasks' `files[]`). Phases that overlap wait for the next wave. Cap the wave at **3** — beyond that, context and merge-risk outgrow the wall-clock win.
3. **Fix-findings mode**: themes wave-ize the same way, using each theme's finding locations as its file set. `theme-polish` is cross-cutting by construction — it always runs alone, last.

A wave of one is normal and correct — serial execution is just the degenerate wave. Never force parallelism by relaxing the disjoint-files rule.

For each wave:

### 2.1 Probe Files

Quick check of every wave member's files. Flag missing files; warn if any single file >500 lines.

### 2.2 Dispatch Subagents (one per wave member, single message)

**BLOCKING: every chunk runs inside a Task subagent.** Main agent does probe → dispatch → checkpoint, never Edit/Write on source files.

Launch one Task per wave member in a SINGLE message. When the wave has more than one member, append this to each dispatch's `## Context` section:

```
- Concurrent phases in this wave: <other ids + their files[]>. Those files belong to their
  phases; this working tree is shared. Stay within your declared files. If the clean fix
  needs a file another wave member owns, return with `outcomes` noting it instead of
  editing it — the orchestrator re-dispatches it serially after the wave.
- Run only file-scoped checks yourself (the specific test file, `cargo check`); the
  orchestrator runs each phase's full `verification` after the wave — concurrent full-suite
  runs contend on build locks and ports.
```

The dispatch templates below paste the verbatim Elegance Dispatch Bar text captured in step 2.0. Same bar in plan mode and fix-findings mode — read once, reuse N times.

**Plan mode dispatch:**

```
Task general-purpose: "
## Task
Execute phase <id>: <phase.goal>

## Phase JSON
<paste phase JSON: tasks, files, verification, manual_verification>

## Context
- summary: <spec.summary>
- success_criteria: <spec.success_criteria>
- key_files: <spec.context.key_files>
- patterns: <spec.context.patterns>
- constraints: <spec.context.constraints>
- Already completed: <progress.completed>

## The bar the user set for me
<paste the verbatim Elegance Dispatch Bar text captured in step 2.0>

Plan-mode addendum:
- Search the codebase for an existing helper before adding new utility code.
- Follow existing patterns; deviate when the existing pattern is itself inelegant — note the deviation in your report.

## Constraints
- TDD per task (RED → GREEN → REFACTOR). REFACTOR is mandatory. Skip TDD only for pure refactor, docs, or config-only changes.
- Record every command as you run it (don't summarize at the end).

## Return shape

Return JSON in exactly this shape — fill in your values, keep the field names and structure:

```json
{
  "outcomes": ["Added timeout flag to clap config"],
  "files_modified": ["src/cli.rs", "tests/cli_timeout.rs"],
  "commands_run": [
    { "command": "cargo test --test cli_timeout", "exit_code": 0, "stdout_tail": "test result: ok. 4 passed" },
    { "command": "cargo clippy -- -D warnings", "exit_code": 0, "stdout_tail": "" }
  ]
}
```

`commands_run[]` is a forensic log — entries can be structured objects (as shown) or plain summary strings like `'cargo test — 4 passed'`. Whatever you'll find useful to read later. Nothing downstream parses this programmatically.
\"
```

**Fix-findings mode dispatch:**

```
Task general-purpose: "
## Task
Resolve theme: <theme-id> — <theme-description>

## Spec rationale (read before fixing)
- summary: <spec.summary>
- success_criteria: <spec.success_criteria>
- patterns: <spec.context.patterns>
- constraints: <spec.context.constraints>

When the findings cluster around a structural issue, check the spec rationale first. If the spec already explains why the structure is what it is, the right fix is often outside the findings (e.g., the spec was wrong). In that case, do NOT patch the codebase. Return:
- `files_modified: []`
- `outcomes: ["spec inelegant — <one-paragraph reason>. Re-planning required."]`
The orchestrator surfaces this for re-planning instead of dispatching the next chunk.

## Findings (read all before fixing any)
<paste each finding verbatim: title, severity, location, failure, fix>

## Approach: symptoms vs. structure
These findings are clustered because they likely share a structural cause. Diagnose first, patch never.
1. Read all findings before touching code. Identify the structural issue they point at.
2. Fix the structure once. If the structural change resolves N of M findings as a side effect, re-evaluate the rest before applying their fixes — they may dissolve too.
3. Do NOT apply each fix as an isolated patch. The fixes are reviewer hypotheses about individual symptoms; the synthesizer grouped them because the real fix is upstream.

## The bar the user set for me
<paste the verbatim Elegance Dispatch Bar text captured in step 2.0>

Fix-findings addendum:
- If the cleaner shape requires touching files outside the findings list, take it — note the drift in your `outcomes` summary.

## Constraints
- Run tests after the change set; capture exit_code.
- Record every command as you run it (don't summarize at the end).

## Return shape

Return JSON in exactly this shape — fill in your values, keep the field names and structure:

```json
{
  "findings_addressed": ["src/orders/handler.rs:81 N+1 query in list-orders", "src/orders/handler.rs:142 magic 30s timeout"],
  "files_modified": ["src/orders/handler.rs", "src/orders/store.rs"],
  "commands_run": [
    { "command": "cargo test orders", "exit_code": 0, "stdout_tail": "test result: ok. 12 passed" },
    { "command": "cargo clippy -- -D warnings", "exit_code": 0, "stdout_tail": "" }
  ]
}
```

`commands_run[]` is a forensic log — structured objects or summary strings, your call. Nothing downstream parses it programmatically.
\"
```

**BLOCKING: Do NOT specify a `model` parameter** — subagents inherit the current session's model.

### 2.2a TDD Cycle and elegance ordering

Skip TDD only for pure refactoring, config-only, or docs changes. Otherwise the dispatch prompt above is the contract:

RED (failing test) → GREEN (the smallest *complete* expression of the change — not the shortest path through the test, the cleanest path) → REFACTOR (re-read, delete what doesn't earn its line) → final Diff self-check across the chunk → apply what the answers tell you → return.

REFACTOR is per-task; the Diff self-check runs once at the end of the chunk after all tasks are GREEN. The diff itself is the record — answer the self-check questions honestly and let the answers shape the final diff before you return.

### 2.3 Checkpoint (Once Per Wave, Atomic Write)

When all wave members have returned (set `in_progress` to the comma-joined wave ids while they run — it's a free-form status string; resume keys off `completed[]` only):

1. **Verify each member serially**: run its `verification` (plan mode) or tests (fix-findings mode). Run the command fresh, capture the actual exit_code — never guess. Re-run if any doubt.
2. **Manual verification** — if `phase.manual_verification` is non-empty (plan mode), **you (the orchestrating agent) perform these checks yourself.** Do not surface them to the user. Do not call `AskUserQuestion`. You have full tool access — run the commands via Bash, start servers in tmux, curl endpoints, verify TUI output by capturing tmux panes, read output, inspect the browser. The `manual_verification` field describes what to check and how; execute those steps, read the results, and judge pass/fail yourself. If the check fails, treat it the same as a failed automated verification: do not checkpoint that member, diagnose and fix.
3. Append every **verified** member's ID to `progress.completed[]` in one write. Set `in_progress: null`. If all chunks are now complete set `status: "completed"`, otherwise `status: "in_progress"`. Do NOT append an ID whose verification failed.
4. Append `files_modified[]` (de-duped) and `commands_run[]` to `progress.artifacts`.
5. Atomic write `progress.json` via `.tmp` → `mv`. Same pattern for `session.json` updates.
6. Update `session.json.last_checkpoint_at` to current UTC ISO-8601.
7. Failed members go through the 3-strike protocol **serially** before the next wave is computed — never re-dispatch a failing chunk as part of a fresh wave.

### 2.4 Loop

Compute the next wave (2.0a) from the updated `completed[]`. All chunks complete → Phase 3.

---

## Phase 3: Quality Check

Run the plan's `success_criteria` checks (plan mode) or full test suite + typecheck (fix-findings mode). Read `references/verification-gates.md`: identify the proving command, run it fresh, read full output, verify, then claim done.

Criteria not expressible as a command (e.g., "No new helper added without first searching for an existing one") are verified by reading `git diff <base>...HEAD`. Cite the diff line that proves the criterion holds.

---

## Phase 4: Cumulative Diff Self-Check (BLOCKING)

After `success_criteria` passes, the orchestrator runs the diff self-check at the *whole-session* level — the dispatched subagent only sees its own chunk; this catches cross-phase drift that no chunk-level review can.

1. Run `git diff <base>...HEAD` (or the equivalent for the session's worktree). Read the full output.
2. Answer each question with concrete evidence. Cite file:line:

   - Is there any line whose removal would NOT change behavior across the whole change? Name one or confirm none exists.
   - Is the same value stored in two places (parallel state introduced across phases)? Name where or confirm one source of truth.
   - Is there a check guarding a case that cannot occur in this codebase? Name one or confirm none.
   - Did phase N add a wrapper, helper, or abstraction that a later phase made unnecessary? Name one or confirm none.

3. If any answer names a finding, dispatch a polish chunk to address it. Only mark the session complete after the polish chunk's verification passes. Do NOT mark complete with unaddressed elegance findings — it's faster to fix them now than after review.

This check uses the same evidence discipline as `references/verification-gates.md`: cite file:line, no "should be fine."

---

## Phase 5: Summary & Next Steps

```
All chunks complete and verified.

What's next?
1. Review the work — /work-review (recommended for substantive changes)
2. Ship it — /ship (commit, PR, compound learnings)
```

After the user's choice:

1. `progress.json.status = "completed"` (atomic write).
2. Phase 1 trap clears `session.json.active_skill`. ship handles `session.status = "completed"`.
3. Worktree cleanup if applicable.

---

## Recovery & Errors

**Recovery**: "carry on" / "continue" / `/work` with no args all route through Phase 0 → Phase 1 resume. Resume recomputes the next wave (2.0a) from `progress.completed[]` — an interrupted wave simply re-runs; its unverified members were never appended. No work is lost — `progress.json` is atomically written, partial states never persist.

**3-Strike protocol per chunk** (record each attempt in `progress.error_log[]`):

1. **Attempt 1**: diagnose & fix.
2. **Attempt 2**: alternative approach — never repeat the same failing action.
3. **Attempt 3**: broader rethink — question assumptions.
4. **After 3 failures**: append to `progress.error_log[]` and escalate via AskUserQuestion (retry / skip / abort). If skip, the gap stays in the log so work-review can surface it.

Test failures fix before checkpointing — never append a chunk ID to `completed[]` with failing tests. The chunk being attempted stays in `progress.in_progress` (not yet appended to `completed[]`) until verification passes. Schema-version mismatch on any input artifact: halt with the literal `"Unsupported schema version <N>. Re-run the producing skill to regenerate."`

---

## Anti-Patterns

- **Synthesize a TaskList from findings.json** — findings.json IS the list. Group by theme (not by file) and dispatch.
- **Group fix-findings by `location`** — produces one chunk per file, which inflates dispatch count for any review with single-finding files. Use theme groups instead (see Phase 2 chunk-definition section). 17 findings spread across 9 files should land in ~4 themes, not 9.
- **Write a baseline.json or compute a hash** — neither exists in the simplified model. spec.json is the live target.
- **Worktree-per-chunk** — disjoint `files[]` in one tree IS the isolation mechanism for wave members; worktrees are session-granularity (Phase 1 step 5). Per-chunk worktrees add merge cost and dependency installs and break "phase B builds on phase A's code."
- **Relax the disjoint-files rule to widen a wave** — overlapping phases run in later waves. A wave of one is correct, not a failure to parallelize.
- **BLOCKING: Direct main-agent execution of "small" chunks** — dispatch every chunk via Task. The main agent does probe + dispatch + checkpoint, nothing else.
- **BLOCKING: Declare done without running verification** — `references/verification-gates.md` requires fresh evidence. Each chunk's `verification` must execute and pass before the chunk is marked completed.

---

## Detailed References

- `references/verification-gates.md` — Evidence-before-claim protocol and banned phrases.
- `ixion/schemas/progress.schema.json`, `session.schema.json` — authoritative shapes for the artifacts this skill writes.
