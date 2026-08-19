# Plan mode (loaded by Phase 1 when the session has a `spec.json` to execute)

## What a chunk is

Chunk = phase from `spec.json.phases[]`. ID = `phase.id`. Bullets = `phase.tasks[]`.

## Dispatch template (Phase 2.2)

```
Task general-purpose: "
## Task
Execute phase <id>: <phase.goal>

## Phase JSON
<paste phase JSON: tasks, files, verification, manual_verification>

## Context
- summary: <spec.summary>
- success_criteria: <spec.success_criteria>
- key_files: <spec.context.key_files>
- patterns: <spec.context.patterns>
- constraints: <spec.context.constraints>
- Already completed: <progress.completed>

## The bar the user set for me
Read the "Elegance Dispatch Bar" section of `ixion/skills/ixion-conventions/references/elegance.md` before you touch code. It is the binding contract for this chunk.

Plan-mode addendum:
- Search the codebase for an existing helper before adding new utility code.
- Follow existing patterns; deviate when the existing pattern is itself inelegant — note the deviation in your report.

## Constraints
- TDD per task (RED → GREEN → REFACTOR). REFACTOR is mandatory. Skip TDD only for pure refactor, docs, or config-only changes.
- No `git checkout <path>`, `git restore`, `git reset --hard`, `git stash`, or `git clean`. The tree holds uncommitted work from earlier phases and possibly concurrent wave siblings, and you can't tell which of it is yours — even inside your own declared files, so path arguments don't make these safe.
- To mutation-test (break code deliberately to prove a test really fails), use **copy-mutate-restore**: `cp x.rs x.rs.bak`, mutate, restore from the copy, delete the copy. Never revert via git.
- Record every command as you run it (don't summarize at the end).

## Return shape

Return JSON in exactly this shape — fill in your values, keep the field names and structure:

```json
{
  "outcomes": ["Added timeout flag to clap config"],
  "files_modified": ["src/cli.rs", "tests/cli_timeout.rs"],
  "commands_run": [
    { "command": "cargo test --test cli_timeout", "exit_code": 0, "stdout_tail": "test result: ok. 4 passed" },
    { "command": "cargo clippy -- -D warnings", "exit_code": 0, "stdout_tail": "" }
  ]
}
```

`commands_run[]` is a forensic log — entries can be structured objects (as shown) or plain summary strings like `'cargo test — 4 passed'`. Whatever you'll find useful to read later. Nothing downstream parses this programmatically.
\"
```
