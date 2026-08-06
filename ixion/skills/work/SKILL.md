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

Optional `$ARGUMENTS`: a session locator — a full session id, or a bare slug. Empty falls back to the active pointer. Phase 0 resolves it.

Mode is detected from session contents — never set explicitly.

---

## Phase 0: Session Detection

Read `ixion/skills/ixion-conventions/references/session-handoff.md` now and hold its blocks — Phase 2.3 and Phase 5 cite it again for the resume command.

```bash
<paste the "Resolve the session" block from ixion/skills/ixion-conventions/references/session-handoff.md verbatim, with LOCATOR set to $ARGUMENTS>
```

```bash
<paste the "Validate the resolved session" block from ixion/skills/ixion-conventions/references/session-handoff.md verbatim>
```

`via=none`, `state=missing`, `state=schema-mismatch` and `state=complete` each halt with the message that file's "Error states" table gives, verbatim. `state=complete` is the rung that matters most here: `/work` is the command a resume prints, so it is the one most likely to be pasted after the session already shipped, and continuing would re-run verification against merged work and re-offer "Ship it" on a branch that no longer needs it. Only `state=usable` continues.

Stale-tmp cleanup: if `progress.json.tmp` or `session.json.tmp` exist from an interrupted prior write, delete them. The authoritative file is the un-suffixed one; partial writes never persist past a crash because `.tmp` → `mv` is atomic on local POSIX.

---

## Phase 1: Mode Detection & Load

`progress.json` is the file the rest of the pipeline reads to know what's happening. `work-review` reads it to see what files you touched. Future `/work` invocations read it to resume — and to detect the fix-findings transition, which is decided from this file plus the presence of `review.findings.json`, not from any caller. **Without `progress.json`, the rest of the pipeline can't see your work** — even if the code is correct, nothing downstream knows you ran. Treat writing it as the *first* thing you do, not the last.

Procedure:

