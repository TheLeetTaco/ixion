# Finding Format (all reviewers)

Return findings as natural-language prose. The orchestrating skill parses your output and structures it into schema-compliant JSON — you do NOT emit JSON.

For each finding, provide all of:

- **Title** — a short scannable phrase (no period).
- **Severity** — exactly one of `P1`, `P2`, or `P3`; there is no informational tier. See `ixion-conventions` Severity definitions.
- **Location** — format provided by the invoker. Code review: `<repo-relative-path>` or `<repo-relative-path>:<line>`. Plan review: `<phase_id>` or `<phase_id>/<task_id>`.
- **Failure** — four slots: `<Principle name>. <Intent>. <Observation>. <Reasoning>.` The synthesizer uses the leading name to route — keep it the first token. Your agent definition lists the domain principle names to lead with.
- **Evidence** — **only when your Failure claims the code misbehaves when it runs** (wrong output, panic, hang, race, N+1, leak, resource exhaustion). Name the command that would demonstrate it, or write `unproven: <why running something can't show it>`. You have no Bash — propose the command, don't run it. Structural findings are visible in the source and need no Evidence: omit the line entirely for God Class, Shallow Wrapper, Premature Abstraction, Convention Drift, and their kin.
- **Fix** — a concrete proposed change. The Failure paragraph is binding; the Fix is your best guess — the implementer may find a more elegant resolution. Be specific enough to give a starting point, abstract enough to allow a better path.

Format per finding:

```
**Finding:** <title>
**Severity:** P<n>
**Location:** <location>
**Failure:** <Principle name>. <Intent>. <Observation>. <Reasoning>.
**Evidence:** <command that demonstrates the misbehavior> | unproven: <reason>
**Fix:** <proposed change>
```

Multiple findings: separate with a blank line. No findings: say "No findings." A check that came out clean is not a finding — report it as a sentence of prose above the list, never as an entry under an invented severity.

Do not write to any files — return prose in your response only. The synthesizer owns all file writes.

## Why Evidence exists

A runtime claim that nobody ran is a guess, and confident agreement between reviewers is not proof — reviewers have unanimously backed defects that turned out not to exist. In code review the synthesizer runs the command you name — at every severity, not P1 alone — and drops the finding if it doesn't reproduce, so a precise command is what keeps a real finding alive. `unproven:` is an honest answer and costs the finding one severity tier, or nothing at all at P3, where there is no lower tier to fall to.
