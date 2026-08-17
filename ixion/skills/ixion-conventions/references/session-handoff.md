# Session handoff (shared by plan, plan-creation, plan-review, plan-consolidation, work, work-review and ship)

What a session id looks like, where its directory lives, how any skill turns an argument into one session, and the command a user pastes into a fresh context to land back in it. Modifying session-resolution behavior means editing this file — the callers hold only their scope-specific tails (which artifact they read, which skill they name in the resume command).

A caller consumes a section by reading its text and issuing it as the caller's own Bash call. There is no cross-file source mechanism in this pipeline and this path is not executable — pasting the block *is* the mechanism. Each block assigns every variable it reads, because Claude Code Bash calls share no shell state, and each block prints what it resolved: printed output is the only thing that survives from one call to the next.

Callers cite several sections apiece; read this file once per invocation and hold the blocks, rather than re-reading at each citation.

## Session id and directory layout

**Format:** `<slug>-<YYYY-MM-DD>` with an optional `-N` collision tiebreak (`-2`, `-3`, …).

- **Slug**: kebab-case, alphanumeric + hyphens only. Regex: `^[a-z0-9-]+$`
- **Date**: ISO 8601 `YYYY-MM-DD` (the day the session is created)
- **Tiebreak**: integer suffix starting at `-2` when a session for the same slug already exists for the same date

`add-timeout-flag-2026-04-23` and `refactor-auth-2026-04-23-2` are ids; `add_timeout_flag-2026-04-23` (underscores), `Add-Timeout-2026-04-23` (uppercase) and `timeout-2026-4-23` (unpadded month) are not. `ixion/schemas/session.schema.json` enforces the same shape on `session_id`, so an id this file would reject fails validation there too.

```
.ixion/plugin/sessions/<session-id>/
  spec.json                    # plan-creation writes; plan-consolidation refines
  session.json                 # plan-creation writes; status/active_skill metadata
  spec.json.pre-consolidation  # plan-consolidation writes before refinement
  review.findings.json         # plan-review and work-review write here (consumed by next skill)
  progress.json                # work checkpoint state
.ixion/plugin/active.json      # { "schema_version": 1, "session_id": "<session-id>" }
```

The `plugin/` infix exists so plugin sessions coexist with TUI sessions (`.ixion/sessions/`) in the same repo without collision.

`active.json` has exactly one writer: plan-creation, which writes it after it creates the session directory. Resolution never writes it — see "Resolve the session" below for why.

## Claim a session id

```bash
mkdir -p .ixion/plugin/sessions
SESSION_ID=
for n in "" -2 -3 -4 -5 -6 -7 -8 -9; do
  if mkdir ".ixion/plugin/sessions/<slug>-<YYYY-MM-DD>$n" 2>/dev/null; then
    SESSION_ID="<slug>-<YYYY-MM-DD>$n"; break
  fi
done
printf 'session=%s\n' "$SESSION_ID"
```

Creation *is* the probe: plain `mkdir` (no `-p`) fails atomically when the slot is taken, so two sessions planning the same slug on the same day can never both land in one directory — a `test -d` probe followed by a separate create would race. An empty `session=` means all ten slots are taken; that is ten sessions for one slug on one day, so stop and ask the user to clean up rather than widening the suffix range.

## Resolve the session

Precedence, highest first: a session id this conversation already established, an exact directory match on the caller's locator token, a prefix scan of that token, then `active.json`.

```bash
SESSIONS=.ixion/plugin/sessions
POINTER=.ixion/plugin/active.json
REMEMBERED=
LOCATOR='<the session locator the caller extracted from $ARGUMENTS, or empty>'
SESSION_ID=

if [ -n "$REMEMBERED" ]; then
  SESSION_ID="$REMEMBERED"; VIA=remembered
elif [ -n "$LOCATOR" ] && [ -d "$SESSIONS/$LOCATOR" ]; then
  SESSION_ID="$LOCATOR"; VIA=exact
elif [ -n "$LOCATOR" ]; then
  MATCH=$(find "$SESSIONS" -maxdepth 1 -type d -name "$LOCATOR-*" 2>/dev/null | sort -r | head -1)
  SESSION_ID="${MATCH##*/}"; VIA=prefix
  [ -n "$MATCH" ] || SESSION_ID="$LOCATOR"
elif [ -f "$POINTER" ]; then
  SESSION_ID=$(jq -r .session_id "$POINTER"); VIA=pointer
else
  VIA=none
fi

printf 'session=%s\nvia=%s\n' "$SESSION_ID" "$VIA"
```

**Identity check before writing anything:** if this conversation already established a session id (plan-creation ran earlier, or an orchestrator passed one), that remembered id is authoritative — not active.json. If active.json names a different session, another Claude Code session claimed the pointer since this run started; use the remembered id directly and don't touch active.json.