1. **Detect mode** from session contents:
   - `progress.json` exists with `mode: "fix-findings"` → resume fix-findings.
   - `progress.json` exists with `mode: "plan"` AND `status: "completed"` AND `review.findings.json` exists → **fix-findings transition**: rename `progress.json` → `progress.json.plan-mode` to preserve the audit trail, then continue to step 2.
   - `progress.json` exists with `mode: "plan"` → resume plan mode.
   - `progress.json` missing AND `review.findings.json` exists AND `spec.json` exists → error: `"Run /ixion:plan-consolidation <session-id> to merge review findings before starting work."`
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
     SDIR=".ixion/plugin/sessions/<session= from Phase 0>"
     jq '.active_skill = null' "$SDIR/session.json" > "$SDIR/session.json.tmp" \
       && mv "$SDIR/session.json.tmp" "$SDIR/session.json"
   }
   trap cleanup_active_skill EXIT
   ```

   The `&&` is what makes this atomic rather than merely two-step. The redirection truncates the temp file *before* `jq` runs, so a `jq` that fails — unparseable `session.json`, a filter typo, `jq` missing from the host — leaves an empty temp that an unconditional `mv` then renames over the real record. Reproduced: a 75-byte `session.json` became 0 bytes. Renaming only on success leaves the original untouched and a stale empty temp behind, which is exactly what Phase 0's stale-tmp cleanup above already deletes.

5. **Resolve the branch roles, then decide where commits land.** Every chunk gets committed at its checkpoint (2.3), so this decision precedes all of them. Resolve once, here — the worktree path and the in-place path both consume the same answer.

   ```bash
   <paste the "Resolve the branch roles" block from ixion/skills/ixion-conventions/references/git-branches.md verbatim>
   ```

   **`current=` empty** — a detached HEAD. Stop and surface it per that file's "Detached HEAD" section. `on_protected=no` here is not permission to carry on: nothing matched because there is no branch name to match.

   **`on_protected=no`** — HEAD is already on a feature branch, where a resumed session and a hand-branched one both arrive. Nothing in the rest of this step applies; go to step 6.

   **`on_protected=yes`** — a checkpoint commit would otherwise land on a shared branch, so the session needs a branch of its own. The **worktree assessment** (advisory) picks how it gets one: if `spec.json` modifies >10 files, has >3 phases, or any phase touches high-risk paths (auth, payments, migrations), prompt:

   ```
   Ready to execute.
   Scope: N files, M phases.

   1. Current branch (Recommended for small changes)
   2. Create worktree (Recommended for >10 files or high-risk paths)
   ```

   **Worktree.** Branch it from the resolved `integration=`, then make the worktree a self-contained pipeline home — the session artifacts must travel with the code they describe:

   ```bash
   git worktree add -b <slug> ../<repo>-<slug> '<integration= from the resolution block>'
   mkdir -p ../<repo>-<slug>/.ixion/plugin/sessions
   cp -r .ixion/plugin/sessions/<session= from Phase 0> ../<repo>-<slug>/.ixion/plugin/sessions/
   printf '{ "schema_version": 1, "session_id": "%s" }\n' "<session= from Phase 0>" > ../<repo>-<slug>/.ixion/plugin/active.json
   ```

   Passing the start point is what lets this path check nothing out in the primary working tree — leaving that tree untouched is the reason the worktree flow exists, so it neither switches nor probes for dirt.

   Then remind about dependency install + `/init`, and continue the session from inside the worktree. The copy in the main checkout is stale from this moment — run `work-review` and `ship` from the worktree; `ship` copies the final session dir back before `git worktree remove`. This is also the strong-isolation answer for running two features in parallel: each gets its own worktree, its own branch, and its own `.ixion/plugin/` state. That isolation covers concurrent sessions and file collisions; it does not protect against the destructive git commands the dispatch templates' `## Constraints` block prohibits, which run inside the worktree and discard its uncommitted work just the same.

   **In place.** The session branch is created where HEAD stands, so when `current=` is the production branch and `integration=` differs, move to integration first — branching from production would measure the session against production. That switch rewrites tracked files, so probe before it:

   ```bash
   <paste the "Probe the working tree" block from ixion/skills/ixion-conventions/references/git-branches.md verbatim>
   ```

   `tree=dirty` halts the session: name the files and stop so the user can commit or stash them. Do not fall through to branching from production — that records `base_ref` against production and reproduces, for exactly those sessions, the stale-base bug this resolution exists to remove. On `tree=clean`:

   ```bash
   <paste the "Switch to the integration branch" block from ixion/skills/ixion-conventions/references/git-branches.md verbatim>
   ```

   Where `current=` is already `integration=` there is nothing to move to and no probe to run. Either way, the session branch is cut from where HEAD now stands:

   ```bash
   git switch -c "<slug>"
   ```

6. **Record the base ref and the integration branch.**

   ```bash
   BASE_REF=$(jq -r .base_ref .ixion/plugin/sessions/<session= from Phase 0>/session.json)
   [ "$BASE_REF" = null ] && BASE_REF=$(git merge-base HEAD '<integration= from step 5>')
   ```

   `base_ref` is optional in `session.schema.json`, and `jq -r` prints the four-character string `null` — not an empty string — when it is absent: a fresh session, or one predating checkpoint commits. Reading the recorded value first is what makes resume safe: a recomputed merge-base can have moved forward past the session's own work once the integration branch has advanced and been merged in, which empties every diff measured against it.

   Write `BASE_REF` into `session.json.base_ref` and step 5's `integration=` into `session.json.integration_branch` in one atomic write (same pattern as step 3) — but only when the fallback above fired. A resume leaves both fields exactly as recorded: where `integration_branch` is absent there, the session predates the field and its `base_ref` describes the older branch point, so back-filling a freshly-resolved name would make the two name different branches, and `ship` reads the absence to derive its PR base from `base_ref` instead.

   `work` is the only skill that writes either field — Phase 3, Phase 4, `work-review` and `ship` are separate invocations that share no variables, so these two fields are how they agree on one base commit and one PR target.

