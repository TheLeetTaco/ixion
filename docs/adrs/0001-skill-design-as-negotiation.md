# ADR-001: Skill Design as Negotiation

## Status

Accepted — captured during iterative test-driven refinement of `/yolo` and the planning pipeline, and cited as binding by `CLAUDE.md` and `README.md`. Still refined with experience; changes land as amendments here.

## Context

We built a plugin around a chain of skills (plan-creation → plan-review → plan-consolidation → work → work-review → fix-findings) connected by structured JSON artifacts (`spec.json`, `progress.json`, `review.findings.json`). The schemas were designed to make handoffs explicit and the test suite was designed to fail-loudly on artifact violations.

When we exercised the full chain via `/yolo` (autonomous orchestrator), tests revealed a consistent class of failures that didn't fit the "agent didn't understand" framing:

- **Decision drift.** User said "tests with unittest. Stdlib only — no pip install." plan-creation honored it. plan-review suggested pytest as more idiomatic. plan-consolidation rationalized "pytest is a dev dependency, not shipped at runtime" and rewrote `success_criteria` to admit pytest — explicitly noting the contradiction in parentheses while integrating it.
- **Bookkeeping skipped.** Agent created the requested `notes.py`, `app.py`, `tests/test_notes.py`, ran them, produced findings — but never wrote `progress.json`, the artifact downstream skills depend on.
- **Schema violations on ceremony.** `commands_run` written as bare summary strings instead of objects with `exit_code`, even though the schema and dispatch templates clearly required objects.
- **Compressed protocols.** Multi-step TDD/RED-GREEN-REFACTOR collapsed to "code written, tests pass, done" with no per-step record.

Adding "BLOCKING" language, validators, and stricter schemas didn't fix it. Some runs passed cleanly; others failed on the same bugs. The behavior was non-deterministic.

The reframe: the agent has its own preferences. It wants to ship the working result. It charitably reinterprets ambiguous constraints. It compresses protocols when the result is achievable without them. These aren't "bugs in the agent" — they're the agent's defaults. **Specifying behavior to an agent is closer to negotiating with a counterparty than to writing code that compiles.**

What worked, across runs, was **aligning our demands with what the agent already wants to do.** What didn't work was forcing demands the agent saw no reason for.

## Decision

We commit to designing skills as a negotiation: identify what we genuinely need, identify what the agent genuinely prefers, and find shapes where both converge.

### Principle 1: Coax, don't block

Schema validators, BLOCKING gates, and "MUST NOT" language work for a few runs and then drift. The agent's path of least resistance prevails over time. Better levers:

- **Concrete templates over rules.** Show a JSON example with the right field shapes; the agent mirrors it. Rules ("commands_run must be objects, not strings") get compressed away when the agent is in summary mode.
- **First-person voice over third-person rules.** *"I'm away from the keyboard and cannot answer any questions"* creates more weight than *"no user interaction in the main loop."* Models respond to social/personal context differently than to abstract specifications. Third-person rules read like specs to interpret; first-person personal context reads as a constraint imposed by a human who'll be affected by violation.
- **Anticipation over abstraction.** Enumerate the specific prompts the agent will encounter and what to pick at each one. *"When work-review asks 'Fix or ship?', pick Fix"* beats *"no AskUserQuestion calls"* because the specific case is pre-loaded as a handler. When the prompt actually appears, the agent recognizes it as something already pre-decided, not a new decision to make.
- **Permission framing over prohibition.** *"I trust you to make this call"* invites the agent to act; *"do not do X"* invites the agent to reason about whether X applies. Permission carries through better.
- **Reframe demands to align with agent preferences.** "Track what you did after the fact" loses to the agent's instinct to move on. "Declare you've started before doing any work" wins because declaration is itself a natural workflow primitive.
- **Sequence steps so the right action is the path of least resistance.** Make the artifact write the *first* visible action, not bookkeeping after the visible work is done.

These levers compound. The strongest orchestrator prompts use all of them: first-person personal context + concrete anticipation of each prompt + permission framing + workflow-primitive sequencing.

### Principle 2: Distinguish *what* from *how*

Users specify *what* to build (the feature), the *whats* of structure (file names, endpoint shapes, tools they care about), and explicit *hows* they care about (specific libraries, ports, conventions). They generally underspecify the rest.

