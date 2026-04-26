# ADR-001: Skill Design as Negotiation

## Status

Draft — captured during iterative test-driven refinement of `/yolo` and the planning pipeline. Refine with experience.

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
| `progress.json` existence + `mode`/`status` | work-review, /yolo, `/work` resume | Load-bearing — strict |
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

Move shared text to canonical references: `flywheel/skills/flywheel-conventions/references/research-workflow.md`, `flywheel/skills/flywheel-conventions/references/elegance.md`. Each caller's local reference shrinks to a thin "we use this for these inputs" overlay. Modifying the dispatch shape now means editing one file.

### Principle 9: Test the assumed-easy path; expect failures to surface latent bugs

The integration tests (especially the e2e `/yolo` test) revealed bugs that the older markdown-handoff workflow had been silently committing for months. The structured approach didn't *create* the bugs; it *exposed* them.

Implication: when the test fails on something that "always worked before," the bug was always there. The structured contract is the diagnostic; the looser old contract was the painkiller.

### Principle 10: Coaxing fixes are non-deterministic by nature

Same prompt produces slightly different output across runs. Coaxing reduces the failure rate but doesn't eliminate it. For a load-bearing channel that *must* succeed every time, accept that some structural backstop is necessary even if it adds friction. For ceremony, accept the non-determinism and move on.

### Principle 11: The orchestrator is the agent — directives must stay salient through child-skill loads

When `/yolo` invokes `plan-creation`, it's not a sub-process. The same Claude that read /yolo's directives is the same Claude that reads plan-creation's SKILL.md. Both sets of instructions are in the same context window. The orchestrator and the child are not separate processes negotiating across a wire — they're one stream of reasoning loading new instructions on top of older ones.

The risk: child-skill instructions can locally conflict with orchestrator directives, and the agent reads the local instruction more recently. /yolo's "don't call AskUserQuestion" gets drowned out by `plan-consolidation`'s "Present each P3 via AskUserQuestion" because the latter is fresher and more specific.

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

## Consequences

### Positive

- Skill prompts shrink: less BLOCKING language, fewer redundant rules, more concrete examples.
- Schemas tighten where it matters and loosen where it doesn't.
- Decision drift is mitigated by the verbatim user prompt being a first-class artifact every stage sees.
- Bookkeeping artifacts (especially `progress.json`) get written reliably because the framing matches the agent's natural workflow primitives.
- Reviewer findings are routable because the four-slot Failure template makes the leading principle mechanical to extract.
- The `flywheel:` plugin surface is uniform: one concept (skills), one slash form (`/<skill>`).
- Shared text lives in single sources of truth; modifications don't drift across copies.

### Negative / accepted trade-offs

- Coaxing fixes are non-deterministic. Run-to-run variation is real. Some bugs slip through occasionally.
- Loosened schemas (commands_run accepts strings or objects) lose forensic precision. Acceptable because nothing programmatically consumes that precision.
- Verbatim user prompt as `constraints[0]` is a positional convention the agent has to honor. Not a structural guarantee. We accept this because adding a separate top-level field for it would create another field the agent might forget to populate (per the "agents are lazy about fields" experience).
- The `/yolo` autonomous orchestrator is by nature higher-risk than the interactive `/plan → /work → /review → /work` flow. Its design assumes the user trusts the agent to make the calls; users who want oversight should use the manual flow.

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

- `flywheel/skills/flywheel-conventions/references/elegance.md` — the Elegance Dispatch Bar and Anti-Pattern Catalog. Earliest example of the "concrete templates over rules" principle.
- `flywheel/skills/flywheel-conventions/references/research-workflow.md` — the canonical locate→consolidate→analyze workflow shared across plan-creation, research, and brainstorm. Earliest example of "one source of truth for shared dispatch text."
- `flywheel/skills/work/SKILL.md` Phase 1 — the "declare you've started before doing any work" reframing of `progress.json` (Principle 5).
- `flywheel/skills/plan-consolidation/SKILL.md` Phase 5 — the contradiction-vs-addition framing for finding integration (Principle 2).
- `flywheel/skills/yolo/SKILL.md` — the autonomous orchestrator. Demonstrates Principles 1 and 11: first-person voice, specific anticipation of each AskUserQuestion site, permission-framed delegation. The current prose was iterated through six failed test runs to find what stayed salient through child-skill loads.
- `tests/integration/lib/tmux.sh::pane_has_skill_invocation` — checks the TUI scrollback for `Skill(<name>)` markers. The empirical evidence layer of Principle 12.
- `tests/integration/lib/tmux.sh::pane_save_history` — auto-captures full pane scrollback on test exit, so failures (including SIGKILL and silent stops) are post-mortem-debuggable.
- `CLAUDE.md` — operational guide: running tests, monitoring patterns, debugging discipline, common failure modes. The applied side of these principles.