7. **Reconcile the checkpoint record before any wave is computed.** 2.3 writes a member into `completed[]` and its sha into `checkpoint_commits[]` in separate steps, so an interrupted session can be resumed with an id in the first and nothing in the second. For each such id, ask git whether the commit landed after all:

   ```bash
   BASE_REF=$(jq -r .base_ref .ixion/plugin/sessions/<session= from Phase 0>/session.json)
   git log --format=%H --grep="^Ixion-Chunk: <chunk id>$" "$BASE_REF"..HEAD
   ```

   Step 6 wrote that field a moment ago, so it is a commit id here and needs no fallback of its own. The range still earns its place: chunk ids are phase ids, so an earlier session on this same branch can have committed a `Ixion-Chunk: phase-1` trailer of its own, and an unbounded `--grep` would hand back that stranger's sha to record as this chunk's work.

   A sha means only the record was lost: append `{ "chunk_id": "<id>", "sha": "<sha>" }` and leave the id in `completed[]`. Re-dispatching it instead would spend a subagent re-deriving work already in history and then record an empty commit as though it were the chunk. Empty output means the commit never landed: drop the id so 2.0a picks the chunk up again. Atomic write either way.

   2.0a takes `completed[]` as its exclusion set and makes no such check of its own, so a chunk this step doesn't rescue is skipped forever — silently, with no error. A fresh session has both arrays empty and this is a no-op.

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

Quick check of every wave member's files. Flag missing files; warn if any single file >500 lines. Then check them for edits this session didn't make:

```bash
git status --porcelain -- <every wave member's declared files>
```

`git add <path>` stages a file's entire working-tree diff from HEAD, not just the lines the chunk touched, so anything already dirty in a declared file gets swept into that chunk's checkpoint commit under a message describing work it isn't. Any output here goes to the user before dispatch — name the dirty files and ask whether to commit them first or move the chunk to a later run. Don't clean them yourself; the `## Constraints` prohibition on destructive git commands exists because that uncommitted work may be the user's.

### 2.2 Dispatch Subagents (one per wave member, single message)

**BLOCKING: every chunk runs inside a Task subagent.** Main agent does probe → dispatch → checkpoint, never Edit/Write on source files.

Launch one Task per wave member in a SINGLE message. Append this to every dispatch's `## Context` section:

```
- Run only file-scoped checks yourself: the specific test file, plus the gate the
  `language-standards` skill tags **per-chunk** in its Tooling Gates section — load the
  skill and run that gate exactly as written there, flags included. The orchestrator runs
  each phase's full `verification` after the wave, so a full-suite run of your own is
  duplicated work, and in a multi-member wave it contends with siblings on build locks
  and ports.
```

When the wave has more than one member, append this bullet as well:

