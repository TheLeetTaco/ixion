---
module: System
date: 2026-08-20
problem_type: pattern
component: development_workflow
symptoms:
  - "A newly added assertion passes on the first run and is assumed to work"
  - "A guard covers a case the corpus no longer contains, so it can never fail"
  - "A green suite hides a check that was never executed"
root_cause: missing_validation
resolution_type: workflow_improvement
severity: high
tags: [testing, mutation-testing, verification, false-green, evidence]
---

# A check that has never failed has not been tested

## The pattern

After adding or changing any assertion, **break the thing it guards and confirm it complains**. An assertion that has only ever been observed passing is indistinguishable from one that cannot fail.

## Why this keeps earning its keep

Three instances in a single session, each of which survived a fully green suite:

**A lint arm that scanned nothing.** `lint_source_checkout_paths` gained `--include='*.json'` so a citation inside a schema description would be caught. Deleting that flag outright left the suite at `93 passed, 0 failed` — the two fixtures were both `.md`, and the real corpus had just been cleaned of every `.json` citation, so nothing could exercise the new arm. It passed because there was nothing left for it to find.

**A scanner that never ran.** The embedded-shell block scanner lives in a ```` ```bash ```` fence wrapping a `node -e '…'` program whose code contains backtick literals. A regex extraction produced a fragment that node rejected; with stderr suppressed this read as "0 hits — clean". The scanner had not run at all.

**A filter that matched everything.** A `grep -qE "$pattern"` where `$pattern` came back empty from a failed `sed` accepted every input, so the "does it reject bad ids" half of a check passed vacuously.

## The discipline

For each new assertion, write down the mutation that should kill it, then run it:

```bash
cp target target.bak
# make the specific change the assertion exists to catch
<run the suite>          # MUST report a failure naming that assertion
cp target.bak target && rm target.bak
```

Mutate in **both** directions where the check couples two sources. A schema-versus-reference agreement check was mutated twice — loosening the schema produced `accepts -1; accepts -10; accepts -0`, widening the reference produced `rejects '-1'`. One direction alone would have left half of it unproven.

## Corollary: distrust your own tooling before the code

Twice in the same session a "finding" turned out to be an artifact of the investigation rather than a defect: a `grep -v` filter that removed the added lines of a diff and made an intact file look gutted, and a `sed` mutation that silently did not apply, so the "mutant survived" result was meaningless.

Check the artifact directly — `cat -A` for whitespace, `od -c` for line endings, stderr unsuppressed, the file itself rather than a derived view — before concluding anything about the code.

### The named cause, found later: `command -v python3` on Windows

The "mutation silently did not apply" case above recurred in session `ship-auto-merge-2026-08-20`, and this time the mechanism has a name worth writing down.

A mutation test was run to prove two new harness assertions were not vacuous. It used `"$(command -v python3 || command -v python)"` to apply the mutation. On the Windows development host `python3` is the Microsoft Store shim: it **resolves on `PATH`** — so `command -v` finds it — and then executes nothing, printing an install advert to stdout. The mutation never applied, the harness reported `87 passed, 0 failed`, and that green result was one step away from being reported as evidence the assertions bite. Re-run with the correct probe, disabling the guard failed exactly the two assertions it should.

The repo already documents this hazard and prescribes the fix. `ixion/skills/ixion-conventions/references/session-handoff.md` probes by *execution*, not by resolution, precisely because resolution is what the shim satisfies:

```bash
for PY in python3 python; do "$PY" -c '' 2>/dev/null && break; done
```

Two things generalise beyond this one binary:

- **The interpreter probe is not only for the shipped blocks.** Every ad-hoc command typed during verification needs it too. Here the correct idiom was already in context — pasted into six earlier calls in the same session — and the wrong one still got used the moment the command was improvised rather than cited.
- **A mutation test that reports "all pass" is itself the signal to check the mutation applied.** That is the expected-failure case; a green suite there is the one outcome that means the run told you nothing. Make the mutation step *assert* it changed something (`assert s2 != s`) rather than trusting the edit landed.


