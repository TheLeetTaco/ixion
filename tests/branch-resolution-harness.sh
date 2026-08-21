#!/usr/bin/env bash
# Offline proof of the branch-resolution blocks in the canonical reference and
# of the push-and-PR flow `ship` drives them with. Each git topology named in the
# task scenarios is built as a throwaway repo — with a local bare repo standing in
# for origin, so the fetch and the push are exercised for real — under a temp dir,
# and torn down on exit: no network, no API credential, no residue. The blocks are
# extracted by heading title, so the harness runs the same text callers paste into
# their own Bash calls. `gh pr create` is not covered: it needs a GitHub remote
# and a credential, and its whole effect is the PR it opens, so a stub would only
# test the stub. The auto-merge blocks are different — their effect is which rung
# they reach and whether they arm at all, which is the block's own logic — so a
# `gh` on PATH answers their probes and records what they called.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REFERENCE="$ROOT/ixion/skills/ixion-conventions/references/git-branches.md"
# The worktree lifecycle is split by what each half needs: creating one needs a
# resolved integration branch, so it lives in REFERENCE; removing one needs only
# the repository root and the derived path, so it lives with the derivation in
# HANDOFF. Both halves are exercised here: `work` creates the tree and `ship`
# prints the removal for the user to run once the PR merges.
HANDOFF="$ROOT/ixion/skills/ixion-conventions/references/session-handoff.md"
SHIP="$ROOT/ixion/skills/ship/SKILL.md"
. "$ROOT/tests/integration/lib/assert.sh"
# sandbox.sh for fixture_git_config and add_bare_origin. It sources nothing and
# shells out to nothing but git, so sharing the recipe costs this harness none of
# the tmux or credential dependencies the rest of lib/ carries.
. "$ROOT/tests/integration/lib/sandbox.sh"

[ -f "$REFERENCE" ] || { note_fail "reference not found: $REFERENCE"; finalize; }
[ -f "$HANDOFF" ] || { note_fail "reference not found: $HANDOFF"; finalize; }
[ -f "$SHIP" ] || { note_fail "skill not found: $SHIP"; finalize; }

# section <file> <heading title> -> the bash block under that heading, at any level.
section() {
  awk -v title="$2" '
    /^#/ {
      h = $0; sub(/^#+[ \t]+/, "", h)
      if (insec) exit
      if (h == title) insec = 1
      next
    }
    insec && /^```bash/ { inblk = 1; next }
    inblk && /^```/ { exit }
    inblk { print }
  ' "$1"
}

ROLES_BLOCK=$(section "$REFERENCE" "Resolve the branch roles")
RECORDED_BLOCK=$(section "$REFERENCE" "Verify a recorded integration branch")
CREATE_BLOCK=$(section "$REFERENCE" "Create or reuse the session worktree")
REMOVE_BLOCK=$(section "$HANDOFF" "Remove the session worktree")
FETCH_BLOCK=$(section "$SHIP" "Refresh the remote-tracking refs")
PUSH_BLOCK=$(section "$SHIP" "Push the session branch")
BASE_BLOCK=$(section "$SHIP" "Resolve the PR base")
REPO_BLOCK=$(section "$SHIP" "Resolve the repository")
AUTOMERGE_BLOCK=$(section "$SHIP" "Resolve auto-merge availability")
ARM_BLOCK=$(section "$SHIP" "Arm auto-merge")
# The three field idioms ship's terminal write and a later resolution are made
# of. They are exercised on their own in tests/session-resolution-harness.sh;
# here they are the fixture the ordering invariant is asserted through.
WRITE_BLOCK=$(section "$HANDOFF" "Set session fields")
READ_BLOCK=$(section "$HANDOFF" "Read a session field")
VALIDATE_BLOCK=$(section "$HANDOFF" "Validate the resolved session")

