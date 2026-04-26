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

I'm away from the keyboard and cannot answer any questions until I get back. Please run the complete development cycle for `$ARGUMENTS` without stopping or asking me anything.

Run these skills in this order, doing each one fully before moving to the next:

1. **Run `plan-creation`** with the feature description. Wait for it to write `spec.json` to the session dir before continuing.
2. **Run `plan-review`** against the spec. Wait for it to write `review.findings.json`.
3. **Run `plan-consolidation`**. It will merge the findings into the spec and produce `spec.json.pre-consolidation` as a sidecar.
4. **Run `work`** to implement the consolidated spec. It will write `progress.json` and produce the source files described in the spec.
5. **Run `work-review`** on what was just built. It will write a fresh `review.findings.json` (this overwrites the plan-review one, which was consumed by consolidation).
6. **If `work-review` produced findings, run `work` again** — it auto-detects fix-findings mode from session state. If `work-review` produced no findings, you can stop here.

Each skill writes its own artifacts (the JSON files). Those artifacts on disk are the proof the skill ran. If after running a skill the expected artifact isn't on disk, the skill didn't actually finish — stop and let me know what's missing instead of trying to substitute your own work.

**Don't shortcut the skills.** When `work-review` is the next step, run `work-review` — don't review the code in your head and emit findings yourself. Let each skill write its artifact properly.

You will encounter `AskUserQuestion` prompts during this run. **I'm not here to answer any of them.** Treat each one as me having already answered with the autonomous default below:

- **plan-consolidation** asks me to triage open questions one by one. → Pick the recommended option for each. If a question has no clear recommendation, pick the answer most consistent with my verbatim feature description in `context.constraints[0]`.
- **plan-consolidation** may also surface P3 findings for triage. → Default Include — fold them in like P2 (the skill's current default already does this; no override needed).
- **work** ends with a "Review the work / Ship it" prompt. → Pick **Review the work** — that's what I want next.
- **work-review** ends with a "Fix findings / Ship as-is" prompt. → Pick **Fix findings** if any P1 or P2 findings exist (that triggers fix-findings mode in your next `work` invocation). If only P3s remain, you can skip the fix-cycle.

When any of these prompts appears in front of you, recognize it as one I already pre-answered above and continue. Do not actually call `AskUserQuestion` for them. Document any planning decisions you made on my behalf in `context.constraints[]` so I can see what you chose when I get back.

For open questions during consolidation specifically: read `context.constraints[0]` (my verbatim description). If I named a specific tool (e.g., `Convex`, `Cloudflare Workers`, `Sentry`), pick that one. If I scoped something out (e.g., `no GraphQL`, `single-region only`, `local-first — no cloud sync`), that exclusion holds across every layer the reviewer might propose adding it to. Read my words literally, not charitably — don't relax the scope.

I trust you to ship a working result. Run the sequence end to end. Stop after one fix-cycle. Let me see what you produced when I get back.

## Input

`$ARGUMENTS` is the feature description (free-text). If empty, error: `"YOLO requires a feature description."`

---

## Sequence

Each step has a precondition (the previous step's artifact) and a postcondition (its own artifact). Verify the precondition before invoking the step; verify the postcondition before moving on. **An artifact missing means the step didn't actually finish, regardless of what the agent said.** Don't proceed if the artifact isn't there — stop and report.

| Step | Skill | Precondition (must exist) | Postcondition (must exist after) |
|---|---|---|---|
| 1 | `plan-creation` | `$ARGUMENTS` non-empty | `spec.json` in session dir, `active.json` updated |
| 2 | `plan-review` | `spec.json` exists | `review.findings.json` exists |
| 3 | `plan-consolidation` | `review.findings.json` exists | `spec.json.pre-consolidation` exists, `review.findings.json` deleted, `spec.json` rewritten |
| 4 | `work` (plan mode) | consolidated `spec.json` exists | `progress.json` with `mode: "plan"`, `status: "completed"` |
| 5 | `work-review` | `progress.json` (plan mode complete) | `review.findings.json` exists (work-review's output) |
| 6 | `work` (fix-findings mode) | `progress.json` mode=plan complete + `review.findings.json` | `progress.json` with `mode: "fix-findings"`, `status: "completed"`, `progress.json.plan-mode` archive present |

### Step-by-step

1. **plan-creation.** Invoke with `$ARGUMENTS`. After it returns, verify `spec.json` exists in `.flywheel/plugin/sessions/<active>/`. If missing, plan-creation didn't complete — stop and report.

2. **plan-review.** After invocation, verify `review.findings.json` exists. If missing, plan-review didn't write findings — stop and report.

3. **plan-consolidation.** **Auto-resolve every open question using the recommendation.** Do NOT call `AskUserQuestion`. If a question has no clear recommendation, pick the option that adds the least new state or abstraction (the elegance default). Document each auto-resolved decision in `context.constraints[]`. After invocation, verify the consolidation completed: `spec.json.pre-consolidation` should exist (sidecar) AND `review.findings.json` should be GONE (consumed). Both conditions must hold — sidecar alone means consolidation started but didn't finish.

4. **work (plan mode).** After invocation, verify `progress.json` exists AND has `mode: "plan"` AND `status: "completed"`. **The presence of `progress.json` is what step 5 (work-review) and step 6 (mode detection) both depend on.** If `progress.json` is missing, work didn't run — stop and report. If `status` is anything other than `"completed"`, work isn't done.

5. **work-review.** After invocation, verify `review.findings.json` exists (this is the work-review output, not the earlier plan-review output that was consumed in step 3). If missing, work-review didn't write findings — stop and report.

6. **If work-review produced findings, invoke work again** for the fix pass. work auto-detects fix-findings mode from session state (`progress.json` has `mode: "plan"`, `status: "completed"`, AND `review.findings.json` exists → switches to fix-findings). After invocation, verify `progress.json` now has `mode: "fix-findings"` AND `status: "completed"`. Also verify `progress.json.plan-mode` exists as the archive.

7. **Stop after one fix-cycle.** If work-review after the fix pass still has P1 findings, stop and report rather than looping. P2/P3 leftovers are acceptable.

8. **Final summary:**
   - Session id
   - Files modified (from `progress.artifacts.files_modified`)
   - Findings: integrated count, deferred count, remaining P1/P2 count
   - Any unresolved errors

---

## Constraints

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