Reviewers naturally fill in the *underspecified hows* — robustness, polish, correctness. **This is good scope growth.** Atomic writes, type hints, content-type headers, input validation, locking — all valuable additions when the user didn't specify.

What's NOT good: scope additions that **contradict an explicit user choice**. If the user said "with unittest," reviewers shouldn't propose pytest. If the user said "stdlib only," reviewers shouldn't add pytest as "dev-only." The user's explicit *hows* are immutable; their underspecified *hows* are reviewer territory.

This dichotomy reshapes consolidation logic: contradictions defer; non-contradicting additions integrate.

### Principle 3: Verbatim user prompt as authoritative artifact

Paraphrasing the user's prompt into a `summary` field loses the literal wording. Downstream stages see only the paraphrase and reinterpret it charitably ("stdlib only" → "stdlib only at runtime").

The verbatim prompt belongs in a designated, persistent slot — currently `context.constraints[0]` with the prefix `User feature description (verbatim, authoritative): `. Every dispatch that includes `context.constraints[]` shows the user's exact words to the agent. Reviewers and consolidation reference it as the constraint of last resort.

Cost: one entry per spec, prefix convention. Benefit: the user's exact words travel through the pipeline as a first-class artifact, not as a memory the agent can rationalize away.

### Principle 4: Distinguish load-bearing artifacts from ceremony

Strict schemas make sense for artifacts other skills consume programmatically. They're friction without payoff for forensic logs and self-discipline notes nothing reads.

| Artifact / field | Consumed by | Treatment |
|---|---|---|
| `spec.json` content | every downstream skill | Load-bearing — strict schema |
| `progress.json` existence + `mode`/`status` | work-review, `/work` resume and mode detection | Load-bearing — strict |
| `review.findings.json` | plan-consolidation, work fix-findings | Load-bearing — strict |
| `commands_run[]` shape | nothing — forensic only | Ceremony — accept any shape |
| `simplifications_made[]` | nothing — self-discipline | Ceremony — advisory, not required |

Tightening ceremony fights the agent for nothing. Loosening it lets the agent stay engaged on the load-bearing parts.

### Principle 5: Make load-bearing writes feel like preconditions, not bookkeeping

`progress.json` was being skipped because the agent treated it as bookkeeping after-the-fact. Reframing as "declare you've started before reading the spec, before dispatching any subagent, before opening any source file — this is what tells the rest of the pipeline what mode you're in" turns the same write into a workflow primitive. The agent's natural impulse to "set up the workspace before starting" now produces the artifact as a side effect.

The pattern: when a load-bearing artifact is being skipped, look for a "do this before you start" reframing instead of "do this after you finish."

### Principle 6: Skills as the unit of capability; commands are skills that orchestrate

Initially we had `commands/` (slash-command entry points) separate from `skills/` (capability units). Six of eight commands were thin wrappers — `/fly:debug` invoked the `debug` skill and added nothing. The orchestration commands (`/fly:plan`, `/fly:review`) were skills in disguise, just lacking the structural support skills have (references, allowed-tools, frontmatter for invocation).

Collapse: every capability is a skill. Skills with `user-invocable: true` (default) appear as slash commands. The `fly:` namespace prefix is also dropped — single concept (skills), single surface (`/<skill-name>`).

### Principle 7: Reviewer findings use a four-slot Failure template

Reviewers were free-form on the `failure` field. Synthesizers couldn't reliably extract the leading principle name (Shallow Wrapper / Race Condition / God Class / etc.) for routing. Findings became hard to action.

Template: `**Failure:** <Principle name>. <Intent>. <Observation>. <Reasoning>.`

Slots are mechanical to fill, hard to skip, and the leading principle name is the first token — easy for the consolidator to route. Principle names come from any well-known catalog (elegance anti-patterns, SOLID, DRY, performance/data-integrity canonical names).

### Principle 8: One source of truth for shared dispatch / convention text

The locator/analyzer dispatch templates lived in three places (one per caller). They drifted. The Elegance Dispatch Bar lived in a reference and was supposed to be pasted "verbatim" by the orchestrator into every dispatch — sometimes that read-and-paste was skipped under context pressure.

