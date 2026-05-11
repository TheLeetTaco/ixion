---
name: work-review
description: Perform exhaustive code reviews using multi-agent analysis. Reviews PRs, branches, or current changes. Writes review.findings.json to the active session. Triggers on "review", "code review", "check PR".
allowed-tools:
  - Read
  - Write
  - Grep
  - Glob
  - Bash
  - Task
  - Skill
  - AskUserQuestion
---

# Work Reviewing Skill

Perform exhaustive code reviews using multi-agent analysis. Collect each reviewer's prose findings, structure them into the schema, dedup semantically, and write a merged `review.findings.json` into the active session directory.

**Architecture:** Reviewers return natural-language prose; the synthesizer (this skill) is the single schema enforcer. Reviewers focus on finding issues; structuring is the synthesizer's job.

## Input

The review target is provided via `$ARGUMENTS`. Can be:

- PR number (numeric): `123`
- GitHub URL: `https://github.com/org/repo/pull/123`
- Branch name: `feature/my-branch`
- Empty: review current branch changes

The **active session** is resolved via `.flywheel/plugin/active.json`. If that file is missing, error with:

```
No active session. Run /plan first.
```

---

## Phase 0: Setup

### Determine review target

```bash
git branch --show-current
# If PR number:
gh pr view <PR_NUM> --json title,body,files
```

### Setup environment

- If already on target branch: proceed with analysis.
- If different branch: offer to check out the target branch or create a worktree with `git worktree add`.

Ensure the code is ready for analysis before dispatching reviewers.

### Discover project context

Use Glob to find architectural docs once at the orchestrator level — reviewers consume the resulting paths instead of doing parallel discoveries:

- `CLAUDE.md`
- `agents.md`
- `docs/architecture.md`
- `docs/adrs/**/*.md`
- `docs/coding-guidelines*.md`

Collect the matching paths into `PROJECT_CONTEXT_PATHS`. Inline them in every reviewer dispatch under "PROJECT CONTEXT PATHS." If no docs match, pass `none` — reviewers skip discovery and apply universal principles only.

---

## Phase 1: Dispatch Reviewer Agents

Launch Task for every reviewer in a SINGLE message. Each Task prompt MUST include:

1. The diff / PR content inline (or a reference the reviewer can read)
2. Code-scope location format: `<repo-relative-path>` or `<repo-relative-path>:<line>`
3. The no-file-write constraint (reviewers return prose; synthesizer handles all file writes)
4. The active session's spec rationale (inlined from `spec.context`) — reviewers must distinguish *implementer error* from *plan-prescribed shape*

Read the active session's `spec.json` before composing the dispatch. Extract `spec.summary`, `spec.context.patterns`, and `spec.context.constraints` to paste inline below.

**Standard reviewer prompt shape:**

```
Before assessing your domain, Read `flywheel/skills/flywheel-conventions/references/elegance.md`, the "Lead with the Failure" section of `flywheel/skills/flywheel-conventions/SKILL.md`, and the project context paths listed below. The elegance lens applies to every domain — don't defer to reviewer-elegance.

Required output discipline:
1. Format each Failure as four slots: `**Failure:** <Principle name>. <Intent>. <Observation>. <Reasoning>.` Principle name = any well-known principle (elegance catalog, SOLID, DRY, language-specific anti-pattern, performance/data-integrity canonical name like "N+1 Query" or "Race Condition"). The synthesizer uses the leading name to route structural failures to redesign vs patch — keep it the first token.
2. Each Fix MUST propose the elegant alternative concretely, not just flag the issue. The implementer treats your Fix as a hypothesis — be specific without over-prescribing.

Review this change.

CHANGE:
[diff or PR content, or path the reviewer should Read]

PROJECT CONTEXT PATHS (read these for the project's grain — do not re-discover):
[list of paths from the Discover-project-context step in Phase 0, or "none" if no docs exist]

PLAN CONTEXT (from spec.json — the planner's design rationale):
- summary: <spec.summary>
- patterns: <spec.context.patterns>
- constraints: <spec.context.constraints>

The planner may have explicitly considered and rejected the alternative you'd suggest. Findings that contradict a documented rejection should explain why the rejection no longer holds — otherwise suppress them.

Entries in `constraints[]` starting with `Deferred:` record reviewer recommendations from plan-review that consolidation chose not to auto-integrate. The implementer may have taken some of these up by judgment — if a file or capability you see traces back to a `Deferred:` entry, that's principled extension, not implementer error. Note it once; don't re-flag the underlying recommendation as if it were new.

Use code-scope locations: `<repo-relative-path>` or `<repo-relative-path>:<line>`. Do NOT emit JSON; the synthesizer structures your output.

Do NOT write to any files. The synthesizer owns all file writes.
```

