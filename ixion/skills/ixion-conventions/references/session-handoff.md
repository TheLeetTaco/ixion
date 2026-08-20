# Session handoff (shared by plan, plan-creation, plan-review, plan-consolidation, work, work-review and ship)

What a session id looks like, which repository root its directory hangs off, how any skill reads or writes one field of a session artifact, how any skill turns an argument into one session, where that session's worktree lives and how it is retired, and the command a user pastes into a fresh context to land back in it. Modifying session-resolution behavior means editing this file — the callers hold only their scope-specific tails (which artifact they read, which skill they name in the resume command).

A caller consumes a section by reading its text and issuing it as the caller's own Bash call. There is no cross-file source mechanism in this pipeline and this path is not executable — pasting the block *is* the mechanism. Each block assigns every variable it reads, because Claude Code Bash calls share no shell state, and each block prints what it resolved: printed output is the only thing that survives from one call to the next.

Callers cite several sections apiece; read this file once per invocation and hold the blocks, rather than re-reading at each citation.

## Session id and directory layout

**Format:** `<slug>-<YYYY-MM-DD>` with an optional `-N` collision tiebreak (`-2`, `-3`, …).

- **Slug**: kebab-case, alphanumeric + hyphens only. Regex: `^[a-z0-9-]+$`
- **Date**: ISO 8601 `YYYY-MM-DD` (the day the session is created)
- **Tiebreak**: integer suffix starting at `-2` when a session for the same slug already exists for the same date

`add-timeout-flag-2026-04-23` and `refactor-auth-2026-04-23-2` are ids; `add_timeout_flag-2026-04-23` (underscores), `Add-Timeout-2026-04-23` (uppercase) and `timeout-2026-4-23` (unpadded month) are not. `${CLAUDE_PLUGIN_ROOT}/schemas/session.schema.json` enforces the same shape on `session_id`, so an id this file would reject fails validation there too.

```
<repo root>/.ixion/plugin/sessions/<session-id>/
  spec.json                    # plan-creation writes; plan-consolidation refines
  session.json                 # plan-creation writes; status/active_skill metadata
  spec.json.pre-consolidation  # plan-consolidation writes before refinement
  review.findings.json         # plan-review and work-review write here (consumed by next skill)
  progress.json                # work checkpoint state
<checkout root>/.ixion/plugin/active.json   # { "schema_version": 1, "session_id": "<session-id>" }
```

The `plugin/` infix exists so plugin sessions coexist with TUI sessions (`.ixion/sessions/`) in the same repo without collision.

The two paths are anchored differently on purpose, and the block below resolves both roots in one go. `<repo root>` is the repository's shared root — the main checkout and every linked worktree of it resolve the same one — so a session claimed in one checkout is the same session read in another, and there is one record of it rather than one per tree. `<checkout root>` is the root of the one working tree the skill is running in, so each worktree has its own `active.json`. Sharing it would put two parallel sessions on one pointer, each retargeting the other's bare `/ixion:work` — the exact collision worktrees are used to avoid. The sessions tree is the record; the pointer is a per-terminal convenience default, and a default only means anything when it is the terminal's own.

Both are roots rather than relative paths for the same reason: a skill is invoked from wherever the user happens to be standing, and `work` now gives every session a worktree, so a nested subdirectory is the ordinary case rather than the corner one. A pointer addressed as `.ixion/plugin/active.json` from two directories down is simply absent, and a bare `/ixion:work` in a checkout that has a perfectly good pointer reports that there is no active session.

`active.json` has exactly one writer: plan-creation, which writes it after it creates the session directory. Resolution never writes it — see "Resolve the session" below for why.

## Resolve the session root

```bash
REPO_ROOT=
COMMON=$(git rev-parse --git-common-dir 2>/dev/null) && REPO_ROOT=$(cd "$COMMON/.." && pwd)
CHECKOUT_ROOT=
TOP=$(git rev-parse --show-toplevel 2>/dev/null) && CHECKOUT_ROOT=$(cd "$TOP" && pwd)
printf 'repo_root=%s\ncheckout_root=%s\n' "$REPO_ROOT" "$CHECKOUT_ROOT"
```