check_section() {
  [ -n "$3" ] || note_fail "no bash block under section \"$2\" in $1"
}
check_section "$REFERENCE" "Resolve the branch roles" "$ROLES_BLOCK"
check_section "$REFERENCE" "Verify a recorded integration branch" "$RECORDED_BLOCK"
check_section "$REFERENCE" "Create or reuse the session worktree" "$CREATE_BLOCK"
check_section "$HANDOFF" "Remove the session worktree" "$REMOVE_BLOCK"
check_section "$SHIP" "Refresh the remote-tracking refs" "$FETCH_BLOCK"
check_section "$SHIP" "Push the session branch" "$PUSH_BLOCK"
check_section "$SHIP" "Resolve the PR base" "$BASE_BLOCK"
check_section "$SHIP" "Resolve the repository" "$REPO_BLOCK"
check_section "$SHIP" "Resolve auto-merge availability" "$AUTOMERGE_BLOCK"
check_section "$SHIP" "Arm auto-merge" "$ARM_BLOCK"
check_section "$HANDOFF" "Set session fields" "$WRITE_BLOCK"
check_section "$HANDOFF" "Read a session field" "$READ_BLOCK"
check_section "$HANDOFF" "Validate the resolved session" "$VALIDATE_BLOCK"
[ "$fail" = 0 ] || finalize

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ixion-branch-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# new_repo <name> [<initial branch>] -> repo path, one commit deep.
new_repo() {
  local dir="$WORK/$1"
  mkdir -p "$dir"
  if [ "$#" -ge 2 ]; then git -C "$dir" init -q -b "$2"; else git -C "$dir" init -q; fi
  fixture_git_config "$dir"
  echo seed > "$dir/seed.txt"
  git -C "$dir" add seed.txt
  git -C "$dir" commit -qm init
  printf '%s\n' "$dir"
}

run_block() { ( cd "$1" && printf '%s\n' "$2" | bash ); }

fill() { printf '%s\n' "$1" | sed "s|$2|$3|g"; }

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

expect() {
  if [ "$2" = "$3" ]; then note_pass "$1"; else note_fail "$1 (expected '$3', got '$2')"; fi
}

# --- t2: the production-branch ladder ---------------------------------------

repo=$(new_repo origin-head main)
add_bare_origin "$repo" main
out=$(run_block "$repo" "$ROLES_BLOCK")
expect "origin/HEAD -> origin/main: production resolves to main" "$(field "$out" production)" main

repo=$(new_repo default-init)
expected=$(git -C "$repo" symbolic-ref --short HEAD)
out=$(run_block "$repo" "$ROLES_BLOCK")
expect "bare init, no remote: production is the existing local branch" "$(field "$out" production)" "$expected"

repo=$(new_repo master-only master)
out=$(run_block "$repo" "$ROLES_BLOCK")
expect "only master, no remote: production resolves to master" "$(field "$out" production)" master

repo=$(new_repo trunk-only trunk)
out=$(run_block "$repo" "$ROLES_BLOCK")
expect "init -b trunk, no remote: production resolves to trunk" "$(field "$out" production)" trunk

repo=$(new_repo detached trunk)
git -C "$repo" switch -q --detach HEAD
out=$(run_block "$repo" "$ROLES_BLOCK")
if [ "$(field "$out" production)" = HEAD ]; then
  note_fail "detached HEAD: production came back as the literal string HEAD"
else
  note_pass "detached HEAD: production is not the literal string HEAD"
fi
expect "detached HEAD: current branch is empty" "$(field "$out" current)" ""
expect "detached HEAD: not reported as on a protected branch" "$(field "$out" on_protected)" no

# --- t3: integration branch and protected set -------------------------------

repo=$(new_repo main-develop main)
git -C "$repo" branch develop
out=$(run_block "$repo" "$ROLES_BLOCK")
expect "main + develop: integration resolves to develop" "$(field "$out" integration)" develop
expect "main + develop: protected set holds both" "$(field "$out" protected)" "main develop"
expect "main + develop, HEAD on main: on a protected branch" "$(field "$out" on_protected)" yes

repo=$(new_repo main-only main)
out=$(run_block "$repo" "$ROLES_BLOCK")
expect "main alone: integration collapses to production" "$(field "$out" integration)" main
expect "main alone: protected set holds exactly one entry" "$(field "$out" protected)" main

repo=$(new_repo main-dev main)
git -C "$repo" branch dev
out=$(run_block "$repo" "$ROLES_BLOCK")
expect "main + dev: integration resolves to dev" "$(field "$out" integration)" dev