```
- Concurrent phases in this wave: <other ids + their files[]>. Those files belong to their
  phases; this working tree is shared. Stay within your declared files. If the clean fix
  needs a file another wave member owns, return with `outcomes` noting it instead of
  editing it — the orchestrator re-dispatches it serially after the wave.
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
- No `git checkout <path>`, `git restore`, `git reset --hard`, `git stash`, or `git clean`. The tree holds uncommitted work from earlier phases and possibly concurrent wave siblings, and you can't tell which of it is yours — even inside your own declared files, so path arguments don't make these safe.
- To mutation-test (break code deliberately to prove a test really fails), use **copy-mutate-restore**: `cp x.rs x.rs.bak`, mutate, restore from the copy, delete the copy. Never revert via git.
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
- No `git checkout <path>`, `git restore`, `git reset --hard`, `git stash`, or `git clean`. The tree holds uncommitted work from earlier phases and possibly concurrent wave siblings, and you can't tell which of it is yours — even inside your own declared files, so path arguments don't make these safe.
- To mutation-test (break code deliberately to prove a test really fails), use **copy-mutate-restore**: `cp x.rs x.rs.bak`, mutate, restore from the copy, delete the copy. Never revert via git.
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

### 2.3 Checkpoint (Once Per Wave; One Commit Per Verified Member)

When all wave members have returned (set `in_progress` to the comma-joined wave ids while they run — it's a free-form status string; resume keys off `completed[]` only):

1. **Verify each member against its own change.** Run its `verification` (plan mode) or tests (fix-findings mode) fresh, capture the actual exit_code — never guess. Re-run if any doubt.

   Verification runs in the shared tree, which holds every member's edits including the broken ones. Verify one member at a time, and when one fails, quarantine its edits before verifying the next — otherwise a correct sibling fails on a tree it didn't break and enters the 3-strike protocol hunting a defect it doesn't own:

   ```bash
   set -e
   Q=$(mktemp -d)
   for f in <failed member's files_modified[], each path shell-quoted>; do
     mkdir -p "$Q/$(dirname "$f")" && cp "$f" "$Q/$f"   # keep the failed attempt
     if git cat-file -e "HEAD:$f" 2>/dev/null; then
       git show "HEAD:$f" > "$f"
     else
       rm "$f"                                          # absent at HEAD => the member created it
     fi
   done
   ```

   This works because 2.0a made the wave's file sets disjoint and 2.1 confirmed they were clean, so HEAD holds exactly what the member started from. `cat-file -e` asks the one question the delete branch is for — is this path in HEAD at all — so a `git show` that fails for any other reason aborts under `set -e` instead of reading as "the member created it" and deleting the file. Restore every quarantined file (`cp "$Q/$f" "$f"`) once the last member is verified — the 3-strike protocol needs the failed attempt to diagnose, and losing it would cost more than the isolation buys.

   The restore stays the orchestrator's: a dispatched subagent is prohibited from these commands, and nothing in a dispatch prompt may ask one to run them.

   A wave of one has no sibling to protect — verify and move on.
2. **Manual verification** — if `phase.manual_verification` is non-empty (plan mode), **you (the orchestrating agent) perform these checks yourself.** Do not surface them to the user. Do not call `AskUserQuestion`. You have full tool access — run the commands via Bash, start servers in tmux, curl endpoints, verify TUI output by capturing tmux panes, read output, inspect the browser. The `manual_verification` field describes what to check and how; execute those steps, read the results, and judge pass/fail yourself. If the check fails, treat it the same as a failed automated verification: do not checkpoint that member, diagnose and fix.
3. Append every **verified** member's ID to `progress.completed[]` in one write. Set `in_progress: null`. If all chunks are now complete set `status: "completed"`, otherwise `status: "in_progress"`. Do NOT append an ID whose verification failed.
4. Append `files_modified[]` (de-duped) and `commands_run[]` to `progress.artifacts`.
5. Atomic write `progress.json` via `.tmp` → `mv`. Same pattern for `session.json` updates.
6. **Commit and record each verified member, one member at a time.** A session that stays uncommitted until `ship` puts a whole multi-phase feature one destructive command away from gone; per-chunk grain means a revert costs one phase rather than a whole wave.

   A member's commit and its record are one unit. Run this to completion for one member before starting the next, so an interruption costs only the member in flight:

   ```bash
   git add -- <that member's returned files_modified[], each path shell-quoted>
   git commit --allow-empty -m "<imperative one-liner naming that chunk's goal>" -m "Ixion-Chunk: <that member's chunk id>"
   git rev-parse HEAD
   ```

   then append `{ "chunk_id": "<id>", "sha": "<sha>" }` to `progress.artifacts.checkpoint_commits[]` and write `progress.json` atomically (`.tmp` → `mv`, exactly as step 5) before touching the next member. Yes, that's a write per member on top of step 5's — the sha doesn't exist until the commit does, and batching them into one write at the end of the wave would leave every member already committed by then recorded nowhere.

   Stage the paths the member **returned**, not the `files[]` it was dispatched with: a fix-findings chunk is allowed to drift onto files outside its list (the fix-findings addendum says so), and that drift belongs in the same commit as the rest of the chunk. Explicit paths only: staging the whole tree instead would sweep in `.ixion/`, which some repos don't ignore, plus any sibling member's work.

   Message follows ship's rules: imperative mood, never a `Co-Authored-By` line, never AI attribution. The `Ixion-Chunk:` trailer is the only handle tying a commit back to its chunk once `progress.json` has stopped naming it — Phase 1 step 7 reads it to tell a lost record from lost work. It gets its own `-m` so it lands column-zero and step 7's anchored `--grep` matches; folding it into the first `-m` as a second line indents it to match this code block, and the lookup then silently finds nothing.

   `--allow-empty` covers the member that verified without editing anything — a phase whose verification only confirms existing behaviour, a fix-findings theme whose finding turned out moot. Without the flag that commit exits 1 with "nothing to commit", a failure no retry can fix, so the chunk would burn all three strikes and the session could never reach `completed`. With it, an empty chunk records a sha like any other and needs no state of its own.

   **If a commit fails** — a rejecting pre-commit hook, `index.lock` contention, a full disk — the chunk is not done. Its work is sitting uncommitted and, left in `completed[]`, nothing would ever re-dispatch it. Remove its id from `completed[]` in that member's write, unstage its paths (`git reset -- <those paths>`, which moves the index only and leaves the work in the tree), and hand it to the 3-strike protocol alongside step 1's failures. **Then carry the loop on through the remaining members.** Each member owns its commit and its write, so one rejection neither strands a sibling in `completed[]` uncommitted nor leaks its staged paths into the next member's commit.

   The invariant, holding after every one of these writes rather than only at the end of the wave: each id in `completed[]` has a `checkpoint_commits[]` entry naming the commit that holds its work, and a chunk whose commit failed is in neither array.
7. Update `session.json.last_checkpoint_at` to current UTC ISO-8601.
8. **Print how to resume, now that the wave's commits exist.** Long sessions are where a user clears context mid-run, and the wave boundary is the point where doing so is free.

   ```bash
   <paste the "Resume command" block from ixion/skills/ixion-conventions/references/session-handoff.md verbatim, with SKILLS='work'>
   printf 'waves: %s done, %s remaining\n' "<waves checkpointed so far>" "<chunks not in completed[], grouped by 2.0a>"
   ```

   Here rather than after step 5: step 5 appends every verified member to `completed[]` before this loop has attempted a single commit, and step 6 pulls an id back out when its commit is rejected — so a line printed at step 5 advertises work that may not be in history and a count that may be wrong by the time the wave ends.

   Skip it when nothing remains. Phase 5's closing block is the accurate one for a finished session, and a `/ixion:work` line beside it offers to re-enter a session with no chunks left.

   What this does *not* cover is an interruption between a member's commit and its record. Phase 1 step 7 is the net for that: it asks git whether each `completed[]` id has a commit and drops the ids that don't, so a resumed session re-dispatches exactly the chunks whose work never landed.
9. Failed members go through the 3-strike protocol **serially** before the next wave is computed — never re-dispatch a failing chunk as part of a fresh wave.

### 2.4 Loop

Compute the next wave (2.0a) from the updated `completed[]`. All chunks complete → Phase 3.

---

## Phase 3: Quality Check

Run the plan's `success_criteria` checks (plan mode) or full test suite + typecheck (fix-findings mode). Read `references/verification-gates.md`: identify the proving command, run it fresh, read full output, verify, then claim done.

Criteria not expressible as a command (e.g., "No new helper added without first searching for an existing one") are verified by reading the session's cumulative diff:

```bash
git diff "$(jq -r .base_ref .ixion/plugin/sessions/<session= from Phase 0>/session.json)"..HEAD
```

Phase 1 step 6 wrote that field before the first chunk ran, so it is a commit id by the time you get here.

Cite the diff line that proves the criterion holds.

**Leave the record before Phase 4.** These checks run once per session rather than once per chunk, so nothing else ever re-runs them — and to `work-review`, `ship` and any later auditor, a criterion that passed, one that failed, and one that was never reached all read the same unless Phase 3 leaves the forensic trail 2.3 leaves for chunks. Append one entry per command you actually ran to `progress.artifacts.commands_run`, quoting its output rather than summarising it — a gate that reports itself skipped rather than failing says so in its own words, and a paraphrase drops exactly the distinction the entry exists to hold:

```json
[
  { "command": "shellcheck tests/lib/*.sh", "exit_code": 0 },
  { "command": "license-audit", "exit_code": 0, "stdout_tail": "SKIPPED: license-audit not installed" }
]
```

Criteria you resolved from the cumulative diff ran no command and get no entry — the cited diff line is their evidence. Then atomic write `progress.json` via `.tmp` → `mv`, exactly as 2.3 step 5. Do it before starting Phase 4: the self-check there can send you into a polish chunk that runs commands of its own, and the record of what proved the criteria should already be on disk by then.

---

## Phase 4: Cumulative Diff Self-Check (BLOCKING)

After `success_criteria` passes, the orchestrator runs the diff self-check at the *whole-session* level — the dispatched subagent only sees its own chunk; this catches cross-phase drift that no chunk-level review can.

1. Run `git diff "$(jq -r .base_ref .ixion/plugin/sessions/<session= from Phase 0>/session.json)"..HEAD`. Read the full output. Every chunk is committed by now, so this spans the whole session.
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
All chunks complete, verified, and committed on <branch>.

What's next?
1. Review the work (recommended for substantive changes)
2. Ship it — push the branch, open the PR, compound learnings
```

