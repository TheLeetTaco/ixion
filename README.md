# Ixion

A plugin for Claude Code and OpenCode that runs a plan → work → review → ship workflow, with six-perspective agent review at the plan and code boundaries.

Everything is a skill. `/plan` to plan, `/work` to implement, `/work-review` to review, `/ship` to send a PR. Reviewer, locator, and analyzer subagents do the heavy lifting in fresh contexts so the main thread stays compact.

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

| Skill                | What it does |
|----------------------|--------------|
| `/brainstorm`        | Conversational exploration before detailed planning |
| `/research`          | Standalone codebase research using locate→analyze |
| `/plan`              | Orchestrator: runs `plan-creation` → `plan-review` → `plan-consolidation` |
| `/plan-creation`     | Research, validate claims via Context7, emit a work-ready `spec.json` |
| `/plan-review`       | All reviewer agents in parallel; deduplicates findings into `review.findings.json` |
| `/plan-consolidation`| Resolve open questions with the user; merge findings into the spec |
| `/work`              | Execute `spec.json` (plan mode) or `review.findings.json` (fix-findings mode) |
| `/work-review`       | Multi-agent code review on PRs, branches, or current changes |
| `/debug`             | Iterative fix-verify cycle for a specific reported issue |
| `/compound`          | Capture a solved problem as searchable documentation |
| `/ship`              | Branch → commit → PR; compounds learnings on the way out |

## How it works

### Planning in phases

`/plan` orchestrates three skills in sequence, each writing to the same session:

1. **Create** — Research the codebase (locate→analyze), validate high-risk claims against external docs (Context7), and draft `spec.json`
2. **Review** — Run all reviewer agents in parallel (architecture, performance, data integrity, elegance, etc.), deduplicate findings, surface conflicts as open questions
3. **Consolidate** — Resolve open questions with the user one at a time, then restructure everything into an actionable checklist ready for `/work`

### Research with tiered agents

`/research` (and the research step inside `/plan-creation`) uses a two-phase locate→analyze pattern:

- **Locators** (cheap, parallel, haiku) find WHERE things are — paths and `file:line` refs only, no Read tool
- **Analyzers** (expensive, targeted, sonnet) understand HOW things work — full file reads on the top findings, documentarian mode (no suggestions)

This costs a fraction of an all-in-one research agent for the same fidelity.

### Execution with recovery

`/work` uses a probe-dispatch-checkpoint pattern. State files and session tracking mean you can clear context mid-work and resume with `/work` (no args). It runs in two modes — `plan` (executing `spec.json`) and `fix-findings` (executing `review.findings.json`) — and picks the mode itself from session state: a completed plan-mode `progress.json` alongside a present `review.findings.json` means the next bare `/work` is a fix pass.

### Multi-agent review

`/work-review` runs all reviewer agents in parallel, deduplicates findings, detects conflicts between reviewers, and writes a structured `review.findings.json` ready for `/work` to consume in fix-findings mode.

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

### Locators (4) — cheap, parallel, haiku

Find WHERE things are without reading files. No Read tool — paths and `file:line` references only.

| Agent              | Tools         | Purpose |
|--------------------|---------------|---------|
| `locator-codebase` | Grep, Glob    | Files and components |
| `locator-patterns` | Grep, Glob    | Specific patterns (`file:line`) |
| `locator-docs`     | Grep, Glob    | Documentation |
| `locator-web`      | WebSearch     | Relevant URLs (no fetching) |

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

## Client differences

Same skills, slightly different plumbing.

| Aspect          | Claude Code                     | OpenCode |
|-----------------|---------------------------------|----------|
| Distribution    | Plugin marketplace or local install | `install_opencode.py` |
| Skill syntax    | `/skill-name`                   | `/skill-name` |
| Config location | `~/.claude/plugins/cache/...`   | `~/.config/opencode/` |
| Auto-update     | Marketplace toggle              | Re-run install script |
| Context7 MCP    | Bundled in plugin manifest or via installer | Configured into `opencode.json` |

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
```

Requirements: `ANTHROPIC_API_KEY` set; `tmux`, `claude`, `jq`, `bunx` on PATH. Schema validation uses `bunx ajv-cli` (no install needed).

| Case                                | What it exercises | Cost |
|-------------------------------------|-------------------|------|
| `00-plugin-loads.test.sh`           | `--plugin-dir` discovery; `/plan` and `/work` show up in palette | none (no model call) |
| `01-fly-work-resumes.test.sh`       | `work` against a seeded session: `progress.json` lands and validates, mode is `plan` | ~1–3 min |
| `02-fly-plan-creates-spec.test.sh`  | `plan` orchestrator end-to-end: writes `spec.json`, `session.json`, `active.json` | ~3–10 min |
| `07-chain-smoke.test.sh`            | The full chain driven skill-by-skill (`/plan`, `/work`, `/work-review`, `/work`); asserts each artifact, both schema validity and `Skill()` markers | ~10 min |

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
