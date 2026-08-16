---
name: plan-consolidation
description: Refine the active session's spec.json by merging reviewer review.findings.json into it. Backs up the pre-refinement spec to a .pre-consolidation sidecar. Triggers on "consolidate plan", "finalize plan".
allowed-tools:
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - Bash
  - AskUserQuestion
---

# Plan Consolidation Skill

Merge review findings into the active session's `spec.json`. Pre-refinement spec is preserved as a `.pre-consolidation` sidecar so the refinement is auditable (D7). The refined `spec.json` retains the same top-level shape as the pre-refinement spec — only the content changes. Do NOT add top-level fields like `origin`, `risks`, or `notes`; the schema rejects additional properties. Namespace: plugin uses `.ixion/plugin/sessions/`.

## Input

Optional `$ARGUMENTS`: a session locator — a full session id, or a bare slug. Empty falls back to the active pointer. Phase 0 resolves it.

---

## Phase 0: Load Session

Read `ixion/skills/ixion-conventions/references/session-handoff.md` now and hold its blocks — Phase 6 cites it again for the resume command.

```bash
<paste the "Resolve the session" block from ixion/skills/ixion-conventions/references/session-handoff.md verbatim, with LOCATOR set to $ARGUMENTS>
```

```bash
<paste the "Validate the resolved session" block from ixion/skills/ixion-conventions/references/session-handoff.md verbatim>
```

`via=none`, `state=missing`, `state=schema-mismatch` and `state=complete` each halt with the message that file's "Error states" table gives, verbatim. On `state=usable`, read the two inputs from `dir=`:

- `spec.json` (the pre-refinement spec)
- `review.findings.json` (written by plan-review)

**Errors:**

- `review.findings.json` missing → ask the user to run plan-review first, or abort
- `spec.json` missing → the session is broken; ask the user to delete and restart

---

## Phase 1: Back Up to Sidecar (D7)

```bash
cp .ixion/plugin/sessions/<id>/spec.json \
   .ixion/plugin/sessions/<id>/spec.json.pre-consolidation
```

Cleaned on `ship`.

---

## Phase 2: No-Op Check

If `review.findings.json` has zero findings and zero open questions:

- Print: "No refinements needed — spec is already work-ready."
- Skip to Phase 6 (next-steps prompt).

---

## Phase 3: Surface Open Questions

Read `ixion/skills/ixion-conventions/references/question-format.md` before proceeding — it contains the question shape, the Why-you slot, and the four reasons that decide whether to ask at all.

Questions to surface:

1. `review.findings.json.open_questions` (entries the synthesizer could not resolve)
2. Inter-reviewer conflicts — findings where two or more reviewers described the same issue but assigned different severities. Surface the divergence; the user decides which severity is right rather than defaulting to the more severe.

Pick each question's reason from what that question actually turns on — `open_questions[]` carries whatever the synthesizer could not resolve, which is Preference for a taste call and Missing fact for an input it had no way to look up. A severity conflict is usually Scope, because the severity it settles decides how much the spec goes on to prescribe.

Ask each in the reference's shape, and carry the answer into Phase 4 verbatim — including whether the user picked it or delegated it, which Phase 4's decision string records. **BLOCKING: Never proceed with unresolved questions.**

---

## Phase 4: Propagate Decisions Into the Spec

**BLOCKING: Each resolved decision MUST be reflected in the spec's content, not just remembered in the conversation.** The implementer dispatches against the refined `spec.json`; if a decision isn't IN the spec, it won't be honored — that's a consolidation failure, not an implementer failure.

For each answered question:

1. **Identify affected tasks/phases** — the question's topic points to one or more `phases[].tasks[]`. Read the task descriptions and find the ones that would behave differently under each option.
2. **Rewrite task descriptions** to bake the decision in as a constraint. Examples:
   - "rstest or built-in `#[test]` for tests?" → "built-in" → rewrite test task descriptions to mandate plain `#[test]` fns; remove any `#[rstest]` / `#[case]` attribute references; drop the dev-dependency from the Cargo.toml task.
   - "Single- or multi-tenant for the MVP?" → "single-tenant" → strip `tenant_id` columns from the schema task; remove tenant-scoping middleware; document deferred multi-tenancy in `context.constraints[]`.