Print both onward commands under it, so choosing later — after a `/clear` — costs nothing:

```bash
<paste the "Resume command" block from ixion/skills/ixion-conventions/references/session-handoff.md verbatim, with SKILLS='work-review ship'>
```

After the user's choice:

1. `progress.json.status = "completed"` (atomic write).
2. Phase 1 trap clears `session.json.active_skill`. ship handles `session.status = "completed"`.
3. Worktree cleanup if applicable.

---

## Recovery & Errors

**Recovery**: "carry on" / "continue" / `/ixion:work` with no args all route through Phase 0 → Phase 1 resume. Resume recomputes the next wave (2.0a) from `progress.completed[]` — an interrupted wave simply re-runs; its unverified members were never appended. No work is lost: `progress.json` is atomically written so partial states never persist, and Phase 1 step 7 reconciles any member the interruption caught between its commit and its record.

**3-Strike protocol per chunk** (record each attempt in `progress.error_log[]`):

1. **Attempt 1**: diagnose & fix.
2. **Attempt 2**: alternative approach — never repeat the same failing action.
3. **Attempt 3**: broader rethink — question assumptions.
4. **After 3 failures**: append to `progress.error_log[]` and escalate via AskUserQuestion (retry / skip / abort). If skip, the gap stays in the log so work-review can surface it.

