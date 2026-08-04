---
module: System
date: 2026-08-04
problem_type: mistake
component: development_workflow
symptoms:
  - "A reviewer cites file.md:118 in a file that is 92 lines long"
  - "Three of six reviewers report line numbers beyond end-of-file"
  - "Finding reasoning is correct but every anchor in it is wrong"
root_cause: missing_workflow_step
resolution_type: workflow_improvement
severity: medium
tags: [code-review, dispatch, subagent, line-numbers, citations, review-findings]
---

# Reviewers handed a diff file report diff offsets as file line numbers

## Symptom

A `work-review` round dispatched six reviewers against a 754-line change. Because reviewer agents have `Read, Grep, Glob, Skill` and **no Bash**, they cannot run `git diff` themselves, so the orchestrator wrote the diff to a scratch file and pointed them at it.

Three of the six returned findings anchored to lines that do not exist:

| Cited | Actual file length |
|---|---|
| `git-branches.md:118`, `:186-197` | 92 lines |
| `sandbox.sh:994-997` | 68 lines |
| `session.schema.json:103` | 31 lines |

The *reasoning* in every one of those findings held up — each was corroborated against the real files and survived into `review.findings.json`. Only the anchors were fabricated. The numbers cluster suspiciously close to offsets within the 1000-line diff file.

## Investigation

### Attempted (Failed)

1. Treating it as ordinary hallucination and discounting the findings. This would have discarded real defects — the duplicated handoff sentence, the missing read-once directive, and the detached-HEAD gap were all genuine and all arrived with bad line numbers attached.
2. Assuming the reviewers had not read the sources. They had; the findings quote file content accurately. It is specifically the *numbering* that is wrong.

### Discovery

Checking every cited location against `wc -l` before writing `review.findings.json`:

```bash
node -e '
const fs=require("fs");
const f=JSON.parse(fs.readFileSync("<findings>","utf8"));
for (const x of f.findings){const [p,l]=x.location.split(":");const n=fs.readFileSync(p,"utf8").split("\n").length;
console.log(`${(+l<=n)?"OK  ":"BAD "} ${x.location}  (file has ${n} lines)`);}'
```

Every finding was then re-anchored by grepping the real file for the quoted content. All ten recorded locations verified in range.

## Root Cause

The dispatch handed reviewers a **diff file as the primary artifact**. A unified diff contains its own line numbering in `@@` hunk headers, interleaved with `+`/`-`/context lines, and the file the reviewer is actually reading (`review-diff.patch`) has its own line count of 1000. A reviewer citing "where I saw this" has three plausible numbering systems in front of it and no reason to prefer the one the consumer needs.

The orchestrator chose the diff-file shape for a real reason: inlining 1000 lines into six prompts is expensive, and `ixion-conventions` says to pass paths rather than content to Read-capable agents. That reasoning was sound. The omission was not adding "anchor findings to the source file, not to the diff" to the dispatch, and not verifying anchors at synthesis.

Worth separating from ordinary hallucination: this is a **dispatch-shape defect**. The reviewers behaved reasonably given what they were handed. Changing the prompt fixes it; scolding the model does not.

## Solution

### Fix the dispatch

Tell reviewers explicitly which numbering the consumer wants, and require them to confirm it:

```
CHANGE: Read the diff at <path> for what changed, then open the source files
themselves for anything you intend to cite. Every `location` you report must be
a line number in the SOURCE file, verified by reading that file — never an
offset into the diff. If you cannot confirm a line number in the source, cite
the file path alone.
```

### Verify anchors at synthesis, unconditionally

The synthesizer already owns schema enforcement; anchor-checking belongs in the same pass. Run the in-range check above before writing `review.findings.json`, and re-anchor by grepping the quoted content. Cheap, mechanical, and it caught 3 of 6 here.

## Prevention

- When a subagent cannot run the command that produces an artifact, and you stage the artifact for it instead, state which coordinate system the answer must use. The staged artifact has its own, and it is the wrong one.
- Verify every `location` in a findings file is within the cited file's length before persisting it. A finding whose anchor is wrong survives into the fix pass and sends an implementer to the wrong place.
- Do not discard a finding because its anchor is fabricated. Anchor and reasoning fail independently; re-anchor and keep the reasoning if it corroborates.
- Reviewer tool sets constrain dispatch shape. `Read, Grep, Glob, Skill` and no Bash means the orchestrator must stage anything requiring execution — and must then say how to refer back to it.

## Related Issues

- `ixion/skills/work-review/SKILL.md` 2.2 — validates the location *tier* (code-scope vs plan-scope) but not whether the line exists. This lesson extends that check.
- `docs/solutions/mistakes/verified-a-proxy-instead-of-the-outcome-System-20260804.md` — the other verification lesson from the same round.
- `docs/adrs/0001-skill-design-as-negotiation.md` — Principle 12 (pane markers and disk artifacts as complementary evidence); same instinct, applied to citations.

## Environment

- **Environment:** development
- **Repo:** Ixion plugin
- **Shipped in:** branch `branch-prod-dev-resolution`
- **Round shape:** 6 reviewers, 754-line diff, 14 raw findings → 10 recorded; 3 of 6 reviewers produced out-of-range anchors.
