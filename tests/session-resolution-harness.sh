#!/usr/bin/env bash
# Offline proof of the session-handoff blocks in the canonical reference, plus
# a lint on the one string install_opencode.py's rewrite depends on.
#
# The first half follows tests/branch-resolution-harness.sh: throwaway session
# trees under a temp dir, blocks extracted from the reference by heading title
# and executed verbatim, so what is under test is the text callers paste. No
# network, no API credential, no residue. Sessions are created by the
# reference's own "Claim a session id" block, so the -2 collision suffix the
# regression turns on is the one callers actually produce.
#
# The second half is a lint, and lints have no precedent in tests/ — every
# other test here runs a mechanism and checks its output, where this one reads
# source files and checks a spelling. It exists because install_opencode.py
# rewrites `/ixion:` to `/` for OpenCode by exact match: a printed command that
# spells the prefix any other way resolves nowhere on either client, and
# nothing else in the suite would notice. It is scoped to that one string on
# purpose and is not a template checker.
#
# jq: the reference's pointer and validation blocks call `jq -r`. Rather than
# skip them on a host without jq, this harness puts a python-backed
# `jq -r .key file` shim on PATH so the reference's text still runs unchanged.
# With neither jq nor a working python, those assertions report `SKIPPED:` —
# absence is never reported as a pass.
#
# git: the resume block asks git which checkout it is standing in, so its
# fixtures are real repos rather than bare directories. Off PATH, git gets the
# same `SKIPPED:` treatment for the same reason.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REFERENCE="$ROOT/ixion/skills/ixion-conventions/references/session-handoff.md"
. "$ROOT/tests/integration/lib/assert.sh"
# sandbox.sh for fixture_git_config, the settings the resume block's git fixtures
# need before they can commit. Same selective reuse tests/branch-resolution-harness.sh
# makes: sandbox.sh sources nothing and shells out to nothing but git, so this
# costs the harness none of lib/'s tmux or credential dependencies.
. "$ROOT/tests/integration/lib/sandbox.sh"

[ -f "$REFERENCE" ] || { note_fail "reference not found: $REFERENCE"; finalize; }

# section <heading title> -> the bash block under that heading, at any level.
section() {
  awk -v title="$1" '
    /^#/ {
      h = $0; sub(/^#+[ \t]+/, "", h)
      if (insec) exit
      if (h == title) insec = 1
      next
    }
    insec && /^```bash/ { inblk = 1; next }
    inblk && /^```/ { exit }
    inblk { print }
  ' "$REFERENCE"
}

CLAIM_BLOCK=$(section "Claim a session id")
RESOLVE_BLOCK=$(section "Resolve the session")
NAMES_BLOCK=$(section "Does a token name a session?")
VALIDATE_BLOCK=$(section "Validate the resolved session")
RESUME_BLOCK=$(section "Resume command")

check_section() {
  [ -n "$2" ] || note_fail "no bash block under section \"$1\" in $REFERENCE"
}
check_section "Claim a session id" "$CLAIM_BLOCK"
check_section "Resolve the session" "$RESOLVE_BLOCK"
check_section "Does a token name a session?" "$NAMES_BLOCK"
check_section "Validate the resolved session" "$VALIDATE_BLOCK"
check_section "Resume command" "$RESUME_BLOCK"
[ "$fail" = 0 ] || finalize

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ixion-session-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# --- jq, or a stand-in for it ------------------------------------------------

JQ=absent
if command -v jq >/dev/null 2>&1; then
  JQ=present
else
  # `python3` on Windows is often the Microsoft Store stub, which resolves on
  # PATH and then refuses to run anything — so each candidate is asked to
  # execute an empty program before it is trusted.
  for py in python3 python; do
    command -v "$py" >/dev/null 2>&1 && "$py" -c '' 2>/dev/null || continue
    mkdir -p "$WORK/bin"
    cat > "$WORK/bin/jq" <<SHIM
#!/usr/bin/env bash
# Stands in for \`jq -r .key file\`, the whole of what session-handoff.md asks of jq.
exec "$(command -v "$py")" -c '
import json, re, sys
argv = sys.argv[1:]
if len(argv) != 3 or argv[0] != "-r" or not re.fullmatch(r"\.\w+", argv[1]):
    sys.exit("jq shim: expected -r .key file, got: " + " ".join(argv))