repo=$(new_repo dev-and-develop main)
git -C "$repo" branch dev
git -C "$repo" branch develop
out=$(run_block "$repo" "$ROLES_BLOCK")
expect "dev and develop both present: dev wins" "$(field "$out" integration)" dev

repo=$(new_repo remote-develop main)
git -C "$repo" branch develop
add_bare_origin "$repo" main
git -C "$repo" branch -q -D develop
out=$(run_block "$repo" "$ROLES_BLOCK")
expect "remote-tracking origin/develop, no local develop: integration resolves to develop" \
  "$(field "$out" integration)" develop

# --- t4: error states -------------------------------------------------------

repo=$(new_repo recorded-live main)
git -C "$repo" branch develop
out=$(run_block "$repo" "$(fill "$RECORDED_BLOCK" '<integration_branch recorded in session.json>' develop)")
expect "recorded branch that still exists: usable" "$(field "$out" recorded)" usable
expect "recorded branch that still exists: carried through as the integration branch" \
  "$(field "$out" integration)" develop

repo=$(new_repo recorded-deleted main)
git -C "$repo" branch develop
git -C "$repo" branch -q -D develop
out=$(run_block "$repo" "$(fill "$RECORDED_BLOCK" '<integration_branch recorded in session.json>' develop)")
expect "recorded branch deleted since work ran: stale, so resolution reruns" "$(field "$out" recorded)" stale

# --- t1/t3: the always-worktree topology ------------------------------------

# create <repo> <slug> <worktree path> <integration> -> the block's output.
create_worktree() {
  local block
  block=$(fill "$CREATE_BLOCK" '<slug= from the "Derive the session worktree" block>' "$2")
  block=$(fill "$block" '<worktree= from that same block>' "$3")
  block=$(fill "$block" '<integration= from the branch-roles block>' "$4")
  run_block "$1" "$block" 2>&1
}

# remove_worktree <cwd> <repo root> <worktree path> -> the block's output.
remove_worktree() {
  local block
  block=$(fill "$REMOVE_BLOCK" '<repo_root= from the session-root block>' "$2")
  block=$(fill "$block" '<worktree= from the "Derive the session worktree" block>' "$3")
  run_block "$1" "$block" 2>&1
}

repo=$(new_repo two-branch main)
git -C "$repo" branch dev
git -C "$repo" commit -q --allow-empty -m "dev moves ahead"
git -C "$repo" branch -f dev HEAD
git -C "$repo" switch -q main
integration=$(field "$(run_block "$repo" "$ROLES_BLOCK")" integration)
wt="$WORK/two-branch-feata"
out=$(create_worktree "$repo" feata "$wt" "$integration")
expect "session started on production: the worktree holds the session branch" \
  "$(field "$out" branch)" feata
expect "session started on production: the branch is cut from integration, not production" \
  "$(git -C "$wt" rev-parse HEAD)" "$(git -C "$repo" rev-parse dev)"
expect "the created worktree is the derived path git reports back" \
  "$(git -C "$repo" worktree list --porcelain | sed -n "s|^worktree ||p" | grep -c "feata$")" 1

# Reuse is the same printed answer, which is what makes a resumed session and a
# concurrent claim one path instead of two.
out=$(create_worktree "$repo" feata "$wt" "$integration")
expect "resumed session: the second create reports the same branch rather than failing" \
  "$(field "$out" branch)" feata
expect "resumed session: still exactly one worktree for the slug" \
  "$(git -C "$repo" worktree list --porcelain | sed -n "s|^worktree ||p" | grep -c "feata$")" 1

# A second session claims its own slug: two trees, two branches, one repo.
wtb="$WORK/two-branch-featb"
out=$(create_worktree "$repo" featb "$wtb" "$integration")
expect "second concurrent session: its own branch in its own worktree" \
  "$(field "$out" branch)" featb
expect "second concurrent session: branched from integration too" \
  "$(git -C "$wtb" rev-parse HEAD)" "$(git -C "$repo" rev-parse dev)"