### Reviewer set selection (cost vs. coverage)

Determine the diff size before dispatching:

```bash
git diff <base>...HEAD --shortstat
# Use the "<n> insertions(+), <m> deletions(-)" line; sum = total lines changed.
```

Choose the set:

- **Default — all six** for changes ≥50 lines, refactors, new features, or anything the user flagged as design-impacting.
- **Slim — four (architecture, code-quality, patterns, elegance)** for hotfix-sized changes <50 lines that aren't refactors. Skip `reviewer-performance` (rarely fires for small diffs). `reviewer-elegance` STAYS in the slim set: small diffs are where elegance compounds — every line should justify itself, and elegance findings on small surfaces are precise.

When in doubt, run the default set. The slim set exists only to cut latency on small changes — coverage matters more than speed for design-impacting work.

Dispatch the chosen reviewers in parallel.

### Conditional reviewers

`reviewer-data-integrity` is always included in the default set. In the slim set, include it only when the change touches migration files (`**/migrations/**`, `alembic/`, `prisma/migrations/`). Outside those paths it rarely fires on small diffs.

---

## Phase 2: Synthesize Findings

The synthesizer reads each reviewer's prose output and structures it into `flywheel/schemas/findings.schema.json` shape. Reviewers do NOT emit JSON; the synthesizer is the single schema enforcer.

### 2.1 Read each reviewer's prose output

For each reviewer response:

- Extract per-finding: Title, Severity, Location, Failure (paragraph), Fix.
- If a reviewer returned "No findings" or equivalent, record zero findings from this reviewer.
- If a reviewer's output is incomplete (missing one of the required elements on any finding), construct a synthetic P1 against that reviewer's agent file noting the gap, AND retain the partial finding for the user's visibility.

Synthetic P1 shape (constructed by the synthesizer, in schema):

```json
{
  "title": "Reviewer output incomplete: <reviewer-name>",
  "severity": "P1",
  "location": "flywheel/agents/<reviewer-name>.md",
  "failure": "<reviewer-name> returned a finding missing one of the required elements (Title/Severity/Location/Failure/Fix). The structuring step couldn't fully ingest it; the synthesizer's review may be incomplete for this reviewer's domain. Without complete fields, downstream consumers can't reliably act on the finding.",
  "fix": "Investigate the reviewer's prompt or retry that reviewer. Check whether the agent file or dispatch text needs tightening."
}
```

### 2.2 Validate location format

This is work-review context, so location must be code-scope (`<repo-relative-path>` or `<repo-relative-path>:<line>`). If a reviewer emitted a plan-scope location like `phase-2/t1`, that's a disambiguation failure. Construct a synthetic P1 against the reviewer:

```json
{
  "title": "Wrong location tier: <reviewer-name> emitted plan-scope location in work-review",
  "severity": "P1",
  "location": "flywheel/agents/<reviewer-name>.md",
  "failure": "<reviewer-name> emitted location '<bad-location>' in a work-review context. Code reviews require code-scope locations like 'src/auth.ts' or 'src/auth.ts:42', not plan-scope phase ids. The reviewer must honor the location format the dispatch specified, otherwise findings can't be matched to actual files for fixes.",
  "fix": "Update the reviewer prompt or agent file so the location format always matches the invoker's tier."
}
```

Retain the original (mistargeted) finding alongside so the user can see what was flagged.

### 2.3 Semantic dedup

Walk the findings and group those describing the same issue — reviewers may phrase a shared concern differently (e.g., "missing type hints on handlers" vs "handlers lack return annotations" — same problem). Group by meaning, not by string match.

