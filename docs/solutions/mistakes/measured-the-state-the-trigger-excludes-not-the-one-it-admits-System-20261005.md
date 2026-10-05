---
module: System
date: 2026-10-05
problem_type: mistake
component: tooling
symptoms:
  - "A conditional gate fails correct work in exactly the configuration its condition was written to admit"
  - "The measurement cited as the gate's justification was taken in the state the condition excludes"
  - "`cargo deny check` exits 4 with licenses FAILED on a deny.toml holding only [advisories]"
root_cause: missing_validation
resolution_type: code_fix
severity: medium
tags: [verification, measurement, cargo-deny, gates, conditional-trigger, evidence]
---

# Measured the state the trigger excludes, not the one it admits

## Symptom

The **Advisory gate** in `language-standards` runs cargo-deny only when `deny.toml` declares an `[advisories]` table, and `cargo audit` otherwise. The spec, the CHANGELOG and the ADR amendment all cite one planning measurement as the reason for that condition:

```
cargo-deny 0.19.6, freshly generated crate, no deny.toml  ->  licenses FAILED, exit 4
```

That justified *not* running deny unconditionally. But the shipped block ran the bare command whenever the condition held:

```bash
cargo deny check || cargo deny check --disable-fetch
```

`work-review` reproduced the problem in a fresh `cargo new` crate whose `deny.toml` held only `[advisories]` with `ignore = []`:

```
cargo deny check             -> advisories ok, bans ok, licenses FAILED, sources ok   exit=4
cargo deny check advisories  -> advisories ok                                         exit=0
```

So the gate failed correct work in the configuration it was written to admit, with the same exit-4 failure the condition existed to avoid. The harness never caught it because its fake `cargo-deny` ignored its arguments.

## Investigation

### Attempted (Failed)

1. Measuring the failure that motivated the condition (no config gives exit 4) and treating that as validation of the whole conditional design. It validated the *exclusion*. Nothing ran the command in the state the condition *lets through*.
2. A shadow binary that logged *whether* it ran but not *how*. "Exactly one advisory tool runs per case" passed while that tool ran with the wrong scope.

### Discovery

The empirical gate in `work-review` (ADR Principle 13) ran the command in the admitted state and got exit 4.

## Root Cause

A conditional gate makes two claims:

- **(a)** The condition keeps the command away from states where it would wrongly fail.
- **(b)** The command does the right thing in every state the condition admits.

The planning measurement tested (a) only. The trigger and the command were keyed on different things: the trigger was "`[advisories]` is present", but a bare `cargo deny check` judges every policy table. Only a test of (b) would expose that mismatch, and (b) was never measured.

## Solution

Scope the command to what the trigger names, everywhere it appears:

```bash
# ixion/skills/language-standards/SKILL.md, Advisory gate
cargo deny check advisories || cargo deny check advisories --disable-fetch
```

```yaml
# ixion/skills/language-standards/references/ci-baseline.md, deny job
- uses: EmbarkStudios/cargo-deny-action@<pinned>
  with:
    command: check advisories
```

`tests/rust-gates-harness.sh` now asserts the fake's exact argv: `deny deny check advisories`, plus `--disable-fetch` on the retry. Reverting the block to a bare `check` turns both assertions red.

## Prevention

- For a gate behind a condition, take the measurement in the **minimal state the condition admits** (here, a policy file holding only the triggering table), not only in the state it excludes.
- Check that the command and the trigger cover the same scope. A gate named "advisories" and triggered by `[advisories]` should run an advisories-only command.
- A shadow binary standing in for a scoped command should log and assert its arguments, not just how many times it ran.

## Related Issues

- `docs/solutions/mistakes/verified-a-proxy-instead-of-the-outcome-System-20260804.md`: the neighbouring error, where the check tests a stand-in for the outcome. Here the check was real but run in the wrong state.
- `docs/solutions/patterns/shadow-the-binary-instead-of-seaming-the-caller-System-20260820.md`
- `docs/adrs/0001-amendments.md`: the cargo deny amendment.

## Environment

- **Tool:** cargo-deny 0.19.6
- **Environment:** development
