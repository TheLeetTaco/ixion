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

Required output discipline:
1. Format each Failure as four slots: `**Failure:** <Principle name>. <Intent>. <Observation>. <Reasoning>.` Principle name = any well-known principle (elegance catalog, SOLID, DRY, language-specific anti-pattern, performance/data-integrity canonical name like "N+1 Query" or "Race Condition"). The synthesizer uses the leading name to route structural failures to redesign vs patch — keep it the first token.
2. If your Failure claims the code misbehaves when it RUNS (wrong output, panic, hang, race, N+1, leak), add `**Evidence:** <command that would demonstrate it>` or `**Evidence:** unproven: <why running something can't show it>`. Propose the command — you have no Bash, so don't try to run it. Structural findings need no Evidence line; omit it. The synthesizer runs your command for P1s and drops the finding if it doesn't reproduce, so name something precise enough to actually fail.
3. Each Fix MUST propose the elegant alternative concretely, not just flag the issue. The implementer treats your Fix as a hypothesis — be specific without over-prescribing.
4. If your search exceeds ~30 tool calls, return what you have — partial results beat exhaustive ones.
```

Item 2 applies to code review only. `plan-review` dispatches against a plan — no code exists to run — so its callers drop that line from the preamble.
