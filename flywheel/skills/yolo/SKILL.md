---
name: yolo
description: Autonomously execute the full plan → implement → review → fix cycle without stopping. The agent makes every decision, including answering open questions during plan-consolidation. Use when you'll be away from the keyboard and trust the agent to ship.
argument-hint: "[feature description]"
allowed-tools:
  - Read
  - Bash
  - Skill
---

# YOLO — End-to-End Autonomous Cycle

Run the complete development cycle without user interaction. The user has stepped away — make every decision yourself. When a child skill would normally call `AskUserQuestion`, pick the recommended option instead.

## Input

`$ARGUMENTS` is the feature description (free-text). If empty, error: `"YOLO requires a feature description."`

---

## Sequence (run without stopping between steps)

1. **plan-creation** with the feature description. Wait for `spec.json` to land in the active session dir.
2. **plan-review** against the produced spec. Wait for `review.findings.json`.
3. **plan-consolidation**. **Auto-resolve every open question using the recommendation.** Do NOT call `AskUserQuestion`. If a question has no clear recommendation, pick the option that adds the least new state or abstraction (the elegance default). Document each auto-resolved decision in `context.gotchas[]` per plan-consolidation Phase 4.
4. **work** to implement the consolidated spec. Phase 4 (Cumulative Diff Self-Check) and Phase 5 (Summary & Next Steps) both run normally — but for Phase 5's "what's next?" prompt, pick option 1 (review the work) automatically.
5. **work-review** on the executed branch.
6. If `work-review` produced any findings (P1 or P2), invoke **work** again — it auto-detects fix-findings mode from the session state.
7. **Stop after one fix-cycle.** If `work-review` after the fix pass still has P1 findings, stop and report rather than looping. P2/P3 leftovers are acceptable.
8. Present the final summary:
   - Session id
   - Files modified (from `progress.artifacts.files_modified`)
   - Findings: integrated count, deferred count, remaining P1/P2 count
   - Any unresolved errors

---

## Constraints

- **No user interaction in the main loop.** No `AskUserQuestion` calls. Every prompt that would normally pause for human input gets the recommended answer.
- **Auto-resolve, don't auto-skip.** Open questions during consolidation get *answered* (recommendation applied + recorded in `context.gotchas[]`), not deferred.
- **One fix-cycle maximum.** Avoids runaway loops on persistent P1s.
- **Stop on hard error.** If a child skill errors irrecoverably (3-strike protocol exhausted, schema validation failure with no obvious fix, etc.), stop and report. Don't paper over.
- **No shipping.** YOLO ends at the work-review fix pass. The user runs `/ship` themselves after auditing the result.

---

## Failure handling

| Failure | Action |
|---|---|
| `plan-creation` can't produce a valid spec | Stop. Report what's missing. |
| `plan-review` returns no findings | Continue — that's a valid outcome. |
| `plan-consolidation` schema validation fails after auto-resolve | Stop. Report the field that failed. |
| `work` chunk fails 3-strike protocol | Stop. Report the chunk and last error. |
| `work-review` produces P1 findings after the fix pass | Stop. Report the surviving P1 list. Do NOT continue to a second fix pass. |
| Any child skill returns an error the orchestrator can't interpret | Stop. Report the raw output. |

---

## What this skill is NOT for

- **First-time exploration.** Use `/brainstorm` to shape the idea, then `/plan` if you want to stay in the loop.
- **Sensitive changes.** Auth, payments, migrations — run the cycle interactively so you can review each handoff.
- **Unfamiliar codebases.** YOLO assumes the agent's auto-resolutions during consolidation will be reasonable. That requires the codebase patterns to be discoverable. New repos: start interactive.

If any of the above apply, the user should run `/plan` (interactive) instead and accept the conversation cost.