3. **Update `verification` commands** if the decision changes them. Example: `cargo test` → `cargo test --workspace` after a decision to split the crate into a workspace.
4. **Append the decision to `context.constraints[]`** as a one-line note that survives into the implementer dispatch. Format: `"Decision: <topic> → <answer>. <one-sentence why>."`, with ` (delegated)` after the answer when the user took "You pick what's best", so a later reader can tell my wording from theirs. Example: `"Decision: rustls over openssl → no system OpenSSL dependency in CI. Verification command runs 'cargo test --no-default-features --features rustls'."`.

The bar: a fresh implementer who reads only `spec.json` (no conversation history) must reach the same outcome the user's answer prescribed. If they could plausibly do something different, the decision wasn't propagated thoroughly enough.

---

## Phase 5: Integrate Findings by Severity

**Surface failures into context.** For every P1/P2 finding integrated into spec.json, append a one-line summary of the `failure` to `spec.context.constraints[]` so the implementer sees the reasoning during dispatch, not just the patch.

**Structural failures replace, don't patch.** Match the leading word(s) of each finding's Failure paragraph against the catalog below — string comparison, not judgment. Match → reshape the affected phase. No match → fold the fix into the task description.

Catalog of names that route to redesign (from `ixion/skills/ixion-conventions/references/elegance.md`):

- Universal Principles: Single Source of Truth, Working with the Grain, Depth over Indirection, Narrow Interfaces, One-Direction Data Flow, Dead Code Is Debt
- Structural: God Class, Shallow Wrapper, Forwarding Chain, Parallel State, Speculative Code, Config Soup, Stubborn Duplication
- Data Flow: Manual Sync, Bidirectional Coupling, Cascade Mutation, Leaky Event
- Abstraction: Premature Abstraction, Leaky Interface, Comments-as-Apology, Indirection Tax, Concrete Dependency
- Plan-Specific: Test Desert, Test Afterthought, Reinvented Wheel, Shotgun Surgery
- Performance/data-integrity canonicals: N+1 Query, Race Condition, Layering Violation, Convention Drift

When a finding matches, the patch is the wrong response. Folding "use a JOIN instead" into a task that says "build the in-memory join with N+1 queries" leaves both shapes in the spec. Delete the inelegant task; replace it with one that prescribes the cleaner shape from the start.

Example — finding leads `Forwarding Chain. ...`:

- Spec before: phase-2 task: "Add `UserManager.authenticate()` that calls `AuthService.verify()` that calls `TokenService.check()`."
- Spec after: phase-2 task: "Add a route handler that calls `TokenService.check()` directly." Original task deleted. `constraints[]` records the Failure paragraph one-liner.

The "Maximize elegance over minimizing churn" rule applies: pick the cleaner shape even when reshaping deletes tasks the original spec prescribed.

When reshaping deletes or renames a phase, keep `depends_on[]` edges consistent: drop edges pointing at deleted phase ids (a dangling edge makes `work` wait forever on a phase that no longer exists) and re-point edges from renamed ids.

### Consistency check (run before integrating any finding)

The user's verbatim feature description lives in `context.constraints[0]`, marked `(authoritative)`. **The user's exact words are immutable.** Reviewers don't see the original prompt and may suggest alternatives in good faith — but the user's authority overrides reviewer suggestions every time.

For each finding, before applying its `fix`:

1. **Does the finding propose changing or replacing something the user named explicitly?** If the user wrote "use Stripe for payments" and a finding suggests Braintree, reject it. Rationale: `Rejected: <finding-title> contradicts user's verbatim description ('<user words>')`.

