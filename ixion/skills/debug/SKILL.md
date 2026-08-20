---
name: debug
description: Debug issues with iterative fix loop. Gathers problem description, investigates, then enters fix-verify cycle. Triggers on "debug", "fix this", "troubleshoot". Use when the goal is to fix a specific reported issue. For exploration or new features, use brainstorm or plan-creation.
allowed-tools:
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - Bash
  - Skill
  - AskUserQuestion
---

# Debug

Iterative debug loop: gather problem, investigate, fix loop (max 10 iterations) with verification after each fix.

Read `${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/question-format.md` before proceeding — it contains the question template, the mandatory Why-you slot, and the four reasons that gate whether to ask at all.

---

## Phase 0: Goal Definition

Parse `$ARGUMENTS` for a problem description.

**If `$ARGUMENTS` is empty:**
- Use AskUserQuestion: "Problem: describe what you're seeing. Include error messages, unexpected behavior, or what's broken."
  - **Why you:** Missing fact. The error text, the environment it appeared in, and what you actually observed live in your terminal, not in the repo.

**Check for active work session:**
- Check every `session.json` under the sessions tree — the "Resolve the session root" block in `${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/session-handoff.md` gives the repository root it hangs off, which is shared with every worktree — for any session with `status: "active"` and a non-null `active_skill`. If one exists, name it and continue: "Session <session_id> is mid-<active_skill>. Debugging may conflict with in-progress work." Debugging alongside it is reversible and you just ran `/debug`, so continuing is the decision rather than a question.

**Get verification command:**
- Use AskUserQuestion: "Verification: what command reproduces or shows the problem? (e.g., `cargo test`, `cargo test --test cli`, `curl ...`). Say 'none' for manual verification."
  - **Why you:** Missing fact. The repo has many runnable targets and nothing in it records which one currently fails for you.

**If command provided:**
- Run the command to capture baseline output
- Truncate output to last 2000 characters
- Store as `BASELINE_OUTPUT`

**If "none":**
- Set `MANUAL_MODE = true`
- Skip baseline capture

---

## Phase 1: Investigation

Investigate inline (no subagent dispatch in V1).

### Gather Context

1. Read error output / `BASELINE_OUTPUT` carefully — identify file names, line numbers, error types
2. Search codebase for relevant files:
   ```bash
   # Use Grep to find error strings, function names, class names from the output
   # Use Glob to locate test files, config files, related modules
   ```
3. Check recent git changes:
   ```bash
   git log --oneline -10
   git diff
   git diff --cached
   ```

### Form Hypotheses

Produce 2-3 ranked hypotheses based on the evidence. Format each as:

```
Hypothesis N: <one-line summary>
Evidence: <what points to this>
Likelihood: High / Medium / Low
```

### Set Direction

Present the hypotheses highest-likelihood first and take that one, saying so: "Starting with Hypothesis 1 — <summary>. Redirect me if you already know better." The loop below moves on after three failed iterations, so every hypothesis gets tried whatever the order; the ranking only decides which one gets the first three, and I ranked them, so this is my call to make and report rather than yours to answer.

---

## Phase 2: Fix Loop

```
ITERATION = 0
STRIKES = {}  # track failures per hypothesis
CURRENT_HYPOTHESIS = <highest-likelihood hypothesis>

For each iteration (1 to 10):

  1. Implement ONE targeted fix
     - Minimum change needed
     - If fix requires >5 lines, explain why before implementing

  2. Verify:
     - Automated mode: run verification command, truncate to last 2000 chars
     - Manual mode: ask the verification question below

  3. Evaluate:
     - If FIXED → go to Phase 3
     - If NOT FIXED → analyze new output, adjust approach

  4. Track strikes:
     - STRIKES[CURRENT_HYPOTHESIS] += 1
     - If STRIKES[CURRENT_HYPOTHESIS] >= 3 → move to next hypothesis

  5. If all hypotheses exhausted:
     - Ask the new-direction question below
     - Form new hypotheses from user input
```

### Loop Questions

```
Question: "Verification: did this fix the problem? Describe what you see."
**Why you:** Missing fact. In manual mode nothing I can run observes the result — you are the only instrument reading it.
```

```
Question: "Direction: all hypotheses are exhausted. What are you seeing now, or where should I look next?"
**Why you:** Missing fact. Every hypothesis the evidence supported has failed, so the next one has to come from behavior you have seen and I have not.
```

### Fix Loop Rules

- **Minimum change**: Make the smallest fix needed. If a fix requires >5 lines, explain why before implementing.
- **No shotgun debugging**: Fix root causes. Do NOT make random changes hoping something works.
- **Changes accumulate**: Do NOT stash or revert changes between iterations. Changes build toward the solution.
- **3-Strike Protocol**: 3 failures on the same hypothesis means move to the next. See `ixion-conventions/SKILL.md` for the full 3-Strike Error Protocol.
- **Escalation**: After 10 iterations or all hypotheses exhausted, escalate to user with a summary of everything tried.

### Escalation Summary Format

```
## Debug Escalation
- Problem: <original description>
- Iterations completed: N
- Hypotheses tested: <list>
- Changes made so far: <list of files modified>
- Current state: <what the verification command shows now>
- Recommendation: <next steps if any>
```

---

## Phase 3: Summary & Next Steps

### Summarize the Fix

Provide a clear summary:
- **Root cause**: What was wrong
- **Fix applied**: What changed and why
- **Verification**: Confirmation that the verification command passes

If the root cause was non-obvious — a surprising interaction, a misleading symptom, a fix that future debuggers would want to know about — offer to capture it while the details are fresh:

```
Question: "Capture: document this root cause as a solution doc?"
**Why you:** Scope. Writing the doc is work beyond the fix you asked for.
Options:
1. Run `/ixion:compound` now (Recommended) - Capture it while the details are fresh
2. Skip - The fix stands on its own
3. "You pick what's best" - Let me decide
```

### Show Changes

```bash
git diff
```

### Offer Next Steps

```
Question: "Next: commit the fix, or leave it in the working tree?"
**Why you:** Irreversible. `/ixion:ship` pushes a branch and opens a PR, which puts the fix in front of reviewers and cannot be quietly taken back.
Options:
1. Done for now (Recommended) - Exit; changes stay uncommitted in the working tree
2. Commit - Invoke `/ixion:ship` to commit and open the PR
3. "You pick what's best" - Let me decide
```

---

## Key Principles

- **Verification command is your feedback loop** — trust it over assumptions
- **One fix per iteration** — small, targeted changes that isolate variables
- **Escalate, don't spin** — after 3 strikes on a hypothesis, move on
- **All user interaction happens here** — never dispatch AskUserQuestion to subagents
- **Read before editing** — always Read a file before modifying it
- **Preserve context** — keep `BASELINE_OUTPUT` for comparison throughout the session

---

## Anti-Patterns

- **Shotgun debugging** — random changes hoping something works
- **Skipping verification** — never claim "fixed" without running the verification command
- **Stashing between iterations** — changes accumulate, do not revert
- **AskUserQuestion in subagents** — only the orchestrator interacts with users
- **Fixing symptoms** — address root causes, not surface-level manifestations
- **Multi-fix iterations** — one change per iteration keeps the feedback loop tight