expect "second concurrent session: the first worktree is undisturbed" \
  "$(git -C "$wt" branch --show-current)" feata

# Nothing is copied: the sessions tree stays in the checkout that shares the
# common dir, and neither worktree carries a second copy of it.
mkdir -p "$repo/.ixion/plugin/sessions/feata-2026-08-01"
expect "no session directory is copied into the first worktree" \
  "$(ls -d "$wt/.ixion" 2>/dev/null)" ""
expect "no session directory is copied into the second worktree" \
  "$(ls -d "$wtb/.ixion" 2>/dev/null)" ""

# Nothing switches branches in the invoking checkout, so its state is its own.
expect "the invoking checkout is left on the branch it was on" \
  "$(git -C "$repo" branch --show-current)" main

repo=$(new_repo dirty-start main)
git -C "$repo" branch dev
echo "in flight" >> "$repo/seed.txt"
integration=$(field "$(run_block "$repo" "$ROLES_BLOCK")" integration)
wt="$WORK/dirty-start-feata"
out=$(create_worktree "$repo" feata "$wt" "$integration")
expect "dirty invoking checkout: the session starts anyway" "$(field "$out" branch)" feata
expect "dirty invoking checkout: the uncommitted work is still there" \
  "$(tail -1 "$repo/seed.txt")" "in flight"

repo=$(new_repo single-branch main)
integration=$(field "$(run_block "$repo" "$ROLES_BLOCK")" integration)
wt="$WORK/single-branch-feata"
out=$(create_worktree "$repo" feata "$wt" "$integration")
expect "no integration branch distinct from production: branches from production" \
  "$(git -C "$wt" rev-parse HEAD)" "$(git -C "$repo" rev-parse main)"
expect "no integration branch distinct from production: the branch it named is the one it used" \
  "$integration" main

# git permits a branch in one worktree at a time, which is the collision the
# create block reads as its answer. A second path for a branch already checked
# out cannot be made, and the block says so rather than reporting a reuse.
out=$(create_worktree "$repo" feata "$WORK/single-branch-feata-again" "$integration")
expect "same branch demanded at a second path: reported absent, not reused" \
  "$(field "$out" branch)" absent

# --- t1/t2: ship's push and PR base -----------------------------------------

ship_fetch() { run_block "$1" "$FETCH_BLOCK" 2>&1; }
# The push block stands in the tree by name before it pushes HEAD — a cd into a
# sibling of the repository root does not carry between Bash calls — so the
# placeholder is filled with the worktree the case is shipping from.
ship_push() {
  run_block "$1" "$(fill "$PUSH_BLOCK" '<worktree= from Phase 0, or checkout_root= on the ad-hoc path>' "$1")" 2>&1
}

# ship_base <cwd> <production> <integration> <recorded_integration> <recorded=>
ship_base() {
  local block
  block=$(fill "$BASE_BLOCK" '<production= from the branch-roles block>' "$2")
  block=$(fill "$block" '<integration= from the branch-roles block>' "$3")
  block=$(fill "$block" '<recorded_integration= from the read above>' "$4")
  block=$(fill "$block" '<recorded= from the verify block, empty where no branch name made that block run>' "$5")
  run_block "$1" "$block" 2>&1
}

# verified <cwd> <recorded branch> -> the verify block's recorded= line.
verified() {
  field "$(run_block "$1" "$(fill "$RECORDED_BLOCK" '<integration_branch recorded in session.json>' "$2")")" recorded
}

# start_ship <name> <second branch or ""> <slug>: a repo with a bare origin, a
# session worktree holding one commit, and production/integration resolved from
# inside that worktree — the state every ship case below starts from.
start_ship() {
  local roles
  repo=$(new_repo "$1" main)
  [ -z "$2" ] || git -C "$repo" branch "$2"
  add_bare_origin "$repo" main
  roles=$(run_block "$repo" "$ROLES_BLOCK")
  production=$(field "$roles" production)
  integration=$(field "$roles" integration)
  wt="$WORK/$1-$3"
  create_worktree "$repo" "$3" "$wt" "$integration" >/dev/null
  printf 'feature work\n' > "$wt/feature.txt"
  git -C "$wt" add feature.txt
  git -C "$wt" commit -qm "add feature"
}