Move shared text to canonical references: `ixion/skills/ixion-conventions/references/research-workflow.md`, `ixion/skills/ixion-conventions/references/elegance.md`. Each caller's local reference shrinks to a thin "we use this for these inputs" overlay. Modifying the dispatch shape now means editing one file.

### Principle 9: Test the assumed-easy path; expect failures to surface latent bugs

The integration tests — especially the end-to-end test that then existed, which drove the whole chain through `/yolo` — revealed bugs that the older markdown-handoff workflow had been silently committing for months. The structured approach didn't *create* the bugs; it *exposed* them.

Implication: when the test fails on something that "always worked before," the bug was always there. The structured contract is the diagnostic; the looser old contract was the painkiller.

### Principle 10: Coaxing fixes are non-deterministic by nature

Same prompt produces slightly different output across runs. Coaxing reduces the failure rate but doesn't eliminate it. For a load-bearing channel that *must* succeed every time, accept that some structural backstop is necessary even if it adds friction. For ceremony, accept the non-determinism and move on.

### Principle 11: The orchestrator is the agent — directives must stay salient through child-skill loads

When `/plan` invokes `plan-creation`, it's not a sub-process. The same Claude that read `/plan`'s directives is the same Claude that reads plan-creation's SKILL.md. Both sets of instructions are in the same context window. The orchestrator and the child are not separate processes negotiating across a wire — they're one stream of reasoning loading new instructions on top of older ones.

The risk: child-skill instructions can locally conflict with orchestrator directives, and the agent reads the local instruction more recently. `/plan`'s instruction to carry the session id explicitly through every step gets drowned out by each child skill's own "resolve the session via `active.json`" fallback, because the local rule is fresher and more concrete — which is exactly how a concurrent session's pointer ends up hijacking a run.

This principle was originally derived from `/yolo`, where the collision was starker: its "don't call AskUserQuestion" was routinely overridden by whichever child skill most recently told the agent to ask something. `/yolo` is gone, but the mechanism it exposed is a property of skills-loading-skills, not of that one orchestrator.

What makes the orchestrator's directives survive reading conflicting child-skill instructions:

- **First-person personal context.** Creates emotional/social weight that persists. *"I'm not here to answer"* carries through; *"the orchestrator does not invoke AskUserQuestion"* fades.
- **Specific anticipation.** Pre-load handlers for the specific patterns the agent will encounter ("when work-review asks Fix or ship, pick Fix"). When the local prompt appears, the agent recognizes it as already-handled rather than a new decision.
- **Permission framing.** "I trust you to ..." invites the agent to act; "do not ..." invites the agent to reason about whether the prohibition applies in this specific case.

This reshapes how to write orchestrator skills. Don't give the agent a rule to interpret at runtime; give them a pre-decided answer to a specific situation they'll recognize. Trust that the agent will retain the answer through the child skill load, but build that retention by writing in the voice and specificity that retains.

### Principle 12: Pane markers and disk artifacts are complementary evidence

Tests should verify two distinct claims about a skill execution:

| Evidence | What it proves | Failure mode if absent |
|---|---|---|
| `Skill(<name>)` appears in TUI pane scrollback | Agent invoked the skill via the Skill tool | Agent compressed the skill into inline reasoning |
| Skill's expected artifact exists on disk | Skill ran AND completed its work | Skill was invoked but didn't act on its instructions |

Both signals are needed. A passing artifact assertion without a pane marker can't distinguish from agents successfully shortcutting a skill. A pane marker without an artifact means the agent invoked but didn't execute.

The implementation lives in `tests/integration/lib/tmux.sh::pane_has_skill_invocation`. Tests assert pane markers at each milestone alongside the artifact-on-disk checks. The pane scrollback is also auto-saved on test exit (via `pane_save_history`) so post-mortem inspection works even when the test exits abnormally.

A corollary: when designing skills that other skills will orchestrate, the skill should leave a clearly-named artifact on disk as evidence of completion. "Did this skill run?" should be answerable by `ls`, not by reading prose claims in the agent's pane output.

### Principle 13: Runtime claims are settled by running something, not by agreement

Reviewers have `Read, Grep, Glob, Skill` and no Bash. Everything they assert about *runtime* behavior — a race, an N+1, a panic path, a wrong output — is inference from reading. The synthesizer then merges, dedups, and trims those inferences, but nothing in the chain ever executes the code, so a confident and wrong defect report reaches the fix pass looking exactly like a correct one.

