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

Branch resolution later supplied the sharpest evidence for this principle, because the drift was observed rather than anticipated. The `refs/remotes/origin/HEAD` lookup was inlined at four sites — `work` once, `work-review` once, `ship` twice — and had already split into two incompatible micro-variants: a named `DEFAULT_BRANCH` variable in `work`, an inlined subshell in `work-review` and `ship`, each trailing its own near-duplicate paragraph about what to do when no remote is configured. Adding a second branch role to four already-drifted copies would have multiplied the drift, so the mechanism moved to `ixion/skills/ixion-conventions/references/git-branches.md`. That reference carries the shared error states too — dirty tree, detached HEAD, a recorded branch that no longer exists — so each failure mode is decided once instead of per caller.

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

So the finding contract gains a fifth slot, **Evidence**, on findings that claim runtime misbehavior: the command that would demonstrate it, or `unproven: <reason>`. Reviewers propose; they still don't run. The synthesizer — which does have Bash — runs that command at every severity and *drops* findings that don't reproduce (`work-review` 2.3c). Structural findings are exempt: a God Class is visible in the source, and demanding a command for it would be ceremony.

This is coaxing, not a validator, and it reuses vocabulary `work/references/verification-gates.md` already established for the implementer ("a claim without a fresh command output is a guess"). That discipline had simply never been pointed at the reviewer's claims. Plan review is exempt by nature — there is no code to run yet.

The kill is asymmetric on purpose: reproducing keeps the finding at the severity its reviewer gave it, failing to reproduce deletes it rather than demoting it. A findings list that accumulates plausible-but-unreproducible entries trains the reader to skim, which costs more than the missed finding would have.

### Principle 14: A question to the user needs a stated reason, and the reasons are the gate

Nine skills address the user directly, and four of them had independently authored a presentation format: `plan-consolidation`'s Context/Recommendation/Options block, `plan-creation`'s option table, `compound`'s numbered menu, `brainstorm`'s per-approach card. With no shared reference the copies drifted exactly as Principle 8 predicts. `research/references/research-document-template.md` marked option 1 `(Recommended)` in its prose list and then restated the same three options in a table directly beneath it with the marker dropped — one question, two renderings, disagreeing about the default. Three sites spelled the marker `(recommended)` against twelve that capitalized it. The delegation option lived under two names at once, `plan-consolidation`'s `"You pick what's best"` and `compound/references/decision-menu.md`'s free-form `Other`. `brainstorm/SKILL.md` restated the one-question-per-call rule in three separate places, none of them carrying the `BLOCKING:` marker `plan-consolidation` had put on the same rule.

Underneath the drift was a larger omission: across the roughly 25 questions in the plugin, not one told the user why the answer was theirs rather than the agent's. A question with no stated reason is indistinguishable from a question the agent could have answered itself, which is how a skill ends up outsourcing a decision it was hired to make.

So `ixion/skills/ixion-conventions/references/question-format.md` becomes the one home for the shape, cited by a single line from each of the nine skills, and every question carries a `**Why you:**` slot naming a reason from a four-entry catalog: Preference, Irreversible, Missing fact, Scope. **The catalog is not a labelling scheme, it is a gate on asking at all** — when no entry fits, the skill doesn't ask; it picks the determined best solution, applies it, and says what it picked and why. Making the slot mandatory is what makes the gate bite, because a reason you cannot write down is a reason you did not have. **Questions tagged Irreversible are exempt from the gate** and get asked even when the agent could compute the answer: being right about an unrecoverable action is not the same as being allowed to take it. That exemption is stated in the reference rather than hard-coded at `ship`'s call sites, because a site added later has nothing else holding an Irreversible tag up against the Elegance Bar's standing pressure to delete.

A fifth reason, 'Contradicts you', was drafted and dropped. It was the only candidate with no site among the questions inventoried, and the "Considered and deferred" bar below rejects an addition whose only support is a plausible name. The reference says a fifth reason is added when a concrete site needs one — which, now that there is one home, means editing one file.

This is coaxing, not a validator, per Principle 1: the reference ships a concrete template with a Strong and a Weak worked example rather than a rule to check, and carrying the one-question-per-call rule into it deliberately dropped the `BLOCKING:` prefix it used to wear. Principle 10 applies unchanged — the slot will sometimes go missing, and that is the accepted cost until several runs show it being dropped. Converting the call sites paid for itself the way Principle 9 says it should: `work`'s worktree prompt fires only when the change is already assessed as large, yet the recommendation sat on option 2, so the test autopilot's bare-Enter default had been quietly choosing the current branch for exactly the high-risk changes the prompt exists to protect; and two of `compound/references/decision-menu.md`'s seven options wrote into `ixion/skills/` relative to the user's repo rather than the installed plugin, so the files they produced were inert.

One blind spot, stated plainly because it is easy to overclaim: `tests/integration/lib/tmux.sh` pins the pane at `-x 200 -y 50`, `tmux_capture` runs `capture-pane -p` with no `-S`, so only the visible viewport is read, and `autopilot_respond` recognizes a dialog by its widget chrome and accepts the highlighted default without ever reading question or option prose. An optional `docker-run.sh 07` run therefore confirms that the reshaped dialogs don't deadlock and nothing more; a dialog whose Why-you line had scrolled off the top would be detected, answered, and passed. Checking that the line actually rendered means reading a saved `pane_save_history` capture and looking for it.

### Amendment: `/yolo` retired

The autonomous orchestrator has been removed. It chained all six skills with every human checkpoint pre-answered, and its whole value was "you can walk away."