# The push is what publishes the branch a PR is opened from, and it is the whole
# of ship's write side now: no branch is switched and no tree is borrowed, which
# is the property the deleted lock and EXIT trap used to buy at length.
start_ship ship-push dev feata
main_before=$(git -C "$repo" rev-parse main)
ship_fetch "$wt" >/dev/null
ship_push "$wt" >/dev/null
expect "push from the session worktree: the session branch is published" \
  "$(git -C "$repo.git" rev-parse feata)" "$(git -C "$wt" rev-parse HEAD)"
expect "push from the session worktree: it tracks origin" \
  "$(git -C "$wt" rev-parse --abbrev-ref feata@{upstream})" origin/feata
expect "push from the session worktree: the main checkout is left on its own branch" \
  "$(git -C "$repo" branch --show-current)" main
expect "push from the session worktree: the worktree is left on the session branch" \
  "$(git -C "$wt" branch --show-current)" feata
expect "push from the session worktree: the integration branch is untouched" \
  "$(git -C "$repo.git" rev-parse dev)" "$main_before"
expect "push from the session worktree: nothing is merged into the integration branch" \
  "$(git -C "$repo.git" rev-list --count --merges dev)" 0

# The four cases recorded_integration= produces and the base each resolves to.
# This is the whole of the branching a PR flow does.
start_ship ship-base dev feata
# The recorded branch is deliberately not the one fresh resolution names, so the
# two paths cannot agree by accident: dev wins resolution, develop is what work
# recorded, and only reading the record produces develop.
git -C "$repo" branch develop
expect "recorded branch that still exists: it is the PR base, over what resolution names" \
  "$(field "$(ship_base "$wt" "$production" "$integration" develop "$(verified "$wt" develop)")" base)" develop
expect "recorded branch that is gone: the freshly resolved integration branch is the base" \
  "$(field "$(ship_base "$wt" "$production" "$integration" oldint "$(verified "$wt" oldint)")" base)" dev
expect "session predating the field: production is the base, not integration" \
  "$(field "$(ship_base "$wt" "$production" "$integration" null "")" base)" main
expect "ad-hoc ship, no session read: the freshly resolved integration branch is the base" \
  "$(field "$(ship_base "$wt" "$production" "$integration" "" "")" base)" dev

# A single-branch repo has no integration branch distinct from production, so
# every one of those answers collapses onto production — and nothing creates a
# dev to fill the gap, which the merge flow used to do.
start_ship ship-single "" feata
expect "single-branch repo: an ad-hoc ship bases the PR on production" \
  "$(field "$(ship_base "$wt" "$production" "$integration" "" "")" base)" main
expect "single-branch repo: a session predating the field bases it on production too" \
  "$(field "$(ship_base "$wt" "$production" "$integration" null "")" base)" main
ship_push "$wt" >/dev/null
expect "single-branch repo: no integration branch is created to ship into" \
  "$(git -C "$repo" branch --list dev)" ""
expect "single-branch repo: none is published either" \
  "$(git -C "$repo.git" branch --list dev)" ""

# Resolution reads local refs by rule, so the fetch is what makes a dev another
# session published visible at all. Without it this base is production, and the
# PR shows the whole release as its diff.
start_ship ship-fetch "" feata
git clone -q -b main "$repo.git" "$WORK/ship-fetch-peer"
fixture_git_config "$WORK/ship-fetch-peer"
git -C "$WORK/ship-fetch-peer" push -q origin HEAD:refs/heads/dev
expect "before the fetch: the dev another session published is invisible" \
  "$(field "$(run_block "$wt" "$ROLES_BLOCK")" integration)" main
ship_fetch "$wt" >/dev/null
integration=$(field "$(run_block "$wt" "$ROLES_BLOCK")" integration)
expect "after the fetch: it resolves as the integration branch" "$integration" dev
expect "after the fetch: the PR is based on it rather than on production" \
  "$(field "$(ship_base "$wt" "$production" "$integration" "" "")" base)" dev

