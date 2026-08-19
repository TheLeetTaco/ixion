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
- Session locator: a full session id or a bare slug
- Empty: review the current branch's changes against the active session

---

## Phase 0: Setup

### Resolve the session

Read `ixion/skills/ixion-conventions/references/session-handoff.md` now and hold its blocks — Phase 3 cites it again for the resume command.

`$ARGUMENTS` here may be a review target rather than a session locator, and one shape is genuinely both: `fix-login-2026-08-06` is a legal branch name *and* a legal session id. **An existing session directory wins the tiebreak** — the session is what supplies the `spec.json` reviewers are dispatched with, whereas a branch name only says which diff to read, and Phase 1 derives that from the session's `base_ref` anyway. So the argument is a locator only when it names a session on disk — under the repository root, which the block above resolves once for every session path this skill builds:

```bash
<paste the "Resolve the session root" block from ixion/skills/ixion-conventions/references/session-handoff.md verbatim>
```

```bash
<paste the "Does a token name a session?" block from ixion/skills/ixion-conventions/references/session-handoff.md verbatim, with TOKEN set to the whole of $ARGUMENTS>
```

`names_session=yes` — `LOCATOR` is that whole argument. `names_session=no` — leave `LOCATOR` empty, which sends resolution to the pointer instead of erroring on a session that was never named, and leaves the argument free to be what it is: a PR number, a URL, or a branch this repo has no session for.

```bash
<paste the "Resolve the session" block from ixion/skills/ixion-conventions/references/session-handoff.md verbatim>
```

```bash
<paste the "Validate the resolved session" block from ixion/skills/ixion-conventions/references/session-handoff.md verbatim>
```

An empty `repo_root=`, `via=none`, `state=missing`, `state=schema-mismatch` and `state=complete` each halt with the message that file's "Error states" table gives, verbatim. Only `state=usable` continues.

### Determine review target

```bash
git branch --show-current
# If PR number:
gh pr view <PR_NUM> --json title,body,files
```

### Stand where the work is

A session under review has its own worktree — `work` gives every session one — and its branch is checked out there and nowhere else. Derive that path rather than reviewing whatever the invoking checkout happens to hold:

```bash
<paste the "Derive the session worktree" block from ixion/skills/ixion-conventions/references/session-handoff.md verbatim>
```

`present=yes` — `cd` into `worktree=` and run the rest of this skill from there, so the diff below and the reviewers' file reads see the session's own tree.

`present=no` — say which path was expected and stop. A session that reached review has a worktree; its absence means `ship` already retired it, and the checkout you are standing in holds a different branch's work that no reviewer should be handed as this session's.