That value turned out to be squeezed from both sides. Changes safe enough to run unattended rarely need six skills of ceremony; changes big enough to earn the pipeline are ones you want to watch. The middle band was real but much narrower than the skill's framing suggested. Surveying how other spec-driven toolchains handle this sharpened the point: they treat the human checkpoints *between* phases as the primary value, and `/yolo` deleted exactly those.

Principle 13 is the sharpest illustration of what removing the human actually cost. Interactively, a confidently-wrong P1 costs five seconds — you read it and dismiss it. Under `/yolo` the same finding went straight to the fix pass and the agent wrote code to solve a problem that didn't exist. Removing the reader is what made unfalsifiable findings expensive.

What the removal did *not* change: `work` decides fix-findings mode from session state — a completed plan-mode `progress.json` plus a present `review.findings.json` — never from a caller. `/yolo` relied on that autodetection; it never provided it. This is the claim the whole removal rests on, and `tests/integration/cases/07-chain-smoke.test.sh` asserts it directly by invoking `/work` twice.

The orphaned `pipeline[]` checklist field left `session.schema.json` with it. Tests `03` and `04` were replaced by `07`, which drives the same chain skill-by-skill and answers the now-live dialogs through the test harness's autopilot. Principles 1 and 11 keep their substance — see the Related-work note on where their worked example now lives.

### Amendment: python for `jq`, a worktree per session, a merge instead of a PR

Four changes were asked for in one breath — replace `jq` with python, drop `gh` and merge to `dev` instead of opening a PR, run every session in a worktree, and find token savings that don't cost capability. They are recorded together because they turned out to share a shape: each one removed something the plugin was reaching outside itself for and replaced it with something the repository, the interpreter, or git already knew.

**The python idiom is a Principle 8 extraction, not a search-and-replace.** `jq` was called at roughly a dozen sites across `work`, `work-review` and `ship`, and those sites had already drifted into two spellings of the same read and a temp-file convention nobody could point at — the same drift Principle 8 records for branch resolution, arrived at independently. So the conversion landed as two named blocks in `session-handoff.md`, **"Read a session field"** and **"Set session fields"**, cited everywhere and authored nowhere else. Three details in them are load-bearing and are decided once precisely because they were being improvised twelve times: the read prints the literal four characters `null` for an absent or JSON-null key, which is what `jq -r` printed and what every reader in the plugin still compares against; the write takes repeated `<field> '<JSON value>'` argv pairs and parses them all before opening anything, so a malformed value raises before the original file is at risk; and the temp is pinned beside its target as `<path>.tmp` rather than left to `tempfile`, because `os.replace` is atomic only within one filesystem and raises across one, and `TMPDIR` is a different filesystem from the repo on a great many hosts.

Both blocks probe `python3` then `python` and trust a candidate only after it has run `python -c ''`. That is not defensive padding for an impossible case: Windows ships a `python3` shim that resolves on PATH and then executes nothing, which is the exact host this plugin was developed on. Asking each candidate to run an empty program is the whole test, which is why no `command -v` precedes it — a binary that isn't installed fails the same check.

*Rejected: a multi-line `python3 - <<'PY'` heredoc at each call site.* It reads better in isolation and is the shape a python programmer reaches for. But `docs/solutions/mistakes/markdown-embedded-shell-fails-silently-System-20260729.md` records that markdown indentation silently alters heredoc semantics, and nothing in this pipeline executes these blocks at authoring time — the first time a broken block runs is in front of a user. A single-line `-c` program has no indentation surface to get wrong. This is Principle 1 applied to our own authoring: prefer the shape that cannot be typed incorrectly over the shape that reads well and fails silently.

*Rejected: migrating only the shipped skills.* The dependency lived in the harnesses, five integration cases, `run.sh`, the Dockerfile's toolchain check, `validate.yml`, and both operator documents. Stopping at `ixion/` would have left a contributor's install instructions unchanged and the repo carrying two JSON idioms, which is the drift this whole extraction exists to end. `tests/integration/lib/json.sh` became the suite's one home for the same reason the reference is the plugin's. The python-backed `jq` shim `session-resolution-harness.sh` used to install for hosts without `jq` was deleted as dead code — the reference's own blocks are now what the harness runs, so the harness tests the mechanism instead of a stand-in for it.

One scope note worth recording because it looked like scope creep and wasn't: three of `work`'s "atomically write session.json" instructions were prose rather than `jq` calls. Converting only the `jq` sites would have met the success criterion on a technicality while leaving three field writes as the agent's to improvise — exactly the state that produced two spellings of the read.

**The sessions tree hangs off the shared repository root; `active.json` deliberately does not.** With a worktree per session, the obvious move is to give each worktree its own session state, and it is wrong: a session claimed in one checkout would be invisible from another, and the same session would have as many records as it had trees. So the tree hangs off the absolutized `git rev-parse --git-common-dir`, the one git question whose answer every linked worktree shares.

The split is the interesting half. `active.json` stays **per-checkout**, anchored to `--show-toplevel`. A single shared pointer would put two parallel sessions on one convenience default, each bare `/ixion:work` retargeting the other's — the precise collision worktrees are being adopted to prevent. The tree is the record; the pointer is a per-terminal default, and a default only means anything when it is the terminal's own.