`REMEMBERED` therefore ships empty rather than as a fill-in placeholder, and a caller binds it only when it genuinely holds an id. It is the highest rung, so an unsubstituted placeholder there would be a non-empty string that outranks the id the user actually typed, resolving the session to the placeholder text itself — a wrong answer that reads like a right one. Empty is the state every caller is in unless it says otherwise, so the safe case needs no action and only the rare one does.

The exact-match rung is what makes a full session id mean the session it names. Without it, a locator that is a *prefix of its own collision sibling* resolves to the sibling: with `feat-foo-2026-08-06` and `feat-foo-2026-08-06-2` both on disk, `-name "feat-foo-2026-08-06-*"` matches only the `-2` directory, so passing the base id silently lands on the wrong session — and passing it in a repo with no sibling matches nothing at all. The scan stays underneath it, because a bare slug (`feata`) matches no directory and must still resolve to the most recent dated session sharing it. The ISO-date suffix sorts lexically, so `sort -r | head -1` is the most-recent tiebreak. When the scan matches nothing, `SESSION_ID` falls back to the raw locator, because `${MATCH##*/}` of an empty match is empty and the `Session <session-id> not found.` message would have nothing to name. `via=` stays `prefix` through that fallback: the error table keys on `state=`, and the only branch that reads `via=` at all asks whether it is `pointer`. The scan discards `find`'s stderr for the same reason the token probe below does: until a repo's first session is claimed there is no sessions directory, and a `No such file or directory` line printed at the user while resolution falls back correctly reads as a fault in the tool.

`LOCATOR` is a token the caller supplies, not `$ARGUMENTS` itself. Most callers take the whole argument string; `ship` also carries a commit-message hint in `$ARGUMENTS` and passes only the leading token.

**No branch of this block writes `active.json`** — not the exact match, not the prefix scan. The pointer is a convenience default for bare invocations, and a resolution step that retargeted it would let a command pasted in one terminal silently redirect a concurrent session's bare `/ixion:work` in another. Keeping the single writer (plan-creation, at create time) removes that race entirely rather than narrowing it. The accepted cost is stated so no caller re-decides it: after you paste an explicit session id, a *later bare* invocation in the same terminal still resolves through `active.json` and can land on a different session. Keep passing the id — that is what the resume command below exists to make effortless.

## Does a token name a session?

The same two rungs the block above tries in order, asked as a yes/no question instead of used as a lookup — which is why both exist and why they live together. Two callers need the question first, because their argument is not known to be a locator at all: `ship` must tell a leading session id from the first word of a commit-message hint, and `work-review` must tell a locator from a PR number, URL or branch name.

```bash
SESSIONS=.ixion/plugin/sessions
TOKEN='<the single token to test>'

if [ -n "$TOKEN" ] \
   && { [ -d "$SESSIONS/$TOKEN" ] \
        || [ -n "$(find "$SESSIONS" -maxdepth 1 -type d -name "$TOKEN-*" -print -quit 2>/dev/null)" ]; }; then
  printf 'names_session=yes\n'
else
  printf 'names_session=no\n'
fi
```

`-print -quit` where resolution sorts: existence is the whole answer here, and picking *which* dated session a bare slug means stays resolution's job.

## Error states

Four conditions decided here so no caller re-decides them, each with exactly one message.

| Signal | Message |
|---|---|
| `via=none` | `No active session. Run /ixion:plan to create one, or name one: /ixion:work <session-id>.` |
| `state=missing` | `Session <session-id> not found.` |
| `state=schema-mismatch` | `Unsupported schema version <N>. Re-run the producing skill to regenerate.` |
| `state=complete` | `Session <session-id> is already complete. Run /ixion:plan to start a new one.` |

Commands named in these messages are spelled the way the installer for this tree installs them. `install_claude_code.sh` qualifies them with the plugin namespace, and `plan` is why: a bare `/plan` on that host is a built-in and never reaches this plugin, so an error message instructing it would strand the user it was written to help.

`via=none` needs nothing inspected — no id was resolved, so there is nothing on disk to look at. The other three do, and share one probe, which reports `via=none` itself rather than making the caller decide whether to run it:

### Validate the resolved session

```bash
SESSIONS=.ixion/plugin/sessions
POINTER=.ixion/plugin/active.json
SESSION_ID='<session= from the resolution block>'
VIA='<via= from the resolution block>'
SDIR="$SESSIONS/$SESSION_ID"

[ "$VIA" = pointer ] && { [ -z "$SESSION_ID" ] || [ ! -d "$SDIR" ]; } && rm -f "$POINTER"

if [ -z "$SESSION_ID" ]; then
  printf 'via=none\n'
elif [ ! -d "$SDIR" ]; then
  printf 'state=missing\n'
else
  SCHEMA=$(jq -r .schema_version "$SDIR/session.json")
  STATUS=$(jq -r .status "$SDIR/session.json")
  if [ "$SCHEMA" != 1 ]; then
    printf 'state=schema-mismatch\nschema_version=%s\n' "$SCHEMA"
  elif [ "$STATUS" = completed ]; then
    printf 'state=complete\n'
  else
    printf 'state=usable\ndir=%s\n' "$SDIR"
  fi
fi
```

