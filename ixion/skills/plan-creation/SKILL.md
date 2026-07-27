---
name: plan-creation
description: Research codebase, validate external claims, and emit a work-ready spec.json for a new planning session. Single-pass creation with integrated validation via Context7 and locator/analyzer agents. Triggers on "create plan", "plan for", "write a plan". For exploratory requests where the user is unsure what to build, prefer brainstorm first. Once spec.json exists, use plan-review for evaluation or go straight to work. For a reviewed spec, use plan-consolidation to merge findings.
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

# Plan Creation Skill

Research the codebase, validate technical claims, and emit a work-ready `spec.json` in a single pass. Output validates against `ixion/schemas/spec.schema.json`.

## Core Principles

1. **Codebase reality first** — dispatch locators before hypothesizing patterns.
2. **Decisions, not code** — capture approach, boundaries, risks, test scenarios. Do not pre-write implementation code.
3. **Executable-from-day-one** — if you can't commit to concrete file paths or test scenarios, surface an `open_question` instead of a vague task.
4. **BLOCKING: Validate high-risk claims** — security, payments, crypto, migrations, privacy trigger external validation via Context7.

## Input

Feature description via `$ARGUMENTS`. If empty, ask user.

---

## Phase 0: Check for Existing Knowledge

Before codebase research, check existing knowledge (skip missing dirs):

1. **Standards** (`docs/standards/`) — Search by tags for reusable patterns.
2. **Solutions** (`docs/solutions/`) — Verified fixes from past work (up to 5 matches).
3. **Research** (`docs/research/`) — Recent research within 30 days:
   ```bash
   find docs/research -name "*<topic-keywords>*" -mtime -30 2>/dev/null | head -3
   ```

If relevant knowledge found, use it as starting point for Phase 1. Fold key references into `context.constraints[]` or `context.patterns[]` so they survive into the dispatch.

---

## Phase 1: Understand Codebase Context

**BLOCKING:** Do NOT use Read/Grep/Glob for TARGET CODEBASE research — dispatch locator Tasks first, then feed results to analyzer Tasks. Skill references, plan artifacts, and template files are exempt.

Run the canonical research workflow: all four locators in parallel → consolidate → all four analyzers in parallel. Read `ixion/skills/ixion-conventions/references/research-workflow.md` for locator templates, the consolidation rule, and analyzer templates.