# gh picks a repository itself when a repo has a second remote and no default
# recorded, and picking one the branch was never pushed to fails as "No commits
# between". Naming origin's is what avoids that, in all three URL spellings.
repo=$(new_repo remote-url main)
add_bare_origin "$repo" main
git -C "$repo" remote add upstream https://github.com/elsewhere/other.git
for url in https://github.com/owner/repo.git git@github.com:owner/repo.git https://github.com/owner/repo; do
  git -C "$repo" remote set-url origin "$url"
  expect "repository resolved from origin at $url" \
    "$(field "$(run_block "$repo" "$REPO_BLOCK")" repo)" owner/repo
done

# --- the auto-merge ladder --------------------------------------------------

# A `gh` on PATH answering the two probes the ladder makes, from the environment
# so one stub serves every case. An empty answer exits non-zero printing nothing,
# which is what a probe that answered nothing looks like. Every call is appended
# to GH_CALLS, which is how the arming cases below prove what did and did not run.
GH_DIR="$WORK/gh-stub"
GH_CALLS="$WORK/gh-calls"
mkdir -p "$GH_DIR"
cat > "$GH_DIR/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "$1 $2" in
  'api repos/owner/repo') [ -n "${GH_ALLOWED:-}" ] || exit 1; printf '%s\n' "$GH_ALLOWED" ;;
  'pr view') [ -n "${GH_STATE:-}" ] || exit 1; printf '%s\n' "$GH_STATE" ;;
esac
STUB
chmod +x "$GH_DIR/gh"

# with_gh <allow_auto_merge> <mergeStateStatus> <block> -> the block's output,
# run against the stub with GH_CALLS emptied first.
with_gh() {
  : > "$GH_CALLS"
  run_block "$WORK" "export PATH='$GH_DIR':\$PATH GH_CALLS='$GH_CALLS' GH_ALLOWED='$1' GH_STATE='$2'
$3" 2>/dev/null
}

automerge_block() {
  local block
  block=$(fill "$AUTOMERGE_BLOCK" '<repo= from the repository block>' owner/repo)
  fill "$block" '<url= from the Create the PR block>' https://github.com/owner/repo/pull/1
}

# expect_automerge <label> <allow_auto_merge> <mergeStateStatus> <automerge> <gates>
expect_automerge() {
  local out
  out=$(with_gh "$2" "$3" "$(automerge_block)")
  expect "$1: automerge=$4" "$(field "$out" automerge)" "$4"
  expect "$1: gates=$5" "$(field "$out" gates)" "$5"
}

expect_automerge "repository setting off" false CLEAN off ""
expect_automerge "blocked by a requirement" true BLOCKED deferred BLOCKED
expect_automerge "behind its base" true BEHIND deferred BEHIND
expect_automerge "nothing gating the PR" true CLEAN immediate CLEAN
expect_automerge "checks failing that do not gate the merge" true UNSTABLE immediate UNSTABLE
for state in UNKNOWN DIRTY DRAFT; do
  expect_automerge "mergeability reported as $state" true "$state" unknown "$state"
done

# An unread setting is not a setting read as off, and a PR with nothing gating it
# must not arm behind one. `gates=` is empty on that rung specifically: the state
# was read, but it is not why arming was refused, and reporting it as the reason
# would name the PR as the obstacle when the obstacle is the permission probe.
expect_automerge "setting unread, state read: unknown, not the off it never read" "" CLEAN unknown ""
expect_automerge "state unread, setting read: unknown, and no state to report" true "" unknown ""

# --- arming against the state the answer was given about --------------------

