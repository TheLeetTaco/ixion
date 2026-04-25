# Elegance Reference

Two outputs, one source of truth:

- **Anti-Pattern Catalog** — named violations used by reviewers and plan-consolidation. Plan-consolidation routes "structural failure" findings by the names below — when a finding's Failure paragraph leads with one of them (or a Universal Principle), consolidation re-shapes the affected phase rather than patching the task description.
- **Elegance Dispatch Bar** — the contract pasted verbatim into every work-implementation subagent dispatch. The orchestrator reads the bar from this file and pastes it into the dispatch text; subagents receive it inline.

Both encode the same principle: every line must do important work. The catalog names what failure looks like; the bar tells the implementer how to avoid it.

---

## Anti-Pattern Catalog

### Universal Principles (lead-with names)

- **Single Source of Truth** — every datum has one canonical home; copies drift.
- **Working with the Grain** — use the language/framework's idiomatic primitive; ceremony signals you're fighting it.
- **Depth over Indirection** — abstractions hide complexity, don't redistribute it.
- **Narrow Interfaces, Deep Modules** — simple surface, rich internals.
- **One-Direction Data Flow** — no cycles between A and B.
- **Dead Code Is Debt** — code that doesn't change behavior is noise.

### Structural Anti-Patterns

| Anti-Pattern | Signal | Elegant alternative |
|---|---|---|
| **God Class** | Class/module with 3+ unrelated responsibilities | Split by responsibility |
| **Shallow Wrapper** | Wraps an API, adds no new capability | Call the API directly |
| **Forwarding Chain** | A calls B calls C, B just delegates | A calls C directly, or A writes state C reads |
| **Parallel State** | Same value stored in two places | Single source of truth, derive the rest |
| **Speculative Code** | Built for hypothetical future requirements | Delete it. Add when needed. |
| **Config Soup** | Many optional fields, valid combinations unclear | Discriminated variants or composable primitives |

### Data Flow Anti-Patterns

| Anti-Pattern | Signal | Elegant alternative |
|---|---|---|
| **Manual Sync** | Code that copies a value between representations | Derive the dependent value from the source |
| **Bidirectional Coupling** | A depends on B, B depends on A | Shared abstraction or invert one direction |
| **Cascade Mutation** | State update triggers chain of side effects | Compute derived values declaratively |
| **Leaky Event** | Producer filters/transforms events for specific consumers | Emit raw events; consumers own their filtering |

### Abstraction Anti-Patterns

| Anti-Pattern | Signal | Elegant alternative |
|---|---|---|
| **Premature Abstraction** | Generic base/interface with one implementation, no extension plan | Inline it. Extract when the second consumer appears. |
| **Leaky Interface** | Consumer must understand internals to use correctly | Deep module with self-documenting interface |
| **Indirection Tax** | Layer exists only to satisfy a rule, no value added | Remove the layer. Question the rule. |
| **Concrete Dependency** | Business logic imports infrastructure directly | Depend on abstraction, inject the impl |

### Plan-Specific Anti-Patterns

| Anti-Pattern | Signal | Elegant alternative |
|---|---|---|
| **Test Desert** | Implementation phases with zero test steps | Tests alongside implementation in each phase |
| **Test Afterthought** | All tests deferred to a final phase | Red-green-refactor within each phase |
| **Reinvented Wheel** | Plan builds something that already exists | Reuse or extend existing code |
| **Shotgun Surgery** | One change requires touching 4+ components | Missing shared abstraction |

---

## Elegance Dispatch Bar

The orchestrator pastes the section below verbatim into every work-implementation dispatch. The dispatched subagent treats this as the binding contract.

### Maximize elegance, not minimal churn

Pick the more elegant design even if it means a larger refactor.

- Every line you add must do important work. If you can't name what concretely breaks when a line is removed, delete it.
- Single source of truth — read from existing state, don't duplicate.
- Use the language/framework's idiomatic primitive before reaching for a wrapper.
- Wrappers and helpers must add capability, not move code around. No Shallow Wrappers, no Forwarding Chains.
- No Speculative Code, no defensive checks for impossible cases, no backward-compat shims for nonexistent consumers.
- Prefer deletion to modification. The best fix is often less code, not more.

### Counter-examples (the shapes we reject)

BAD: `export const getUser = (id) => userService.findById(id);` — Shallow Wrapper.
GOOD: callers use `userService.findById(id)` directly.

BAD: `try { return parseDate(x); } catch { return null; }` — swallows the failure.
GOOD: throw a typed error so the caller routes to retry.

BAD: `if (config?.options?.advanced?.timeout) { ... }` — Speculative depth on always-present config.
GOOD: `timeout` is required; remove the optional chain.

### Reporting requirements (BLOCKING)

`simplifications_made[]` MUST contain at least one entry. Each entry uses one of these forms — pick the form by what you actually did:

- `Avoided <anti-pattern-name> at <path>:<line> by <action>` — use when the obvious approach would have introduced the named anti-pattern and you didn't. Reference a name from the Anti-Pattern Catalog above.
- `Deleted <N> lines from <path> (<reason>)` — use when net change is negative.
- `Consolidated <path-A> + <path-B> → <path-C>` — use when two things became one.
- `No simplifications: <concrete reason why none were warranted>` — use when the chunk genuinely needed everything it has, OR when the spec itself is the source of inelegance and patching is wrong (in fix-findings mode, this signals re-planning required).

Free-form prose ("phase was small," "everything was needed") fails validation. The orchestrator rejects malformed entries and re-prompts.

### Diff self-check before claiming done

Re-read your full diff and answer with concrete evidence:

1. Is there any line whose removal would NOT change behavior? Name one or confirm none exists.
2. Is the same value stored in two places? Name where or confirm one source of truth.
3. Is there a check guarding a case that cannot occur in this codebase? Name one or confirm none.

If you can't answer with evidence, you didn't actually re-read the diff.