Two mechanical details earned their lines by being bugs first. `--git-common-dir` answers *relative* from a subdirectory, so the `cd … && pwd` around it is what stops two callers standing at different depths from holding two strings for one directory; and the absolutization hangs off an `&&` rather than sitting on its own line because `cd "/.." && pwd` succeeds and yields `/`, which would turn "not in a repository" into a plausible-looking root that every path built from it accepts. Adding the second root then exposed a real defect in the first: `--show-toplevel` answers in the host's native spelling, so on Windows it returned `C:/Users/…` to be compared against the common dir's `/c/Users/…`. Two spellings of one directory is the failure the shared `cd … && pwd` treatment exists to prevent, whichever way it arises.

**Every session gets a worktree, and its path is derived rather than stored.** The size assessment, the AskUserQuestion that used it, the in-place branch path, the dirty-tree probe and the session-directory copy were all deleted — five mechanisms whose only job was deciding whether to do the thing that is now always done. Principle 14 had already caught that prompt recommending the wrong option; making the answer unconditional deletes the prompt rather than fixing its default.

The path is a pure function of `session_id` — `<repo>-<slug>` beside the repository root — and is recorded nowhere. **This does not weaken the "persisted home" pattern the session directory establishes; it is the same rule applied honestly.** The session directory is persisted because nothing derives it: it holds artifacts whose existence and content are facts about the run. The worktree path derives from an id the session already carries, so storing it would put a second representation of one deterministic value in `session.json`, and every reader would then need a staleness branch and a fallback order whose entire job is reconciling the copy with the source it was copied from. Persist what you cannot recompute; recompute what you can.

The one thing a record would genuinely have settled — two invocations racing to start one session — is settled better without it. `git worktree add -b` is issued before anything is probed, and git permits a branch in at most one worktree, so the two collide on the branch name and exactly one wins; the loser reads back the branch and reuses what the winner made. A read-then-create against a stored record would leave a window between the two where both believe they won.

Teardown got a single owner, `ship`, because `ship` owns the merge that makes the tree disposable. Its `cd "$REPO_ROOT"` is load-bearing rather than tidy: under unconditional worktrees the agent is standing inside the directory it is removing, and git refuses to remove its own working directory. `git-branches.md`'s `Probe the working tree` and `Switch to the integration branch` sections were deleted with their only caller, and the dirty-tree error state went with them — the checkout a session starts from is never touched now, which is exactly why a session can start while it is dirty.

**The per-worktree build cost is real and is not mitigated.** Every worktree pays its own dependency install and build output — `node_modules`, `target/`, a virtualenv — and under unconditional worktrees every session pays it rather than only the large ones. A shared build cache was considered and rejected, and the reasoning lives here alone — `git-branches.md` loads on every `work`, `work-review` and `ship` invocation, and a rejected alternative changes nothing the agent does at runtime. Where one exists it is per-ecosystem (`CARGO_TARGET_DIR` and its like), so adopting it means Ixion learning a build system per language and inventing the configuration surface to name them — the same Speculative Configuration this ADR rejects a branch-names config file for below. And it partly defeats itself: a shared Cargo target directory serializes concurrent builds on `target/.cargo-lock`, so two sessions building at once take turns and hand back the parallelism the worktrees were bought for. A user who wants that trade exports the variable before invoking; the plugin does not make the choice for them. The `worktree-per-chunk` ban is unchanged — chunks within one session share a tree.

One residual is stated plainly rather than buried, because it is a limit of comparing derived paths as text. Under Git Bash a repo beneath an MSYS *mount alias* — `C:/Users/<you>/AppData/Local/Temp` is aliased to `/tmp` on the development host — resolves `repo_root` to `/c/Users/…` from the main checkout and `/tmp/…` from a worktree. Both name the same directory, so every read and write still lands correctly; only textual comparison misfires, and the visible symptom is a spurious `cd` line in a resume command that works when pasted. Repos on other drives are unaffected, and the integration suite touches `/tmp` only inside the Linux container where no aliasing exists. It is recorded here rather than fixed because the fix — canonicalizing through the alias table — would be machinery serving one shell on one platform for a cosmetic symptom.

**`ship` merges into the integration branch, and the merge runs against the main checkout.** Phase 4 is now fetch, re-resolve the roles, resolve the merge target, confirm, `--no-ff` merge, push. Every git command in it is `git -C "$REPO_ROOT"`, and that follows from the worktree decision rather than being a separate choice: git permits a branch in at most one worktree, `ship` runs inside the session's own with the feature branch checked out, and the main checkout is the one tree free to stand on the integration branch while the merge happens. The confirmation is tagged **Irreversible** under Principle 14 — the merge lands on the branch every other worktree builds from, and undoing it after the push means a revert everyone has already pulled — which is the tag that gets asked even where the agent could compute the answer.

Where integration resolves equal to production, `ship` creates `dev` off production, pushes it, and merges into that, naming the branch creation in the question because publishing a long-lived shared branch is the larger half of what the answer authorises. **This is decided from git state and does not reopen the per-project branch-config rejection below.** That rejection is about where the *names* come from, and it stands: nothing here reads a config file, invents a settings surface, or asks the user to declare anything. What is new is only what happens when detection finds no integration branch — previously nothing, now a creation the user confirms. The distinction is worth being precise about because the alternative was worse in both directions: refusing would have left **Ixion's own repository, which carried no `dev` or `develop` when this was written, unable to ship itself**, and merging into production instead would have departed from what was actually asked for. Detection is still by those two names only, so a team whose integration branch is `staging` gets a `dev` created alongside it — that is the same ceiling the rejection below already names, not a new one.

