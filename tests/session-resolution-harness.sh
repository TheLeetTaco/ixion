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
# The second half is lints, and lints have no precedent in tests/ — every other
# test here runs a mechanism and checks its output, where these read source
# files and check what a string says. One exists because install_opencode.py rewrites
# `/ixion:` to `/` for OpenCode by exact match: a printed command that spells
# the prefix any other way resolves nowhere on either client, and nothing else
# in the suite would notice. Each is scoped to one such string on purpose; none is a
# template checker.
#
# python: the reference reads and writes session fields with a single-line
# python program, so every assertion over those blocks needs an interpreter the
# same two-candidate probe would trust. Without one they report `SKIPPED:` —
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

ROOT_BLOCK=$(section "Resolve the session root")
CLAIM_BLOCK=$(section "Claim a session id")
READ_BLOCK=$(section "Read a session field")
WRITE_BLOCK=$(section "Set session fields")
RESOLVE_BLOCK=$(section "Resolve the session")
NAMES_BLOCK=$(section "Does a token name a session?")
VALIDATE_BLOCK=$(section "Validate the resolved session")
DERIVE_BLOCK=$(section "Derive the session worktree")
RESUME_BLOCK=$(section "Resume command")

check_section() {
  [ -n "$2" ] || note_fail "no bash block under section \"$1\" in $REFERENCE"
}
check_section "Resolve the session root" "$ROOT_BLOCK"
check_section "Claim a session id" "$CLAIM_BLOCK"
check_section "Read a session field" "$READ_BLOCK"
check_section "Set session fields" "$WRITE_BLOCK"
check_section "Resolve the session" "$RESOLVE_BLOCK"
check_section "Does a token name a session?" "$NAMES_BLOCK"
check_section "Validate the resolved session" "$VALIDATE_BLOCK"
check_section "Derive the session worktree" "$DERIVE_BLOCK"
check_section "Resume command" "$RESUME_BLOCK"
[ "$fail" = 0 ] || finalize

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ixion-session-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# --- the interpreter the reference's field idioms probe for ------------------

# The same two-candidate probe the "Read a session field" block runs, asked here
# so the assertions that depend on it report SKIPPED rather than failing on a
# host with no python at all. `-c ''` is the whole test: a candidate that is not
# installed fails it too, and the Microsoft Store stub is the reason a candidate
# that resolves on PATH is not yet trusted.
PY=
for py in python3 python; do "$py" -c '' 2>/dev/null && { PY=$py; break; }; done

# git answers both the session root and the resume command's cd, so their
# fixtures are real repos with real linked worktrees. Off PATH it gets the same
# SKIPPED: treatment, for the same reason: absence is never reported as a pass.
GIT=
command -v git >/dev/null 2>&1 && GIT=git

# --- fixtures and block plumbing ---------------------------------------------

new_root() {
  local dir="$WORK/$1"
  mkdir -p "$dir/.ixion/plugin/sessions"
  printf '%s\n' "$dir"
}