value = json.load(open(argv[2])).get(argv[1][1:])
print("null" if value is None else value)
' "\$@"
SHIM
    chmod +x "$WORK/bin/jq"
    PATH="$WORK/bin:$PATH"
    JQ=present
    break
  done
fi

# --- fixtures and block plumbing ---------------------------------------------

new_root() {
  local dir="$WORK/$1"
  mkdir -p "$dir/.ixion/plugin/sessions"
  printf '%s\n' "$dir"
}

run_block() { ( cd "$1" && printf '%s\n' "$2" | bash ); }

fill() { printf '%s\n' "$1" | sed "s|$2|$3|g"; }

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

expect() {
  if [ "$2" = "$3" ]; then note_pass "$1"; else note_fail "$1 (expected '$3', got '$2')"; fi
}

# claim <root> <slug>-<date> -> the session id the reference's claim block took.
claim() {
  run_block "$1" "$(fill "$CLAIM_BLOCK" '<slug>-<YYYY-MM-DD>' "$2")" | sed -n 's/^session=//p'
}

# seed_session <root> <session-id> <schema_version> <status>
seed_session() {
  printf '{"schema_version": %s, "session_id": "%s", "status": "%s"}\n' "$3" "$2" "$4" \
    > "$1/.ixion/plugin/sessions/$2/session.json"
}

# resolve <root> <remembered id> <locator>
#
# An empty remembered id leaves the block's own `REMEMBERED=` line untouched,
# which is the shape all six callers paste: they bind LOCATOR and nothing else.
# So every assertion below that passes "" is also asserting that an unbound
# REMEMBERED cannot outrank the locator.
resolve() {
  local block=$RESOLVE_BLOCK
  [ -n "$2" ] && block=$(fill "$block" '^REMEMBERED=$' "REMEMBERED=$2")
  block=$(fill "$block" '<the session locator the caller extracted from $ARGUMENTS, or empty>' "$3")
  run_block "$1" "$block"
}

# names_session <root> <token>
names_session() {
  run_block "$1" "$(fill "$NAMES_BLOCK" '<the single token to test>' "$2")"
}

# validate <root> <session-id> <via>
validate() {
  local block
  block=$(fill "$VALIDATE_BLOCK" '<session= from the resolution block>' "$2")
  block=$(fill "$block" '<via= from the resolution block>' "$3")
  run_block "$1" "$block"
}

# resume <dir> <skills> <session-id>
resume() {
  local block
  block=$(fill "$RESUME_BLOCK" \
    '<the skills that can continue this session, space-separated: plan-review, plan-consolidation, work, work-review or ship>' "$2")
  block=$(fill "$block" '<session= from the resolution block>' "$3")
  run_block "$1" "$block"
}

# --- resolving a locator to one session --------------------------------------

root=$(new_root exact)
expect "claim: the first session for a slug and date takes the unsuffixed id" \
  "$(claim "$root" feat-foo-2026-08-06)" feat-foo-2026-08-06
out=$(resolve "$root" "" feat-foo-2026-08-06)
expect "full session id: resolves to the directory it names" "$(field "$out" session)" feat-foo-2026-08-06
expect "full session id: reported as an exact match" "$(field "$out" via)" exact

# The regression the exact-match rung exists for: `-name "<base>-*"` matches the
# -2 sibling and never the base, so the prefix scan alone lands on the sibling.
root=$(new_root collision)
claim "$root" feat-foo-2026-08-06 >/dev/null
expect "claim: a second session for the same slug and date takes the -2 suffix" \
  "$(claim "$root" feat-foo-2026-08-06)" feat-foo-2026-08-06-2
out=$(resolve "$root" "" feat-foo-2026-08-06)
expect "base id with its -2 sibling present: resolves to the base, not the sibling" \
  "$(field "$out" session)" feat-foo-2026-08-06

root=$(new_root slug)
claim "$root" feata-2026-08-01 >/dev/null
out=$(resolve "$root" "" feata)
expect "bare slug: resolves by prefix scan" "$(field "$out" session)" feata-2026-08-01
expect "bare slug: reported as a prefix match" "$(field "$out" via)" prefix

claim "$root" feata-2026-08-05 >/dev/null
out=$(resolve "$root" "" feata)
expect "bare slug over two dated sessions: the most recent date wins" \
  "$(field "$out" session)" feata-2026-08-05

root=$(new_root remembered)
claim "$root" feat-bar-2026-08-06 >/dev/null
printf '{"schema_version": 1, "session_id": "someone-elses-2026-08-06"}\n' \
  > "$root/.ixion/plugin/active.json"
