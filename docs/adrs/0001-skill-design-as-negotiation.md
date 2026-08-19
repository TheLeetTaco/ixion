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

**The per-worktree build cost is real and is not mitigated.** Every worktree pays its own dependency install and build output — `node_modules`, `target/`, a virtualenv — and under unconditional worktrees every session pays it rather than only the large ones. A shared build cache was considered and rejected in `git-branches.md`'s create section: where one exists it is per-ecosystem (`CARGO_TARGET_DIR` and its like), so adopting it means Ixion learning a build system per language and inventing the configuration surface to name them — the same Speculative Configuration this ADR rejects a branch-names config file for below. And it partly defeats itself: a shared Cargo target directory serializes concurrent builds on `target/.cargo-lock`, so two sessions building at once take turns and hand back the parallelism the worktrees were bought for. A user who wants that trade exports the variable before invoking; the plugin does not make the choice for them. The `worktree-per-chunk` ban is unchanged — chunks within one session share a tree.

One residual is stated plainly rather than buried, because it is a limit of comparing derived paths as text. Under Git Bash a repo beneath an MSYS *mount alias* — `C:/Users/<you>/AppData/Local/Temp` is aliased to `/tmp` on the development host — resolves `repo_root` to `/c/Users/…` from the main checkout and `/tmp/…` from a worktree. Both name the same directory, so every read and write still lands correctly; only textual comparison misfires, and the visible symptom is a spurious `cd` line in a resume command that works when pasted. Repos on other drives are unaffected, and the integration suite touches `/tmp` only inside the Linux container where no aliasing exists. It is recorded here rather than fixed because the fix — canonicalizing through the alias table — would be machinery serving one shell on one platform for a cosmetic symptom.

**`ship` merges into the integration branch, and the merge runs against the main checkout.** Phase 4 is now fetch, re-resolve the roles, resolve the merge target, confirm, `--no-ff` merge, push. Every git command in it is `git -C "$REPO_ROOT"`, and that follows from the worktree decision rather than being a separate choice: git permits a branch in at most one worktree, `ship` runs inside the session's own with the feature branch checked out, and the main checkout is the one tree free to stand on the integration branch while the merge happens. The confirmation is tagged **Irreversible** under Principle 14 — the merge lands on the branch every other worktree builds from, and undoing it after the push means a revert everyone has already pulled — which is the tag that gets asked even where the agent could compute the answer.

Where integration resolves equal to production, `ship` creates `dev` off production, pushes it, and merges into that, naming the branch creation in the question because publishing a long-lived shared branch is the larger half of what the answer authorises. **This is decided from git state and does not reopen the per-project branch-config rejection below.** That rejection is about where the *names* come from, and it stands: nothing here reads a config file, invents a settings surface, or asks the user to declare anything. What is new is only what happens when detection finds no integration branch — previously nothing, now a creation the user confirms. The distinction is worth being precise about because the alternative was worse in both directions: refusing would have left **Ixion's own repository, which carried no `dev` or `develop` when this was written, unable to ship itself**, and merging into production instead would have departed from what was actually asked for. Detection is still by those two names only, so a team whose integration branch is `staging` gets a `dev` created alongside it — that is the same ceiling the rejection below already names, not a new one.

`work-review` dropped its PR-number and URL targets with `gh`. *Rejected: keeping PR-number targets by fetching `refs/pull/N/head` directly.* It works, needs no binary, and would have preserved a real capability — and it re-adds a GitHub-specific assumption in the same change whose point is removing one. A third shared error state, "Integration branch checked out in another worktree", joined `git-branches.md` as prose rather than a probe, for the reason Detached HEAD is prose: `git switch` already prints the holding worktree's path, and a probe would only restate it.

**The token work was scoped by a capability-neutral bar, and the bar is the decision.** Asked whether token usage could come down "without loosing a lot of capabilities," the answer taken was stricter than the question: *capability-neutral savings only* — reviewer counts stay at four and six, every agent keeps its model tier. That became a success criterion checkable by grep ("every reviewer count and every agent model tier is unchanged"), and zero `model:` lines were touched.

Under that bar the saving came from Principle 8's mechanism rather than from doing less. The reviewer dispatch preamble had been *pasting* the Elegance Dispatch Bar and Anti-Pattern Catalog into every reviewer prompt; it now names them by path, converging on what `finding-format.md` already did. That is **7,160 bytes — roughly 1,790 tokens — per reviewer prompt, about 14,320 tokens per pipeline at four reviewers and 21,480 at six**, traded for one extra Read round-trip per reviewer per wave, the same round-trip `finding-format.md` already costs. `work`'s per-chunk dispatch got the same treatment, and `work/SKILL.md`'s mode-specific content moved into `references/plan-mode.md` and `references/fix-findings-mode.md`, loaded on demand: 527 → 408 lines, 39,385 → 32,216 bytes, about 1,792 tokens off every invocation. Mode detection stayed in `SKILL.md`, because that is what decides which reference to load.

