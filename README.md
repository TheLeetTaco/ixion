# Ixion

A plugin for Claude Code and OpenCode that runs a plan → work → review → ship workflow, with six-perspective agent review at the plan and code boundaries.

Everything is a skill. On Claude Code the skills are plugin-qualified — `/ixion:plan` to plan, `/ixion:work` to implement, `/ixion:work-review` to review, `/ixion:ship` to merge. On OpenCode the installer strips the prefix and the same skills answer to `/plan`, `/work`, and so on. Reviewer, locator, and analyzer subagents do the heavy lifting in fresh contexts so the main thread stays compact.

## Install

### Claude Code

**Marketplace (recommended):**

```
/plugin marketplace add TheLeetTaco/ixion
/plugin install ixion@ixion-marketplace
```

**Local:**

```bash
git clone https://github.com/TheLeetTaco/ixion.git
cd ixion
./install_claude_code.sh
```

### OpenCode

```bash
git clone https://github.com/TheLeetTaco/ixion.git
cd ixion
python3 install_opencode.py
```

This transforms the plugin into OpenCode's config format and writes to `~/.config/opencode/`. Re-run the script to update.

### Optional: Context7

Context7 provides up-to-date framework documentation during plan creation. Both installers will prompt you to configure it. Get an API key at https://context7.com/dashboard.

To configure manually later:

**Claude Code:**

```bash
claude mcp add --header "CONTEXT7_API_KEY: your-key-here" \
  --transport http context7 https://mcp.context7.com/mcp
```

**OpenCode** — add to `~/.config/opencode/opencode.json`:

```json
{
  "mcp": {
    "context7": {
      "type": "remote",
      "url": "https://mcp.context7.com/mcp",
      "headers": {
        "CONTEXT7_API_KEY": "{env:CONTEXT7_API_KEY}"
      }
    }
  }
}
```

### Staying up to date

Re-run the install script for your client to pull the latest version. The Claude Code marketplace auto-update toggle is currently unreliable, so re-running is the safe path on both clients.

**Claude Code:** `bash install_claude_code.sh`

**OpenCode:** `python3 install_opencode.py`

## What problems this solves

### Agents write good code only when forced to re-evaluate from different perspectives

A single pass produces plausible code. Plausible code passes type checks and runs the happy path, but it is rarely well-architected, fast, safe, idiomatic, or elegant — those are different concerns that don't all surface from the same vantage point. Ixion's core loop forces re-evaluation from six perspectives at the two moments where it matters most:

```
plan → 6-perspective review → fix → work → 6-perspective review → fix
```

The six perspectives are independent reviewer subagents, each in fresh context, each only looking through their own lens:

- **architecture** — boundaries, system design, integration shape
- **code-quality** — type safety, idioms, maintainability
- **data-integrity** — migrations, transactions, referential integrity
- **elegance** — single source of truth, working with the grain
- **patterns** — project conventions, duplicated utilities
- **performance** — bottlenecks, query plans, scalability

Findings are deduplicated and conflicts surfaced as open questions, then fed back into either the plan (`/plan-consolidation`) or the code (`/work` in fix-findings mode). The structural problems that one-pass agents miss get caught before they become hundreds or thousands of lines of bad code.

### Context windows fill up too fast

Agents struggle on large codebases because context fills with search results, file contents, and tool output. Ixion compacts at every phase:

- **Research** produces persistent docs, not sprawling chat
- **Plans** distill research into actionable phases (`spec.json`)
- **Subagents** get fresh context per chunk and return compact results
- **Session files** (`progress.json`, `active.json`) enable mid-task recovery

We try to keep the main thread in the range where models perform best.

### Human attention is spent on the wrong things

Reviewing code line-by-line catches individual mistakes. Reviewing research and plans catches structural problems before they become code:

| Review target | Prevents             |
|---------------|----------------------|
| Research      | Thousands of bad lines |
| Plans         | Hundreds of bad lines  |
| Code          | Individual mistakes    |

Ixion asks for human approval at research and plan boundaries because that's where attention has the most leverage. Those gates are the design, not an obstacle to route around: a wrong assumption caught at the research boundary costs a sentence, and the same assumption caught after implementation costs a rewrite. The skills are separate commands precisely so you can stop between them.

