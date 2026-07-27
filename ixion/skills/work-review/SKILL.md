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

The session is resolved in this order:

1. **Remembered id** — if this conversation already established a session id (the pipeline ran earlier, or an orchestrator passed one), that id is authoritative — not active.json. If active.json names a different session, another Claude Code session claimed the pointer since this run started; use the remembered id directly and don't touch active.json.
2. **Slug in `$ARGUMENTS`** (`^[a-z0-9-]+$`, and not a PR/URL/branch target) → prefix-scan `.ixion/plugin/sessions/<slug>-*`; tiebreak by most-recent date.
3. **Otherwise** → `.ixion/plugin/active.json`. If that file is missing, error with:

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

Run the "Project context discovery" step from `ixion/skills/ixion-conventions/references/reviewer-dispatch.md` to collect `PROJECT_CONTEXT_PATHS`.

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
<paste the "Dispatch preamble" from ixion/skills/ixion-conventions/references/reviewer-dispatch.md verbatim>

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

Entries in `constraints[]` starting with `Rejected:` record reviewer recommendations consolidation rejected because they contradict the user's verbatim description. If a file or capability you see traces back to a `Rejected:` entry, the implementer overrode the user's explicit choice — flag it; don't treat it as principled extension.

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

The synthesizer reads each reviewer's prose output and structures it into `ixion/schemas/findings.schema.json` shape. Reviewers do NOT emit JSON; the synthesizer is the single schema enforcer.

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
  "location": "ixion/agents/<reviewer-name>.md",
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
  "location": "ixion/agents/<reviewer-name>.md",
  "failure": "<reviewer-name> emitted location '<bad-location>' in a work-review context. Code reviews require code-scope locations like 'src/auth.rs' or 'src/auth.rs:42', not plan-scope phase ids. The reviewer must honor the location format the dispatch specified, otherwise findings can't be matched to actual files for fixes.",
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
2. **First check `spec.context.constraints[]` for `Rejected:` entries.** Consolidation records reviewer recommendations it rejected as contradictions (entries prefixed `Rejected:` or tagged `[Contradicts user]`). If the out-of-spec file is the implementer taking up one of those — e.g., `tests/http_layer.rs` matching a `Rejected: Untested HTTP Layer finding` constraint — this is **implementer-took-up-rejection**: the implementer overrode a constraint recorded to protect the user's explicit words. Emit a P2 synthetic finding with location `<path>` and title `Took up rejected constraint: <title>` so the contradiction surfaces for the user, and treat the reviewer's content findings on the file on their merits, independent of the drift.
3. If not a rejected-constraint uptake, evaluate intent: does the file's existence look like a **principled extension** (DRY crossed a threshold, SRP split, shared helper, test fixture), or **scope creep** (unrelated refactor, speculative abstraction, drive-by changes)?
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

Reviewers review from a best-practices lens; they don't read the user's exact prompt. So when a reviewer pushes back on a user choice (e.g., suggests `smol` where the user said `tokio`, or suggests caching where the user explicitly scoped to "MVP — no caching"), the pushback is real information — users sometimes deviate from best practice out of laziness, not principle, and the reviewer's "you should be using X" deserves to surface so the user can confirm or revisit the decision.

I keep contradicting findings in the published list, but I tag them so downstream stages know they're advisory:

- Prefix the `title` with `[Contradicts user] `
- Append one sentence to `failure`: `Rejected: contradicts constraints[0] ('<user words>'); record the pushback, do not auto-apply.`

The contradiction shapes I tag:

- a different tool than the user named ("user said `axum`, finding says switch to `actix-web`")
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

I apply both treatments (tag, then trim) after 2.3 (dedup) and 2.3a (arbitration), then run the empirical gate (2.3c) on what's left, before 2.4. Trimming first keeps me from spending commands on findings I was going to drop anyway.

### 2.3c Empirical gate on P1 runtime claims

Reviewers can't run anything. I can. Before a P1 goes out claiming the code misbehaves at runtime, I run the command its **Evidence** slot names and see for myself.

This applies only to P1 findings whose Failure asserts runtime misbehavior — wrong output, panic, hang, race, N+1, leak, resource exhaustion. Structural P1s are exempt (God Class, Layering Violation, and their kin), as is everything at P2 and P3, and anything tagged `[Contradicts user]`. Reviewing a plan? Skip this stage — there's no code to run.

For each qualifying P1:

| What the command does | What I do with the finding |
|---|---|
| Demonstrates the failure | Keep P1. Append the command and the salient output line to `failure`. |
| Runs clean — the claimed misbehavior doesn't happen | **Drop it.** Note the refutation in the summary. |
| Won't run (missing fixture, needs network, no such path) | Keep, downgrade to P2, append `unproven: <what blocked the check>`. |
| Evidence says `unproven:` already | Downgrade to P2. No command to run. |

The asymmetry is deliberate: reproducing keeps the P1, but failing to reproduce *deletes* the finding rather than demoting it. A defect report that got an honest attempt and didn't hold up is noise, and noise in a P1 list is what teaches the next reader to skim past the real findings. Expect to drop a real fraction of them — and treat a round where nothing dies as a sign the commands were too weak to falsify anything, not as a clean bill of health.

Two guardrails. Run only what the Evidence slot names — this is a review, so no editing files, no fixing anything, no `git` mutations. And if a command hangs or wants input, kill it and treat that as "won't run" rather than burning the round on it.

### 2.4 Structure into schema and write

All deduped findings persist — P1, P2, and P3 alike. There is no triage prompt; the fix pass applies every finding, and contradictions are already tagged `[Contradicts user]` for the fix pass to skip.

Compose the final JSON, conforming to `ixion/schemas/findings.schema.json`:

```json
{
  "schema_version": 1,
  "findings": [ /* ALL deduped findings, plus synthetic P1s for incomplete reviewers and wrong-location-tier */ ],
  "open_questions": [ /* union across reviewers */ ]
}
```

Validate against `ixion/schemas/findings.schema.json`. If validation fails, the synthesizer's structuring step had a bug — fix and retry.

Resolve the target path via `.ixion/plugin/active.json`:

```
.ixion/plugin/sessions/<session_id>/review.findings.json
```

Write atomically: write to `review.findings.json.tmp` then rename.

---

## Phase 3: Summary & Next Steps

Print a condensed summary:

```
Work Review — <target>

Reviewers: N ran (<list>)
Findings: M total → K dedup groups
Severity: P1=<count>, P2=<count>, P3=<count>
P1 runtime claims: <checked> checked → <reproduced> reproduced, <refuted> refuted, <unproven> unproven
Wrong-location-tier violations: <count>
Incomplete reviewer outputs: <count>

Top findings:
- <title> (P1)
- <title> (P1)
- <title> (P2)

Review written to: .ixion/plugin/sessions/<session_id>/review.findings.json
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

If a finding this round repeats one from a previous review of the same codebase, that's knowledge worth keeping — offer to run the `compound` skill to capture the recurring pattern.

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

