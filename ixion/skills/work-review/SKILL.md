---
name: work-review
description: Perform exhaustive code reviews using multi-agent analysis. Reviews a named session's work, a checked-out branch, or the current changes. Writes review.findings.json into the session under review, or under .ixion/plugin/reviews/ when there is no session. Triggers on "review", "code review", "check the diff".
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

- Branch name: `feature/my-branch`
- Session locator: a full session id or a bare slug
- Empty: review the current branch's changes against the active session

---

## Phase 0: Setup

### Resolve the session

Read `${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/session-handoff.md` now and hold its blocks — Phase 3 cites it again for the resume command. Paste each block from what you read; a Phase 0 written from memory resolves plausible-looking values that send the diff, the reviewers and the findings to three different trees.

`$ARGUMENTS` here may be a review target rather than a session locator, and one shape is genuinely both: `fix-login-2026-08-06` is a legal branch name *and* a legal session id. **An existing session directory wins the tiebreak** — the session is what supplies the `spec.json` reviewers are dispatched with, whereas a branch name only says which diff to read, and Phase 1 derives that from the session's `base_ref` anyway. So the argument is a locator only when it names a session on disk — under the repository root, which the block above resolves once for every session path this skill builds:

```bash
<paste the "Resolve the session root" block from ${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/session-handoff.md verbatim>
```

```bash
<paste the "Does a token name a session?" block from ${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/session-handoff.md verbatim, with TOKEN set to the whole of $ARGUMENTS>
```

`names_session=yes` — `LOCATOR` is that whole argument. `names_session=no` — leave `LOCATOR` empty, which sends resolution to the pointer instead of erroring on a session that was never named, and leaves the argument free to be what it is: a branch this repo has no session for.

```bash
<paste the "Resolve the session" block from ${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/session-handoff.md verbatim>
```

```bash
<paste the "Validate the resolved session" block from ${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/session-handoff.md verbatim>
```

An empty `repo_root=`, `state=missing`, `state=schema-mismatch` and `state=complete` each halt with the message that file's "Error states" table gives, verbatim — each is a session that was named and is unusable.

`via=none` is the signal that does not halt, exactly as in `ship`: nothing named a session, which is an **ad-hoc review** — a branch, or the changes on the checkout you are standing in, with no Ixion session behind them. That is a supported way to use this skill, and halting there would answer it by naming two skills the user didn't ask for. Continue to the target block.

### Derive the session worktree

```bash
<paste the "Derive the session worktree" block from ${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/session-handoff.md verbatim>
```

An ad-hoc review resolved no session, so this prints `present=no` and the block below takes the other branch.

### Resolve the review target, its tree, and where the review is written

Three things are decided together because each depends on the same answer: which tree holds the code, and which directory this review belongs to.

```bash
REPO_ROOT='<repo_root= from the session-root block>'
[ -n "$REPO_ROOT" ] || { printf 'repo_root=\n'; exit 1; }
SDIR='<dir= from the validation block, empty on an ad-hoc review>'
TARGET='<the whole of $ARGUMENTS, or empty>'
NAMES_SESSION='<names_session= from the token probe>'
KIND=
TREE=
OUT=

if [ -n "$SDIR" ] && { [ "$NAMES_SESSION" = yes ] || [ -z "$TARGET" ]; }; then
  KIND=session
  TREE='<worktree= from the derive block>'
  [ '<present= from the derive block>' = yes ] || KIND=worktree-gone
  OUT="$SDIR"
elif [ -n "$TARGET" ]; then
  if git show-ref --verify --quiet "refs/heads/$TARGET"; then
    KIND=branch
    TREE=$(git worktree list --porcelain \
      | awk -v b="refs/heads/$TARGET" '/^worktree /{w=substr($0,10)} $0=="branch "b{print w; exit}')
    [ -n "$TREE" ] || KIND=not-checked-out
  elif git show-ref --verify --quiet "refs/remotes/origin/$TARGET"; then
    KIND=remote-only
  else
    KIND=unknown
  fi
  OUT="$REPO_ROOT/.ixion/plugin/reviews/$TARGET-$(date -u +%F)"
else
  KIND=checkout
  TREE='<checkout_root= from the session-root block>'
  OUT="$REPO_ROOT/.ixion/plugin/reviews/$(git -C "$TREE" branch --show-current)-$(date -u +%F)"
fi

[ "$KIND" = session ] || [ -z "$TREE" ] || mkdir -p "$OUT"
printf 'kind=%s\ntree=%s\nout=%s\n' "$KIND" "$TREE" "$OUT"
```

A usable session is the target on two routes and not on a third: the argument named it (`names_session=yes`), or there was no argument at all and the pointer supplied it — the bare `/ixion:work-review` that follows a `/work`. An argument that names a *branch* is honoured as a branch even when a pointer session happens to be usable, which is the tiebreak the section above states.