A skill issues this before anything else that touches session state, and every block below is pasted with `REPO_ROOT` and `CHECKOUT_ROOT` bound to what it printed.

Two values, two scopes, one block. `--git-common-dir` is the one git question whose answer is shared across checkouts: a linked worktree's own `--git-dir` is private to that worktree, the common dir is the one they all point at. Its parent is the repository root the sessions tree hangs off, whichever checkout the skill was invoked from. `--show-toplevel` is its exact counterpart — the root of the single working tree the caller is standing in, answered the same from any depth within it — and that is where the per-checkout `active.json` lives.

The common dir answers *relative* from a subdirectory — `../../.git` from `ixion/skills` where the repo root answers `.git` — so the `cd … && pwd` is not decoration. Without it, two callers standing at different depths hold two different strings for one directory, and the single-root premise fails one level down. `--show-toplevel` answers absolute already, and goes through the same `cd … && pwd` for the other half of that reason: git reports it in the host's native spelling, so on Windows the shell that resolved `C:/Users/you/repo` here is comparing it against the `/c/Users/you/repo` the common dir yielded. Two spellings of one directory is the failure this treatment exists to prevent, whichever way it arises.

Outside a repository `git rev-parse` fails and both stay empty, which is the `repo_root=` error state below. The absolutization hangs off the `&&` rather than running on its own line because `cd "/.." && pwd` succeeds and yields `/`: run unconditionally, it would turn "no repository" into a plausible-looking root that every path built from it accepts.

`CHECKOUT_ROOT` alone can be empty where `REPO_ROOT` is not — inside `.git/`, or in a bare repository. That case gets no error state of its own: the checkout root's only consumer is the pointer, the pointer is a convenience default for bare invocations, and a checkout with no working tree has no default to offer. The blocks below leave `POINTER` unset there and resolution falls through to `via=none`, which is already the message for "nothing named a session."

A block that builds a path from the root refuses an empty root first, before the path exists to be probed — `"$REPO_ROOT/.ixion/plugin/sessions"` with an empty root is `/.ixion/plugin/sessions`, and `docs/solutions/mistakes/empty-id-makes-a-path-probe-answer-present-System-20260806.md` is four instances of what happens when the guard tests the path instead of the variable.

## Claim a session id

```bash
REPO_ROOT='<repo_root= from the session-root block>'
[ -n "$REPO_ROOT" ] || { printf 'repo_root=\n'; exit 1; }
SESSIONS="$REPO_ROOT/.ixion/plugin/sessions"
mkdir -p "$SESSIONS"
SESSION_ID=
SDIR=
for n in "" -2 -3 -4 -5 -6 -7 -8 -9; do
  if mkdir "$SESSIONS/<slug>-<YYYY-MM-DD>$n" 2>/dev/null; then
    SESSION_ID="<slug>-<YYYY-MM-DD>$n"; SDIR="$SESSIONS/$SESSION_ID"; break
  fi
done
printf 'session=%s\ndir=%s\n' "$SESSION_ID" "$SDIR"
```

Creation *is* the probe: plain `mkdir` (no `-p`) fails atomically when the slot is taken, so two sessions planning the same slug on the same day can never both land in one directory — a `test -d` probe followed by a separate create would race. `dir=` is the claimed directory, printed here because the caller's next act is to write artifacts into it and re-spelling the sessions path at each write is how the root stops being resolved in one place. An empty `session=` means all ten slots are taken; that is ten sessions for one slug on one day, so stop and ask the user to clean up rather than widening the suffix range.

## Read a session field

```bash
for PY in python3 python; do "$PY" -c '' 2>/dev/null && break; done
FILE="<the JSON file to read>"
FIELD="<the top-level key to read>"
VALUE=$("$PY" -c 'import json, sys; value = json.load(open(sys.argv[1])).get(sys.argv[2]); print("null" if value is None else value)' "$FILE" "$FIELD")
printf '%s=%s\n' "$FIELD" "$VALUE"
```

An absent key and a key whose value is JSON `null` both print the four-character string `null`. That is the spelling every reader in the plugin compares against — a reader that printed `None` or an empty string would send `work` down the recorded-value branch on a session that has no recorded value, and `git diff` would be handed the word `None` as a ref.