`work-review` dropped its PR-number and URL targets with `gh`. *Rejected: keeping PR-number targets by fetching `refs/pull/N/head` directly.* It works, needs no binary, and would have preserved a real capability — and it re-adds a GitHub-specific assumption in the same change whose point is removing one. A third shared error state, "Integration branch checked out in another worktree", joined `git-branches.md` as prose rather than a probe, for the reason Detached HEAD is prose: `git switch` already prints the holding worktree's path, and a probe would only restate it.

**The token work was scoped by a capability-neutral bar, and the bar is the decision.** Asked whether token usage could come down "without loosing a lot of capabilities," the answer taken was stricter than the question: *capability-neutral savings only* — reviewer counts stay at four and six, every agent keeps its model tier. That became a success criterion checkable by grep ("every reviewer count and every agent model tier is unchanged"), and zero `model:` lines were touched.

Under that bar the saving came from Principle 8's mechanism rather than from doing less. The reviewer dispatch preamble had been *pasting* the Elegance Dispatch Bar, the Anti-Pattern Catalog, and `ixion-conventions/SKILL.md`'s "Finding Quality: Lead with the Failure" into every reviewer prompt; it now names all three by path, converging on what `finding-format.md` already did. Measured on the final tree that is **9,704 bytes per reviewer prompt — 7,154 from `elegance.md`, 2,550 from the conventions section — roughly 2,400 tokens**, and a pipeline dispatches reviewers twice, so **about 19,000 tokens at the slim count of four and 29,000 at the default six**. An earlier figure of 7,160 bytes here counted the `elegance.md` half and forgot the excerpt beside it. The trade is one extra Read round-trip per reviewer per wave, the same round-trip `finding-format.md` already costs. The saving lands in the *orchestrator's* context specifically: the reviewer reads the same text either way, and what disappears is the four-to-six identical copies the orchestrator was emitting into its own transcript.

`work`'s per-chunk dispatch got the same treatment, and `work/SKILL.md`'s mode-specific content moved into `references/plan-mode.md` and `references/fix-findings-mode.md`. Mode detection stayed in `SKILL.md`, because that is what decides which reference to load — and Phase 1 then Reads whichever one matched, unconditionally, so **the saving is the net of the two files, not the deletion from `SKILL.md` alone**: 39,444 bytes before the split against 32,610 + 2,447 = 35,057 in plan mode and 32,610 + 4,729 = 37,339 in fix-findings mode.

**That comparison still has the wrong denominator, and against the right one the per-invocation number is a regression.** `work` Phase 0 Reads `session-handoff.md` in full and Phase 1 Reads `git-branches.md` in full, and this session grew both. Measured against `781698d`, what a plan-mode `/work` loads before it dispatches anything:

| | base | now |
|---|---|---|
| `work/SKILL.md` | 39,444 | 32,610 |
| `work/references/plan-mode.md` | — | 2,447 |
| `session-handoff.md` | 15,861 | 33,123 |
| `git-branches.md` | 7,579 | 8,940 |
| **total** | **62,884** | **77,120** |

That is **+14,236 bytes, +22.6%, roughly +3,600 tokens on every `work` invocation**, in the session whose fourth goal was reducing token usage. `elegance.md` leaving the orchestrator — 7,906 bytes, since the dispatch now names it by path instead of the orchestrator reading and pasting it — buys back most of one invocation's worth, but every dispatched chunk reads those bytes itself, so from two chunks up the wave spends more than the move saved.

Where the growth went is worth naming, because it is not padding. `session-handoff.md` more than doubled to carry three things `work` needs: the "Read a session field" / "Set session fields" idiom that replaced nine hand-authored `jq` call sites, the worktree derivation and removal that unconditional worktrees require, and the `REPO_ROOT`/`CHECKOUT_ROOT` split that makes a session claimed in one checkout the same session read in another. All three bought capability. The part that was overhead — paragraphs justifying alternatives considered and not built — was cut afterwards under the Rationale Discipline rule (`ixion-conventions/SKILL.md`: rationale only when it changes what the agent does at runtime), and came to 1,139 bytes, 3% of the file; what those paragraphs argued now lives in this document, above and in "Considered and deferred". The prose that survived the sweep is the kind that stops a later editor simplifying a block into a broken shape — why the `cd … && pwd` is not decoration, why the schema and status reads print on one line, why the two date-stripping `sed`s must move together — and by that test it earns its bytes.

**So both halves are true and the record has to carry both:** the paste-to-pointer change saves roughly five times per pipeline what the reference growth costs per `work` invocation, so the token goal is met at pipeline scale and missed per invocation. A reader told only the first half will conclude `work` got cheaper, and it did not. The lever left untouched, if the per-invocation figure ever needs to come down, is that `work` Reads all of `session-handoff.md` while citing none of "Claim a session id", "Does a token name a session?" or "Remove the session worktree" — but the sections are cited by title from seven skills, so splitting the file is a change to every citation and to `lint_dangling_sections`, not a trim.

Heading-based extraction is the standing risk in all of this — a cited section is found by its title, so renaming a heading breaks the citation silently. `lint_dangling_sections` was added to the session harness for it and immediately caught a pre-existing dangling citation (`"Lead with the Failure"` against the real heading `"Finding Quality: Lead with the Failure"`), which is Principle 9 landing on our own reference files.

### Amendment: back to a PR, and the borrowed checkout deleted with it

The amendment above recorded `ship` ending in a `--no-ff` merge onto the integration branch. The user reversed that decision: `ship` pushes the session branch, opens a PR against the right base, and stops. The reasoning above is left standing because it was sound about what it argued — but it weighed the merge as the *end* of the work, and a PR is where review happens for anyone who is not the person who typed `/ixion:ship`.