`kind=` decides everything below, and four of its six values stop here with a message of their own:

| `kind=` | What it is |
|---|---|
| `session` | The pipeline case: the resolved session's own work, in its own worktree, reviewed against its `spec.json`. |
| `branch` | An ad-hoc review of a named branch, in whichever worktree has it checked out. |
| `checkout` | An ad-hoc review of the changes on the tree you were invoked from. |
| `worktree-gone` | The session resolved and its worktree is absent. Name the path that was expected and stop — it was retired after its PR merged, and the checkout you are standing in holds a different branch's work that no reviewer should be handed as this session's. |
| `not-checked-out` | The branch exists and no worktree holds it. Say so, and say that `git worktree add <path> <branch>` is what makes it reviewable — 2.3c runs the Evidence commands the reviewers name, and a tree with no dependencies installed fails every one of them, so a throwaway checkout would answer "won't run" to the whole gate. Stop. |
| `remote-only` / `unknown` | The argument names a remote-only branch, or neither a session on disk nor a ref in this repo. Say which, and stop. A bare number lands on `unknown` rather than in a lookup of its own. |

`tree=` is the one directory every block below stands in. It is a sibling of the repository root in the `session` case and can be one in the `branch` case, so a `cd` into it does not carry to the next Bash call and a dispatched reviewer does not start there — `session-handoff.md`'s "Derive the session worktree" section says why. Every Bash block below that reads the tree therefore begins with `cd '<tree= from Phase 0>' || exit 1`, and every path that leaves this skill — to a reviewer, or to Read — is absolute under it.

`out=` is where the diff and the findings are written, and on an ad-hoc review it is **never a session directory**. Writing into the session `active.json` happens to name would hand findings from an unrelated branch to that session's next `/work`, which reads a present `review.findings.json` as its instruction to start a fix pass. A second review of the same branch on the same day replaces the first; the session case is unaffected, because its `out=` is the session dir it has always been.

### Discover project context

Run the "Project context discovery" step from `${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/reviewer-dispatch.md` to collect `PROJECT_CONTEXT_PATHS`, with `tree=` as the root it Globs from.

---

## Phase 1: Dispatch Reviewer Agents

Launch Task for every reviewer in a SINGLE message. Each Task prompt MUST include:

1. The absolute path of the staged diff and of the source root it was cut from — never the diff inline, and never a relative path
2. Code-scope location format: `<repo-relative-path>` or `<repo-relative-path>:<line>`
3. The no-file-write constraint (reviewers return prose; synthesizer handles all file writes)
4. On `kind=session`, the session's spec rationale (inlined from `spec.context`) — reviewers must distinguish *implementer error* from *plan-prescribed shape*

On `kind=session`, read the session's `spec.json` before composing the dispatch and extract `spec.summary`, `spec.context.patterns` and `spec.context.constraints` to paste inline below. An ad-hoc review has no spec: pass `PLAN CONTEXT: none — this change was not planned through Ixion; judge it on its own merits and on the project context paths.` and drop the two paragraphs below it about documented rejections, which describe a `constraints[]` array that does not exist here.

**Standard reviewer prompt shape:**