For each group:
- Take max severity (P1 > P2 > P3). Severity is not promoted by corroboration; a P3 that three reviewers flagged is still a P3.
- Merge the Failure paragraphs into a single rich paragraph that captures the union of intent + observation + reasoning. Preserve the leading principle name from the four-slot format — do not paraphrase the first token.
- Pick the strongest Fix or merge them into a single coherent proposal.

### 2.3a Drift arbitration (files outside spec scope)

When a reviewer finding targets a file that is NOT in `spec.phases[].files[]`, the synthesizer arbitrates before including it in the final output.

Procedure for each such finding:

1. Read the file. The reviewer flagged something specific; evaluate the finding against the actual file content.
2. **First check `spec.context.constraints[]` for `Deferred:` entries.** Consolidation surfaces deferred reviewer recommendations from plan-review (entries prefixed `Deferred:` or tagged `[Contradicts user]` and integrated as deferred). If the out-of-spec file is the implementer taking up one of those — e.g., `tests/test_app.py` matching a `Deferred: Untested HTTP Layer finding` constraint — this is **implementer-took-up-deferral**: principled extension by design. Note it once in the synthesis output (`"<path> — implementer took up deferred constraint '<title>'. Surface for user awareness; no finding."`) and otherwise treat the reviewer's content findings on the file on their merits, independent of the drift.
3. If not a deferred-uptake, evaluate intent: does the file's existence look like a **principled extension** (DRY crossed a threshold, SRP split, shared helper, test fixture), or **scope creep** (unrelated refactor, speculative abstraction, drive-by changes)?
4. **If principled extension**: keep or drop the reviewer's finding based on its merit, independent of the drift. Do NOT additionally flag "file outside baseline" — the file being outside baseline is not, by itself, a finding.
5. **If scope creep**: keep the reviewer's finding. Additionally emit a P2 synthetic finding with location `<path>` and title "Out-of-scope file: <path>" noting the unrelated work.

Principled-extension signals:
- File is in a `tests/fixtures/`, `shared/`, or similar reuse-pattern location
- Has 2+ production consumers (DRY threshold)
- Aligns with an agents.md / ADR rule the spec already cites in `context.patterns[]`
- No behavior change outside what the spec phases declared

Creep signals:
- Unrelated to any declared phase goal
- Single-consumer, no reuse
- Adds new behavior not declared in any phase
- Touches files/directories far from the phase's declared scope

The synthesizer applies this judgment once at merge time.

### 2.3b Tag contradictions with the verbatim prompt; scale findings to the change's actual surface

Two judgment calls I make as the synthesizer, in this order, before P3 triage. Both apply to findings of every severity.

**Tag — don't drop — contradictions with the verbatim user prompt.**

Reviewers review from a best-practices lens; they don't read the user's exact prompt. So when a reviewer pushes back on a user choice (e.g., suggests `Bun` where the user said `Node.js`, or suggests caching where the user explicitly scoped to "MVP — no caching"), the pushback is real information — users sometimes deviate from best practice out of laziness, not principle, and the reviewer's "you should be using X" deserves to surface so the user can confirm or revisit the decision.

I keep contradicting findings in the published list, but I tag them so downstream stages know they're advisory:

- Prefix the `title` with `[Contradicts user] `
- Append one sentence to `failure`: `Deferred: contradicts constraints[0] ('<user words>'); record the pushback, do not auto-apply.`

The contradiction shapes I tag:

- a different tool than the user named ("user said `Express`, finding says switch to `Fastify`")
- a different shape than the user specified ("user said handlers as plain functions, finding says wrap them in a service class")
- a different scope than the user asked for ("user said `read-only API for the MVP`, finding says add `POST` and `DELETE` endpoints")

Findings that fill in *underspecified* hows — robustness, security, type hints, error handling the user didn't speak to — pass through untagged. That's good scope growth.

The point of tagging instead of dropping: reviewer pushback is the value, not the noise. The tag preserves the record; downstream skills treat `[Contradicts user]`-tagged findings as advisory, not actionable.

**Scale findings to the change's actual size.**

If reviewers surface 30+ findings on a 300-line program, they're working the universal anti-pattern catalog rather than the specific code. I trust my judgment to drop the over-eager ones:

