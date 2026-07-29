# Verification Gates

Evidence discipline before claiming any phase, chunk, or session is complete.

## Verification Protocol

Before claiming any work is done:

1. **IDENTIFY**: what command proves the claim?
2. **RUN**: execute the full command fresh — not cached, not "from earlier."
3. **READ**: full output, exit code, failure count.
4. **VERIFY**: does the output actually confirm the claim?
5. **ONLY THEN**: state the claim, citing the evidence.

A claim without a fresh command output is a guess. The pipeline downstream — work-review, /ship, future /work resumes — assumes the evidence behind every checkpoint is real.

---

## Banned Phrases Before Verification

Never write any of these without a verified command and exit code:

- "Done", "Fixed", "Complete", "Passing", "Working"
- "Should work", "Probably", "Seems to"
- "Great!", "Perfect!", "Looks good!"

These phrases skip the verify step. They turn an unverified claim into a forwarded claim, and the claim becomes evidence by repetition. Run the command first.

---

## Evidence Requirements

| Claim | Required proof |
|-------|----------------|
| Tests pass | Test output: 0 failures, exit code 0 |
| Build works | Exit code 0 from build command |
| Bug fixed | Red→green cycle: test failed before, passes now |
| Feature implemented | Test exists AND test output shows pass |
| Phase complete | All `verification` commands ran fresh and passed |
| Success criteria met | Each criterion has a cited command output OR a line from the session's cumulative diff (Phase 3) proving it |