```
<paste the "Dispatch preamble" from ${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/reviewer-dispatch.md verbatim>

Review this change.

CHANGE: Read the diff at <out= from Phase 0>/review.diff for what changed, then open the source files themselves under <tree= from Phase 0> for anything you intend to cite — that tree holds the change; the directory you start in does not. Every `location` you report must be a line number in the SOURCE file, verified by reading that file — never an offset into the diff. If you cannot confirm a line number in the source, cite the file path alone.

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

The diff is staged once, below, and reviewers Read it by path. Inlined, it would be emitted six times into this skill's own context; staged without the sentence about numbering, it is what a reviewer then cites offsets from — `docs/solutions/mistakes/reviewers-given-a-diff-file-cite-diff-offsets-System-20260804.md` is the round that taught both halves.

### Reviewer set selection (cost vs. coverage)

Determine the diff size before dispatching:

```bash
<paste the "Resolve the branch roles" block from ${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/git-branches.md verbatim>
```

```bash
cd '<tree= from Phase 0>' || exit 1
BASE_REF=null
if [ '<kind= from Phase 0>' = session ]; then
  <paste the "Read a session field" block from ${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/session-handoff.md verbatim, with FILE set to "<dir= from Phase 0>/session.json" and FIELD set to base_ref>
  BASE_REF=$VALUE
fi
[ "$BASE_REF" = null ] && BASE_REF=$(git merge-base HEAD '<integration branch>')
git diff "$BASE_REF"..HEAD --shortstat
git diff "$BASE_REF"..HEAD > '<out= from Phase 0>/review.diff'
# Use the "<n> insertions(+), <m> deletions(-)" line; sum = total lines changed.
```

`<integration branch>` is the `integration=` line the first block printed.

`work` recorded `base_ref` in Phase 1 as this branch's starting commit, and committed each chunk as it verified it — so the session's work is in commits on this branch, and only a diff against `base_ref` sees it. Measuring against `HEAD` alone, or against production, sizes the reviewer set off the wrong number.

The field is optional in `session.schema.json`, and an ad-hoc review reads no session file at all — a review of a session that predates checkpoint commits finds it absent and the read block prints the four-character string `null`, which `git diff` rejects. Both fall back to the merge-base against the integration branch, which is the same base `work` would have recorded, and which for an ad-hoc review is exactly the diff its PR would carry.

Choose the set:

- **Default — all six** for changes ≥50 lines, refactors, new features, or anything the user flagged as design-impacting.
- **Slim — four (architecture, code-quality, patterns, elegance)** for hotfix-sized changes <50 lines that aren't refactors. Skip `reviewer-performance` (rarely fires for small diffs). `reviewer-elegance` STAYS in the slim set: small diffs are where elegance compounds — every line should justify itself, and elegance findings on small surfaces are precise.

When in doubt, run the default set. The slim set exists only to cut latency on small changes — coverage matters more than speed for design-impacting work.

Dispatch the chosen reviewers in parallel.

### Conditional reviewers

`reviewer-data-integrity` is always included in the default set. In the slim set, include it only when the change touches migration files (`**/migrations/**`, `alembic/`, `prisma/migrations/`). Outside those paths it rarely fires on small diffs.

---

## Phase 2: Synthesize Findings

The synthesizer reads each reviewer's prose output and structures it into `${CLAUDE_PLUGIN_ROOT}/schemas/findings.schema.json` shape. Reviewers do NOT emit JSON; the synthesizer is the single schema enforcer.

### 2.1 Read each reviewer's prose output

Run the "Read each reviewer's prose output" step from `${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/finding-synthesis.md`.

### 2.2 Validate location format

Run the "Validate the location tier" step from `${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/finding-synthesis.md`. This is work-review context, so code-scope is the required tier and a plan-scope location is the violation.

Then, for every `<path>:<line>` location, confirm the line is within that file's length under `<tree= from Phase 0>`, and where it is not, re-anchor by grepping the quoted content. A finding whose anchor is out of range keeps its reasoning and loses its number — cite the path alone rather than send the fix pass to a line that does not exist.

### 2.3 Semantic dedup

Run the "Semantic dedup" step from `${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/finding-synthesis.md`.

### 2.3a Drift arbitration (files outside spec scope)

**`kind=session` only.** Drift is measured against the spec's declared files, and an ad-hoc review has no spec — there is nothing for a file to have drifted from, so skip this step entirely rather than inventing a baseline. Every finding is then judged on its merits, which is what steps 4 and 5 do anyway.

When a reviewer finding targets a file that is NOT in `spec.phases[].files[]`, the synthesizer arbitrates before including it in the final output.

Procedure for each such finding:

1. Read the file at its absolute path under `<tree= from Phase 0>` — the checkout you started in holds the pre-change version. The reviewer flagged something specific; evaluate the finding against the actual file content.
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

Run the "Tag contradictions, then scale findings to the target's actual size" step from `${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/finding-synthesis.md`, after 2.3 (dedup) and 2.3a (arbitration), then run the empirical gate (2.3c) on what's left, before 2.4. Trimming first keeps me from spending commands on findings I was going to drop anyway.

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

The counts go into the file as well as the console, as one more `open_questions[]` entry: `Gate: <checked> checked → <reproduced> reproduced, <refuted> refuted, <unproven> unproven; <unattempted> unattempted at the budget` — the same line Phase 3 prints, wearing a prefix the same way `Refuted and dropped:` does. The console line scrolls away with the session; the file line is what `ship` copies into the PR body, and `gh pr list --json body` over merged PRs is then the first measurement of whether the reviewers pay for their tokens. A round with no qualifying findings still writes the line with zeros, because "the gate had nothing to check" and "the gate was skipped" must read differently.

Three guardrails. Run only what the Evidence slot names — this is a review, so no editing files, no fixing anything, no `git` mutations. Run it with `cd '<tree= from Phase 0>' &&` in front, because the tree under review is not where a Bash call starts. And if a command hangs or wants input, kill it and treat that as "won't run" rather than burning the round on it.

### 2.4 Structure into schema and write

Every finding that survived 2.3c persists — P1, P2, and P3 alike. There is no triage prompt; the fix pass applies every finding it receives, which now means every finding whose runtime claim wasn't refuted. Contradictions are already tagged `[Contradicts user]` for the fix pass to skip.

Compose the final JSON, conforming to `${CLAUDE_PLUGIN_ROOT}/schemas/findings.schema.json`:

```json
{
  "schema_version": 1,
  "findings": [
    {
      "title": "<short scannable phrase>",
      "severity": "P1",
      "location": "<repo-relative-path>:<line>",
      "failure": "<Principle name>. <Intent>. <Observation>. <Reasoning>.",
      "fix": "<concrete proposed change>"
    }
  ],
  "open_questions": [ /* union across reviewers, plus one "Refuted and dropped:" record per finding the gate killed, plus the one "Gate:" count line */ ]
}
```

Those five keys are the whole of a finding and the names are not negotiable: `failure` and `fix` carry the four-slot paragraph and the proposed change, and a synthesizer that writes `description` and `feedback` instead produces a file the schema rejects and the fix pass cannot read. Observed 2026-08-21. `${CLAUDE_PLUGIN_ROOT}/schemas/findings.example.json` is a filled-in copy if you want one.

Validate against `${CLAUDE_PLUGIN_ROOT}/schemas/findings.schema.json`. If validation fails, the synthesizer's structuring step had a bug — fix and retry.

Write into the directory Phase 0 resolved:

```
<out= from Phase 0>/review.findings.json
```

Write atomically: write to `review.findings.json.tmp` then rename. On `kind=session` that is the session directory, which is what `work` reads to enter fix-findings mode. On an ad-hoc review it is the per-review directory under `.ixion/plugin/reviews/`, which nothing reads — see Phase 3.

**If you are about to write under `.ixion/plugin/reviews/`, read `kind=` again.** That directory exists only for `branch` and `checkout` — reviews with no session behind them. A review that resolved a session and lands there is stranded: `work` reads `review.findings.json` from the session directory and nowhere else, so the fix pass this review exists to feed never sees it, and the session looks reviewed while carrying no findings. Observed on 2026-08-21, in a run where Phase 0's block was recalled rather than pasted. There are exactly two destinations and `out=` is which one — do not compose a third from the session id.

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

Review written to: <out= from Phase 0>/review.findings.json
```