out=$(resolve "$root" feat-bar-2026-08-06 "")
expect "id this conversation established: outranks a pointer another session moved" \
  "$(field "$out" session)" feat-bar-2026-08-06
expect "id this conversation established: reported as remembered" "$(field "$out" via)" remembered

# Every caller pastes validation straight after resolution with nothing between,
# so the first-contact state has to survive both blocks and not just the first.
root=$(new_root none)
out=$(resolve "$root" "" "")
expect "no locator and no pointer: nothing resolved" "$(field "$out" via)" none
expect "no locator and no pointer: validation says so too, rather than reading the sessions dir" \
  "$(field "$(validate "$root" "$(field "$out" session)" none)" via)" none

root=$(new_root missing)
out=$(resolve "$root" "" feat-nope-2026-08-06)
expect "locator naming no directory: the raw locator survives so the error can name it" \
  "$(field "$out" session)" feat-nope-2026-08-06
out=$(validate "$root" feat-nope-2026-08-06 prefix)
expect "locator naming no directory: reported missing, not silently usable" \
  "$(field "$out" state)" missing

# A repo before its first session is claimed has no .ixion at all — the one tree
# new_root cannot build, and the only one where the prefix scan searches a
# directory that isn't there.
root="$WORK/unclaimed"
mkdir -p "$root"
out=$(resolve "$root" "" feata 2>&1)
expect "no sessions directory yet: the raw locator survives for the error to name" \
  "$(field "$out" session)" feata
if printf '%s\n' "$out" | grep -qi 'no such file'; then
  note_fail "no sessions directory yet: the scan narrated a miss it recovered from"
else
  note_pass "no sessions directory yet: the scan falls back silently"
fi
expect "no sessions directory yet: nothing resolved, so validation says so" \
  "$(field "$(validate "$root" "" prefix)" via)" none

# --- asking whether a token names a session at all ---------------------------

root=$(new_root token)
claim "$root" feata-2026-08-01 >/dev/null
expect "token that is a full session id: names a session" \
  "$(field "$(names_session "$root" feata-2026-08-01)" names_session)" yes
expect "token that is a bare slug: names a session" \
  "$(field "$(names_session "$root" feata)" names_session)" yes
expect "token that is the first word of a commit-message hint: names no session" \
  "$(field "$(names_session "$root" tighten)" names_session)" no

# --- pointer fallback and session validation (the jq-dependent blocks) -------

if [ "$JQ" = absent ]; then
  echo "SKIPPED: pointer fallback and session validation need jq, or a python interpreter to stand one in"
else
  root=$(new_root pointer)
  id=$(claim "$root" feat-baz-2026-08-06)
  seed_session "$root" "$id" 1 active
  printf '{"schema_version": 1, "session_id": "%s"}\n' "$id" > "$root/.ixion/plugin/active.json"
  out=$(resolve "$root" "" "")
  expect "no locator, pointer present: falls back to active.json" "$(field "$out" session)" "$id"
  expect "no locator, pointer present: reported as a pointer resolution" "$(field "$out" via)" pointer
  expect "schema_version 1, status active: usable" "$(field "$(validate "$root" "$id" pointer)" state)" usable

  seed_session "$root" "$id" 2 active
  out=$(validate "$root" "$id" pointer)
  expect "schema_version 2: reported as a mismatch" "$(field "$out" state)" schema-mismatch
  expect "schema_version 2: the offending version is named" "$(field "$out" schema_version)" 2

  seed_session "$root" "$id" 1 completed
  expect "status completed: short-circuits instead of resuming" \
    "$(field "$(validate "$root" "$id" completed-check)" state)" complete

  # Clearing a stale pointer is scoped to pointer-resolved ids: an id the user
  # typed says nothing about whether another session's pointer is still good.
  root=$(new_root stale-pointer)
  printf '{"schema_version": 1, "session_id": "gone-2026-08-06"}\n' \
    > "$root/.ixion/plugin/active.json"
  validate "$root" gone-2026-08-06 prefix >/dev/null
  if [ -f "$root/.ixion/plugin/active.json" ]; then
    note_pass "missing session the user named: pointer left alone"
  else
    note_fail "missing session the user named: pointer deleted anyway"
  fi
  validate "$root" gone-2026-08-06 pointer >/dev/null
  if [ -f "$root/.ixion/plugin/active.json" ]; then
    note_fail "missing session the pointer named: stale pointer kept"
  else
    note_pass "missing session the pointer named: stale pointer cleared"
  fi

  # The other route to an unresolved session: an active.json too corrupt for jq
  # to read yields no id at all, so validation cannot reach it by looking the id
  # up on disk — the empty-id rung reports first. The pointer is still the thing
  # that failed, and is still the caller's to clear.
  root=$(new_root corrupt-pointer)
  printf '{ not valid json\n' > "$root/.ixion/plugin/active.json"
  out=$(resolve "$root" "" "" 2>/dev/null)
  expect "unparseable active.json: resolution takes the pointer route and gets no id" \
    "$(field "$out" via)-$(field "$out" session)" pointer-
  expect "unparseable active.json: validation reports nothing resolved" \
    "$(field "$(validate "$root" "$(field "$out" session)" pointer)" via)" none
  if [ -f "$root/.ixion/plugin/active.json" ]; then
    note_fail "unparseable active.json: the pointer that produced no id survives"
  else
    note_pass "unparseable active.json: the pointer that produced no id is cleared"
  fi