Test failures fix before checkpointing — never append a chunk ID to `completed[]` with failing tests. The chunk being attempted stays in `progress.in_progress` (not yet appended to `completed[]`) until verification passes. A schema-version mismatch on `spec.json`, `progress.json` or `review.findings.json` halts the same way Phase 0 halts on `session.json`'s — with `session-handoff.md`'s `state=schema-mismatch` message.

---

## Anti-Patterns

- **Synthesize a TaskList from findings.json** — findings.json IS the list. Group by theme (not by file) and dispatch.
- **Group fix-findings by `location`** — produces one chunk per file, which inflates dispatch count for any review with single-finding files. Use theme groups instead (see Phase 2 chunk-definition section). 17 findings spread across 9 files should land in ~4 themes, not 9.
- **Write a baseline.json or compute a content hash** — the session's one reference point is `session.json.base_ref`, a commit id resolved in Phase 1. spec.json is the live target.
- **Worktree-per-chunk** — disjoint `files[]` in one tree IS the isolation mechanism for wave members; worktrees are session-granularity (Phase 1 step 5). Per-chunk worktrees add merge cost and dependency installs and break "phase B builds on phase A's code."
- **Relax the disjoint-files rule to widen a wave** — overlapping phases run in later waves. A wave of one is correct, not a failure to parallelize.
- **BLOCKING: Direct main-agent execution of "small" chunks** — dispatch every chunk via Task. The main agent does probe + dispatch + checkpoint, nothing else.
- **BLOCKING: Declare done without running verification** — `references/verification-gates.md` requires fresh evidence. Each chunk's `verification` must execute and pass before the chunk is marked completed.

---

## Detailed References

- `references/verification-gates.md` — Evidence-before-claim protocol and banned phrases.
- `ixion/schemas/progress.schema.json`, `session.schema.json` — authoritative shapes for the artifacts this skill writes.