This applies when the review target is the resolved session's own work, which is the pipeline case. A PR number or URL names a target that came from GitHub rather than from this session; review that one where you stand.

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
<paste the "Resolve the branch roles" block from ixion/skills/ixion-conventions/references/git-branches.md verbatim>
```

```bash
<paste the "Read a session field" block from ixion/skills/ixion-conventions/references/session-handoff.md verbatim, with FILE set to "<dir= from Phase 0>/session.json" and FIELD set to base_ref>
BASE_REF=$VALUE
[ "$BASE_REF" = null ] && BASE_REF=$(git merge-base HEAD '<integration branch>')
git diff "$BASE_REF"..HEAD --shortstat
# Use the "<n> insertions(+), <m> deletions(-)" line; sum = total lines changed.
```

`<integration branch>` is the `integration=` line the first block printed.

`work` recorded `base_ref` in Phase 1 as this branch's starting commit, and committed each chunk as it verified it — so the session's work is in commits on this branch, and only a diff against `base_ref` sees it. Measuring against `HEAD` alone, or against production, sizes the reviewer set off the wrong number.

The field is optional in `session.schema.json` — a review of a session that predates checkpoint commits, or of a branch `work` never touched, finds it absent, and the read block prints the four-character string `null` for that, which `git diff` rejects. The merge-base against the integration branch is the same base `work` would have recorded.

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

Run the "Read each reviewer's prose output" step from `ixion/skills/ixion-conventions/references/finding-synthesis.md`.

### 2.2 Validate location format

Run the "Validate the location tier" step from `ixion/skills/ixion-conventions/references/finding-synthesis.md`. This is work-review context, so code-scope is the required tier and a plan-scope location is the violation.

### 2.3 Semantic dedup

Run the "Semantic dedup" step from `ixion/skills/ixion-conventions/references/finding-synthesis.md`.

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

Run the "Tag contradictions, then scale findings to the target's actual size" step from `ixion/skills/ixion-conventions/references/finding-synthesis.md`, after 2.3 (dedup) and 2.3a (arbitration), then run the empirical gate (2.3c) on what's left, before 2.4. Trimming first keeps me from spending commands on findings I was going to drop anyway.

### 2.3c Empirical gate on runtime claims

Reviewers can't run anything. I can. Before a finding goes out claiming the code misbehaves at runtime, I run the command its **Evidence** slot names and see for myself.

This applies at every severity — P1, P2 and P3 alike — to any finding whose Failure asserts runtime misbehavior (wrong output, panic, hang, race, N+1, leak, resource exhaustion) and whose Evidence slot names a command. What stays outside the gate: structural findings at any severity (God Class, Layering Violation, and their kin), anything tagged `[Contradicts user]`, and plan review, which has no code to run.

For each qualifying finding:

| What the command does | What I do with the finding |
|---|---|
| Demonstrates the failure | Keep it at its severity. Append the command and the salient output line to `failure`. |
| Runs clean — the claimed misbehavior doesn't happen | **Drop it.** Note the refutation in the summary. |
| Won't run (missing fixture, needs network, no such path) | Keep, downgrade exactly one tier — P1 to P2, P2 to P3, and a P3 stays P3 because there is no lower tier — and append `unproven: <what blocked the check>`. |
| Evidence says `unproven:` already | Downgrade one tier on that same scale. No command to run. |

The asymmetry is deliberate: reproducing keeps the finding where it is, but failing to reproduce *deletes* it rather than demoting it, at P3 as much as at P1. A defect report that got an honest attempt and didn't hold up is noise, and noise in a findings list is what teaches the next reader to skim past the real ones. Expect to drop a real fraction of them — and treat a round where nothing dies as a sign the commands were too weak to falsify anything, not as a clean bill of health.

Dropping is the one outcome that leaves nothing behind: the finding's body is gone and the console summary scrolls away. So before I delete a refuted finding I append a line to `open_questions[]` — `Refuted and dropped: <title> (<location>) — <command> gave <the output line that refuted it>`. That array takes freeform strings, and it's the only place a later session can read what I deleted and why. The `Refuted and dropped:` prefix is what keeps the array readable now that it carries two things: everything else in it is a question still waiting on an answer, and an entry wearing this prefix is a settled record that needs none — the same marker-in-the-text convention `[Contradicts user]` uses on a finding title.

I spend at most **12 commands per round**, and I spend them a pass at a time: one P1, one P2, one P3, then the next of each, taking appearance order within a severity. Cycling rather than draining P1 first is what keeps the budget from re-creating the defect this gate was widened to close — a round whose P1 list alone reaches 12 would otherwise pass every P2 and P3 runtime claim through unchecked into a fix pass that fixes all three tiers. Every command's output lands in my context as well as on the clock, and the gate now reaches findings a large review produces by the dozen. A finding I never reach keeps the severity its reviewer proposed and gets `unproven: gate budget exhausted` appended to `failure` — I don't attempt it, and I don't downgrade it for a check I chose not to run.

The 12 is a starting value, not a measurement: no round has been counted yet. The Phase 3 summary reports how many qualifying findings I left unattempted alongside how many I checked, so the next person to touch this number sets it from a round that actually ran, and a starved round reads differently from a clean one.

Two guardrails. Run only what the Evidence slot names — this is a review, so no editing files, no fixing anything, no `git` mutations. And if a command hangs or wants input, kill it and treat that as "won't run" rather than burning the round on it.

### 2.4 Structure into schema and write

Every finding that survived 2.3c persists — P1, P2, and P3 alike. There is no triage prompt; the fix pass applies every finding it receives, which now means every finding whose runtime claim wasn't refuted. Contradictions are already tagged `[Contradicts user]` for the fix pass to skip.

Compose the final JSON, conforming to `ixion/schemas/findings.schema.json`:

```json
{
  "schema_version": 1,
  "findings": [ /* ALL deduped findings, plus synthetic P1s for incomplete reviewers and wrong-location-tier */ ],
  "open_questions": [ /* union across reviewers, plus one "Refuted and dropped:" record per finding the gate killed */ ]
}
```

Validate against `ixion/schemas/findings.schema.json`. If validation fails, the synthesizer's structuring step had a bug — fix and retry.

Write into the session Phase 0 resolved:

```
<dir= from Phase 0>/review.findings.json
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
Gated runtime claims (all severities): <checked> checked → <reproduced> reproduced, <refuted> refuted, <unproven> unproven; <unattempted> unattempted at the budget
Wrong-location-tier violations: <count>
Incomplete reviewer outputs: <count>

Top findings:
- <title> (P1)
- <title> (P1)
- <title> (P2)

Review written to: <dir= from Phase 0>/review.findings.json
```

The "Top findings" list shows 3-5 highest-severity finding titles, ordered by severity then by appearance.

### Next-step prompt

Read `ixion/skills/ixion-conventions/references/question-format.md` before proceeding — it contains the question shape, the Why-you slot, and the four reasons that decide whether to ask at all.

```
What's next?
**Why you:** Preference. The findings are on disk either way; whether they earn a fix pass before the PR is a judgment about this change's risk, not about the findings.
1. Implement review findings (Recommended)
2. Ship as-is
3. "You pick what's best" - Let me decide
```

If a finding this round repeats one from a previous review of the same codebase, that's knowledge worth keeping — offer to run the `compound` skill to capture the recurring pattern.

Option 1 is `work` again — it detects fix-findings mode from the completed plan-mode `progress.json` plus the `review.findings.json` just written, so it takes the same session id as every other invocation and no path argument. Print both onward commands under the prompt, so choosing later — after a `/clear` — costs nothing:

```bash
<paste the "Resume command" block from ixion/skills/ixion-conventions/references/session-handoff.md verbatim, with SKILLS='work ship'>
```

**No markdown write to `docs/reviews/`.** The durable artifact is `review.findings.json` in the session dir.

---

## Key Principles

- **P1 findings block merge.** Present them prominently in the chat summary.
- **Run reviewers in parallel.** Single message, multiple Task calls.
- **BLOCKING: Always persist the review.** Write `review.findings.json` before presenting the summary. The JSON is the single durable artifact that survives context clears.
- **Prompt for implementation.** After presenting findings, offer to invoke `work` on the review file.

---

## Error Handling

- **Session resolution failures**: Phase 0 halts on them with the `session-handoff.md` "Error states" messages.
- **Reviewer failures**: emit synthetic P1 against that reviewer, continue with others. Minimum 50% reviewer success before proceeding.
- **Git/GitHub failures**: if PR not found, verify number. If gh CLI not authenticated, surface setup instructions.
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