2. **Does the finding contradict an existing `success_criteria` entry derived from the user's words?** Reject, same rationale form.

**Do not reinterpret the user's words to accommodate the finding.** "No Docker" means *no Docker for any environment* — dev, test, CI, production — even if a reviewer thinks containerization is the obvious choice. The user said what they said. Honor it literally; do not charitably re-scope it. Do NOT rewrite the existing `success_criteria` or `summary` to make room for the finding — that's how drift sneaks into the spec. If the existing content conflicts with the finding, the existing content wins.

Only integrate findings whose fix is consistent with the user's verbatim description AND the existing spec content. The result is an internally-coherent spec that honors the user's exact words, not one that says "X" in success_criteria and "not-X" in verification commands.

### Every finding that passes the consistency check integrates — P1, P2, and P3 alike

There is no deferral tier. The consistency check is the only gate: contradictions are rejected with their one-line `Rejected:` rationale; everything else goes into the spec.

- Fold `fix` language into the affected task's `description`
- Add test scenarios that cover the failure described in `failure`
- If the finding does not map to an existing task: add a new task to the relevant phase

Users describe *what* to build and the *hows* they care about (specific tools, libraries, frameworks, ports, file layouts). They generally underspecify the rest. Reviewers fill in the underspecified rest — robustness, correctness, polish, and capabilities the user didn't think to name. **That's good scope growth, and it all lands in the spec.** What reviewers may NOT do is override something the user named explicitly — that's the contradiction the consistency check catches. Example: "Adds a newtype around a raw `String` id passed through the API" → integrate; "Replace built-in `#[test]` with rstest" when the user said no external crates → reject.

If the user wants to drop an integrated finding after seeing it, they can edit the spec before `/work`. The rule is uniform integrate-or-reject: there is no triage prompt to answer.

---

## Phase 6: Write Refined Spec & Hand Off

1. Validate the refined spec against `ixion/schemas/spec.schema.json`.
2. Atomic write `.ixion/plugin/sessions/<id>/spec.json` (`.tmp` → `mv`).
3. **Delete `review.findings.json`** — it has been consumed. This is the signal to `/work` that no unhandled review remains.
   ```bash
   rm .ixion/plugin/sessions/<id>/review.findings.json
   ```
4. Print summary:
   ```
   Spec refined — <id>
   Integrated: N P1, N P2, N P3
   Rejected: N
   ```
5. **AskUserQuestion:** "Spec consolidated and ready. What next?"
   **Why you:** Preference. Nothing is left unresolved in the artifact; whether to start the run now is about your appetite for it, not about the spec.
   1. Start implementing (Recommended)
   2. Done for now
   3. "You pick what's best" - Let me decide
6. Print the command that starts it, so "done for now" and a `/clear` cost nothing:

   ```bash
   <paste the "Resume command" block from ixion/skills/ixion-conventions/references/session-handoff.md verbatim, with SKILLS='work'>
   ```

---

## Error Handling

- **Session resolution failures:** Phase 0 halts on them with the `session-handoff.md` "Error states" messages.
- **Findings missing:** Prompt user to run plan-review first, or abort
- **Schema validation failure on write:** Restore from `spec.json.pre-consolidation`; report which field failed; do not leave a half-merged spec on disk
- **User rejects every option on an open question:** Abort consolidation; spec stays in pre-refinement state (sidecar was created but the main spec.json was not overwritten)

---

## Anti-Patterns

- **Skip open-question resolution** — Don't refine with unresolved questions
- **BLOCKING: Auto-drop a P1** — P1s integrate; only the user may downgrade to follow-up
- **Resolve a question without rewriting the spec** — Decisions must propagate into task descriptions, verification commands, and `context.constraints[]`. A decision that lives only in the conversation history is invisible to the implementer (Phase 4).
- **Fold structural failures into existing tasks** — Replace the affected phase or task with the simpler shape, don't patch the original. Surface the `failure` into `context.constraints[]`.