The interpreter is probed, not pinned, because Windows' `python3` is frequently the Microsoft Store stub: it resolves on PATH and then executes nothing. Asking each candidate to run an empty program is the whole test — a candidate that is not installed at all fails it too, so a `command -v` in front of it would rule out nothing this does not. When neither candidate runs, `PY` is left as `python` and the next line fails loudly with a command-not-found, which is the failure a reader can act on rather than an empty value that looks like an absent field.

The program is one line because the alternative is a heredoc, and `docs/solutions/mistakes/markdown-embedded-shell-fails-silently-System-20260729.md` records that markdown indentation silently alters heredoc semantics while nothing executes these blocks at authoring time. A single-line `-c` program has no indentation surface at all.

## Set session fields

```bash
for PY in python3 python; do "$PY" -c '' 2>/dev/null && break; done
FILE="<the JSON file to update>"
"$PY" -c 'import json, os, sys; path = sys.argv[1]; tmp = path + ".tmp." + str(os.getpid()); data = json.load(open(path)); data.update(zip(sys.argv[2::2], map(json.loads, sys.argv[3::2]))); handle = open(tmp, "w"); print(json.dumps(data, indent=2), file=handle); handle.close(); os.replace(tmp, path)' \
  "$FILE" <field> '<JSON value>' \
  && printf 'wrote=%s\n' "$FILE"
```

Field and value are an argv pair, repeated for as many fields as the write sets: `status '"completed"' active_skill null`. The value is the JSON literal that should appear in the file, so a string carries its own quotes and `null` is written bare. Every field the file already holds and the call does not name comes back out unchanged.

The write is atomic in the same sense the filter-into-a-temp-then-rename shape it replaces was, and by the same reasoning: an unparseable file, or a value that is not JSON, raises before the temp is ever opened, so a failed write leaves the original exactly as it was rather than truncating it. The handle is closed before the rename rather than left to the interpreter's deallocation, so what flushes the bytes is in the program instead of in whichever interpreter the probe selected. `&& printf` carries the weight the old `&&` carried: a write that did not happen reports nothing.

The temp is `<path>.tmp.<pid>`, and each half of that name answers a different failure. *Beside its target* rather than under `tempfile`: `os.replace` is atomic only within one filesystem and raises across one, and `TMPDIR` is a different filesystem from the repo on a great many hosts. *Per-process*: the sessions tree hangs off the repository root every checkout shares, so two skills can be writing one session artifact at the same moment, and on a single temp name they would interleave into one half-written file and then rename a path the other had already renamed away. `active.json`'s writer in `plan-creation` suffixes for that reason and spells it `.tmp.$$` — the shell's name for the same number, one convention rather than two.

What the suffix does not buy is a transaction. Each write reloads the whole file, applies the fields it names and writes the document back, so two writers overlapping across that window both succeed and the later one's copy is what remains — the earlier one's fields are dropped with nothing reported. The record assumes **one active skill per session at a time**, which is exactly what `active_skill` names: `plan-creation` and `work` set it on entry and clear it on exit, and `debug` reads it to warn before working alongside a live session.

Both blocks are cited rather than restated. One home means the interpreter probe, the `null` spelling and the temp path are decided once.

The blocks below this one are the exception: they carry the read inline rather than citing it, and the resume block carries the worktree derivation the same way. A caller pastes each of them as a single self-contained unit, and a citation nested inside a pasted block would make every caller's paste two levels deep and interleave the inner block's own printed line into the outer block's `session=` / `state=` / `cd` output, which is the whole of what the next call reads.

## Resolve the session

Precedence, highest first: a session id this conversation already established, an exact directory match on the caller's locator token, a prefix scan of that token, then `active.json`.