The empty-id rung is first because callers paste this block straight after the resolution block with nothing in between, and every caller does. Without it, `$SDIR` is the sessions directory itself: the directory exists, so the lookup runs against `<sessions>/session.json`, and the most ordinary first-contact state there is — a repo with no session and no pointer — surfaces as `Unsupported schema version .` instead of the message written for it. Re-printing `via=none` keys the same table row the resolution block's own `via=none` keys, so the two routes to "nothing resolved" land on one message: the second route is an `active.json` too corrupt for `jq` to read, which leaves `SESSION_ID` empty at `via=pointer` and which a caller-side `via=none` guard would not have caught.

The stale pointer is cleared above the rungs rather than inside one, because both reports can be the pointer's fault and the two would otherwise differ only in whether they clear it: `state=missing` when the id it named has no directory, `via=none` when it was too corrupt to yield an id at all. Neither of those is reachable from the other's branch, so a single guarded statement covers both and each rung is left doing nothing but reporting. The scoping to `via=pointer` is the same in both cases: an id the user typed, or one this conversation remembers, says nothing about whether `active.json` is still good, and deleting it there would break the *other* session that is using it.

`state=complete` is the rung that keeps a resume command from re-entering a finished pipeline. `status` reaches `completed` when the session ships; resuming past that point re-runs verification against merged work and re-offers "Ship it" on a branch that no longer needs it, which reads as a bug in the tool rather than a finished session. `active` and `paused` both continue normally.

## Resume command

Every terminal closing block ends by printing this, so the user can `/clear` and paste one line to land back in this exact session.

It is the last thing the block prints: nothing printed to the user may follow it. A command with prose under it has to be scrolled back to, and the whole point of the block is that a user about to `/clear` copies the last line without reading upward.

Agent-facing instructions may still follow the citation in the skill file — an Error Handling section below it is not a violation, because nothing there reaches the user. The rule is about the printed output, not about where the citation sits in the markdown.

```bash
SKILLS='<the skills that can continue this session, space-separated: plan-review, plan-consolidation, work, work-review or ship>'
SESSION_ID='<session= from the resolution block>'

[ -f "$(git rev-parse --git-path gitdir)" ] \
  && printf 'cd %s\n' "$(git rev-parse --show-toplevel)"
for skill in $SKILLS; do
  printf '/ixion:%s %s\n' "$skill" "$SESSION_ID"
done
```

In the main checkout a single-skill closing block prints one line:

```
/ixion:work add-timeout-flag-2026-04-23
```

Inside a git worktree it prints two, and both are part of the paste:

```
cd /home/you/src/ixion-add-timeout-flag
/ixion:work add-timeout-flag-2026-04-23-2
```

`SKILLS` is a list because a closing block that offers the user a choice has to print every branch of it, and the `cd` belongs to the checkout rather than to any one command — issuing the block once per skill would probe and print it twice. One list under one probe is what keeps that format from being hand-written at the call sites that need two.

The `cd` line is what a session id alone cannot carry. `work` may move a session into a worktree, which copies the session directory across and leaves the main checkout's copy stale from that moment; a command pasted without the `cd` resolves the id against the stale copy and works on the wrong tree. Git writes a `gitdir` file inside a linked worktree's git dir and nowhere else, so testing for it answers which checkout you are standing in, from any directory within it. Resist the shorter-looking probe of comparing `--git-dir` against `--git-common-dir`: from a subdirectory `--git-dir` answers absolute while `--git-common-dir` stays relative, so the two differ textually in a plain main checkout and the `cd` line prints a path the user does not need and did not expect. Skills run from wherever the user invoked them, which makes that the ordinary case rather than the corner one — a probe of this kind is only believable once it has been run from a nested directory of both checkouts.

What the `cd` line closes is the pasted path, and only that. A bare `/ixion:work` typed in the main checkout still resolves against the stale copy and writes progress there until `ship` copies the worktree's session dir back. That residual is accepted, not overlooked: marking the stale copy would take a sentinel file plus a fifth `state=` rung to read it, which is machinery for the one window the printed command already covers.

Print the **full session id**, never the bare slug. The slug goes back through the prefix scan and its most-recent tiebreak, which is exactly the resolution a resume command exists to bypass — and a `-2` session resumed by slug lands on whichever sibling sorts first, not the one that was just worked.

The prefix on that printed command is the plugin namespace `install_claude_code.sh` installs these skills under, and `plan` is why it is not optional: that host ships a built-in `/plan` which would shadow this skill. `install_opencode.py` rewrites the prefix away for a host that installs skills bare, and every occurrence of it in this file sits inside a command a user types or pastes, so that rewrite has one unambiguous match target.