Consensus does not fix this. External work on adversarial review pipelines reports that the large majority of LLM-generated defect candidates do not survive scrutiny, and — more pointedly — records a case where ten reviewers unanimously backed a vulnerability that did not exist and only empirical testing eliminated it. Adding reviewers, or adding critics who argue about the finding, buys agreement rather than truth.

So the finding contract gains a fifth slot, **Evidence**, on findings that claim runtime misbehavior: the command that would demonstrate it, or `unproven: <reason>`. Reviewers propose; they still don't run. The synthesizer — which does have Bash — runs the command for P1s and *drops* findings that don't reproduce (`work-review` 2.3c). Structural findings are exempt: a God Class is visible in the source, and demanding a command for it would be ceremony.

This is coaxing, not a validator, and it reuses vocabulary `work/references/verification-gates.md` already established for the implementer ("a claim without a fresh command output is a guess"). That discipline had simply never been pointed at the reviewer's claims. Plan review is exempt by nature — there is no code to run yet.

The kill is asymmetric on purpose: reproducing keeps the P1, failing to reproduce deletes the finding rather than demoting it. A P1 list that accumulates plausible-but-unreproducible entries trains the reader to skim, which costs more than the missed finding would have.

### Amendment: `/yolo` retired

The autonomous orchestrator has been removed. It chained all six skills with every human checkpoint pre-answered, and its whole value was "you can walk away."

That value turned out to be squeezed from both sides. Changes safe enough to run unattended rarely need six skills of ceremony; changes big enough to earn the pipeline are ones you want to watch. The middle band was real but much narrower than the skill's framing suggested. Surveying how other spec-driven toolchains handle this sharpened the point: they treat the human checkpoints *between* phases as the primary value, and `/yolo` deleted exactly those.

Principle 13 is the sharpest illustration of what removing the human actually cost. Interactively, a confidently-wrong P1 costs five seconds — you read it and dismiss it. Under `/yolo` the same finding went straight to the fix pass and the agent wrote code to solve a problem that didn't exist. Removing the reader is what made unfalsifiable findings expensive.

What the removal did *not* change: `work` decides fix-findings mode from session state — a completed plan-mode `progress.json` plus a present `review.findings.json` — never from a caller. `/yolo` relied on that autodetection; it never provided it. This is the claim the whole removal rests on, and `tests/integration/cases/07-chain-smoke.test.sh` asserts it directly by invoking `/work` twice.

The orphaned `pipeline[]` checklist field left `session.schema.json` with it. Tests `03` and `04` were replaced by `07`, which drives the same chain skill-by-skill and answers the now-live dialogs through the test harness's autopilot. Principles 1 and 11 keep their substance — see the Related-work note on where their worked example now lives.

### Considered and deferred

Changes evaluated and deliberately not made. Recording them so the next person doesn't re-derive the analysis:

**A PostToolUse hook validating session artifacts against their schemas at write time.** Built, then removed before it ever shipped. It matched `Write|Edit` on basenames `spec.json` / `progress.json` / `review.findings.json` / `active.json` — but every skill writes those artifacts atomically as `<name>.tmp` (or `.tmp.$$`) followed by a Bash `mv`. The Write the hook could see had the wrong basename, and the rename that produced the right one wasn't a tool call the matcher observes. Only `plan-creation`'s initial `spec.json` write could ever trigger it. Matching the temp suffix would have been a two-line fix, but that only surfaced the prior question: Principle 1 says structural enforcement earns its keep where coaxing has *demonstrably* failed, and a gate that never once ran has produced no such evidence. It also imposed a `jq` + `bunx` dependency on every host, silently no-oping without them — the worst property a backstop can have. Revisit only if schema violations are observed surviving into a downstream skill; the fix then is to match the `.tmp` write, not to add a second gate.

**A second opinion-based kill stage** (an independent critic given only the claim, with a mandate to refute). Rejected as redundant once Principle 13 landed: the empirical gate is the stronger form of the same idea, and the evidence specifically says that more opinions were what *failed*. Adding both would grow a pipeline whose token cost is already its main criticism.