## Workflow

```
Plan → Work → Review → Fix → Ship
```

`brainstorm` and `research` are optional entry points. `work-review` can be added before shipping. `ship` automatically compounds learnings.

| Command (Claude Code form) | What it does |
|----------------------------|--------------|
| `/ixion:brainstorm`        | Conversational exploration before detailed planning |
| `/ixion:research`          | Standalone codebase research using locate→analyze |
| `/ixion:plan`              | Orchestrator: runs `plan-creation` → `plan-review` → `plan-consolidation` |
| `/ixion:plan-creation`     | Research, validate claims via Context7, emit a work-ready `spec.json` |
| `/ixion:plan-review`       | All reviewer agents in parallel; deduplicates findings into `review.findings.json` |
| `/ixion:plan-consolidation`| Resolve open questions with the user; merge findings into the spec |
| `/ixion:work`              | Execute `spec.json` (plan mode) or `review.findings.json` (fix-findings mode) |
| `/ixion:work-review`       | Multi-agent code review on a session's work, a branch, or the current changes |
| `/ixion:debug`             | Iterative fix-verify cycle for a specific reported issue |
| `/ixion:compound`          | Capture a solved problem as searchable documentation |
| `/ixion:ship`              | Branch → commit → merge into the integration branch; compounds learnings on the way out |

Every skill but `plan` also answers to its bare name on Claude Code, which is how the prose below refers to them.

## How it works

### Planning in phases

`/ixion:plan` orchestrates three skills in sequence, each writing to the same session:

1. **Create** — Research the codebase (locate→analyze), validate high-risk claims against external docs (Context7), and draft `spec.json`
2. **Review** — Run all reviewer agents in parallel (architecture, performance, data integrity, elegance, etc.), deduplicate findings, surface conflicts as open questions
3. **Consolidate** — Resolve open questions with the user one at a time, then restructure everything into an actionable checklist ready for `/work`

### Research with tiered agents

`/research` (and the research step inside `/plan-creation`) uses a two-phase locate→analyze pattern:

- **Locators** (cheap, parallel, haiku for the local ones) find WHERE things are — paths and `file:line` refs only, no Read tool
- **Analyzers** (expensive, targeted, sonnet) understand HOW things work — full file reads on the top findings, documentarian mode (no suggestions)

This costs a fraction of an all-in-one research agent for the same fidelity.

### Execution with recovery

`/work` uses a probe-dispatch-checkpoint pattern, so you can clear context mid-work and pick the session back up. Every stage ends by printing the whole line that resumes it — `/ixion:work <session-id>`, preceded by a `cd` when the session moved into a worktree. Paste that line into the fresh context and you land on the session you just left, whatever else has happened since. Invoking `/work` with no arguments still works and falls back to `active.json`, but that pointer belongs to whichever session was planned most recently, so it is the convenience path rather than the reliable one. It runs in two modes — `plan` (executing `spec.json`) and `fix-findings` (executing `review.findings.json`) — and picks the mode itself from session state: a completed plan-mode `progress.json` alongside a present `review.findings.json` means the next bare `/work` is a fix pass.

### Multi-agent review

`/work-review` runs all reviewer agents in parallel, deduplicates findings, detects conflicts between reviewers, and writes a structured `review.findings.json` ready for `/work` to consume in fix-findings mode.

### Branching in a two-branch repo

`/work` creates the session branch from the integration branch, and `/ship` merges it back into that same branch with `--no-ff`. Start `/work` on production while a distinct integration branch exists and it switches to integration first, then branches — so checkpoint commits never land on a shared branch, and the session's diff covers the session rather than everything since the last release.

The integration branch is detected from git state; there is nothing to configure. A local or remote-tracking `dev` or `develop` is the integration branch, `dev` winning if a repo carries both. **A repo with neither gets one the first time it ships** — `/ship` creates `dev` off the default branch, pushes it, and merges into that, behind the same confirmation the merge itself carries. Detection is by those two names only, so a team whose integration branch is `staging` or `next` gets a `dev` alongside it.