After the canonical workflow completes, also check `CLAUDE.md` for team conventions (if analyzer-docs didn't already surface it) and recent similar features for precedent.

### Map analyzer outputs to spec.context

- **analyzer-codebase findings** → `key_files[]` (paths + one-line reasons). Flags fold into `constraints[]`.
- **analyzer-patterns findings** → `patterns[]` (named patterns with `file.ext:line` references the implementer can match).
- **analyzer-docs findings** → `constraints[]` (decisions, constraints, prerequisites, warnings from CLAUDE.md / ADRs / inline docs).
- **analyzer-web findings** → `constraints[]` (best practices, version constraints, deprecations from external sources).

### Flag handling

- `EXISTING_SOLUTION` → record in `constraints[]` and adjust phases to reuse rather than reinvent.
- `DRY_VIOLATION` → add a consolidation task to the affected phase.
- `PATTERN_CONFLICT` → record in `constraints[]` with rationale for keeping or correcting.
- `INTEGRATION_RISK` → record in `constraints[]` and add covering tests to the relevant phase.
- `OPEN_QUESTION` → record in spec `open_questions[]`.
- `CLAIM_INVALID` / `VERSION_ISSUE` → record in `open_questions[]`; may trigger Phase 2 Context7 deep-validation.

### Validation gate (BLOCKING)

Before proceeding to Phase 2, verify codebase research quality:

1. **File paths exist**: Spot-check 3-5 referenced paths.
2. **Patterns identified**: Found relevant existing implementations?
3. **Conventions clear**: Know how this codebase handles similar features?
4. **DRY checked**: No proposed work duplicates existing code?

Minor gaps → note in `open_questions`. Significant gaps (no similar patterns) → ask user. Max 2 re-research attempts.

---

## Phase 2: Validate External Claims

Verify technical claims before they become plan assumptions. Only runs when high-risk topics detected.

Read `references/validation-research.md` before proceeding (high-risk keyword heuristic, Context7 workflow, dispatch templates).

Scan draft plan for high-risk keywords (security, payments, crypto, migrations, privacy). If any found → run external validation. Else skip.

When triggered:

1. **Framework Docs Validation** — Verify claimed library features via Context7
2. **Version Compatibility** — Check for breaking changes and deprecations
3. **Best Practices** — Look up recommended patterns

Incorporate findings into the spec. Flag `CLAIM_INVALID` or `VERSION_ISSUE` as `open_questions` if they change the approach.

---

## Phase 3: Design Synthesis (BLOCKING — every spec records elegance reasoning)

Every spec MUST emit at least one `context.constraints[]` entry recording the design decision. This preserves the reasoning so reviewers and implementers don't re-litigate, and it's the signal that elegance was on the table — not skipped.

1. Sketch candidate shapes:
   - **Non-trivial features** (multiple plausible decompositions, new abstractions, multi-layer changes): sketch 2-3 candidates — typically "the natural one" and "a simpler one that consolidates with existing code." Add a third only if a different decomposition is genuinely plausible.
   - **Trivial features** (bug fixes, small additions, pure config changes, single established pattern): one candidate is fine.

2. Pick the shape that's simplest, most symmetric, and adds the least new state or abstraction. The Elegance Discipline applies: maximize elegance over minimizing churn — pick the cleaner shape even if it means a larger refactor.

3. Record the decision in `context.constraints[]` (mandatory, even when trivial):
   - **When alternatives existed**: `Considered: <alternative>. Rejected because: <one-sentence reason>.`
   - **When no alternative existed**: `Single obvious shape — no alternative considered because <concrete reason>.` (e.g., "the codebase already has one established route-handler pattern.")

   "I didn't think about it" is not a concrete reason. If you can't write either form, you haven't done the synthesis.

   **Strong:** `Considered: a UserAuthService struct wrapping the Stripe SDK + a separate UserSessionStore. Rejected because: Forwarding Chain — every method just delegates to Stripe. Inlining the SDK calls in src/routes/auth.rs is shorter, removes a file, and matches the existing pattern in src/routes/payments.rs:14.`

   **Weak:** `Considered other approaches. Picked this one.` — Names no alternative, names no anti-pattern, gives no reason. Doesn't survive the bar.

---

## Phase 4: Compose and Write Artifacts

Spec is a structured JSON document validated against `ixion/schemas/spec.schema.json`. Namespace: plugin uses `.ixion/plugin/sessions/`.

### Step 1 + 2: Derive session id by claiming the directory

Format: `<slug>-<YYYY-MM-DD>` (kebab-case slug), collision tiebreak `-2` … `-9`. Creation IS the probe — plain `mkdir` (no `-p`) fails atomically if the slot is taken, so a concurrent session planning the same slug can never land in the same directory:

```bash
mkdir -p .ixion/plugin/sessions
for n in "" -2 -3 -4 -5 -6 -7 -8 -9; do
  if mkdir ".ixion/plugin/sessions/<slug>-<YYYY-MM-DD>$n" 2>/dev/null; then
    SESSION_ID="<slug>-<YYYY-MM-DD>$n"; break
  fi
done
```

See `references/formatting-guide.md` for the full pattern.

### Step 3: Synthesize phases and tasks

- Each phase has one clear purpose (Single Responsibility)
- Extract shared setup into an early foundation phase
- Order test steps before implementation steps within each task
- Assign concrete repo-relative file paths from locator/analyzer findings
- Declare each phase's `depends_on[]` — the phase ids it genuinely builds on. Foundation phases get `[]`; phases that only need the foundation list just the foundation. Don't chain phases that merely happen to be written in sequence — phases with true dependencies get them declared, and `work` runs independent phases (disjoint `files[]`) concurrently. A phase with no `depends_on` field falls back to depending on the phase before it (serial).

### Step 4: Enumerate test scenarios per task

Every task lists concrete test scenarios — sentences an implementer could turn directly into test cases. If you can't write one, surface an `open_question`.

### Step 5: Spec Quality Bar gate

Apply the Spec Quality Bar from `ixion-conventions`. Verify: clear file paths, enumerated test scenarios, explicit verification commands. Unresolved uncertainty → `open_questions[]`, not vague tasks.

Add at least one elegance criterion to `success_criteria[]`. Anchor it to your Phase 3 rejection using this template:

`No instance of <rejected-shape> in <scope>.`

Example: Phase 3 rejected "wrap clap's arg accessors in a get_arg() helper." Criterion: `No get_arg-style wrapper around clap arg access in src/cli/.`

If Phase 3 recorded "Single obvious shape — no alternative considered," use one of these universals instead:

- "No new helper added without first searching for an existing one."
- "No new file imported by exactly one consumer (single-use abstractions inlined)."
- "No code path with a guard for a state that cannot occur in this codebase."
- "No line whose removal would not change behavior."

A single criterion that applies uniformly across the whole spec is sufficient. The criterion makes elegance a verifiable acceptance bar, not a hope.

### Step 6: Write `spec.json`

Path: `.ixion/plugin/sessions/<session-id>/spec.json`

Required top-level fields: `schema_version: 1`, `summary` (100–5000 chars; the system-level goal and what we're building), `context`, `phases`, `success_criteria`. Optional: `open_questions` (array of strings). See `ixion/schemas/spec.schema.json` for the authoritative shape.

**BLOCKING: top-level fields are exactly the set above.** `additionalProperties: false` rejects anything else — do NOT emit `risks`, `notes`, `assumptions`, or any field not listed in the schema. Risk discussion belongs in `context.constraints[]`; uncertainty belongs in `open_questions[]`.

**BLOCKING: `context` must use the schema shape** — not a free-form object. Exactly three arrays:

- `key_files[]` — repo-relative paths the implementer should know about, with one-line reasons.
- `patterns[]` — existing patterns to follow, named so the implementer can match the codebase style.
- `constraints[]` — pitfalls AND design rationale. Surprises the implementer needs to know: prerequisites, rejected alternatives, why-this-shape decisions, principle violations surfaced from review, edge cases.

**`context.constraints[0]` is the user's verbatim feature description.** Copy `$ARGUMENTS` literally, prefixed with `User feature description (verbatim, authoritative): `. This is the canonical record of what the user actually said — every downstream skill (plan-review, plan-consolidation, work) reads it via the dispatched `context.constraints[]` and treats the user's exact words as the authoritative constraint. Do not paraphrase, summarize, or reinterpret. The user's words go in unmodified.

```json
{
  "key_files": ["src/main.rs — axum app + route handlers", "tests/healthz.rs — integration test"],
  "patterns": ["axum route handlers as plain async fns", "integration tests in tests/ calling the router via tower::ServiceExt::oneshot"],
  "constraints": [
    "User feature description (verbatim, authoritative): Add a /healthz endpoint that returns the build SHA to my axum service. Plain cargo test for tests — no test frameworks.",
    "Considered 3-phase split; rejected because phase-1 was just mkdir"
  ]
}
```

Research rationale (stack choice, why-this-pattern, rejected alternatives) goes in `context.patterns[]` and `context.constraints[]` as richer entries — those array items have no length cap. The spec is the single artifact; there is no narrative sidecar.

**BLOCKING: `phases[].tasks[]` must use the schema shape**. No extra fields — `additionalProperties: false` rejects anything unknown. Each phase shape:

```json
{
  "id": "phase-1",
  "goal": "Land the healthz route and a smoke test.",
  "files": ["src/main.rs", "tests/healthz.rs"],
  "tasks": [
    {
      "id": "t1",
      "description": "Add axum GET /healthz returning JSON `{sha: env!(\"BUILD_SHA\")}`.",
      "files": ["src/main.rs"],
      "test_scenarios": [
        "GET /healthz returns 200 with a body containing `sha`",
        "POST /healthz returns 405 method not allowed"
      ]
    }
  ],
  "verification": "cargo test --test healthz",
  "manual_verification": null,
  "depends_on": []
}
```

A later phase that builds on this one declares `"depends_on": ["phase-1"]`.

**`verification` is always a runnable command** — the implementer executes it after the phase to confirm the work landed. It must be a non-empty string.

For phases that are genuinely hard to automate (HTTP servers, GUI changes, processes you'd normally exercise by hand), use a minimal **smoke command** instead of leaving verification null:

```json
{
  "id": "phase-2",
  "goal": "Run the HTTP server on port 3000.",
  "files": ["src/main.rs"],
  "tasks": [...],
  "verification": "timeout 3 cargo run 2>&1 | grep -q 'listening on' || true",
  "manual_verification": "Optional: curl http://localhost:3000/healthz to verify the route responds."
}
```

The smoke command starts the process, greps for a startup signal, and exits cleanly via `|| true`. Other minimal-smoke patterns: `cargo check` (verifies the code compiles), `cargo build` (verifies it links). `manual_verification` is for supplementary checks **the orchestrating agent performs itself** (not the user) — things like curling an endpoint, inspecting browser output, capturing tmux panes to verify TUI behavior, or reading server logs. The orchestrator has full tool access and will execute these steps directly. `manual_verification` is allowed to be `null` but `verification` is not.

**BLOCKING: DO NOT** add `name`, `verification_commands`, or any other field to a task — the schema rejects them. Use `description` for the narrative; put verification at the phase level, not the task level. `test_scenarios[]` are plain strings (one scenario per entry; include expected behavior in the string). `files[]` entries are plain repo-relative paths (no " (new)" suffixes, no annotations).

### Step 7: Write `session.json`

Path: `.ixion/plugin/sessions/<session-id>/session.json`

Fields: `schema_version: 1`, `session_id`, `slug`, `status: "active"`, `started_at` (ISO 8601), `last_checkpoint_at: null`, `active_skill: "plan-creation"`. On exit, set `active_skill: null`.

### Step 8: Update `.ixion/plugin/active.json`

```json
{ "schema_version": 1, "session_id": "<session-id>" }
```

Write via a PID-suffixed temp (`active.json.tmp.$$` → `mv`) so a concurrent session's in-flight write is never clobbered mid-rename.

### Step 9: Print summary

Print the spec's `summary` field + next-steps hint.

---

## Phase 5: Summary & Next Steps

**AskUserQuestion:** "Spec ready at `.ixion/plugin/sessions/<id>/spec.json`. What next?"

| Option | Action |
|--------|--------|
| Run review (Recommended) | Invoke `skill: plan-review` |
| Proceed to work | Invoke `skill: work` |
| Done for now | Display path and exit |

---

## Error Handling

- **Agent failure:** Log and continue with available findings
- **Missing CLAUDE.md:** Note conventions may be incomplete
- **No similar patterns found:** Ask user for guidance on approach
- **Context7 failure:** Fall back to WebSearch for external validation
- **Write failure:** Create `.ixion/plugin/sessions/<id>/` with `mkdir -p`, report errors
- **Session id collision past `-9`:** Error out — user probably has a stuck session

---

## Anti-Patterns

- **BLOCKING: Write code** — research and planning ONLY. If tempted to code, add it to the spec instead
- **Skip codebase research** — even "simple" features benefit from understanding patterns
- **Read target codebase files directly instead of dispatching analyzers** — use the locate→analyze pattern
- **Skip locators and go straight to analyzers with assumed paths** — locators discover; analyzers analyze
- **Emit a vague task instead of an open_question** — surface uncertainty
- **Omit file references** — include paths (never absolute)
- **Skip AskUserQuestion** — user must choose next step
- **BLOCKING: Skip external validation for high-risk topics** — security, payments, migrations MUST be validated against docs
- **Run external validation for everything** — only high-risk topics warrant the token cost

---

## Detailed References

- `references/validation-research.md` — High-risk heuristic, Context7 workflow, external validation dispatch templates
- `references/formatting-guide.md` — Session id format, directory layout, artifact filenames, collision behavior
