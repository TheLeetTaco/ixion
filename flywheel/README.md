# Flywheel Plugin

A plugin for Claude Code and OpenCode that turns development cycles into momentum.

## What Problems Does This Solve?

### Context windows fill up too fast

AI agents struggle with large codebases because context windows fill with search results, file contents, and tool outputs. Flywheel manages this through deliberate compaction at each phase:

- **Research → Plan → Implement workflow** - Each phase produces compact artifacts, not sprawling chat
- **`docs/research/` artifacts** - Persist research findings across sessions
- **`progress.json` checkpoints** - Atomic state writes enable recovery if context is lost mid-work
- **Subagent dispatch** - Fresh context for research tasks, compact results returned

This keeps context utilization in the 40-60% range where models perform best.

**Session Recovery:** If you need to clear context mid-work, just run `/work` with no arguments. The session file remembers where you left off.

### Knowledge walks out the door

When an agent solves a problem, the solution lives in chat history and disappears. Flywheel captures lessons so they persist:

- **`/compound`** - Document solutions while context is fresh
- **`/ship`** - Automatically compounds learnings when opening a PR, so knowledge capture is built into the shipping flow
- **`docs/solutions/`** - Searchable knowledge base with YAML frontmatter
- **Automatic discovery** - Planning skills surface relevant past solutions

These learnings live in your codebase, so they're automatically shared with your team.

### Human attention is spent on the wrong things

Reviewing code line-by-line catches individual mistakes. Reviewing research and plans catches structural problems before they become code:

| Review Target | Prevents |
|---------------|----------|
| Research | Thousands of bad lines |
| Plans | Hundreds of bad lines |
| Code | Individual mistakes |

Flywheel requires human approval at research and plan boundaries because that's where your attention has the most impact.

## Installation

### Claude Code

**Marketplace (recommended):**

```
/plugin marketplace add wsauret/flywheel
/plugin install flywheel@flywheel-marketplace
```

**Local:**

```bash
git clone https://github.com/wsauret/flywheel.git
cd flywheel
./plugin/install_claude_code.sh
```

### OpenCode

```bash
git clone https://github.com/wsauret/flywheel.git
cd flywheel
python3 plugin/install_opencode.py
```

This transforms the plugin into OpenCode's config format and writes to `~/.config/opencode/`. Re-run the script to update.

Both installers will prompt you to configure the Context7 MCP server (optional, for up-to-date framework docs during planning). For manual setup details, see the [repository README](https://github.com/wsauret/flywheel).

## Components

| Component | Count |
|-----------|-------|
| Agents | 15 |
| Skills | 15 |

## Agents

Agents are organized into categories for easier discovery.

### Reviewers (6)

| Agent | Description |
|-------|-------------|
| `reviewer-architecture` | Analyze architectural decisions and compliance |
| `reviewer-code-quality` | Python/TypeScript review with high quality bar |
| `reviewer-data-integrity` | Database migrations and data integrity |
| `reviewer-patterns` | Analyze code for patterns and anti-patterns |
| `reviewer-performance` | Performance analysis and optimization |
| `reviewer-elegance` | Design elegance review for plans and code |

### Research Locators (4) - Cheap, Parallel

Find WHERE things are without reading full contents. Use haiku model.

| Agent | Tools | Description |
|-------|-------|-------------|
| `locator-codebase` | Grep, Glob | Find WHERE files and components live |
| `locator-patterns` | Grep, Glob | Find WHERE patterns exist (file:line refs) |
| `locator-docs` | Grep, Glob | Find WHERE documentation lives |
| `locator-web` | WebSearch | Find relevant URLs (no fetching) |

### Research Analyzers (5) - Expensive, Targeted

Understand HOW things work by reading files. Use sonnet model. Documentarian mode - no suggestions.

| Agent | Tools | Description |
|-------|-------|-------------|
| `analyzer-codebase` | Read, Grep, Glob | Understand HOW code works |
| `analyzer-patterns` | Read, Grep, Glob | Extract code examples with context |
| `analyzer-docs` | Read, Grep, Glob | Extract insights from documentation |
| `analyzer-web` | WebFetch, Read | Fetch and analyze web content deeply |
| `analyzer-git-history` | Bash, Read, Grep, Glob | Analyze git history for code evolution and development insights |

## Skills

Every flywheel capability is a skill. Skills are user-invocable as `/<skill-name>` in both Claude Code and OpenCode.

### Workflow Skills

| Skill | Description |
|-------|-------------|
| `/plan` | **Orchestrator** — runs plan-creation → plan-review → plan-consolidation in sequence |
| `/brainstorm` | Conversational exploration of ideas before planning |
| `/research` | Comprehensive codebase research using locate→analyze pattern |
| `/plan-creation` | Research codebase, validate claims, emit a work-ready spec.json |
| `/plan-review` | Critique a plan from multiple reviewer perspectives (architecture, perf, data integrity, elegance, etc.) |
| `/plan-consolidation` | Resolve open questions with the user; merge findings into the spec |
| `/work` | Execute the active session's plan or review findings |
| `/work-review` | Multi-agent code review on PRs, branches, or current changes |
| `/compound` | Capture solved problems as categorized documentation |
| `/debug` | Iterative debug loop with verification after each fix attempt |
| `/ship` | Branch creation, commit, push, PR creation, and compound learnings |

**Core Workflow:**
```
/plan → /work → /ship
```

`/brainstorm` and `/research` are optional entry points. `/work-review` can be added before shipping. `/ship` automatically compounds learnings.

### Domain-Specific Skills

| Skill | Description |
|-------|-------------|
| `astronomer-airflow` | Operational reference for Airflow 3.x on Astronomer |

### Utility Skills

| Skill | Description |
|-------|-------------|
| `flywheel-conventions` | Shared conventions for subagents: token limits, output format, severity definitions |
| `language-standards` | Language-specific standards for Python, TypeScript, SQL; loaded by reviewers on demand |

## Research Pattern

Flywheel uses a two-phase locate→analyze pattern for research:

1. **Locators (cheap, parallel)**: Find WHERE things are using haiku model
   - No Read tool - paths and file:line references only
   - Run all locators in parallel

2. **Analyzers (expensive, targeted)**: Understand HOW things work using sonnet model
   - Only analyze top 15 findings from locators
   - Documentarian mode: document what IS, not what SHOULD BE
   - Full file reads (no partial reads)

This reduces context usage significantly compared to all-in-one research agents.

## Client Differences

While Flywheel provides the same functionality on both clients, there are a few structural differences:

| Aspect | Claude Code | OpenCode |
|--------|------------|----------|
| Distribution | Plugin marketplace or local install | `install_opencode.py` script |
| Command syntax | `/skill-name` | `/skill-name` |
| Config location | `~/.claude/plugins/cache/...` | `~/.config/opencode/` |
| Auto-update | Marketplace toggle | Re-run install script |
| Context7 MCP | Bundled in plugin or configured via installer | Configured via installer into `opencode.json` |