The resolution itself, the protected set, and the error states every skill handles identically (dirty tree, detached HEAD, an integration branch deleted between `work` and `ship`) live in `ixion/skills/ixion-conventions/references/git-branches.md`.

## Components

| Type                 | Count | Examples |
|----------------------|------:|----------|
| Workflow skills      | 11    | `brainstorm`, `research`, `plan`, `plan-creation`, `plan-review`, `plan-consolidation`, `work`, `work-review`, `debug`, `compound`, `ship` |
| Utility skills       | 2     | `ixion-conventions`, `language-standards` |
| Reviewer agents      | 6     | `architecture`, `code-quality`, `data-integrity`, `elegance`, `patterns`, `performance` |
| Research locators    | 4     | `codebase`, `patterns`, `docs`, `web` |
| Research analyzers   | 5     | `codebase`, `patterns`, `docs`, `web`, `git-history` |

### Reviewers (6)

| Agent                     | What it reviews |
|---------------------------|-----------------|
| `reviewer-architecture`   | Architectural decisions, component boundaries, system design |
| `reviewer-code-quality`   | Type safety, idioms, maintainability; loads `language-standards` (Rust) on demand |
| `reviewer-data-integrity` | Database migrations, transaction boundaries, referential integrity |
| `reviewer-elegance`       | Single source of truth, working with the grain, no ceremony |
| `reviewer-patterns`       | Project conventions, codebase norms, duplicated utilities |
| `reviewer-performance`    | Bottlenecks, query plans, scalability characteristics |

### Locators (4) — cheap, parallel

Find WHERE things are without reading files. No Read tool — paths and `file:line` references only. The three local locators run on haiku; `locator-web` needs sonnet to judge search-result relevance.

| Agent              | Model  | Tools           | Purpose |
|--------------------|--------|-----------------|---------|
| `locator-codebase` | haiku  | Grep, Glob, LS  | Files and components |
| `locator-patterns` | haiku  | Grep, Glob, LS  | Specific patterns (`file:line`) |
| `locator-docs`     | haiku  | Grep, Glob, LS  | Documentation |
| `locator-web`      | sonnet | WebSearch       | Relevant URLs (no fetching) |

### Analyzers (5) — more powerful, targeted, sonnet

Understand HOW things work via full file reads. Documentarian mode — no suggestions.

| Agent                 | Tools                    | Purpose |
|-----------------------|--------------------------|---------|
| `analyzer-codebase`   | Read, Grep, Glob         | Implementation details |
| `analyzer-patterns`   | Read, Grep, Glob         | Code examples in context |
| `analyzer-docs`       | Read, Grep, Glob         | Synthesize documentation |
| `analyzer-web`        | WebFetch, Read           | Deep web content extraction |
| `analyzer-git-history`| Bash, Read, Grep, Glob   | Code evolution and contributors |

## Schemas

Session artifacts live in `.ixion/plugin/sessions/<id>/` and validate against schemas in `ixion/schemas/`:

| Artifact                  | Schema                  | Written by |
|---------------------------|-------------------------|------------|
| `spec.json`               | `spec.schema.json` | `plan-creation` / `plan-consolidation` |
| `review.findings.json`    | `findings.schema.json`  | `plan-review` / `work-review` |
| `progress.json`           | `progress.schema.json`  | `work` |
| `session.json`            | `session.schema.json`   | `plan-creation` |
| `active.json`             | `active.schema.json`    | `plan-creation` (pure pointer — run state lives in `session.json`) |

Two sidecars also land in the session dir and are audit trails, not inputs: `spec.json.pre-consolidation` (the pre-refinement spec, written by `plan-consolidation`) and `progress.json.plan-mode` (the completed plan-mode progress, renamed by `work` when it enters fix-findings mode).

## Client differences

Same skills, slightly different plumbing.

| Aspect          | Claude Code                     | OpenCode |
|-----------------|---------------------------------|----------|
| Distribution    | Plugin marketplace or local install | `install_opencode.py` |
| Command syntax  | `/ixion:<skill>`; bare `/plan` reaches a built-in instead | `/<skill>` — the installer rewrites `/ixion:` away |
| Config location | `~/.claude/plugins/cache/...`   | `~/.config/opencode/` |
| Auto-update     | Marketplace toggle              | Re-run install script |
| Context7 MCP    | Bundled in plugin manifest or via installer | Configured into `opencode.json` |

