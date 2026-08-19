# Question Format (skills that address the user)

Every question you put to the user answers one implicit question first: what makes this choice theirs rather than yours? The `**Why you:**` slot is that answer, and its catalog is also the gate — when no reason fits, you don't ask.

One question per AskUserQuestion call — never a `questions: [...]` array longer than one. Ask, await the answer, then ask the next; bundled prompts collapse into a wizard-style "Review your answers" flow.

```
Question: "[Topic]: [the question, one line]"
**Why you:** <Reason>. <one clause naming what you can't derive>.
Options:
1. [Recommended option] - [what it does]
2. [Alternative] - [what it does]
3. "You pick what's best" - Let me decide
```

The Options list is for questions that enumerate alternatives. A confirmation or an inline edge-case question — a generated branch name to accept or edit, a push that just failed — carries the Question and Why-you slots alone, with nothing to recommend or delegate.

The recommended option is listed first because the default answer should be the one worth accepting unread — so under **Irreversible** the non-destructive option leads and carries the marker even where you would otherwise recommend proceeding, and a confirmation with no Options list defaults to declining. Option 3 is always present and always last; when the user takes it, apply the recommendation and name the option you applied.

Two fields from earlier question templates are dropped. `Context:` and `My recommendation:` are both subsumed by the slots above — Why-you already carries the only context that changes the user's answer, and the recommendation now shows as option 1 instead of as prose the reader has to match back to the list.

## Reasons

- **Preference** — the answer turns on taste or priorities that no amount of reading the codebase would settle.
- **Irreversible** — the action is hard or impossible to undo: a force-push, a published branch, rewritten history.
- **Missing fact** — only the user holds the input, such as the error text, the repro command, or what they actually observed.
- **Scope** — the choice changes what gets built rather than how, so answering it for them would enlarge the job they agreed to.

A fifth reason is added when a concrete site needs one, not in advance.

**The gate:** when no reason fits, don't ask. Pick the determined best solution, apply it, and report what you picked and why in the same breath. Questions tagged **Irreversible** are exempt from the gate — ask them even when you could compute the answer, because being right about an unrecoverable action is not the same as being allowed to take it.

**Strong:**
> Question: "Merge: bring `fix/search-pagination`'s 4 commits into `dev` and push?"
> **Why you:** Irreversible. The merge lands on the branch every other worktree in this repo builds from, and undoing it after the push means a revert commit everyone else has already pulled.

**Weak:**
> Question: "Naming: call the module `session_store` or `store`?" — no reason fits. The surrounding code already implies one; pick it and say which you picked.
> `debug/SKILL.md` used to ask "Continue debugging anyway?" after finding a mid-work session. Nothing was irreversible and no fact was missing — the user had just run `/debug` — so this gate deleted it; the skill now names the conflicting session and continues.
