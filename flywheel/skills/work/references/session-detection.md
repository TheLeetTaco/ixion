# Session Detection (Phase 0)

Active-pointer model, stale-pointer rescue, and slug-arg tiebreak. Read this file before Phase 0 to handle every input shape correctly.

## Active-Pointer Model

Session state lives under `.flywheel/plugin/sessions/<session-id>/`. The currently-active session is identified by `.flywheel/plugin/active.json`:

```json
{ "schema_version": 1, "session_id": "add-timeout-flag-2026-04-23" }
```

Session id pattern: `<slug>-<YYYY-MM-DD>` (optional `-N` suffix for collisions). The active pointer resolves to a session directory containing `spec.json`, `session.json`, and (after first chunk completes) `progress.json`. `review.findings.json` may also be present, written by `plan-review` (consumed by `plan-consolidation`) or `work-review` (consumed by `work` in fix-findings mode).

## Phase 0 Procedure

Follow this decision tree **in order**. Each branch short-circuits the next.

### Step 1: Inspect `$ARGUMENTS`

| `$ARGUMENTS` | Action |
|---|---|
| empty | Fall through to Step 2 (use active session). |
| slug (matches `^[a-z0-9-]+$`) | Prefix-scan for sessions (see Step 3). |

### Step 2: Empty args — resolve active session

1. If `.flywheel/plugin/active.json` is missing:
   ```
   Error: No active session. Run /plan or /work <slug>.
   ```
   Exit with a non-zero status.

2. Read `.flywheel/plugin/active.json`:
   ```bash
   SESSION_ID=$(jq -r '.session_id' .flywheel/plugin/active.json)
   ```

3. **Stale-pointer rescue (P1-F)** — if `.flywheel/plugin/sessions/$SESSION_ID/` does not exist:
   ```
   Error: Session $SESSION_ID not found. Clearing active pointer.
   Run /plan or /work <slug>.
   ```
   Then: `rm -f .flywheel/plugin/active.json`. Exit with a non-zero status.

4. Otherwise: `SESSION_DIR=.flywheel/plugin/sessions/$SESSION_ID`. Continue to Phase 1.

### Step 3: Slug arg — prefix-scan with tiebreak (P1-H)

```bash
SLUG="$ARGUMENTS"
# Prefix-scan: collect all sessions whose id starts with <slug>-<date>.
matches=$(find .flywheel/plugin/sessions -maxdepth 1 -type d -name "${SLUG}-*" | sort -r)
```

- Zero matches: error "No session matching slug '$SLUG'. Run /plan first."
- One match: that's the session. Set `SESSION_DIR`, update `active.json`, continue to Phase 1.
- Multiple matches: **tiebreak by lexical sort desc**. ISO-date suffix (`-YYYY-MM-DD`) sorts lexically = chronologically. Take the first result after `sort -r`. Update `active.json` to the winner, continue to Phase 1.

Write the new active pointer atomically per the Phase 2 atomic-write rule:

```bash
printf '{"schema_version":1,"session_id":"%s"}' "$WINNER" > .flywheel/plugin/active.json.tmp
mv .flywheel/plugin/active.json.tmp .flywheel/plugin/active.json
```

## Validation Checks Before Proceeding

Once the session is resolved, before Phase 1:

1. **Schema version match** — `session.json.schema_version == 1`. Reject with `"Unsupported schema version <N>. Re-run the producing skill to regenerate."`
2. **`spec.json` presence** for plan-mode work, or **`review.findings.json` presence** for fix-findings mode. Missing → ask the user to run the preceding skill.
3. **Stale `.tmp` cleanup** — if `progress.json.tmp` exists from a prior interrupted write, delete it. The authoritative state file is `progress.json`; `.tmp` is scratch.

## If Session Exists AND `$ARGUMENTS` Disagrees

- **Same session (arg resolves to same session_id as active.json)**: proceed.
- **Different session (arg resolves to a different session_id)**: update `active.json` to the new session_id (auto-switch; providing an arg is implicit confirmation). Briefly note the switch, no prompt.