```bash
REPO_ROOT='<repo_root= from the session-root block>'
[ -n "$REPO_ROOT" ] || { printf 'repo_root=\n'; exit 1; }
SESSIONS="$REPO_ROOT/.ixion/plugin/sessions"
CHECKOUT_ROOT='<checkout_root= from the session-root block>'
POINTER=
[ -n "$CHECKOUT_ROOT" ] && POINTER="$CHECKOUT_ROOT/.ixion/plugin/active.json"
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
  for PY in python3 python; do "$PY" -c '' 2>/dev/null && break; done
  SESSION_ID=$("$PY" -c 'import json, sys; value = json.load(open(sys.argv[1])).get(sys.argv[2]); print("null" if value is None else value)' "$POINTER" session_id); VIA=pointer
else
  VIA=none
fi

printf 'session=%s\nvia=%s\n' "$SESSION_ID" "$VIA"
```

**Identity check before writing anything:** if this conversation already established a session id (plan-creation ran earlier, or an orchestrator passed one), that remembered id is authoritative — not active.json. If active.json names a different session, another Claude Code session claimed the pointer since this run started; use the remembered id directly and don't touch active.json.

`REMEMBERED` therefore ships empty rather than as a fill-in placeholder, and a caller binds it only when it genuinely holds an id. It is the highest rung, so an unsubstituted placeholder there would be a non-empty string that outranks the id the user actually typed, resolving the session to the placeholder text itself — a wrong answer that reads like a right one. Empty is the state every caller is in unless it says otherwise, so the safe case needs no action and only the rare one does.

The exact-match rung is what makes a full session id mean the session it names. Without it, a locator that is a *prefix of its own collision sibling* resolves to the sibling: with `feat-foo-2026-08-06` and `feat-foo-2026-08-06-2` both on disk, `-name "feat-foo-2026-08-06-*"` matches only the `-2` directory, so passing the base id silently lands on the wrong session — and passing it in a repo with no sibling matches nothing at all. The scan stays underneath it, because a bare slug (`feata`) matches no directory and must still resolve to the most recent dated session sharing it. The ISO-date suffix sorts lexically, so `sort -r | head -1` is the most-recent tiebreak. When the scan matches nothing, `SESSION_ID` falls back to the raw locator, because `${MATCH##*/}` of an empty match is empty and the `Session <session-id> not found.` message would have nothing to name. `via=` stays `prefix` through that fallback: the error table keys on `state=`, and the only branch that reads `via=` at all asks whether it is `pointer`. The scan discards `find`'s stderr for the same reason the token probe below does: until a repo's first session is claimed there is no sessions directory, and a `No such file or directory` line printed at the user while resolution falls back correctly reads as a fault in the tool.

`POINTER` is built from the checkout root rather than from the current directory, so a bare `/ixion:work` two levels down inside a session worktree finds that worktree's pointer and still cannot see its neighbour's. It is left unset where there is no working tree, which sends the last rung to `via=none` without ever forming `/.ixion/plugin/active.json` — a path an unguarded build would then probe, which is the shape `docs/solutions/mistakes/empty-id-makes-a-path-probe-answer-present-System-20260806.md` records four times.

`LOCATOR` is a token the caller supplies, not `$ARGUMENTS` itself. Most callers take the whole argument string; `ship` also carries a commit-message hint in `$ARGUMENTS` and passes only the leading token.

**No branch of this block writes `active.json`** — not the exact match, not the prefix scan. The pointer is a convenience default for bare invocations, and a resolution step that retargeted it would let a command pasted in one terminal silently redirect a concurrent session's bare `/ixion:work` in another. Keeping the single writer (plan-creation, at create time) removes that race entirely rather than narrowing it. The accepted cost has two halves, stated so no caller re-decides them. After you paste an explicit session id, a *later bare* invocation in the same terminal still resolves through `active.json` and can land on a different session. And a session's own worktree never has a pointer at all: `plan-creation` is the single writer and runs in the main checkout before `work` cuts the tree, and `work` copies nothing into it — so a bare invocation from inside a session worktree resolves `via=none`, which is the one checkout where that session's work actually is. Keep passing the id — that is what the resume command below exists to make effortless, and why it prints the `cd` alongside it.

## Does a token name a session?

The same two rungs the block above tries in order, asked as a yes/no question instead of used as a lookup — which is why both exist and why they live together. Two callers need the question first, because their argument is not known to be a locator at all: `ship` must tell a leading session id from the first word of a commit-message hint, and `work-review` must tell a locator from a branch name.