# arm_block <the gates= value the confirmation quoted> -> the block, filled.
arm_block() {
  local block
  block=$(fill "$ARM_BLOCK" '<url= from the Create the PR block>' https://github.com/owner/repo/pull/1)
  fill "$block" '<gates= from the resolution above>' "$1"
}

# AskUserQuestion waits on a person, so the state the outcome line quoted is the
# one thing the arm command cannot assume is still true.
out=$(with_gh true CLEAN "$(arm_block CLEAN)")
expect "state unchanged since the question: nothing drifted" "$(field "$out" drifted)" ""
expect "state unchanged since the question: auto-merge is armed" \
  "$(grep -c -- '--auto' "$GH_CALLS")" 1

out=$(with_gh true BLOCKED "$(arm_block CLEAN)")
expect "state drifted while the question was open: the new state is reported" \
  "$(field "$out" drifted)" BLOCKED
expect "state drifted while the question was open: nothing is armed" \
  "$(grep -c -- '--auto' "$GH_CALLS")" 0

# --- the terminal write, and what a later arming cannot undo ----------------

# session_field <cwd> <session.json> <field> -> that field's value.
session_field() {
  local block
  block=$(fill "$READ_BLOCK" '<the JSON file to read>' "$2")
  block=$(fill "$block" '<the top-level key to read>' "$3")
  field "$(run_block "$1" "$block")" "$3"
}

# session_state <repo root> <session-id> -> state=, as a ship invoked fresh
# against that id reads it.
session_state() {
  local block
  block=$(fill "$VALIDATE_BLOCK" '<repo_root= from the session-root block>' "$1")
  block=$(fill "$block" '<checkout_root= from the session-root block>' "$1")
  block=$(fill "$block" '<session= from the resolution block>' "$2")
  block=$(fill "$block" '<via= from the resolution block>' exact)
  field "$(run_block "$1" "$block")" state
}

# Both blocks are python programs, so absence of an interpreter the reference's
# own two-candidate probe would trust is reported rather than passed.
PY=
for py in python3 python; do "$py" -c '' 2>/dev/null && { PY=$py; break; }; done

if [ -z "$PY" ]; then
  echo "SKIPPED: the terminal write and the session validation are python programs, and no python interpreter on PATH runs one"
else
  root="$WORK/terminal-write"
  id=feata-2026-08-20
  sdir="$root/.ixion/plugin/sessions/$id"
  mkdir -p "$sdir"

  # ship_tail <arming outcome>: the write, then that outcome, in one shell —
  # which is what makes the assertions below about ordering rather than about
  # two unrelated steps. `gh pr merge` is not run for the reason `gh pr create`
  # is not, and all the invariant needs from it is its exit status.
  ship_tail() {
    local write
    printf '{"schema_version": 1, "session_id": "%s", "status": "active"}\n' "$id" > "$sdir/session.json"
    write=$(fill "$WRITE_BLOCK" '<the JSON file to update>' "$sdir/session.json")
    write=$(fill "$write" "<field> '<JSON value>'" "status '\"completed\"' active_skill null")
    run_block "$root" "$write
$1" >/dev/null 2>&1
  }

  ship_tail ':'
  expect "declined arming: session.json is still completed" \
    "$(session_field "$root" "$sdir/session.json" status)" completed
  expect "declined arming: a fresh resolution reports the session complete" \
    "$(session_state "$root" "$id")" complete

  ship_tail 'printf "failed enabling auto-merge\n" >&2; exit 1'
  expect "failed arming: session.json is still completed" \
    "$(session_field "$root" "$sdir/session.json" status)" completed
  expect "failed arming: a fresh resolution reports the session complete, not usable" \
    "$(session_state "$root" "$id")" complete
fi

# --- t3: removal, which ship now hands to the user --------------------------


repo=$(new_repo teardown main)
wt="$WORK/teardown-feata"
create_worktree "$repo" feata "$wt" main >/dev/null
out=$(remove_worktree "$wt" "$repo" "$wt")
expect "removal issued from inside the worktree: it succeeds anyway" \
  "$(field "$out" removed)" "$wt"
expect "removal issued from inside the worktree: the directory is gone" \
  "$(ls -d "$wt" 2>/dev/null)" ""
expect "removal leaves the session branch behind" \
  "$(git -C "$repo" branch --list feata)" "  feata"

wt="$WORK/teardown-featb"
create_worktree "$repo" featb "$wt" main >/dev/null
echo scratch > "$wt/scratch.txt"
out=$(remove_worktree "$wt" "$repo" "$wt")
expect "worktree holding uncommitted work: removal refuses" "$(field "$out" removed)" ""
expect "worktree holding uncommitted work: the tree and the file survive" \
  "$(cat "$wt/scratch.txt" 2>/dev/null)" scratch

finalize