**What the reversal deletes is larger than what it restores, and that is the substance of it.** A merge needs a working tree with the target branch checked out, and git permits a branch in at most one worktree — so the merge had to borrow the main checkout, and everything downstream of that borrowing existed only to make the borrowing safe: a `mkdir` lock in the shared `.git` so two ships could not hold the one tree at once, a `WAS` capture under that lock with an EXIT trap restoring it on every exit, a `git -C "$REPO_ROOT"` guard leading every block, and five failure paths — a worktree already holding the integration branch, a local integration branch that would not fast-forward, a merge conflict, a rejected push, and a rejected publish of a freshly created `dev`. Opening a PR touches no working tree at all, so all of it goes, together with the `dev` auto-creation the merge forced into existence (a merge needs something to merge *into*) and the Irreversible confirmation guarding it. `git-branches.md`'s third error state, "Integration branch checked out in another worktree", went with its only caller — exactly as `Probe the working tree` and `Switch to the integration branch` went with theirs one amendment earlier.

Two things the merge got right are kept, because they are about *which branch* rather than about merging. The `git fetch origin` stays, in `ship` alone: resolution reads local refs by rule, and a `dev` another session published an hour ago is invisible without it, which would silently base the PR on production and show the whole release as its diff. And the three-case base resolution returns unchanged from before the merge — the recorded `integration_branch` where `git show-ref` still finds it, the freshly resolved `integration=` where it is stale or where an ad-hoc ship read no session at all, and `production=` for a session predating the field, whose `base_ref` was measured against production and would show a diff it was never measured from if pointed at integration. It is now an extractable block rather than prose, which is what lets the offline harness test the branching.

One thing is new rather than restored: `gh pr create` is given `--repo`, resolved from `origin`'s URL. A repo with a second remote and no `gh` default recorded makes `gh` choose a repository itself, and choosing one the branch was never pushed to answers `No commits between ...`, which names neither the cause nor the remote it picked — the failure this plugin was developed against. The alternative, `gh repo set-default`, was rejected for the same reason the branch-names config file is rejected below: it writes persistent configuration into the user's repository to spare one command an argument.

Two consequences had to be decided rather than derived:

**The session worktree is no longer retired by `ship`.** Teardown had a single owner because `ship` owned the merge that made the tree disposable. A PR makes nothing disposable — review may ask for changes, and those changes belong on that branch in the one tree that has it checked out — so removing the tree at ship time would strand the user. `ship` now prints `session-handoff.md`'s "Remove the session worktree" block filled in, under a line saying to run it once the PR merges. The block did not move and is still the single source of that command; only its caller changed, from a step that ran it to a step that hands it over.

**The session is still marked `status: completed`, even though the work has not landed.** The word is arguable and the argument is worth recording. It is kept because `completed` describes the *pipeline*, not the branch: Ixion has no step after "PR opened" — review happens on the PR, and a later push to the same branch updates it without re-entering anything — and the write is precisely what stops a resume line pasted afterwards from re-running verification against shipped work and asking `gh` for a second PR on a branch that already has one. Reopen this if a skill is ever added that acts on an open PR, because then `completed` would be hiding a step that exists.

`gh` returns as a hard dependency of `ship`, and nothing needed restoring to the documented prerequisites: it was never listed in `CLAUDE.md`, `README.md`, `tests/integration/Dockerfile` or `validate.yml` before the merge either, because no integration case invokes `ship`. The `jq` removal is untouched — `git grep -nwE 'jq' -- ixion/ tests/ .github/ CLAUDE.md README.md` still finds nothing.

`tests/branch-resolution-harness.sh`'s twelve merge cases were rebuilt around what a PR flow actually branches on: base resolution across all four values `recorded_integration=` can take, the fetch that makes another session's published `dev` visible, and the push, asserted to leave both the main checkout and the session worktree on the branches they were already on — the property the deleted lock and trap used to buy at length. **The `gh pr create` call itself is not exercised and is not faked**, because it needs a GitHub remote and a credential, and a stub would test the stub. What that leaves unproven is the flag assembly: that `--repo` and `--base` reach `gh` with the values the blocks printed. The blocks that compute them are covered; the one line that spends them is not.

### Amendment: `ship` arms auto-merge, and the probe that makes arming honest

`ship` ends by opening a PR and stopping. This adds one step after that: resolve whether auto-merge is available, and where it is, ask once and arm `gh pr merge --auto --squash --delete-branch`. No poller, no session held open, no step that waits on GitHub.

**The premise the request rested on is factually wrong, and correcting it is the whole design.** The feature description said `gh pr merge --auto` *errors* when the repository's `allow_auto_merge` setting is off, and reasoned from there that arming after the PR is already open leaves the user worse off than not trying. It does not error. cli/cli#8792 reports that with the setting off the command returns success and merges the PR on the spot, and the issue exists precisely because nothing is raised. cli/cli#13880 (reproduced on gh 2.96.0) reports the second half: with the setting on but nothing gating the PR, `--auto` also merges immediately rather than deferring. Both land an unreviewed diff the instant `/ixion:ship` runs — the outcome the return to a PR flow, one amendment above, exists to produce instead.

This is a correction of fact, not a contradiction of a user choice, and it resolves the user's own stated question — probe before arming, or arm and degrade on error — for a *stronger* reason than the description assumed. The danger is silent success, not loud failure.