```bash
REPO_ROOT='<repo_root= from the session-root block>'
[ -n "$REPO_ROOT" ] || { printf 'repo_root=\n'; exit 1; }
SESSIONS="$REPO_ROOT/.ixion/plugin/sessions"
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

Five conditions decided here so no caller re-decides them, each with exactly one message.

| Signal | Message |
|---|---|
| `repo_root=` (empty) | `Not inside a git repository. Ixion keeps session state at the repository root — run this from a checkout.` |
| `via=none` | `No active session. Run /ixion:plan to create one, or name one: /ixion:work <session-id>.` |
| `state=missing` | `Session <session-id> not found.` |
| `state=schema-mismatch` | `Unsupported schema version <N>. Re-run the producing skill to regenerate.` |
| `state=complete` | `Session <session-id> is already complete. Run /ixion:plan to start a new one.` |

Commands named in these messages are spelled the way the installer for this tree installs them. `install_claude_code.sh` qualifies them with the plugin namespace, and `plan` is why: a bare `/plan` on that host is a built-in and never reaches this plugin, so an error message instructing it would strand the user it was written to help.

`repo_root=` and `via=none` need nothing inspected — the first has no root to look under, the second resolved no id to look for. The other three do, and share one probe, which reports `via=none` itself rather than making the caller decide whether to run it:

### Validate the resolved session

```bash
REPO_ROOT='<repo_root= from the session-root block>'
[ -n "$REPO_ROOT" ] || { printf 'repo_root=\n'; exit 1; }
SESSIONS="$REPO_ROOT/.ixion/plugin/sessions"
CHECKOUT_ROOT='<checkout_root= from the session-root block>'
POINTER=
[ -n "$CHECKOUT_ROOT" ] && POINTER="$CHECKOUT_ROOT/.ixion/plugin/active.json"
SESSION_ID='<session= from the resolution block>'
VIA='<via= from the resolution block>'
SDIR="$SESSIONS/$SESSION_ID"

[ -n "$POINTER" ] && [ "$VIA" = pointer ] && { [ -z "$SESSION_ID" ] || [ ! -d "$SDIR" ]; } && rm -f "$POINTER"

if [ -z "$SESSION_ID" ]; then
  printf 'via=none\n'
elif [ ! -d "$SDIR" ]; then
  printf 'state=missing\n'
else
  for PY in python3 python; do "$PY" -c '' 2>/dev/null && break; done
  set -- $("$PY" -c 'import json, sys; data = json.load(open(sys.argv[1])); print(*("null" if data.get(k) is None else data.get(k) for k in sys.argv[2:]))' "$SDIR/session.json" schema_version status)
  SCHEMA=$1
  STATUS=$2
  if [ "$SCHEMA" != 1 ]; then
    printf 'state=schema-mismatch\nschema_version=%s\n' "$SCHEMA"
  elif [ "$STATUS" = completed ]; then
    printf 'state=complete\n'
  else
    printf 'state=usable\ndir=%s\n' "$SDIR"
  fi
