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

- If the input is a **slug** (lowercase kebab, e.g. `feat-user-auth`) that matches an existing session under `.ixion/plugin/sessions/<slug>-*` whose `spec.json` exists: start with `plan-review` (skip creation)
- **Otherwise** (feature description, or a path to a design document ending in `-design.md`): start with `plan-creation`

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

After plan-creation, the session dir at `.ixion/plugin/sessions/<session-id>/` contains the spec.json and session.json that subsequent skills read. The active pointer `.ixion/plugin/active.json` is the glue for bare interactive invocations only — as the orchestrator, capture the session id plan-creation prints and pass it to plan-review and plan-consolidation explicitly (`skill: plan-review` with the id as input). A concurrent Claude Code session can retarget active.json mid-run; the id you captured is this run's identity.

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

Display summary: session id, session dir path, phases completed, findings count, and any critical items.

---

## Error Handling

- **plan-creation fails**: Report error, do not proceed
- **plan-review fails**: Report error, still run consolidation on what we have
- **plan-consolidation fails**: Report error, present un-consolidated plan (still usable)

---

## Examples

- `/plan Add user authentication with OAuth2` — Full mode (all 3 phases, creates a new session)
- `/plan .ixion/plugin/designs/oauth2-design.md` — Design mode (creation uses design doc as input, creates a new session)
- `/plan feat-user-auth` — Review mode if a session slug `feat-user-auth-*` already exists (skips creation, starts at review)

---

After consolidation, the session dir contains: `spec.json` (refined with findings integrated), `spec.json.pre-consolidation` (backup of the pre-refinement spec), and `session.json`. The `review.findings.json` is consumed and removed. Ready for `/work`.
