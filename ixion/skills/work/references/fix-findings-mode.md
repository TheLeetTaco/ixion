# Fix-findings mode (loaded by Phase 1 when a completed plan run left `review.findings.json` behind)

## What a chunk is

Chunk = **theme group** of findings — a logical cluster (e.g. one design refactor, one shared-helper simplification, one polish pass) that one subagent can address in a single dispatch. ID = `theme-<slug>` (e.g. `theme-scaffolding-redesign`, `theme-polish`). Bullets = the findings in that theme. **Every finding gets fixed** — P1 through P3 — with one exception: findings whose title starts with `[Contradicts user]` are advisory pushback against the user's explicit choice; skip them and list them in `outcomes` so the user sees the pushback without it being auto-applied.

**Theme grouping (the synthesizer's job):**

- Cluster findings whose suggested fixes share a structural change (same file or same coordinated cross-file edit). A `[Pattern cluster]`-prefixed group is one such change already — the members carry one shared Fix across scattered locations, so keep them in one theme rather than splitting them by file.
- Group all small unrelated polish (1-line comment fixes, import merges, single-finding files) into one `theme-polish` chunk; do NOT dispatch one subagent per single-finding file.
- Aim for 1-5 themes regardless of finding count. 17 findings → ~4 themes is right; 17 findings → 17 themes is wrong.
- Themes don't have to be balanced. A scaffolding redesign with 3 findings is a theme; a polish pass with 9 P3s is also a theme.
- Theme name should describe the change (e.g. `theme-loadmd-simplify`), not the file (e.g. `theme-load-step-markdown-ts`).

## Dispatch template (Phase 2.2)

```
Task general-purpose: "
## Task
Resolve theme: <theme-id> — <theme-description>

## Spec rationale (read before fixing)
- summary: <spec.summary>
- success_criteria: <spec.success_criteria>
- patterns: <spec.context.patterns>
- constraints: <spec.context.constraints>

When the findings cluster around a structural issue, check the spec rationale first. If the spec already explains why the structure is what it is, the right fix is often outside the findings (e.g., the spec was wrong). In that case, do NOT patch the codebase. Return:
- `files_modified: []`
- `outcomes: ["spec inelegant — <one-paragraph reason>. Re-planning required."]`
The orchestrator surfaces this for re-planning instead of dispatching the next chunk.

## Findings (read all before fixing any)
<paste each finding verbatim: title, severity, location, failure, fix>

## Approach: symptoms vs. structure
These findings are clustered because they likely share a structural cause. Diagnose first, patch never.
1. Read all findings before touching code. Identify the structural issue they point at.
2. Fix the structure once. If the structural change resolves N of M findings as a side effect, re-evaluate the rest before applying their fixes — they may dissolve too.
3. Do NOT apply each fix as an isolated patch. The fixes are reviewer hypotheses about individual symptoms; the synthesizer grouped them because the real fix is upstream.

## The bar the user set for me
Read the "Elegance Dispatch Bar" section of `${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/elegance.md` before you touch code. It is the binding contract for this chunk.

Fix-findings addendum:
- If the cleaner shape requires touching files outside the findings list, take it — note the drift in your `outcomes` summary.

## Constraints
- Run tests after the change set; capture exit_code.
- No `git checkout <path>`, `git restore`, `git reset --hard`, `git stash`, or `git clean`. The tree holds uncommitted work from earlier phases and possibly concurrent wave siblings, and you can't tell which of it is yours — even inside your own declared files, so path arguments don't make these safe.
- To mutation-test (break code deliberately to prove a test really fails), use **copy-mutate-restore**: `cp x.rs x.rs.bak`, mutate, restore from the copy, delete the copy. Never revert via git.
- Record every command as you run it (don't summarize at the end).

## Return shape

Return JSON in exactly this shape — fill in your values, keep the field names and structure:

```json
{
  "findings_addressed": ["src/orders/handler.rs:81 N+1 query in list-orders", "src/orders/handler.rs:142 magic 30s timeout"],
  "files_modified": ["src/orders/handler.rs", "src/orders/store.rs"],
  "commands_run": [
    { "command": "cargo test orders", "exit_code": 0, "stdout_tail": "test result: ok. 12 passed" },
    { "command": "cargo clippy -- -D warnings", "exit_code": 0, "stdout_tail": "" }
  ]
}
```

`commands_run[]` is a forensic log — structured objects or summary strings, your call. Nothing downstream parses it programmatically.
\"
```