fi

# --- the resume command every closing block prints ---------------------------

if ! command -v git >/dev/null 2>&1; then
  echo "SKIPPED: the resume command's worktree probe is a git question, and git is not on PATH"
else
  # The worktree probe is the intricate half: an earlier version compared
  # `--git-dir` against `--git-common-dir`, which differ textually from any
  # subdirectory of a plain checkout, so it printed a cd nobody asked for. The
  # probe answers per checkout rather than per directory, so both checkouts are
  # exercised from their root and from a nested subdirectory — the four
  # positions that tell the shipped probe from the one it replaced. Nothing
  # reads a file here, so the seed commit is empty.
  id=add-timeout-flag-2026-04-23
  main="$WORK/plain"
  mkdir -p "$main/nested"
  git -C "$main" init -q
  fixture_git_config "$main"
  git -C "$main" commit -q --allow-empty -m init
  expect "plain checkout, from its root: the resume line stands alone" \
    "$(resume "$main" work "$id")" "/ixion:work $id"
  expect "plain checkout, from a nested subdirectory: still no cd line" \
    "$(resume "$main/nested" work "$id")" "/ixion:work $id"

  wt="$WORK/linked"
  git -C "$main" worktree add -q "$wt" -b linked
  mkdir -p "$wt/nested"
  wt_top=$(git -C "$wt" rev-parse --show-toplevel)
  expect "linked worktree, from its root: the cd line leads the paste" \
    "$(resume "$wt" work "$id")" "cd $wt_top
/ixion:work $id"
  expect "linked worktree, from a nested subdirectory: the cd line still leads" \
    "$(resume "$wt/nested" work "$id")" "cd $wt_top
/ixion:work $id"

  expect "a closing block offering two skills: one cd probe, one command each" \
    "$(resume "$wt" 'work-review ship' "$id")" "cd $wt_top
/ixion:work-review $id
/ixion:ship $id"
fi

# --- lint: the /ixion: spelling install_opencode.py matches on ---------------

# Printed commands only. Prose naming a skill (`/compound`) is not a command the
# user pastes back, and install_opencode.py's rewrite does not depend on it.
lint_printed_commands() {
  grep -rnE "printf '/" "$1" --include='*.md' | grep -v "printf '/ixion:"
}

offenders=$(lint_printed_commands "$ROOT/ixion")
if [ -z "$offenders" ]; then
  note_pass "every printed command in ixion/ spells the /ixion: prefix"
else
  note_fail "printed commands missing the /ixion: prefix:
$offenders"
fi

lintbed="$WORK/lint"
mkdir -p "$lintbed"
printf "printf '/work %%s\\\\n' \"\$SESSION_ID\"\n" > "$lintbed/unprefixed.md"
if [ -n "$(lint_printed_commands "$lintbed")" ]; then
  note_pass "lint: a printed command without the prefix is caught"
else
  note_fail "lint: a printed command without the prefix went unnoticed"
fi

rm "$lintbed/unprefixed.md"
printf 'Manual invocation: `/compound`. Paste back: `/ixion:work <session-id>`.\n' \
  > "$lintbed/prose.md"
if [ -z "$(lint_printed_commands "$lintbed")" ]; then
  note_pass "lint: bare slash-commands in prose are not its business"
else
  note_fail "lint: fired on a bare slash-command in prose"
fi

finalize