# new_repo <name> -> a real one-commit repo, the fixture the session-root block
# and the resume command's worktree derivation both need. Nothing reads a file
# in these, so the seed commit is empty.
new_repo() {
  local dir="$WORK/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  fixture_git_config "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

# repo_root <dir> -> repo_root=, as the session-root block resolves it from <dir>.
repo_root() { field "$(run_block "$1" "$ROOT_BLOCK")" repo_root; }

# checkout_root <dir> -> checkout_root=, the other half of the same block: the
# root of the one working tree <dir> is inside, which is what carries the pointer.
checkout_root() { field "$(run_block "$1" "$ROOT_BLOCK")" checkout_root; }

run_block() { ( cd "$1" && printf '%s\n' "$2" | bash ); }

fill() { printf '%s\n' "$1" | sed "s|$2|$3|g"; }

# Every block that touches the sessions tree is pasted with the repo root bound.
# The helpers below take it as a trailing optional argument defaulting to the
# directory the block runs in; the two coincide everywhere except the worktree
# cases, which is the split under test. The default is ${N-...} and not
# ${N:-...} so a case can hand a block an empty root on purpose.
fill_root() { fill "$1" '<repo_root= from the session-root block>' "$2"; }
fill_checkout() { fill "$1" '<checkout_root= from the session-root block>' "$2"; }

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

expect() {
  if [ "$2" = "$3" ]; then note_pass "$1"; else note_fail "$1 (expected '$3', got '$2')"; fi
}

# claim <cwd> <slug>-<date> [repo root] -> the session id the claim block took.
claim() {
  local block
  block=$(fill_root "$CLAIM_BLOCK" "${3-$1}")
  run_block "$1" "$(fill "$block" '<slug>-<YYYY-MM-DD>' "$2")" | sed -n 's/^session=//p'
}

# seed_session <root> <session-id> <schema_version> <status>
seed_session() {
  printf '{"schema_version": %s, "session_id": "%s", "status": "%s"}\n' "$3" "$2" "$4" \
    > "$1/.ixion/plugin/sessions/$2/session.json"
}

# resolve <cwd> <remembered id> <locator> [repo root]
#
# An empty remembered id leaves the block's own `REMEMBERED=` line untouched,
# which is the shape all six callers paste: they bind LOCATOR and nothing else.
# So every assertion below that passes "" is also asserting that an unbound
# REMEMBERED cannot outrank the locator.
resolve() {
  local block
  block=$(fill_root "$RESOLVE_BLOCK" "${4-$1}")
  block=$(fill_checkout "$block" "${5-$1}")
  [ -n "$2" ] && block=$(fill "$block" '^REMEMBERED=$' "REMEMBERED=$2")
  block=$(fill "$block" '<the session locator the caller extracted from $ARGUMENTS, or empty>' "$3")
  run_block "$1" "$block"
}

# names_session <cwd> <token> [repo root]
names_session() {
  local block
  block=$(fill_root "$NAMES_BLOCK" "${3-$1}")
  run_block "$1" "$(fill "$block" '<the single token to test>' "$2")"
}

# validate <cwd> <session-id> <via> [repo root]
validate() {
  local block
  block=$(fill_root "$VALIDATE_BLOCK" "${4-$1}")
  block=$(fill_checkout "$block" "${5-$1}")
  block=$(fill "$block" '<session= from the resolution block>' "$2")
  block=$(fill "$block" '<via= from the resolution block>' "$3")
  run_block "$1" "$block"
}

# read_field <root> <file> <field>
read_field() {
  local block
  block=$(fill "$READ_BLOCK" '<the JSON file to read>' "$2")
  block=$(fill "$block" '<the top-level key to read>' "$3")
  run_block "$1" "$block"
}

# set_fields <root> <file> <pairs>, where <pairs> is the literal argv tail the
# block's placeholder stands for: `status '"completed"' active_skill null`.
set_fields() {
  local block
  block=$(fill "$WRITE_BLOCK" '<the JSON file to update>' "$2")
  block=$(fill "$block" "<field> '<JSON value>'" "$3")
  run_block "$1" "$block"
}

# derive <cwd> <session-id> [repo root]
derive() {
  local block
  block=$(fill_root "$DERIVE_BLOCK" "${3-$1}")
  run_block "$1" "$(fill "$block" '<session= from the resolution block>' "$2")"
}

# resume <cwd> <skills> <session-id> [repo root]
resume() {
  local block
  block=$(fill_root "$RESUME_BLOCK" "${4-$1}")
  block=$(fill "$block" \
    '<the skills that can continue this session, space-separated: plan-review, plan-consolidation, work, work-review or ship>' "$2")
  block=$(fill "$block" '<session= from the resolution block>' "$3")
  run_block "$1" "$block"
}

# --- the repository root every session path hangs off ------------------------

if [ -z "$GIT" ]; then
  echo "SKIPPED: the session root is a git question, and git is not on PATH"
else
  main=$(new_repo rooted)
  mkdir -p "$main/nested/deeper"
  mroot=$(repo_root "$main")
  expect "session root, from the repository root: its own absolute path" \
    "$mroot" "$(cd "$main" && pwd)"
  # --git-common-dir answers relative from a subdirectory, so this compares the
  # strings and not the directories they name: two callers at different depths
  # holding two spellings of one root is the single-root premise failing.
  expect "session root, from a nested subdirectory: the same string, not merely the same directory" \
    "$(repo_root "$main/nested/deeper")" "$mroot"

  wt="$WORK/rooted-feata"
  git -C "$main" worktree add -q "$wt" -b feata
  mkdir -p "$wt/nested"
  expect "session root, from a linked worktree: the main checkout's root" \
    "$(repo_root "$wt")" "$mroot"
  expect "session root, from a nested subdirectory of a worktree: still the main checkout's root" \
    "$(repo_root "$wt/nested")" "$mroot"

  # The other half of the same block. The sessions tree is shared, so repo_root
  # is one answer everywhere; the pointer is per-checkout, so checkout_root has
  # to differ between the trees and hold steady at any depth inside each.
  wt_top=$(cd "$wt" && pwd)
  expect "checkout root, from the repository root: its own path" \
    "$(checkout_root "$main")" "$mroot"
  expect "checkout root, from a nested subdirectory: still the checkout it is in" \
    "$(checkout_root "$main/nested/deeper")" "$mroot"
  expect "checkout root, from a linked worktree: that worktree, not the main checkout" \
    "$(checkout_root "$wt")" "$wt_top"
  expect "checkout root, from a nested subdirectory of a worktree: still that worktree" \
    "$(checkout_root "$wt/nested")" "$wt_top"

  outside="$WORK/outside"
  mkdir -p "$outside"
  expect "outside any repository: an empty root, not the / an unguarded absolutization yields" \
    "$(repo_root "$outside")" ""
  expect "outside any repository: an empty checkout root too" \
    "$(checkout_root "$outside")" ""

  # Every block that builds a path from the root refuses an empty one first.
  # The fixture holds a real session because that is the only tree where the
  # bug is visible: an empty root under an empty tree probes a path that is
  # absent anyway, and the whole failure is that it probes one that is present.
  root=$(new_root emptyroot)
  claim "$root" feata-2026-08-01 >/dev/null
  for name in CLAIM RESOLVE NAMES VALIDATE DERIVE RESUME; do
    eval "block=\$${name}_BLOCK"
    out=$(run_block "$root" "$(fill_root "$block" "")" 2>&1)
    if [ "$?" = 0 ]; then
      note_fail "empty root in the $name block: it built a path from nothing"
    else
      expect "empty root in the $name block: refused before any path was built" \
        "$out" "repo_root="
    fi
  done
fi

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

# --- the two field idioms every JSON access in the plugin cites --------------

if [ -z "$PY" ]; then
  echo "SKIPPED: the field idioms are a python program, and no python interpreter on PATH runs one"
else
  root=$(new_root fields)
  id=$(claim "$root" feat-fields-2026-08-06)
  sj="$root/.ixion/plugin/sessions/$id/session.json"
  rel=".ixion/plugin/sessions/$id/session.json"
  seed_fields() {
    printf '{"schema_version": 1, "session_id": "%s", "status": "active", "base_ref": "abc123", "active_skill": null}\n' \
      "$id" > "$sj"
  }
  seed_fields

  expect "read: a present field prints that field and nothing else" \
    "$(read_field "$root" "$rel" base_ref)" "base_ref=abc123"

  # The spelling every reader in the plugin compares against: four characters,
  # `null`, for a key that is absent. A reader that printed `None` or an empty
  # string would take the recorded-value branch on a session that has no
  # recorded value.
  expect "read: an absent key prints the four characters null" \
    "$(read_field "$root" "$rel" integration_branch)" "integration_branch=null"
  expect "read: a JSON null value prints null too, not None" \
    "$(read_field "$root" "$rel" active_skill)" "active_skill=null"

  expect "write: two fields land in one invocation" \
    "$(set_fields "$root" "$rel" "status '\"completed\"' active_skill '\"work\"'")" "wrote=$rel"
  expect "write: the named fields hold their new values" \
    "$(read_field "$root" "$rel" status)-$(read_field "$root" "$rel" active_skill)" \
    "status=completed-active_skill=work"
  expect "write: a field the call did not name is untouched" \
    "$(read_field "$root" "$rel" base_ref)" "base_ref=abc123"

  # The property the old filter-into-a-temp-then-rename shape got from `&&`.
  seed_fields
  printf '{ not valid json\n' > "$sj"
  before=$(cksum < "$sj")
  if set_fields "$root" "$rel" "status '\"completed\"'" >/dev/null 2>&1; then
    note_fail "write: a file that is not JSON was reported written anyway"
  else
    note_pass "write: a file that is not JSON fails the write"
  fi
  expect "write: the failed write left the original byte-identical, not truncated" \
    "$(cksum < "$sj")" "$before"

  # os.replace is atomic only within one filesystem, so the temp is pinned beside
  # its target rather than left to TMPDIR. Occupying `<target>.tmp` with a
  # directory is what makes that observable: the write can only fail here if that
  # is the path it opens.
  seed_fields
  before=$(cksum < "$sj")
  mkdir "$sj.tmp"
  if set_fields "$root" "$rel" "status '\"completed\"'" >/dev/null 2>&1; then
    note_fail "write: the temp file is not <target>.tmp beside the target"
  else
    note_pass "write: the temp file is <target>.tmp beside the target"
  fi
  expect "write: blocking the temp path left the original byte-identical" \
    "$(cksum < "$sj")" "$before"
  rmdir "$sj.tmp"
fi

# --- pointer fallback and session validation ---------------------------------

if [ -z "$PY" ]; then
  echo "SKIPPED: pointer fallback and session validation read their fields with the python idiom"
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

  # The other route to an unresolved session: an active.json too corrupt to
  # parse yields no id at all, so validation cannot reach it by looking the id
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

# --- one sessions tree across checkouts, one pointer per checkout ------------

if [ -z "$GIT" ] || [ -z "$PY" ]; then
  echo "SKIPPED: the shared-tree cases need real linked worktrees and the python field idiom"
else
  main=$(new_repo split)
  mroot=$(repo_root "$main")
  wta="$WORK/split-feata"
  wtb="$WORK/split-featb"
  git -C "$main" worktree add -q "$wta" -b feata
  git -C "$main" worktree add -q "$wtb" -b featb

  ida=$(claim "$wta" feata-2026-08-01 "$(repo_root "$wta")")
  expect "claim from a worktree: the directory lands under the main checkout" \
    "$(ls -d "$mroot/.ixion/plugin/sessions/$ida" 2>/dev/null)" \
    "$mroot/.ixion/plugin/sessions/$ida"
  expect "claim from a worktree: the main checkout resolves it" \
    "$(field "$(resolve "$main" "" feata "$mroot")" session)" "$ida"
  seed_session "$mroot" "$ida" 1 active
  expect "claim from a worktree: the main checkout validates it usable" \
    "$(field "$(validate "$main" "$ida" exact "$mroot")" state)" usable

  idb=$(claim "$main" featb-2026-08-01 "$mroot")
  expect "claim from the main checkout: the other worktree resolves it" \
    "$(field "$(resolve "$wtb" "" featb "$(repo_root "$wtb")")" session)" "$idb"

  # The pointer is the half that stays per-checkout. plan-creation writes it
  # beside the checkout it ran in, so each terminal's bare invocation resolves
  # its own session; one shared pointer would let two parallel sessions
  # retarget each other, which is the collision the worktrees exist to prevent.
  mkdir -p "$wta/.ixion/plugin" "$wtb/.ixion/plugin"
  printf '{"schema_version": 1, "session_id": "%s"}\n' "$ida" > "$wta/.ixion/plugin/active.json"
  printf '{"schema_version": 1, "session_id": "%s"}\n' "$idb" > "$wtb/.ixion/plugin/active.json"
  expect "bare resolution in one worktree: its own pointer" \
    "$(field "$(resolve "$wta" "" "" "$mroot")" session)" "$ida"
  expect "bare resolution in the other worktree: its own pointer, untouched by the first" \
    "$(field "$(resolve "$wtb" "" "" "$mroot")" session)" "$idb"

  # Under unconditional worktrees a skill is ordinarily invoked from somewhere
  # inside one rather than at its root, and a pointer addressed relative to the
  # current directory is simply absent there.
  mkdir -p "$wta/nested/deeper" "$wtb/nested"
  expect "bare resolution from a nested subdirectory: its own worktree's pointer" \
    "$(field "$(resolve "$wta/nested/deeper" "" "" "$mroot" "$(checkout_root "$wta")")" session)" "$ida"
  expect "bare resolution from a nested subdirectory: reported as a pointer resolution, not via=none" \
    "$(field "$(resolve "$wta/nested/deeper" "" "" "$mroot" "$(checkout_root "$wta")")" via)" pointer
  rm "$wtb/.ixion/plugin/active.json"
  expect "bare resolution from a nested subdirectory: still cannot see the other worktree's pointer" \
    "$(field "$(resolve "$wtb/nested" "" "" "$mroot" "$(checkout_root "$wtb")")" via)" none
fi

# --- the worktree path every read site derives rather than reads -------------

if [ -z "$GIT" ]; then
  echo "SKIPPED: the worktree derivation is anchored on a git-resolved root, and git is not on PATH"
else
  # work, work-review and ship each paste this block and none of them records
  # what it printed, so the property under test is that one session id yields
  # one path from every checkout it can be asked from.
  id=add-timeout-flag-2026-04-23
  main=$(new_repo derived)
  mroot=$(repo_root "$main")
  expected="$(cd "$mroot/.." && pwd)/${mroot##*/}-add-timeout-flag"

  out=$(derive "$main" "$id" "$mroot")
  expect "derive: the branch name is the slug the session id carries" \
    "$(field "$out" slug)" add-timeout-flag
  expect "derive: the path is the slug beside the repository root" \
    "$(field "$out" worktree)" "$expected"
  expect "derive: a worktree that was never created is reported absent, not handed back as usable" \
    "$(field "$out" present)" no

  wt="$WORK/derived-add-timeout-flag"
  git -C "$main" worktree add -q "$wt" -b add-timeout-flag
  mkdir -p "$wt/nested"
  expect "derive: an existing worktree is reported present" \
    "$(field "$(derive "$main" "$id" "$mroot")" present)" yes
  expect "derive: git reports the same path back for it" \
    "$(cd "$(git -C "$main" worktree list --porcelain | sed -n "s|^worktree ||p" | grep "add-timeout-flag$")" && pwd)" \
    "$expected"

  # Every read site is a different checkout at a different depth, and the path
  # is a function of the id alone, so all of them have to agree.
  expect "derive: from inside the session's own worktree, the same path" \
    "$(field "$(derive "$wt" "$id" "$(repo_root "$wt")")" worktree)" "$expected"
  expect "derive: from a nested subdirectory, the same path" \
    "$(field "$(derive "$wt/nested" "$id" "$(repo_root "$wt/nested")")" worktree)" "$expected"

  expect "derive: a -2 collision id shares its base's worktree" \
    "$(field "$(derive "$main" "$id-2" "$mroot")" worktree)" "$expected"

  # ship reaches this with nothing resolved on an ad-hoc ship. Deriving there
  # would probe <parent>/<repo>- and answer for a directory nobody named.
  expect "derive: no session resolved, so no path is built from an empty id" \
    "$(derive "$main" "" "$mroot")" "present=no"
fi

# --- the resume command every closing block prints ---------------------------

if [ -z "$GIT" ]; then
  echo "SKIPPED: the resume command's cd line is a git question, and git is not on PATH"
else
  # The cd line asks whether this session's worktree is the checkout you are
  # standing in, and the worktree is derived from the slug in the session id
  # rather than recorded. Both checkouts are exercised from their root and from
  # a nested subdirectory, because the answer is per checkout and not per
  # directory. Nothing reads a file here, so the seed commit is empty.
  id=add-timeout-flag-2026-04-23
  main=$(new_repo resumed)
  mroot=$(repo_root "$main")
  mkdir -p "$main/nested"
  expect "no worktree for this session: the resume line stands alone" \
    "$(resume "$main" work "$id" "$mroot")" "/ixion:work $id"
  expect "no worktree for this session, from a nested subdirectory: still no cd line" \
    "$(resume "$main/nested" work "$id" "$mroot")" "/ixion:work $id"

  wt="$WORK/resumed-add-timeout-flag"
  git -C "$main" worktree add -q "$wt" -b add-timeout-flag
  mkdir -p "$wt/nested"
  wt_top=$(cd "$wt" && pwd)
  expect "session worktree exists, resuming from the main checkout: the cd line leads the paste" \
    "$(resume "$main" work "$id" "$mroot")" "cd $wt_top
/ixion:work $id"
  expect "session worktree exists, resuming from a nested subdirectory of the main checkout: the cd line still leads" \
    "$(resume "$main/nested" work "$id" "$mroot")" "cd $wt_top
/ixion:work $id"
  expect "resuming from inside the session's own worktree: no cd line" \
    "$(resume "$wt" work "$id" "$mroot")" "/ixion:work $id"
  expect "resuming from a nested subdirectory of the session's own worktree: still no cd line" \
    "$(resume "$wt/nested" work "$id" "$mroot")" "/ixion:work $id"

  # A -2 collision id shares its slug with the base id, so it shares the
  # worktree — stripping the date has to take the tiebreak with it.
  expect "a -2 collision id derives the same worktree as its base" \
    "$(resume "$main" work "$id-2" "$mroot")" "cd $wt_top
/ixion:work $id-2"

  expect "a closing block offering two skills: one cd line, one command each" \
    "$(resume "$main" 'work-review ship' "$id" "$mroot")" "cd $wt_top
/ixion:work-review $id
/ixion:ship $id"
fi

# --- lint: session artifacts are addressed through the resolved root ---------

# A session artifact named by a literal `.ixion/plugin/sessions/...` path is a
# path built from the current working directory, which is the main checkout only
# when the skill happens to have been invoked there. Skills name the directory
# validation or the claim block printed instead. The pointer is deliberately not
# covered: `active.json` is per-checkout, so a path relative to the current one
# is exactly right for it.
lint_literal_artifacts() {
  grep -rnE '\.ixion/plugin/sessions/[^ ]*\.json' "$1" --include='*.md'
}

offenders=$(lint_literal_artifacts "$ROOT/ixion")
if [ -z "$offenders" ]; then
  note_pass "every session artifact in ixion/ is addressed through the resolved root"
else
  note_fail "session artifacts named by a path built from the current directory:
$offenders"
fi

lintbed="$WORK/lint"
mkdir -p "$lintbed"
printf 'Read `.ixion/plugin/sessions/<id>/spec.json` for the plan.\n' > "$lintbed/literal.md"
if [ -n "$(lint_literal_artifacts "$lintbed")" ]; then
  note_pass "lint: a literal session-artifact path is caught"
else
  note_fail "lint: a literal session-artifact path went unnoticed"
fi
rm "$lintbed/literal.md"

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

# --- lint: every section cited by title is a heading that exists -------------

# This is the harness that extracts by heading title, and check_section above
# already fails loudly when a session-handoff heading is renamed. Skills reach
# shared reference text the other way round too — prose telling a subagent to go
# read a named section — and nothing was watching those. A renamed heading
# leaves the citation pointing at a real file and no section, so the subagent
# reads nothing and says nothing, which is the same silent shape check_section
# exists to prevent.
lint_dangling_sections() {
  grep -rhoE 'the "[^"]+" section of `[^`]+`' "$1" --include='*.md' | sort -u |
  while IFS= read -r citation; do
    title=$(printf '%s' "$citation" | sed 's/^the "//; s/" section of .*$//')
    path=$(printf '%s' "$citation" | sed 's/^.* section of `//; s/`$//')
    if [ ! -f "$ROOT/$path" ]; then
      printf '%s -> no such file\n' "$citation"
    elif ! awk -v t="$title" '
      /^#/ { h = $0; sub(/^#+[ \t]+/, "", h); if (h == t) ok = 1 }
      END { exit !ok }' "$ROOT/$path"; then
      printf '%s -> that file has no heading with exactly that title\n' "$citation"
    fi
  done
}

offenders=$(lint_dangling_sections "$ROOT/ixion")
if [ -z "$offenders" ]; then
  note_pass "every section ixion/ cites by title is a heading that exists"
else
  note_fail "citations naming a section that is not there:
$offenders"
fi

printf 'Read the "Elegance Dispatch Bat" section of `ixion/skills/ixion-conventions/references/elegance.md`.\n' \
  > "$lintbed/typo.md"
if [ -n "$(lint_dangling_sections "$lintbed")" ]; then
  note_pass "lint: a citation whose heading was renamed away is caught"
else
  note_fail "lint: a citation whose heading was renamed away went unnoticed"
fi
rm "$lintbed/typo.md"

finalize
