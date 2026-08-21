# Changelog

## Unreleased

<!-- Deliberate, not an oversight: the whole 4.x line accumulates here. 4.0.0 and
4.1.0 bumped both manifests without adding entries of their own, so cutting this
block into versioned headings means first writing those two entries from git
history — a release pass, not a retitle. -->

### Added

- **`ship` can arm GitHub auto-merge on the PR it just opened.** After `gh pr create` succeeds, Phase 4 resolves a four-valued `automerge=` — `off`, `deferred`, `immediate`, `unknown` — from the repository's `allow_auto_merge` flag and the PR's `mergeStateStatus`, then asks **once**, tagged Irreversible, before running `gh pr merge --auto --squash --delete-branch`. **Arming is confirmed, never automatic**, and the confirmation's outcome line says which of the two things will happen: `deferred` merges unattended once the gate clears, `immediate` merges on the spot because nothing is gating the PR. On approval the state is read once more, since `AskUserQuestion` waits on a person: arming happens only where it still matches what the confirmation quoted, and a state that drifted while the question was open is reported instead of armed. `off` and `unknown` ask nothing and arm nothing — `off` names the repository setting's location without offering to flip it, `unknown` reports the state where it read one and says availability could not be confirmed where it did not, printing the arming command for later either way. There is no poller and no session held open; the session is still marked `status: completed` and the session worktree is still the user's to remove. `gh pr merge --auto` cannot be called blind: with the repository setting off (cli/cli#8792) or with nothing gating the PR (cli/cli#13880) it merges immediately without erroring, which is why the probe exists. See the amendment in `docs/adrs/0001-skill-design-as-negotiation.md`.

### Changed

- **The empirical Evidence gate applies at every severity.** 3.0.0 ran the Evidence command only for P1s, so an unreproducible P1 was deleted while an unreproducible P2 went straight to `work`'s fix pass, which fixes P1 through P3 without triage. `work-review` 2.3c now gates any finding whose Failure claims runtime misbehavior and whose Evidence names a command; structural findings and `[Contradicts user]` findings are still exempt, and plan review still skips the stage. Refuted findings are dropped at every severity; ones whose command won't run drop exactly one tier (a P3 stays P3). The gate spends at most 12 commands a round, cycling one P1, one P2, one P3 and round again, so a long P1 list can't drain the budget before the lower tiers the widening was for are reached; the summary reports what went unattempted. Before deleting a refuted finding it writes the title, location and refuting output into `open_questions[]` under a `Refuted and dropped:` marker, which separates a settled record from the open questions around it and keeps a deletion auditable after the summary scrolls away.
- **`[Pattern cluster]` groups have consumer rules again.** The synthesizer has always been able to emit one group covering a shape repeated across locations, but neither consumer said what to do with it. `plan-consolidation` now treats such a group as one redesign of the `context.patterns[]` entry that generated the shape rather than N phase patches, and `work` keeps its members in a single fix theme instead of splitting them by file.
- **The gate's scope is stated once.** `ixion-conventions/SKILL.md` cited its own copy of the rule; it now cites `references/finding-format.md`, which is the single home.
- **The deferral tier is gone from the review skills' prose.** 2.0.0 removed the tier itself; the restatements that outlived it in plan review and consolidation are removed, leaving integrate-or-reject as the only model described.

## 3.0.0 — 2026-07-27

### Breaking

- **Removed the `/yolo` skill.** The autonomous orchestrator chained all six pipeline skills with every human checkpoint pre-answered. It is gone: run the skills yourself (`/plan` → `/work` → `/work-review` → `/work`), which is the flow the checkpoints were designed for. Nothing else in the plugin dispatched `/yolo`, and `work` still auto-detects fix-findings mode from session state, so no other skill changes behavior. See the amendment in `docs/adrs/0001-skill-design-as-negotiation.md` for the reasoning.
- **Removed the `pipeline[]` field from `session.schema.json`.** It was `/yolo`'s run checklist and had no other writer or reader.

### Added

- **`tests/integration/cases/07-chain-smoke.test.sh`** — drives the full chain skill-by-skill, replacing the deleted `03-pipeline-end-to-end` and `04-pipeline-smoke`. Carries forward the schema validations that existed only in `03` (consolidated `spec.json`, generated `review.findings.json`, fix-findings `progress.json`) and asserts the `/work` mode-detection transition directly. Answers the now-live `AskUserQuestion` dialogs through the harness's `autopilot_respond`, which had been dead code while `/yolo` existed.
- **Evidence slot on reviewer findings.** Findings claiming runtime misbehavior name a command that would demonstrate it, or mark themselves `unproven:`. `work-review` runs that command for P1s and drops findings that don't reproduce (new stage 2.3c). Recorded as Principle 13 in the ADR.

### Removed

- `tests/integration/cases/03-pipeline-end-to-end.test.sh` and `04-pipeline-smoke.test.sh` — both drove `/yolo` as their sole entry point; superseded by `07`.

## 2.0.0 — 2026-07-26

### Breaking

- **Renamed the plugin: flywheel → ixion.** Plugin `ixion`, marketplace `ixion-marketplace`, plugin dir `ixion/`, session state dir `.ixion/plugin/`, conventions skill `ixion-conventions`. `install_claude_code.sh` removes prior flywheel installs automatically; sessions created under `.flywheel/` are not migrated.
- **Rust-only language standards.** `language-standards` now carries Rust standards inline in its SKILL.md; the Python/TypeScript/SQL references are gone. Pipeline examples, dispatch templates, and verification commands all use the cargo toolchain.
- **Removed the `astronomer-airflow` skill** (inherently Python-tied).
- **Review feedback always applies.** Consolidation and fix-findings integrate every finding; the deferral tier and both P3 triage prompts are gone. The only gate left is the user's verbatim constraints — contradicting findings are rejected with a `Rejected:` note (plan) or tagged `[Contradicts user]` and skipped with a report (code).
- **Schema renamed:** `task-list.schema.json` → `spec.schema.json` (it validates `spec.json`; nothing was ever named task-list).

### Added

- Rust rows in the elegance catalog: Clone to Satisfy Borrowck, Stringly-Typed Errors, Rc\<RefCell\<T\>\> Masking a Design Cycle, MutexGuard Across .await.
- `active.schema.json` for the active-session pointer — a pure pointer (`schema_version`, `session_id`); run state stays in the session's own `session.json`.
- `tests/integration/cases/04-pipeline-smoke.test.sh` — cheap /yolo transition smoke on haiku (~5 min).
- CI (`.github/workflows/validate.yml`): shellcheck, schema compile, example validation, plugin/marketplace version parity, frontmatter sanity.
- Shared reviewer references in `ixion-conventions`: `finding-format.md`, `reviewer-dispatch.md` — single source of truth for the reviewer output contract and dispatch preamble.
- Compound-skill routing nudges at the close of yolo, work-review, and debug.

### Fixed

- README schema table (spec.json validates against the spec schema, plan-review writes `review.findings.json`), stale `simplifications_made[]` audit guidance in CLAUDE.md, `findings.json` naming split in plan-review/plan-consolidation, `findings.example.json` now leads each failure with a catalog principle name and validates in CI.
- Installer: non-TTY runs skip the Context7 prompt automatically; final step verifies the plugin actually loaded.
- Test harness: pane histories land in `${TMPDIR:-/tmp}` alongside sandboxes; `cleanup.sh` finds both (and pre-rename flywheel debris); assert.sh initializes its counters.
