---
name: plan
description: Full planning workflow — create (with integrated validation), review, and consolidate. Orchestrates plan-creation, plan-review, and plan-consolidation. Triggers on "/plan", "create plan", "plan for".
argument-hint: "[feature description OR path to *-design.md OR slug of existing session]"
allowed-tools:
  - Read
  - Bash
  - Skill
  - AskUserQuestion
---

# Full Planning Workflow

**MANDATORY FIRST ACTION — load the correct skill below with the Skill tool and start doing what it says, BEFORE anything else. Do NOT read files, search code, or respond to the user first.**

**A skill is instructions, not a job.** Loading one with the Skill tool puts its steps in front of you and hands the work to *you*. Nothing runs in the background, no agent is dispatched on your behalf, and no completion notification is ever coming — if you finish a turn saying you will wait for one, this workflow stops dead and the user gets nothing. You are the one who does every step of all three skills.

**Pick the first skill from the input:**

An input naming an existing session routes to review; anything else starts a new plan. Resolve it with the shared rules rather than pattern-matching the string — a bare slug and a full session id both name a session, and only the exact-match rung tells a full id apart from its own `-2` collision sibling:

```bash
<paste the "Resolve the session" block from ${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/session-handoff.md verbatim, with LOCATOR set to $ARGUMENTS>
```

- `session=` names a directory holding `spec.json` → start with `plan-review`, passing that id
- anything else — a feature description, a path to a `*-design.md`, or a slug matching no session → start with `plan-creation`

With no input at all there is nothing to resolve: go straight to `plan-creation`, which asks for the description.

**Load it NOW and begin carrying out its steps:**

```
skill: plan-creation
```

OR if the input resolves to an existing session with spec.json:

```
skill: plan-review
```

<input> #$ARGUMENTS </input>

**Note: The current year is 2026.**

---

## IMPORTANT: Planning Mode Only

**DO NOT WRITE OR EDIT ANY CODE DURING PLANNING!**

This workflow is for research and planning only. Implementation happens in `/work`.

---

## Running the rest of the sequence

You run three skills back to back, doing the work of each one yourself. When you finish the last step of one, load the next and keep going — **do not stop between them**, and when a "continue" option is offered, take it.

**Each skill is done when its artifact is on disk, not when you have described it.** That file is the only proof the skill ran:

| Skill | Done when this exists |
|---|---|
| plan-creation | `spec.json` in the session dir |
| plan-review | `review.findings.json` in the session dir |
| plan-consolidation | `spec.json.pre-consolidation` beside a refined `spec.json` |

Check for the file before moving on. If it is not there, the skill has not run yet no matter what you have already said about it — go back and do the steps.

### Full sequence:

```
[Input] → plan-creation → plan-review → plan-consolidation → [Present]
```

After plan-creation, the session dir at `<repo root>/.ixion/plugin/sessions/<session-id>/` contains the spec.json and session.json that subsequent skills read. The active pointer `.ixion/plugin/active.json` is the glue for bare interactive invocations only — as the orchestrator, capture the session id plan-creation prints and pass it to plan-review and plan-consolidation explicitly (`skill: plan-review` with the id as input). A concurrent Claude Code session can retarget active.json mid-run; the id you captured is this run's identity.

1. **plan-creation** → writes `spec.json`, `session.json` into the session dir; updates `active.json`
2. **plan-review** → reads the active session's spec.json, writes `review.findings.json`
3. **plan-consolidation** → merges `review.findings.json` into `spec.json`; backs up pre-consolidation spec to `spec.json.pre-consolidation`

If the input was a slug that resolved to an existing session (review mode), start at step 2.

### Loading each subsequent skill:

Once `spec.json` is on disk, load and run:
```
skill: plan-review
```

Once `review.findings.json` is on disk, load and run:
```
skill: plan-consolidation
```

Pass the captured session id to both — they accept a slug/id argument. Bare invocations fall back to `.ixion/plugin/active.json`, but explicit passing is what keeps this run pinned to its own session if another Claude Code session moves the pointer.

### Phase 4: Present Results

Three parts, in this order. The metrics first, then the overview — and the overview is the part I actually read — then the resume command.

`plan-consolidation` signs off with its own short summary and a "what next?" prompt. That is not this. It's the last child skill closing out, and when it returns you still owe me the overview below before the run is finished — answering the next-step prompt is not the end of the pipeline.

**1. The receipt.** Session id, session dir path, phases completed, findings count by severity, and anything rejected or left open.

**2. The high-level overview.** Write this every time, unprompted. I shouldn't have to ask "so what does this plan actually do?" after reading a findings count — by the time you're printing the receipt you already know the answer, and asking me to request it wastes a round trip. Prose and short tables, not JSON, and no restating the spec field by field:

```
## The problem
What's broken today and what it costs, in two or three sentences. Name the
concrete failure, not the abstraction — "checkpoint commits land on the shared
branch" beats "branch handling is inconsistent".

## The fix
The shape of the solution in a few sentences. Name the one design decision that
mattered most and say what was rejected, if anything was.

## Phases
A small table: phase, what it does, and why it's separate — dependencies,
concurrency, or the reason it can't be folded into its neighbour.

## Two things I'd flag
The riskiest or least-certain parts. Unresolved open questions, assumptions that
could be wrong, coverage gaps, costs the user hasn't seen yet. If review rejected
a finding or the user's decision overrode one, say so here.
```

Scale it to the spec: a two-phase spec gets a shorter version of the same shape, never a longer one. If a section has nothing honest to put in it, drop the section rather than padding it — an empty "things I'd flag" on a genuinely low-risk plan is fine to omit, but reaching for filler to fill it is not.

**3. The command that resumes this session.** This is the outer boundary of planning and the point I am most likely to `/clear` at before implementing:

```bash
<paste the "Resume command" block from ${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/session-handoff.md verbatim, with SKILLS='work'>
```

---

## Error Handling

- **plan-creation fails**: Report error, do not proceed
- **plan-review fails**: Report error, still run consolidation on what we have
- **plan-consolidation fails**: Report error, present un-consolidated plan (still usable)

---

## Examples

- `/ixion:plan Add user authentication with OAuth2` — Full mode (all 3 phases, creates a new session)
- `/ixion:plan .ixion/plugin/designs/oauth2-design.md` — Design mode (creation uses design doc as input, creates a new session)
- `/ixion:plan feat-user-auth` — Review mode if a session `feat-user-auth-*` already exists (skips creation, starts at review)
- `/ixion:plan feat-user-auth-2026-08-06` — the same, pinned to one session rather than the most recent one sharing the slug

`install_claude_code.sh` installs these commands under the plugin namespace because its host ships a built-in `/plan` that would otherwise shadow this skill entirely; `install_opencode.py` rewrites them bare for a host that has no such built-in.

---

After consolidation, the session dir contains: `spec.json` (refined with findings integrated), `spec.json.pre-consolidation` (backup of the pre-refinement spec), and `session.json`. The `review.findings.json` is consumed and removed.
