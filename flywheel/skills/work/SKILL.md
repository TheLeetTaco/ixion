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

Execute the active session's plan or review findings via probe → dispatch → checkpoint. Namespace: plugin uses `.flywheel/plugin/sessions/`.

## Input

No required arguments. Optional `$ARGUMENTS`:

- empty → use the active session from `.flywheel/plugin/active.json`
- slug (`^[a-z0-9-]+$`) → prefix-scan `.flywheel/plugin/sessions/<slug>-*`; tiebreak by most-recent date

Mode is detected from session contents — never set explicitly.

---

## Phase 0: Session Detection

Read `references/session-detection.md`.

Decision tree:

1. **No args, active.json missing** → error: `"No active session. Run /plan or /work <slug>."` Exit.
2. **No args, active.json points to missing session dir** → error: `"Session <id> not found. Clearing active pointer."` Clear active.json. Exit.
3. **No args, active.json present** → use it.
4. **Slug arg** → prefix-scan; tiebreak by lexical-desc sort (ISO-date semantics); update active.json to winner.

Validate `session.json.schema_version == 1`. Mismatch → `"Unsupported schema version <N>. Re-run the producing skill to regenerate."`

---

## Phase 1: Mode Detection & Load

Read `references/load-resume-procedures.md`.

`progress.json` is the file the rest of the pipeline reads to know what's happening. `work-review` reads it to see what files you touched. `/yolo` reads it to detect the fix-findings transition. Future `/work` invocations read it to resume. **Without `progress.json`, the rest of the pipeline can't see your work** — even if the code is correct, nothing downstream knows you ran. Treat writing it as the *first* thing you do, not the last.

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

5. **Worktree assessment**: advisory prompt per `references/load-resume-procedures.md` if scope is large.

No baseline. No hash. No BC coverage check. No TaskList synthesis.

---

## Phase 2: Execute (Per-Chunk Loop)

The chunk unit depends on mode. In both modes, a chunk is a **phase + bullets** structure: one logical unit of work containing several related items the subagent works through in a single dispatch.