*Rejected: arm unconditionally and degrade gracefully on error*, the description's second option. **Speculative Guard** — it defends the one path that does not fail. Per #8792 and #13880 the two dangerous cases both return zero, so the error handler catches nothing and the unreviewed merge lands anyway.

*Rejected: probe only `allow_auto_merge` and arm when it is true.* **Half-Truth Predicate** — the flag answers whether arming is *permitted*, not whether it will *defer*. With the setting on and no required checks, arming merges instantly, so a confirmation phrased from that probe alone tells the user something false at the exact moment the answer is irreversible.

**So the gate is `mergeStateStatus`, and the resolution is four-valued.** `gh pr view --json mergeStateStatus` is the one field that answers both halves of the question at once:

| `mergeStateStatus` | `automerge=` | Meaning |
|---|---|---|
| `BLOCKED`, `BEHIND` | `deferred` | Something gates the merge; arming waits for it |
| `CLEAN`, `UNSTABLE` | `immediate` | Nothing gates it; arming merges now |
| `UNKNOWN`, `DIRTY`, `DRAFT`, empty | `unknown` | Mergeability uncomputed, tree conflicted, PR draft, or probe returned nothing |
| — (`allow_auto_merge` is `false`) | `off` | The repository setting forbids it |

*Rejected: `statusCheckRollup` and `reviewDecision`.* Each answers one half of the gate, and a PR can be blocked by the other half while that half reads clean — a green check rollup on a PR awaiting review, or an approval on a PR whose checks are red. Reading either alone is the same **Half-Truth Predicate** as reading the repository flag alone, one level down.

**The ladder is five rungs, not the four the table suggests, and the extra rung is load-bearing.** `ALLOWED = false` resolves to `off`; a separate `ALLOWED != true` rung — an unread or failed repository probe — resolves to `unknown`; only then do the two `STATE` rungs run, with a final `else` sweeping the rest into `unknown`. Collapsing the first two into a single `[ "$ALLOWED" != true ]` is the obvious simplification and it is wrong: it would print the "Allow auto-merge is off, enable it under Settings" message on a probe that never answered. **No message asserts a repository setting the probe did not read.** That is what the rung buys; a later editor tidying it away deletes the invariant with it.

**`gates=` means one thing: the mergeability state this skill will speak about and act on.** It is empty on both rungs where the skill has nothing to say — the setting read as `false`, and the setting unread — and carries the raw state on every rung where it does, `immediate` included, because the drift guard below arms only against the state `gates=` names and `immediate` reaches that guard too. The unread-setting rung passed the state through in the first draft, which reported a PR mergeability code as the reason arming was refused when the reason was an unanswered permission probe. The emptiness there is the invariant, not an omission.

*Rejected: folding both probes into one `gh api graphql` call.* GraphQL has no URL selector, so it needs the PR number and therefore URL parsing the block does not otherwise do; two `-q` extractions from one response are still two `gh` invocations, so the parse step buys nothing back. The saving is one round-trip on a single human-paced interactive step, against roughly 200 bytes on a budget with 30 left. *Rejected with it: backgrounding the two probes with `&` and `wait`*, which keeps both failure paths and both empty-value cases and adds job control to a block whose entire output is two lines.

**Arming re-reads the state the answer was given about.** `AskUserQuestion` waits on a person, and a PR reading `CLEAN` when the question goes out and `BLOCKED` when it returns turns "merges now" into an unattended merge later — the exact substitution the confirmation exists to prevent. So the arm block reads `mergeStateStatus` once more and arms only where it still equals the `gates=` the outcome line quoted; otherwise it prints `drifted=<state>`, arms nothing, and the user is asked again against the state that is now true. One read spent at the moment it is used is not the poll excluded by name: nothing sleeps, and nothing re-reads unless a person has just answered.

**`unknown` is what makes the design honest rather than merely safe, and it settled a reviewer disagreement.** `reviewer-code-quality` proposed failing closed to `off` — it never arms, so the outcome is identical. `reviewer-data-integrity` objected that `off` *asserts* a repository setting that was never read. `unknown` fails closed exactly as `off` does while claiming only what the probe established, and it absorbs three further states that are neither `off` nor a clean deferral: a conflicted tree, a draft PR, and a mergeability GitHub has not finished computing.

That last one is the common case, not an edge: GitHub computes mergeability asynchronously, so a PR opened seconds earlier reads `UNKNOWN` more often than not. It is also the same window that produces the regression in community#190610 — since March 2026, enabling auto-merge answers HTTP 422 `Failed enabling auto-merge for pull request` when requirements are not yet met (GitHub staff acknowledged it 2026-03-26 with "a fix is in the queue"; re-checked 2026-08-20, still no confirmed fix). Refusing to arm on `unknown` therefore sidesteps most of that 422 window as a side effect of being honest about what was read. The `unknown` message prints the arming command for the user to run once the state settles; it does not sleep, re-probe, or loop, because polling was excluded by name.

