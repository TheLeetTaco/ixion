# Reviewer Dispatch (shared by plan-review and work-review)

Two blocks both orchestrators use. Modifying dispatch behavior means editing this file — the callers hold only their scope-specific tails (location format, target content, plan-vs-code context).

## Project context discovery (orchestrator, once)

Use Glob to find the project's architectural docs once at the orchestrator level — reviewers read the resulting paths instead of doing six parallel discoveries:

- `CLAUDE.md`
- `agents.md`
- `docs/architecture.md`
- `docs/adrs/**/*.md`
- `docs/coding-guidelines*.md`

Glob with `path` set to the tree under review — the session worktree for `work-review`, the repository root for `plan-review` — and collect the matches as absolute paths into `PROJECT_CONTEXT_PATHS`: a reviewer starts in whatever directory the session was launched from, and a relative path would have it read that checkout's copy rather than the tree's own. Inline them in every reviewer dispatch under "PROJECT CONTEXT PATHS." If no docs match, pass `none` — reviewers skip discovery and apply universal principles only.

## Shared reference sections (each reviewer reads by path)

The preamble names the reference sections by path and the orchestrator inlines none of them. Every reviewer needs that text either way, so the copies a paste would add are the ones sitting in the orchestrator's own context — six per round, twice per pipeline — and context is the scarce resource where a disk read is not. `finding-format.md` already reaches every reviewer this way, through their Output Format sections. What that buys the saving is one extra Read round-trip per reviewer per wave: the same round-trip `finding-format.md` already costs each of them.

Project-context docs are paths for the same reason, plus one of their own — reviewers read only the ones their domain touches, and inlining whole ADRs would bloat six prompts.

## Dispatch preamble (paste at the top of every reviewer dispatch)

```
Before assessing your domain, read the reference sections and the project context paths listed below. The elegance lens applies to every domain — don't defer to reviewer-elegance.

## Reference sections to read first
- the "Elegance Dispatch Bar" section of `${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/elegance.md`
- the "Anti-Pattern Catalog" section of `${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/references/elegance.md`
- the "Finding Quality: Lead with the Failure" section of `${CLAUDE_PLUGIN_ROOT}/skills/ixion-conventions/SKILL.md` — already preloaded into your context as the `ixion-conventions` skill, so apply it from there rather than Reading the file again

If your search exceeds ~30 tool calls, return what you have — partial results beat exhaustive ones.

Every finding you return carries all five of Title, Severity, Location, Failure and Fix, plus Evidence where your Output Format section's finding-format reference calls for it. Severity is a literal `P1`, `P2` or `P3`.
```

That last line names the elements and elaborates on none of them, which is the only stable point between two observed failures. The restatement that used to occupy this block described Failure, Evidence and Fix at length and never mentioned Severity; reviewers read it as the authoritative element list and dropped Severity. Deleting the restatement left the list reachable only through `finding-format.md` — and four of six reviewers dropped Severity again, the one reviewer that complied being the only one whose own domain rules happen to name P-labels. A bare naming is too thin to compete with the contract and complete enough that no element can be inferred away. Expanding any single element here rebuilds the partial list; the shape, the four Failure slots and the Evidence condition stay in `finding-format.md`, which every reviewer's Output Format section points to.