fi
```

The empty-id rung is first because callers paste this block straight after the resolution block with nothing in between, and every caller does. Without it, `$SDIR` is the sessions directory itself: the directory exists, so the lookup runs against `<sessions>/session.json`, and the most ordinary first-contact state there is — a repo with no session and no pointer — surfaces as `Unsupported schema version .` instead of the message written for it. Re-printing `via=none` keys the same table row the resolution block's own `via=none` keys, so the two routes to "nothing resolved" land on one message: the second route is an `active.json` too corrupt to parse, which leaves `SESSION_ID` empty at `via=pointer` and which a caller-side `via=none` guard would not have caught.

The stale pointer is cleared above the rungs rather than inside one, because both reports can be the pointer's fault and the two would otherwise differ only in whether they clear it: `state=missing` when the id it named has no directory, `via=none` when it was too corrupt to yield an id at all. Neither of those is reachable from the other's branch, so a single guarded statement covers both and each rung is left doing nothing but reporting. The scoping to `via=pointer` is the same in both cases: an id the user typed, or one this conversation remembers, says nothing about whether `active.json` is still good, and deleting it there would break the *other* session that is using it. The leading `[ -n "$POINTER" ]` is the same guard the resolution block puts on the same variable, kept here because this is the one line that would otherwise act on a path built from an empty root.

One `python -c` reads both fields. The interpreter probe is repeated all over this file because Claude Code Bash calls share no shell state, but these two reads sit inside one fence with `$PY` already bound, so a second spawn would open and parse the same file again to answer half a question. The two values go out space-separated on one line and `set --` splits them, which is safe on these two in particular: a schema version is an integer and a status is one of `active`, `paused` and `completed`, so neither can carry whitespace or a glob character. One line rather than two is not cosmetic: Python translates every `\n` it writes into `\r\n` on Windows and the shell strips only the trailing one, so a two-line print hands back `1\r` as the schema version and it compares unequal to `1`.

`state=complete` is the rung that keeps a resume command from re-entering a finished pipeline. `status` reaches `completed` when the session ships; resuming past that point re-runs verification against merged work and re-offers "Ship it" on a branch that no longer needs it, which reads as a bug in the tool rather than a finished session. `active` and `paused` both continue normally.

## Derive the session worktree

`work` gives every session a worktree of its own, named for the session's slug beside the repository root. The path is a pure function of `session_id`, so it is derived wherever it is needed and recorded nowhere.

```bash
REPO_ROOT='<repo_root= from the session-root block>'
[ -n "$REPO_ROOT" ] || { printf 'repo_root=\n'; exit 1; }
SESSION_ID='<session= from the resolution block>'
[ -n "$SESSION_ID" ] || { printf 'present=no\n'; exit 0; }
SLUG=$(printf '%s' "$SESSION_ID" | sed 's/-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\(-[0-9][0-9]*\)\{0,1\}$//')
WORKTREE="$(cd "$REPO_ROOT/.." && pwd)/${REPO_ROOT##*/}-$SLUG"
PRESENT=no
[ -d "$WORKTREE" ] && PRESENT=yes
printf 'slug=%s\nworktree=%s\npresent=%s\n' "$SLUG" "$WORKTREE" "$PRESENT"
```

`slug=` is also the session branch's name, so `work` creates the branch and the directory from one derivation and `git worktree list --porcelain` reports the same path back.

The parent is absolutized rather than the worktree itself, because the parent always exists and the worktree does not yet on the invocation that creates it. That keeps `worktree=` a single clean absolute path in both states, with `present=` carrying the existence answer instead of an empty string overloading it. A read site that finds `present=no` reports the path it expected rather than working against whatever checkout it is standing in.

Stripping the date takes the `-2` tiebreak with it: collision siblings share a slug, so they share a worktree.

That `sed` is the file's one hand-synchronised pair: the "Resume command" block below needs the same path and re-derives it with the identical expression, because a citation nested inside a pasted block is the shape ruled out above. Widening the tiebreak past `-9` — or changing the date format — means editing both, and this sentence is how the second one gets found.

An empty `SESSION_ID` reports `present=no` and stops there rather than deriving `<parent>/<repo>-` and probing it. `ship` is the caller that reaches this with nothing resolved — an ad-hoc ship has no session and so no worktree — and a path built from an empty id is the shape `docs/solutions/mistakes/empty-id-makes-a-path-probe-answer-present-System-20260806.md` records answering "present" for a directory nobody named.

## Remove the session worktree

```bash
REPO_ROOT='<repo_root= from the session-root block>'
[ -n "$REPO_ROOT" ] || { printf 'repo_root=\n'; exit 1; }
WORKTREE='<worktree= from the "Derive the session worktree" block>'
cd "$REPO_ROOT" && git worktree remove "$WORKTREE" && printf 'removed=%s\n' "$WORKTREE"
```

The undo of the block above, and it lives beside it: it reads that block's `worktree=` and this file's `repo_root=`, and nothing else. Cutting the tree needs a branch to cut it from, which is why `git-branches.md` owns that half; removing it needs no branch at all.

`ship` is the only caller: it owns the merge that makes the worktree disposable, so it owns the disposal. The session branch survives — this removes the checkout, not the work.

The `cd` is load-bearing rather than tidy. Every session runs in a worktree, so the agent is standing inside the very directory it is removing, and git refuses to remove the current working directory. `REPO_ROOT` is the one directory guaranteed to exist and to be outside every session worktree. Continue from there afterwards: the directory the shell started in is gone.

No `--force`. `git worktree remove` refuses a tree holding modified or untracked files, and that refusal is the whole safety property — uncommitted work in a session worktree is the user's, exactly as the `## Constraints` prohibition on destructive git commands has it everywhere else.

