# Finding synthesis (shared by plan-review and work-review)

The steps both synthesizers run between reading reviewer prose and structuring the JSON. Modifying synthesis behavior means editing this file — the callers hold only their scope-specific tails (where each step sits in their own numbering, and the steps only one of them runs).

Both callers cite every section below, so read this file once per invocation and hold it, rather than re-reading at each citation.

## Read each reviewer's prose output

For each reviewer response:

- Extract per-finding: Title, Severity, Location, Failure (paragraph), Fix.
- If a reviewer returned "No findings" or equivalent, record zero findings from this reviewer.
- If a reviewer's output is incomplete (missing one of the required elements on any finding), construct a synthetic P1 against that reviewer's agent file noting the gap, AND retain the partial finding for the user's visibility.

Synthetic P1 shape (constructed by the synthesizer, in schema):

```json
{
  "title": "Reviewer output incomplete: <reviewer-name>",
  "severity": "P1",
  "location": "ixion/agents/<reviewer-name>.md",
  "failure": "<reviewer-name> returned a finding missing one of the required elements (Title/Severity/Location/Failure/Fix). The structuring step couldn't fully ingest it; the synthesizer's review may be incomplete for this reviewer's domain. Without complete fields, downstream consumers can't reliably act on the finding.",
  "fix": "Investigate the reviewer's prompt or retry that reviewer. Check whether the agent file or dispatch text needs tightening."
}
```

## Validate the location tier

The dispatch told every reviewer which tier of location to emit. Code review: `<repo-relative-path>` or `<repo-relative-path>:<line>`. Plan review: `<phase_id>` or `<phase_id>/<task_id>`. A location from the other tier is a disambiguation failure — a code review has no `phase-2/t1` to open, a plan review has no `src/auth.rs:42` anywhere in the spec. Construct a synthetic P1 against the reviewer, and retain the original (mistargeted) finding alongside so the user can see what was flagged.

```json
{
  "title": "Wrong location tier: <reviewer-name> emitted '<bad-location>'",
  "severity": "P1",
  "location": "ixion/agents/<reviewer-name>.md",
  "failure": "<reviewer-name> emitted location '<bad-location>', from the other tier than the one its dispatch specified. A cross-tier location names nothing this review can open, so whatever the finding flagged cannot be acted on.",
  "fix": "Update the reviewer prompt or agent file so the location format always matches the invoker's tier."
}
```

The template names no tier, and filling one in would be the mistake: each caller's citation of this step already says which tier it requires and which is the violation, so a tier spelled here is a second copy of a fact the caller holds — and the copy for the other caller would then have to be derived from it.

## Semantic dedup

Walk the findings and group those describing the same issue — reviewers phrase a shared concern differently. Code review: "missing type hints on handlers" and "handlers lack return annotations" are one problem. Plan review: "phase-2 missing fallback" and "phase-2 lacks retry logic" are one gap. Group by meaning, not by string match.

For each group:

- Take max severity (P1 > P2 > P3). Severity is not promoted by corroboration; a P3 that three reviewers flagged is still a P3.
- Merge the Failure paragraphs into a single rich paragraph that captures the union of intent + observation + reasoning. Preserve the leading principle name from the four-slot format — do not paraphrase the first token.
- Pick the strongest Fix or merge them into a single coherent proposal.

**Cross-finding pattern detection.** Then count the surviving findings by leading principle name. A name that appears in 3+ distinct findings — three independent "Shallow Wrapper" findings, say — is one repeated cause wearing N locations, not N causes. Prefix each member's `title` with `[Pattern cluster] ` and give every member the same Fix: the single change that ends the repetition. Locations stay per-member, because each site still has to be touched; what the shared Fix stops is the reader treating a design decision as a patch list.

## Tag contradictions, then scale findings to the target's actual size

Two judgment calls I make as the synthesizer, in this order. Both apply to findings of every severity.

**Tag — don't drop — contradictions with the verbatim user prompt.**

`spec.context.constraints[0]` carries the user's exact feature description, prefixed `User feature description (verbatim, authoritative):`. Reviewers review from a best-practices lens; they don't read the user's exact prompt. So when a reviewer pushes back on a user choice — proposing `uvicorn` where the user said `gunicorn`, or caching where the user scoped to "MVP — no caching" — the pushback is real information: users sometimes deviate from best practice out of laziness, not principle, and the reviewer's "you should be using X" deserves to surface so the user can confirm or revisit the decision.

I keep contradicting findings in the published list and tag them advisory:

- Prefix the `title` with `[Contradicts user] `
- Append one sentence to `failure`, closing on the verb its target takes — a plan is integrated, a change is applied:
  - Code review: `Rejected: contradicts constraints[0] ('<user words>'); record the pushback, do not auto-apply.`
  - Plan review: `Rejected: contradicts constraints[0] ('<user words>'); record the pushback, do not auto-integrate.`

The contradiction shapes I tag:

- a different tool than the user named (plan review: user said `gunicorn`, finding says switch to `uvicorn`; code review: user said `axum`, finding says switch to `actix-web`)
- a different shape than the user specified (user said `monolithic deploy`, finding says split into microservices; user said handlers as plain functions, finding says wrap them in a service class)
- a different scope than the user asked for (user said `no observability for v0`, finding says add tracing and metrics; user said `read-only API for the MVP`, finding says add `POST` and `DELETE` endpoints)

Findings that fill in *underspecified* hows — robustness, security, type hints, error handling, validation the user didn't speak to — pass through untagged. That's good scope growth and the reviewer's primary value.

The point of tagging instead of dropping: reviewer pushback is the value, not the noise. The tag preserves the record and marks the finding advisory rather than actionable.

**Scale findings to the target's actual size.**

Twenty findings on a 3-phase 60-line spec, or thirty on a 300-line program, means the reviewers worked the universal anti-pattern catalog rather than this specific target. I trust my judgment to drop the over-eager ones:

- Generic critiques the target doesn't earn ("phase-1 lacks rollback procedure" on a stateless transformation; "method exceeds 50 lines" on a clearly readable handler)
- Style preferences with no consequence — the schema already permits it ("`test_scenarios` should be objects, not strings" — the schema accepts strings), or nothing behavioral turns on it (`Path.replace` vs `os.replace`, `int` status codes vs `HTTPStatus`)
- Theoretical scaling concerns far below the target's actual demands ("consider DDD bounded contexts" on a 60-line CRUD MVP; "fsync blocks single-threaded server" on a tiny app the user described as small)

The published count should reflect the target's real surface area. A small spec or a small program rarely earns more than a handful of meaningful findings; if my output is much larger than the target's complexity warrants, I trim.