Two upstream limits are named in the skill by issue number and reasoned about here. `gh` does not expose *which* requirement blocks a `BLOCKED` PR (cli/cli#10775), so `gates=` is necessarily coarse — it names the state, not the check or the reviewer. And `--delete-branch` combined with `--auto` is reported not to fire after a deferred merge (cli/cli#9073): the PR merges, the branch remains. `--delete-branch` is still passed, because it works on the immediate path and is what was asked for, but **nothing is built on top of it** — no wording promises the branch disappears, and no teardown decision assumes it.

**No new session status, which answers this document's own reopen trigger head-on.** The amendment above wrote: *"Reopen this if a skill is ever added that acts on an open PR, because then `completed` would be hiding a step that exists."* Arming auto-merge is exactly such a step, so the trigger is reached. The answer is that `completed` stands, and gets *stronger* rather than looser: Ixion has handed the remainder to GitHub, not to a future Ixion step, and there is nothing left for a resume to resume. *Rejected: a fourth status between "PR open" and `completed`.* **Speculative State** — no reader would branch on it. `Validate the resolved session` tests only for `completed`, so paying for the value means a closed-enum schema change, an edit to that block and to the Error States table seven skills cite, and a new harness case, all to record a fact nothing consumes. The status enum in `session.schema.json` still holds exactly three values and `session.json` gains no field.

**Teardown keeps its single owner: the user.** *Rejected: having `ship` remove the session worktree itself on the `immediate` path*, where it is the one case in which `ship` can actually observe the merge. **Divergent Twin** — two teardown behaviors selected by a condition the user cannot predict before answering the question, to save one pasted command. `ship` prints `session-handoff.md`'s "Remove the session worktree" block in every case, unchanged; only the sentence above it changed, to stop claiming the branch is gone.

Two things were deliberately *not* added. The `off` case prints the Settings → General → Pull Requests → Allow auto-merge path and no command that flips it — the same line the `gh repo set-default` rejection draws one amendment above: this plugin does not write persistent configuration into the user's repository. And Ixion does not try to fix the solo-repo deadlock, where branch protection requires an approval and GitHub forbids approving your own PR, so arming waits forever. That is not ours to solve; the `deferred` outcome line names the state and says `gh` cannot say what would clear it, *including* an approval you cannot give your own PR. Naming that approval as the cause outright would be false for `BEHIND`, where the branch merely needs updating, and unknowable even for `BLOCKED` per cli/cli#10775 — while the softer wording still lets the solo-repo user recognize the deadlock rather than being told checks are pending.

`gh api -q` is `gh`'s own bundled flag and not a shell-out, verified during review, so the probe does not reintroduce the `jq` dependency dropped in 4.0 — `git grep -nwE 'jq' -- ixion/ tests/ .github/ CLAUDE.md README.md` still finds nothing. The change adds `gh` subcommands but no binary, so `gh`'s deliberate absence from `README.md`, `CLAUDE.md`, `tests/integration/Dockerfile` and `validate.yml` is unchanged for the reason it was already unchanged: no integration case invokes `ship`.

**Phase 4 grew 3,970 bytes against a 4,000-byte budget, and the budget is why this amendment is long.** Rationale Discipline (`ixion-conventions/SKILL.md`) says justification that does not change what the agent does at runtime belongs here, and `ship/SKILL.md` is Read in full on every invocation. So the skill names five issues by number and spends one clause each on what they mean for the line beside them; the narrative of what those issues are, when they were checked, and which alternatives they killed lives here alone. A reader who wants to know whether #8792 was fixed and the probe can be deleted has one place to look.

`tests/branch-resolution-harness.sh` covers the ladder at all four `automerge=` values, both spellings of `unknown` — setting unread against state unread, which the first draft could not tell apart — the arm block's two branches, armed and drifted, and a case asserting that a declined or failed arming still leaves `status: completed`, the terminal-write invariant that stops the new step from making the session resumable again. It reaches all of that through a `gh` shadowed onto `PATH`, answering the two probes from the environment and logging every invocation, which is what let the blocks shed the two placeholders they had been carrying for the harness's benefit. **`gh pr create` stays uncovered and unfaked**, for the reason the amendment above gave: its whole effect is the PR it opens, so a stub would test the stub. The auto-merge blocks are the opposite case — their effect *is* their own control flow, which rung is reached and whether `--auto` is called at all — and that is exactly what a stub can prove. One residual is worth stating because it is easy to mistake for new: that harness is not in `validate.yml`'s shellcheck list and never has been — the gap predates this change and is not created by it.

### Considered and deferred

Changes evaluated and deliberately not made. Recording them so the next person doesn't re-derive the analysis:

**A PostToolUse hook validating session artifacts against their schemas at write time.** Built, then removed before it ever shipped. It matched `Write|Edit` on basenames `spec.json` / `progress.json` / `review.findings.json` / `active.json` — but every skill writes those artifacts atomically as `<name>.tmp` (or `.tmp.$$`) followed by a Bash `mv`. The Write the hook could see had the wrong basename, and the rename that produced the right one wasn't a tool call the matcher observes. Only `plan-creation`'s initial `spec.json` write could ever trigger it. Matching the temp suffix would have been a two-line fix, but that only surfaced the prior question: Principle 1 says structural enforcement earns its keep where coaxing has *demonstrably* failed, and a gate that never once ran has produced no such evidence. It also imposed a `jq` + `bunx` dependency on every host, silently no-oping without them — the worst property a backstop can have. Revisit only if schema violations are observed surviving into a downstream skill; the fix then is to match the `.tmp` write, not to add a second gate.

**A lock file serializing writes to `session.json`.** The "Set session fields" block reloads the whole document, applies the fields it names and writes it back, so two writers overlapping across that window both succeed and the later one's copy is what remains. The `.tmp.<pid>` suffix stops them interleaving into one half-written file; it does not make the pair a transaction. Rejected because the record already assumes **one active skill per session at a time** — which is what `active_skill` names, and what `debug` reads to warn before working alongside a live session — and a lock would be a new mechanism guarding the single way to violate it: resuming a session in a second terminal while the first still runs. Only the session's own metadata is at risk there; the work itself is committed on the session branch, which git serializes. The stated assumption is the cheaper half of the same answer. Reopen if a second concurrent writer appears that is not a user resuming by hand.

**A second opinion-based kill stage** (an independent critic given only the claim, with a mandate to refute). Rejected as redundant once Principle 13 landed: the empirical gate is the stronger form of the same idea, and the evidence specifically says that more opinions were what *failed*. Adding both would grow a pipeline whose token cost is already its main criticism.

**A per-project config file naming the production and integration branches.** The two-branch model needs to know which branch is production and which is integration, and letting the user declare both is the obvious shape. Rejected as Speculative Configuration: no configuration mechanism exists anywhere in Ixion. The only runtime-consumed external config in the whole plugin is the Context7 API key, and `install_opencode.py` scopes `managed_paths` precisely so that neither installer ever writes into a user's project. A config file means inventing a settings surface, a schema, a discovery order, and an answer to who creates it — all to carry two strings git already knows. Detection from git state matches the grain of every other branch decision in the codebase. The cost is a real ceiling, not a hypothetical one: detection recognizes `dev` and `develop` and nothing else, so a team whose integration branch is `staging` or `next` is not detected and gets the single-branch behavior. If such a repo turns up, this rejection is what to reopen — not something to work around in a skill.

**Narrowing the reviewer set by touched domain** (dispatching `reviewer-performance` and `reviewer-data-integrity` only when the diff touches code they would have something to say about). It is the largest available token saving and it was declined on the scope answer that framed the token work: capability-neutral only. The saving is real precisely because the reviewer sometimes finds nothing — which is also the case where it is doing its job, since "this change has no data-integrity surface" is a conclusion a reviewer reaches by looking, not a fact a dispatcher can read off a file list. A diff that adds no migration can still break a transaction boundary. Reopen only alongside a way to measure what the narrowed dispatch stopped catching.

**Downgrading `analyzer-docs` and `analyzer-patterns` to haiku.** Declined under the same bar, and it is the weaker of the two proposals: analyzers exist to read whole files and synthesize, which is the work the tier buys. The locators are already on haiku because finding a path is a different job from understanding one, and that split is the line this would have crossed. Recorded so it is not re-proposed as a fresh idea.

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
- `ixion/skills/ixion-conventions/references/git-branches.md` — the production/integration resolution, the protected set, the two commands that make and unmake a session's worktree, and the two shared error states (detached HEAD, a recorded integration branch that no longer exists). The instance of Principle 8 where the duplicated copies had measurably drifted before extraction. Its "Create or reuse the session worktree" section carries the rejection of a shared build cache.
- `ixion/skills/ixion-conventions/references/session-handoff.md` — "Read a session field" and "Set session fields" (the python idiom replacing `jq`, extracted per Principle 8), "Resolve the session root" (the shared repository root against the per-checkout pointer), and "Derive the session worktree" (why the path is computed and not stored). "Set session fields" is the one home for every session-artifact write, `progress.json`'s included; the rejection of a lock file over those writes is in "Considered and deferred" above, and the reference itself states only the one-active-skill assumption a caller has to keep.
- `ixion/skills/ship/SKILL.md` Phase 4 — the push, the three-case PR base, the `--repo` resolved from `origin`, and the worktree-retirement command printed for the user to run once the PR merges.
- `ixion/skills/ship/SKILL.md` Phase 4, "Resolve auto-merge availability" and "Arm auto-merge" — the five-rung ladder producing `automerge=` and `gates=`, and the single Irreversible confirmation whose outcome line is substituted per value. The five upstream issues it names by number (cli/cli#8792, #13880, #9073, #10775, community#190610) are narrated in the amendment above, not in the skill.
- `ixion/skills/ixion-conventions/references/reviewer-dispatch.md` and `ixion/skills/work/references/plan-mode.md` / `fix-findings-mode.md` — the paste-to-pointer conversion and the on-demand mode references, the capability-neutral half of the token work.
- `ixion/skills/work/SKILL.md` Phase 1 — the "declare you've started before doing any work" reframing of `progress.json` (Principle 5).
- `ixion/skills/plan-consolidation/SKILL.md` Phase 5 — the contradiction-vs-addition framing for finding integration (Principle 2).
- `ixion/skills/plan/SKILL.md` — the surviving orchestrator, and the current worked example for Principles 1 and 11. The techniques both principles describe (first-person voice, specific anticipation, permission framing) were originally found by iterating `ixion/skills/yolo/SKILL.md` through six failed test runs; that file was removed when `/yolo` was retired, but the prose patterns it established live on in the skills it used to drive. Recoverable from git history if the original wording is ever needed.
- `ixion/skills/ixion-conventions/references/finding-format.md` and `ixion/skills/work-review/SKILL.md` 2.3c — the Evidence slot and the empirical gate on runtime claims at every severity (Principle 13).
- `ixion/skills/ixion-conventions/references/question-format.md` — the shape of every question put to the user, the `**Why you:**` slot, and the four reasons that gate whether to ask at all (Principle 14).
- `tests/integration/lib/tmux.sh::pane_has_skill_invocation` — checks the TUI scrollback for `Skill(<name>)` markers. The empirical evidence layer of Principle 12.
- `tests/integration/lib/tmux.sh::pane_save_history` — auto-captures full pane scrollback on test exit, so failures (including SIGKILL and silent stops) are post-mortem-debuggable.
- `CLAUDE.md` — operational guide: running tests, monitoring patterns, debugging discipline, common failure modes. The applied side of these principles.