The rewrite covers the command *name*. Whether an argument typed after it — the session id a resume line carries — reaches an OpenCode skill the way it reaches a Claude Code one is untested: `install_opencode.py` leaves `SKILL.md` bodies alone, so the `#$ARGUMENTS` token installs verbatim. Treat OpenCode session targeting as unproven until someone runs it.

## Development

### Layout

```
ixion/
├── ixion/         # plugin source (skills, agents, schemas)
│   ├── agents/       # 15 subagent definitions
│   ├── skills/       # 13 skill definitions, one per directory
│   └── schemas/      # JSON Schemas for session artifacts
├── docs/adrs/        # architectural decisions (read 0001 first)
├── tests/            # tmux integration tests against real API
├── install_claude_code.sh
└── install_opencode.py
```

### Integration tests

Real `tmux` sessions running `claude` against the local plugin (loaded via `--plugin-dir`), driving slash commands and asserting against on-disk artifacts. No mocks — every test that exists hits the real Anthropic API.

```bash
bash tests/integration/run.sh                 # all cases
bash tests/integration/run.sh plugin-loads    # filter by name
IXION_TEST_JOBS=2 bash tests/integration/run.sh   # run 2 cases concurrently
```

Requirements: `ANTHROPIC_API_KEY` set; `tmux`, `claude`, `python3`, `bunx` on PATH, plus `cargo` for `07` (its fixture builds and tests a Rust crate). Schema validation uses `bunx ajv-cli` (no install needed).

Two env vars tune a run: `IXION_TEST_MODEL` overrides the model (cases default to haiku; the runner's default is `claude-sonnet-4-6`), and `IXION_TEST_JOBS` runs N cases concurrently — 2–3 is a sensible ceiling, since parallel cases multiply concurrent API spend and rate-limit pressure.

| Case                                | What it exercises | Cost |
|-------------------------------------|-------------------|------|
| `00-plugin-loads.test.sh`           | `--plugin-dir` discovery; `/plan` and `/work` show up in palette | none (no model call) |
| `01-fly-work-resumes.test.sh`       | `work` against a seeded session: `progress.json` lands and validates, mode is `plan` | ~1–3 min |
| `02-fly-plan-creates-spec.test.sh`  | `plan` orchestrator end-to-end: writes `spec.json`, `session.json`, `active.json` | ~3–10 min |
| `05-parallel-sessions.test.sh`      | `/work <slug>` targets the named session, not whatever `active.json` points at | ~3–4 min |
| `06-parallel-chunks.test.sh`        | `work` executes a `depends_on` spec to completion via wave dispatch | ~4–5 min |
| `07-chain-smoke.test.sh`            | The full chain driven skill-by-skill (`/ixion:plan`, `/work`, `/work-review`, `/work`); asserts each artifact, both schema validity and `Skill()` markers | ~10 min |

When a test fails, the cleanup trap captures the full pane scrollback to `/tmp/ixion-int-<session>-<timestamp>-<label>.pane.txt` and leaves the sandbox in place so you can inspect session state. `bash tests/cleanup.sh --apply` deletes them when you're done. See `CLAUDE.md` for monitoring and debugging recipes.

### Reinstall after plugin changes

```bash
bash install_claude_code.sh < /dev/null 2>&1 | tail -3
```

The integration tests load from `ixion/` directly via `--plugin-dir`, so they pick up source changes without reinstall. `claude` may cache parts of the plugin between sessions — when in doubt, reinstall.

### Architectural philosophy

Skill design is treated as negotiation, not enforcement. Coaxing the model into the right behavior beats structural validators most of the time, and structural enforcement only earns its keep where coaxing has demonstrably failed across multiple runs. Read `docs/adrs/0001-skill-design-as-negotiation.md` before adding gates or validators.

## Inspiration

- **[Compound Engineering Plugin](https://github.com/EveryInc/compound-engineering-plugin)** by Every
- **[HumanLayer Claude Config](https://github.com/humanlayer/humanlayer/tree/main/.claude)** by HumanLayer

## License

[MIT](LICENSE)