- Generic critiques the code doesn't earn ("method exceeds 50 lines" on a clearly readable handler)
- Style preferences with no behavioral consequence (`Path.replace` vs `os.replace`, `int` status codes vs `HTTPStatus`)
- Theoretical scaling concerns far below the code's actual demands ("fsync blocks single-threaded server" on a tiny app the user described as small)

The published count should reflect the change's real surface area. A small program rarely earns more than a handful of meaningful findings; if my output is much larger than the change deserves, I trim.

I apply both treatments (tag, then trim) after 2.3 (dedup) and 2.3a (arbitration), before 2.4 (P3 triage).

### 2.4 Triage P3 findings

After dedup, present P3 findings to the user:

```
P3 (Nice-to-have) findings:
1. [Finding title] — [one-line summary] (file:line)
2. [Finding title] — [one-line summary] (file:line)
...

Which P3 items should be included?
1. All
2. None
3. Pick specific ones (list numbers)
```

Keep only the P3s the user selects. Dropped P3s are omitted from `review.findings.json` entirely — they are not deferred.

If there are no P3 findings, skip this step.

### 2.5 Structure into schema and write

Compose the final JSON, conforming to `flywheel/schemas/findings.schema.json`:

```json
{
  "schema_version": 1,
  "findings": [ /* P1 + P2 + selected P3 findings, plus synthetic P1s for incomplete reviewers and wrong-location-tier */ ],
  "open_questions": [ /* union across reviewers */ ]
}
```

Validate against `flywheel/schemas/findings.schema.json`. If validation fails, the synthesizer's structuring step had a bug — fix and retry.

Resolve the target path via `.flywheel/plugin/active.json`:

```
.flywheel/plugin/sessions/<session_id>/review.findings.json
```

Write atomically: write to `review.findings.json.tmp` then rename.

---

## Phase 3: Summary & Next Steps

Print a condensed summary:

```
Work Review — <target>

Reviewers: N ran (<list>)
Findings: M total → K dedup groups
Severity: P1=<count>, P2=<count>, P3=<count kept>/<count dropped>
Wrong-location-tier violations: <count>
Incomplete reviewer outputs: <count>

Top findings:
- <title> (P1)
- <title> (P1)
- <title> (P2)

Review written to: .flywheel/plugin/sessions/<session_id>/review.findings.json
```

The "Top findings" list shows 3-5 highest-severity finding titles, ordered by severity then by appearance.

### Next-step prompt

```
What's next?
1. Implement review findings (invoke /work on the review file)
2. Ship as-is (skip to /ship)
```

- Option 1: invoke the `work` skill with the `review.findings.json` path as input.
- Option 2: proceed directly to `/ship`.

**No markdown write to `docs/reviews/`.** The durable artifact is `review.findings.json` in the session dir.

---

## Key Principles

- **P1 findings block merge.** Present them prominently in the chat summary.
- **Run reviewers in parallel.** Single message, multiple Task calls.
- **BLOCKING: Always persist the review.** Write `review.findings.json` before presenting the summary. The JSON is the single durable artifact that survives context clears.
- **Prompt for implementation.** After presenting findings, offer to invoke `work` on the review file.

---

## Error Handling

- **Active session missing**: error with "No active session. Run /plan first."
- **Reviewer failures**: emit synthetic P1 against that reviewer, continue with others. Minimum 50% reviewer success before proceeding.
- **Git/GitHub failures**: if PR not found, verify number. If branch inaccessible, suggest worktree. If gh CLI not authenticated, surface setup instructions.
- **File write failure**: retry once with the `.tmp` pattern; if still failing, include full findings in the chat summary rather than losing them.

---

## Anti-Patterns

- Don't present findings one-by-one asking for approval
- Don't skip reviewers to save time — parallel execution is fast
- Don't create vague findings without specific `location` references (`path` or `path:line`)
- Don't mark P1 findings as P2/P3 to avoid blocking merge
- Don't ask reviewers to emit JSON — they emit prose; the synthesizer structures
- Don't write markdown review docs to `docs/reviews/` — removed in the rigor-gradient refactor
- Don't end without prompting the user to implement findings