## Resume command

Every terminal closing block ends by printing this, so the user can `/clear` and paste one line to land back in this exact session.

It is the last thing the block prints: nothing printed to the user may follow it. A command with prose under it has to be scrolled back to, and the whole point of the block is that a user about to `/clear` copies the last line without reading upward.

Agent-facing instructions may still follow the citation in the skill file — an Error Handling section below it is not a violation, because nothing there reaches the user. The rule is about the printed output, not about where the citation sits in the markdown.

```bash
SKILLS='<the skills that can continue this session, space-separated: plan-review, plan-consolidation, work, work-review or ship>'
SESSION_ID='<session= from the resolution block>'
REPO_ROOT='<repo_root= from the session-root block>'
[ -n "$REPO_ROOT" ] || { printf 'repo_root=\n'; exit 1; }

SLUG=$(printf '%s' "$SESSION_ID" | sed 's/-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\(-[0-9][0-9]*\)\{0,1\}$//')
SESSION_WORKTREE=$(cd "$REPO_ROOT/../${REPO_ROOT##*/}-$SLUG" 2>/dev/null && pwd)
HERE=$(cd "$(git rev-parse --show-toplevel)" && pwd)
[ -n "$SESSION_WORKTREE" ] && [ "$SESSION_WORKTREE" != "$HERE" ] \
  && printf 'cd %s\n' "$SESSION_WORKTREE"
for skill in $SKILLS; do
  printf '/ixion:%s %s\n' "$skill" "$SESSION_ID"
done
```

Standing in the checkout that holds this session's work, a single-skill closing block prints one line:

```
/ixion:work add-timeout-flag-2026-04-23
```

Standing anywhere else in the repository it prints two, and both are part of the paste:

```
cd /home/you/src/ixion-add-timeout-flag
/ixion:work add-timeout-flag-2026-04-23-2
```

`SKILLS` is a list because a closing block that offers the user a choice has to print every branch of it, and the `cd` belongs to the checkout rather than to any one command — issuing the block once per skill would resolve and print it twice. One list under one resolution is what keeps that format from being hand-written at the call sites that need two.

The `cd` line is what a session id alone cannot carry. The id resolves to the same session directory from every checkout, but the *branch and the source* it describes live in exactly one of them, and a skill resumed in the wrong tree reads a diff of work that isn't this session's. So the question is whether this session's worktree is the one you are standing in — not whether you are standing in a worktree at all.

`work` names a session's worktree `<repo>-<slug>` beside the repository root, and the slug is already the front of `session_id`, so this block re-derives the path rather than reading one. The date-stripping `sed` here is the twin of the one in "Derive the session worktree" above — the pair noted there; the two move together. The `cd … && pwd` that derives it is also the existence test — a session that never got a worktree, which is every session between `plan` and `work`, resolves to empty, and the guard is on that variable rather than on a probe of the path it would have had. `HERE` goes through the same `cd … && pwd` so the comparison is between two strings built the same way, and it is the checkout root rather than `$PWD` so that a nested subdirectory of the session's own worktree does not print a `cd` into the tree the user is already in. Skills run from wherever the user invoked them, which makes that the ordinary case rather than the corner one — a test of this kind is only believable once it has been run from a nested directory of both checkouts.

Print the **full session id**, never the bare slug. The slug goes back through the prefix scan and its most-recent tiebreak, which is exactly the resolution a resume command exists to bypass — and a `-2` session resumed by slug lands on whichever sibling sorts first, not the one that was just worked.

The prefix on that printed command is the plugin namespace `install_claude_code.sh` installs these skills under, and `plan` is why it is not optional: that host ships a built-in `/plan` which would shadow this skill. `install_opencode.py` rewrites the prefix away for a host that installs skills bare, and every occurrence of it in this file sits inside a command a user types or pastes, so that rewrite has one unambiguous match target.