The "Top findings" list shows 3-5 highest-severity finding titles, ordered by severity then by appearance.

### Next-step prompt

**`kind=session`.** Read `${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/question-format.md` before proceeding — it contains the question shape, the Why-you slot, and the four reasons that decide whether to ask at all.

```
What's next?
**Why you:** Preference. The findings are on disk either way; whether they earn a fix pass before the merge is a judgment about this change's risk, not about the findings.
1. Implement review findings (Recommended)
2. Ship as-is
3. "You pick what's best" - Let me decide
```

Option 1 is `work` again — it detects fix-findings mode from the completed plan-mode `progress.json` plus the `review.findings.json` just written, so it takes the same session id as every other invocation and no path argument. Print both onward commands under the prompt, so choosing later — after a `/clear` — costs nothing:

```bash
<paste the "Resume command" block from ${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/session-handoff.md verbatim, with SKILLS='work ship'>
```

**An ad-hoc review asks nothing**, and says why in one line: the findings are a report, not a pipeline input. `work` detects fix-findings mode from a session's own `progress.json` and `review.findings.json` — never from a path handed to it — so there is no session for these findings to drive, and inventing one would put a spec-less session in front of a fix pass whose dispatch is built from `spec.context`. Print the `out=` path and stop. Naming a session to review is what makes a fix pass available, and the Why-you gate is why this is a stated fact rather than a question: nothing here is the user's to decide.

Either way, if a finding this round repeats one from a previous review of the same codebase, that's knowledge worth keeping — offer to run the `compound` skill to capture the recurring pattern.

**No markdown write to `docs/reviews/`.** The durable artifact is `review.findings.json` in the session dir.

---

## Key Principles

- **P1 findings block merge.** Present them prominently in the chat summary.
- **Run reviewers in parallel.** Single message, multiple Task calls.
- **BLOCKING: Always persist the review.** Write `review.findings.json` before presenting the summary. The JSON is the single durable artifact that survives context clears.
- **BLOCKING: Never write findings into a session the user did not name.** An ad-hoc review resolves through the pointer only to discover there is nothing there; writing its findings into whatever `active.json` happens to name would start that session's next `/work` on a fix pass for another branch's code.
- **Prompt for implementation.** After presenting findings, offer to invoke `work` on the review file.

---

## Error Handling

- **Session resolution failures**: Phase 0 halts on them with the `session-handoff.md` "Error states" messages.
- **Reviewer failures**: emit synthetic P1 against that reviewer, continue with others. Minimum 50% reviewer success before proceeding.
- **Unresolvable target**: `kind=unknown`, `remote-only`, `not-checked-out` and `worktree-gone` each halt before dispatch with the message the Phase 0 table gives.
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