Heading-based extraction is the standing risk in all of this — a cited section is found by its title, so renaming a heading breaks the citation silently. `lint_dangling_sections` was added to the session harness for it and immediately caught a pre-existing dangling citation (`"Lead with the Failure"` against the real heading `"Finding Quality: Lead with the Failure"`), which is Principle 9 landing on our own reference files.

### Considered and deferred

Changes evaluated and deliberately not made. Recording them so the next person doesn't re-derive the analysis:

**A PostToolUse hook validating session artifacts against their schemas at write time.** Built, then removed before it ever shipped. It matched `Write|Edit` on basenames `spec.json` / `progress.json` / `review.findings.json` / `active.json` — but every skill writes those artifacts atomically as `<name>.tmp` (or `.tmp.$$`) followed by a Bash `mv`. The Write the hook could see had the wrong basename, and the rename that produced the right one wasn't a tool call the matcher observes. Only `plan-creation`'s initial `spec.json` write could ever trigger it. Matching the temp suffix would have been a two-line fix, but that only surfaced the prior question: Principle 1 says structural enforcement earns its keep where coaxing has *demonstrably* failed, and a gate that never once ran has produced no such evidence. It also imposed a `jq` + `bunx` dependency on every host, silently no-oping without them — the worst property a backstop can have. Revisit only if schema violations are observed surviving into a downstream skill; the fix then is to match the `.tmp` write, not to add a second gate.

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
- `ixion/skills/ixion-conventions/references/git-branches.md` — the production/integration resolution, the protected set, the two commands that make and unmake a session's worktree, and the three shared error states (detached HEAD, a recorded integration branch that no longer exists, an integration branch held by another worktree). The instance of Principle 8 where the duplicated copies had measurably drifted before extraction. Its "Create or reuse the session worktree" section carries the rejection of a shared build cache.
- `ixion/skills/ixion-conventions/references/session-handoff.md` — "Read a session field" and "Set session fields" (the python idiom replacing `jq`, extracted per Principle 8), "Resolve the session root" (the shared repository root against the per-checkout pointer), and "Derive the session worktree" (why the path is computed and not stored).
- `ixion/skills/ship/SKILL.md` Phase 4 and Phase 5 — the `--no-ff` merge into the integration branch issued against the main checkout, the Irreversible confirmation on it, the branch creation for a repo that has no integration branch yet, and the worktree retirement that follows the merge.
- `ixion/skills/ixion-conventions/references/reviewer-dispatch.md` and `ixion/skills/work/references/plan-mode.md` / `fix-findings-mode.md` — the paste-to-pointer conversion and the on-demand mode references, the capability-neutral half of the token work.
- `ixion/skills/work/SKILL.md` Phase 1 — the "declare you've started before doing any work" reframing of `progress.json` (Principle 5).
- `ixion/skills/plan-consolidation/SKILL.md` Phase 5 — the contradiction-vs-addition framing for finding integration (Principle 2).
- `ixion/skills/plan/SKILL.md` — the surviving orchestrator, and the current worked example for Principles 1 and 11. The techniques both principles describe (first-person voice, specific anticipation, permission framing) were originally found by iterating `ixion/skills/yolo/SKILL.md` through six failed test runs; that file was removed when `/yolo` was retired, but the prose patterns it established live on in the skills it used to drive. Recoverable from git history if the original wording is ever needed.
- `ixion/skills/ixion-conventions/references/finding-format.md` and `ixion/skills/work-review/SKILL.md` 2.3c — the Evidence slot and the empirical gate on runtime claims at every severity (Principle 13).
- `ixion/skills/ixion-conventions/references/question-format.md` — the shape of every question put to the user, the `**Why you:**` slot, and the four reasons that gate whether to ask at all (Principle 14).
- `tests/integration/lib/tmux.sh::pane_has_skill_invocation` — checks the TUI scrollback for `Skill(<name>)` markers. The empirical evidence layer of Principle 12.
- `tests/integration/lib/tmux.sh::pane_save_history` — auto-captures full pane scrollback on test exit, so failures (including SIGKILL and silent stops) are post-mortem-debuggable.
- `CLAUDE.md` — operational guide: running tests, monitoring patterns, debugging discipline, common failure modes. The applied side of these principles.