- **Plan mode**: chunk = phase from `spec.json.phases[]`. ID = `phase.id`. Bullets = `phase.tasks[]`.
- **Fix-findings mode**: chunk = **theme group** of findings — a logical cluster (e.g. one design refactor, one shared-helper simplification, one polish pass) that one subagent can address in a single dispatch. ID = `theme-<slug>` (e.g. `theme-scaffolding-redesign`, `theme-polish`). Bullets = the findings in that theme.

  **Theme grouping (the synthesizer's job):**
  - Cluster findings whose suggested fixes share a structural change (same file or same coordinated cross-file edit).
  - Group all small unrelated polish (1-line comment fixes, import merges, single-finding files) into one `theme-polish` chunk; do NOT dispatch one subagent per single-finding file.
  - Aim for 1-5 themes regardless of finding count. 17 findings → ~4 themes is right; 17 findings → 17 themes is wrong.
  - Themes don't have to be balanced. A scaffolding redesign with 3 findings is a theme; a polish pass with 9 P3s is also a theme.
  - Theme name should describe the change (e.g. `theme-loadmd-simplify`), not the file (e.g. `theme-load-step-markdown-ts`).

### 2.0 Read the Elegance Dispatch Bar (once per session)

Before entering the per-chunk loop, Read `flywheel/skills/flywheel-conventions/references/elegance.md` and extract the "Elegance Dispatch Bar" section. Hold the verbatim text for use in every dispatch this session — do not re-read on each chunk. Same bar applies to plan mode and fix-findings mode.

For each chunk whose ID is NOT in `progress.completed[]`:

### 2.1 Probe Files

Quick check of the chunk's files. Flag missing files; warn if any single file >500 lines.

### 2.2 Dispatch Subagent

**BLOCKING: every chunk runs inside a Task subagent.** Main agent does probe → dispatch → checkpoint, never Edit/Write on source files.

The dispatch templates below paste the verbatim Elegance Dispatch Bar text captured in step 2.0. Same bar in plan mode and fix-findings mode — read once, reuse N times.

#### Should I echo the verbatim user prompt into the dispatch?

The dispatch already lists `constraints` as a bullet (which includes `constraints[0]` — the verbatim user prompt with the `User feature description (verbatim, authoritative):` prefix). For prompts that contain explicit *how* details, I also elevate the verbatim text to a prominent **## User intent** block at the top of the dispatch so the implementer reads it before anything else. For generic prompts, I skip the elevation — echoing is just noise.

I elevate when the prompt contains:

- Specific file/path conventions ("config under `~/.config/myapp/`", "lambdas under `services/api/handlers/`", "logs to stderr only")
- Named tools or libraries ("axios for HTTP", "Drizzle ORM", "fontawesome for icons")
- Concrete function signatures or endpoint shapes ("`subscribe(topic, cb)` returns an unsubscribe function", "`POST /webhooks/stripe` returns 200 even on duplicate IDs")
- Scope qualifiers ("read-only API for the MVP", "feature-flagged behind Unleash", "browser only — no SSR")

I skip when the prompt is generic ("build a CRUD app for X", "add a settings page") — the spec already captures everything substantive and the user trusted me to fill in the hows.

When elevating, prepend the dispatch with:

```
## User intent (verbatim — honor every specific choice)
<paste constraints[0] verbatim, including the prefix>
```

The implementer's natural drift on dispatch boundaries is to re-litigate user choices that look like reviewer suggestions. Surfacing the user's exact words as a top-level intent block is the cheapest insurance against that drift on the prompts that earn it.

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

## Elegance bar (NON-NEGOTIABLE)
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
  "outcomes": ["Added timeout flag to commander config"],
  "files_modified": ["src/cli.ts", "tests/cli/timeout.test.ts"],
  "commands_run": [
    { "command": "bun run test tests/cli/timeout.test.ts", "exit_code": 0, "stdout_tail": "PASS — 4 tests passed" },
    { "command": "bun run typecheck", "exit_code": 0, "stdout_tail": "" }
  ],
  "simplifications_made": [
    "Avoided Shallow Wrapper at src/cli.ts:42 by calling commander directly",
    "Deleted 8 lines from src/cli/timeout-default.ts (single-consumer helper inlined)"
  ]
}
```

`commands_run[]` is a forensic log — entries can be structured objects (as shown) or plain summary strings like `'bun run test — 4 passed'`. Whatever you'll find useful to read later. Nothing downstream parses this programmatically.

`simplifications_made[]` is advisory: log what you actually simplified during the chunk; leave empty if nothing warranted recording.
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
- `simplifications_made: ["No simplifications: spec inelegant — <one-paragraph reason>. Re-planning required."]`
The orchestrator surfaces this for re-planning instead of dispatching the next chunk.

## Findings (read all before fixing any)
<paste each finding verbatim: title, severity, location, failure, fix>

## Approach: symptoms vs. structure
These findings are clustered because they likely share a structural cause. Diagnose first, patch never.
1. Read all findings before touching code. Identify the structural issue they point at.
2. Fix the structure once. If the structural change resolves N of M findings as a side effect, re-evaluate the rest before applying their fixes — they may dissolve too.
3. Do NOT apply each fix as an isolated patch. The fixes are reviewer hypotheses about individual symptoms; the synthesizer grouped them because the real fix is upstream.

## Elegance bar (NON-NEGOTIABLE)
<paste the verbatim Elegance Dispatch Bar text captured in step 2.0>

Fix-findings addendum:
- If the cleaner shape requires touching files outside the findings list, take it — note the drift in your report.
- Record any structural change you made as a `simplifications_made[]` entry using the catalog form (e.g., 'Avoided Forwarding Chain at src/auth.ts:42 by reading state directly'). The structural change IS the most important simplification to report.

## Constraints
- Run tests after the change set; capture exit_code.
- Record every command as you run it (don't summarize at the end).

## Return shape

Return JSON in exactly this shape — fill in your values, keep the field names and structure:

```json
{
  "findings_addressed": ["internal/orders/handler.go:81 N+1 query in list-orders", "internal/orders/handler.go:142 magic 30s timeout"],
  "files_modified": ["internal/orders/handler.go", "internal/orders/store.go"],
  "commands_run": [
    { "command": "go test ./internal/orders/...", "exit_code": 0, "stdout_tail": "ok  internal/orders 0.412s" },
    { "command": "go vet ./...", "exit_code": 0, "stdout_tail": "" }
  ],
  "simplifications_made": [
    "Avoided N+1 Query at orders/handler.go:81 by adding a JOIN in store.ListOrders",
    "Avoided Magic Number at orders/handler.go:142 by extracting orderTimeout"
  ]
}
```

`commands_run[]` is a forensic log — structured objects or summary strings, your call. Nothing downstream parses it programmatically.

`simplifications_made[]` is advisory: if the structural change you made to address the cluster is worth naming, log it. Otherwise leave empty.
\"
```