**Cross-model-family reviewers.** The argument — a model reviewing same-family output inherits the biases that produced it — is plausible, and Ixion's six reviewers all pin `model: sonnet`. But Claude Code can only vary tier, not family; only the OpenCode target could route reviewers to another provider, and the installer currently maps every short model name onto Anthropic IDs. Building that routing would mean new configuration machinery in service of a benefit attested by one unreplicated preprint and some vendor blogs. That is Speculative Code by our own catalog. Revisit if the finding replicates, or if a review round is ever observed failing in a way same-family bias would explain.

## Consequences

### Positive

- Skill prompts shrink: less BLOCKING language, fewer redundant rules, more concrete examples.
- Schemas tighten where it matters and loosen where it doesn't.
- Decision drift is mitigated by the verbatim user prompt being a first-class artifact every stage sees.
- Bookkeeping artifacts (especially `progress.json`) get written reliably because the framing matches the agent's natural workflow primitives.
- Reviewer findings are routable because the four-slot Failure template makes the leading principle mechanical to extract.
- The `ixion:` plugin surface is uniform: one concept (skills), one slash form (`/<skill>`).
- Shared text lives in single sources of truth; modifications don't drift across copies.

### Negative / accepted trade-offs

- Coaxing fixes are non-deterministic. Run-to-run variation is real. Some bugs slip through occasionally.
- Loosened schemas (commands_run accepts strings or objects) lose forensic precision. Acceptable because nothing programmatically consumes that precision.
- Verbatim user prompt as `constraints[0]` is a positional convention the agent has to honor. Not a structural guarantee. We accept this because adding a separate top-level field for it would create another field the agent might forget to populate (per the "agents are lazy about fields" experience).

### Implications for future skill design

When designing a new skill or modifying an existing one, ask:

1. **What's load-bearing here?** Does anything downstream consume this artifact's specific shape? If not, accept any shape.
2. **What's the agent's natural path?** Does our demand align with what the agent already wants to do? If not, find a reframe.
3. **What's a contradiction vs. an addition?** When integrating findings, is this changing what the user said or filling in what the user didn't say?
4. **What's the precondition framing?** Can we make the artifact write feel like "before starting" rather than "after finishing"?
5. **Is there a concrete template?** Can we show the right shape via example instead of describing it via rules?

When a coaxing fix doesn't work after two iterations, consider:

- Whether the demand earns its keep (drop if not).
- Whether the structural backstop is justified (add if yes).
- Whether the failure is exposing a latent issue worth fixing in the underlying skill design rather than the surface prompt.

## Related work

- `ixion/skills/ixion-conventions/references/elegance.md` — the Elegance Dispatch Bar and Anti-Pattern Catalog. Earliest example of the "concrete templates over rules" principle.
- `ixion/skills/ixion-conventions/references/research-workflow.md` — the canonical locate→consolidate→analyze workflow shared across plan-creation, research, and brainstorm. Earliest example of "one source of truth for shared dispatch text."
- `ixion/skills/work/SKILL.md` Phase 1 — the "declare you've started before doing any work" reframing of `progress.json` (Principle 5).
- `ixion/skills/plan-consolidation/SKILL.md` Phase 5 — the contradiction-vs-addition framing for finding integration (Principle 2).
- `ixion/skills/plan/SKILL.md` — the surviving orchestrator, and the current worked example for Principles 1 and 11. The techniques both principles describe (first-person voice, specific anticipation, permission framing) were originally found by iterating `ixion/skills/yolo/SKILL.md` through six failed test runs; that file was removed when `/yolo` was retired, but the prose patterns it established live on in the skills it used to drive. Recoverable from git history if the original wording is ever needed.
- `ixion/skills/ixion-conventions/references/finding-format.md` and `ixion/skills/work-review/SKILL.md` 2.3c — the Evidence slot and the empirical P1 gate (Principle 13).
- `tests/integration/lib/tmux.sh::pane_has_skill_invocation` — checks the TUI scrollback for `Skill(<name>)` markers. The empirical evidence layer of Principle 12.
- `tests/integration/lib/tmux.sh::pane_save_history` — auto-captures full pane scrollback on test exit, so failures (including SIGKILL and silent stops) are post-mortem-debuggable.
- `CLAUDE.md` — operational guide: running tests, monitoring patterns, debugging discipline, common failure modes. The applied side of these principles.
