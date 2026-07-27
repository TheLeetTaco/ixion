# Reviewer Dispatch (shared by plan-review and work-review)

Two blocks both orchestrators use. Modifying dispatch behavior means editing this file — the callers hold only their scope-specific tails (location format, target content, plan-vs-code context).

## Project context discovery (orchestrator, once)

Use Glob to find the project's architectural docs once at the orchestrator level — reviewers read the resulting paths instead of doing six parallel discoveries:

- `CLAUDE.md`
- `agents.md`
- `docs/architecture.md`
- `docs/adrs/**/*.md`
- `docs/coding-guidelines*.md`

Collect the matching paths into `PROJECT_CONTEXT_PATHS`. Inline them in every reviewer dispatch under "PROJECT CONTEXT PATHS." If no docs match, pass `none` — reviewers skip discovery and apply universal principles only.

## Shared reference excerpts (orchestrator reads once)

Before composing dispatches, the orchestrator Reads — once — `ixion/skills/ixion-conventions/references/elegance.md` (the "Elegance Dispatch Bar" and "Anti-Pattern Catalog" sections) and the "Lead with the Failure" section of `ixion/skills/ixion-conventions/SKILL.md`, and pastes those excerpts into every dispatch below. This is the same read-once-paste-N-times idiom `work` uses for the Elegance Dispatch Bar: one orchestrator read replaces six identical subagent reads per round. Project-context docs stay as **paths** — reviewers read only the ones relevant to their domain; inlining whole ADRs would bloat six prompts.

## Dispatch preamble (paste at the top of every reviewer dispatch, with the excerpts filled in)

```
Before assessing your domain, read the pasted reference excerpts and the project context paths listed below. The elegance lens applies to every domain — don't defer to reviewer-elegance.

## Reference excerpts (pasted by the orchestrator — do not re-read the source files)
<paste the Elegance Dispatch Bar + Anti-Pattern Catalog excerpt from elegance.md>
<paste the "Lead with the Failure" excerpt from ixion-conventions SKILL.md>

If your search exceeds ~30 tool calls, return what you have — partial results beat exhaustive ones.
```

The preamble deliberately says nothing about the shape of a finding — that contract lives in `ixion/skills/ixion-conventions/references/finding-format.md`, which every reviewer's Output Format section already points to. Don't restate it here: the restatement that used to occupy this block listed Failure, Evidence and Fix but not Severity, and reviewers took it as the authoritative element list and dropped Severity.