**BLOCKING: Do NOT specify a `model` parameter** — subagents inherit the current session's model.

### 2.2a TDD Cycle and elegance ordering

Skip TDD only for pure refactoring, config-only, or docs changes. Otherwise the dispatch prompt above is the contract:

RED (failing test) → GREEN (minimum code to pass) → REFACTOR (re-read, simplify, delete) → final Diff self-check across the chunk → write `simplifications_made[]` entries grounded in the self-check answers → return.

REFACTOR is per-task; the Diff self-check runs once at the end of the chunk after all tasks are GREEN. The simplifications log records what the self-check surfaced.

### 2.3 Checkpoint (Atomic Write)

Read `references/checkpoint-procedure.md`.

On subagent return:

1. Append chunk ID to `progress.completed[]`.
2. Append `files_modified[]`, `commands_run[]`, and `simplifications_made[]` to `progress.artifacts`.
3. Atomic write `progress.json` (`.tmp` → `mv`).
4. Update `session.json.last_checkpoint_at`.
5. Verify the chunk's `verification` (plan mode) or run tests (fix-findings mode). Capture exit_code. Re-run if any doubt.
6. Manual verification pause if `phase.manual_verification` is non-empty (plan mode).

### 2.4 Ralph Mode Check

Ralph mode activates when any of: spec has >5 phases, `--ralph` flag, or context >50% with >2 chunks remaining. Read `references/ralph-mode.md`.

### 2.5 Loop

Continue to the next non-completed chunk. All complete → Phase 3.

---

## Phase 3: Quality Check

Run the plan's `success_criteria` checks (plan mode) or full test suite + typecheck (fix-findings mode). Read `references/verification-gates.md`: identify the proving command, run it fresh, read full output, verify, then claim done.

Criteria not expressible as a command (e.g., "No new helper added without first searching for an existing one") are verified by reading `git diff <base>...HEAD` + `progress.artifacts.simplifications_made[]`. Cite the diff line or the simplifications entry that proves the criterion holds.

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

Read `references/recovery-and-errors.md`.

**Errors**: 3-Strike protocol per chunk (record each attempt in `progress.error_log`). Subagent failures: retry/skip/abort prompt. Test failures: fix before checkpointing.

---

## Anti-Patterns

- **Synthesize a TaskList from findings.json** — findings.json IS the list. Group by theme (not by file) and dispatch.
- **Group fix-findings by `location`** — produces one chunk per file, which inflates dispatch count for any review with single-finding files. Use theme groups instead (see Phase 2 chunk-definition section). 17 findings spread across 9 files should land in ~4 themes, not 9.
- **Write a baseline.json or compute a hash** — neither exists in the simplified model. spec.json is the live target.
- **BLOCKING: Direct main-agent execution of "small" chunks** — dispatch every chunk via Task. The main agent does probe + dispatch + checkpoint, nothing else.
- **BLOCKING: Declare done without running verification** — `references/verification-gates.md` requires fresh evidence. Each chunk's `verification` must execute and pass before the chunk is marked completed.

---

## Detailed References

- `references/session-detection.md` — Phase 0 active-pointer model, slug-arg tiebreak
- `references/load-resume-procedures.md` — Phase 1 mode detection, fresh-start init, resume invariants
- `references/checkpoint-procedure.md` — Atomic write recipe, `commands_run` accuracy
- `references/progress-file-template.md` — progress.json shape, atomic write invariant, status enum
- `references/session-file-template.md` — session.json shape, `active_skill` lifecycle, skill-exit cleanup trap
- `references/verification-gates.md` — Verification protocol
- `references/recovery-and-errors.md` — Resume flow, 3-Strike protocol
- `references/ralph-mode.md` — Stateless agent loop triggers, checkpoint format
