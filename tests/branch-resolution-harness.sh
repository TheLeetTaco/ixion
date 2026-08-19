#!/usr/bin/env bash
# Offline proof of the branch-resolution blocks in the canonical reference and
# of the merge flow `ship` drives them with. Each git topology named in the task
# scenarios is built as a throwaway repo — with a local bare repo standing in for
# origin, so fetch, push and a rejected push are all exercised for real — under a
# temp dir, and torn down on exit: no network, no API credential, no residue. The
# blocks are extracted by heading title, so the harness runs the same text
# callers paste into their own Bash calls.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REFERENCE="$ROOT/ixion/skills/ixion-conventions/references/git-branches.md"
SHIP="$ROOT/ixion/skills/ship/SKILL.md"
. "$ROOT/tests/integration/lib/assert.sh"
# sandbox.sh for fixture_git_config and add_bare_origin. It sources nothing and
# shells out to nothing but git, so sharing the recipe costs this harness none of
# the tmux or credential dependencies the rest of lib/ carries.
. "$ROOT/tests/integration/lib/sandbox.sh"

[ -f "$REFERENCE" ] || { note_fail "reference not found: $REFERENCE"; finalize; }
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
REMOVE_BLOCK=$(section "$REFERENCE" "Remove the session worktree")
FETCH_BLOCK=$(section "$SHIP" "Refresh the remote-tracking refs")
TARGET_BLOCK=$(section "$SHIP" "Resolve the merge target")
MERGE_BLOCK=$(section "$SHIP" "Merge and push")

check_section() {
  [ -n "$3" ] || note_fail "no bash block under section \"$2\" in $1"
}
check_section "$REFERENCE" "Resolve the branch roles" "$ROLES_BLOCK"
check_section "$REFERENCE" "Verify a recorded integration branch" "$RECORDED_BLOCK"
check_section "$REFERENCE" "Create or reuse the session worktree" "$CREATE_BLOCK"
check_section "$REFERENCE" "Remove the session worktree" "$REMOVE_BLOCK"
check_section "$SHIP" "Refresh the remote-tracking refs" "$FETCH_BLOCK"
check_section "$SHIP" "Resolve the merge target" "$TARGET_BLOCK"
check_section "$SHIP" "Merge and push" "$MERGE_BLOCK"
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

# --- t3: removal, which ship owns -------------------------------------------

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

# --- t1/t2: ship's merge into the integration branch ------------------------

ship_fetch() { run_block "$1" "$(fill "$FETCH_BLOCK" '<repo_root= from Phase 0>' "$2")" 2>&1; }

# ship_target <cwd> <repo root> <feature> <production> <integration>
ship_target() {
  local block
  block=$(fill "$TARGET_BLOCK" '<repo_root= from Phase 0>' "$2")
  block=$(fill "$block" '<current= from the branch-roles block>' "$3")
  block=$(fill "$block" '<production= from the branch-roles block>' "$4")
  block=$(fill "$block" '<the recorded branch where recorded=usable, otherwise integration= from the branch-roles block>' "$5")
  run_block "$1" "$block" 2>&1
}

# ship_merge <cwd> <repo root> <feature> <production> <target> <create>
ship_merge() {
  local block
  block=$(fill "$MERGE_BLOCK" '<repo_root= from Phase 0>' "$2")
  block=$(fill "$block" '<current= from the branch-roles block>' "$3")
  block=$(fill "$block" '<production= from the branch-roles block>' "$4")
  block=$(fill "$block" '<target= from the merge-target block>' "$5")
  block=$(fill "$block" '<create= from the merge-target block>' "$6")
  run_block "$1" "$block" 2>&1
}

# merges <repo> <rev> -> how many merge commits the branch carries.
merges() { git -C "$1" rev-list --count --merges "$2"; }

# peer_push <repo> <branch> <path> <content> -> the sha another clone pushed.
peer_push() {
  local peer
  peer=$(mktemp -d "$WORK/peer-XXXXXX")
  git clone -q -b "$2" "$1.git" "$peer"
  fixture_git_config "$peer"
  printf '%s\n' "$4" > "$peer/$3"
  git -C "$peer" add "$3"
  git -C "$peer" commit -qm "peer edit"
  git -C "$peer" push -q origin "$2"
  git -C "$peer" rev-parse HEAD
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

start_ship ship-two-branch dev feata
ship_fetch "$wt" "$repo" >/dev/null
out=$(ship_target "$wt" "$repo" feata "$production" "$integration")
expect "two-branch repo: the merge target is the integration branch" "$(field "$out" target)" dev
expect "two-branch repo: no branch has to be created" "$(field "$out" create)" no
expect "two-branch repo: the commit count is what the session added" "$(field "$out" commits)" 1
out=$(ship_merge "$wt" "$repo" feata "$production" dev no)
expect "merge issued from the session worktree: it reports the merge commit" \
  "$(field "$out" merged)" "$(git -C "$repo" rev-parse dev)"
expect "merge issued from the session worktree: dev carries the merge" "$(merges "$repo" dev)" 1
expect "merge issued from the session worktree: the merge is pushed" \
  "$(git -C "$repo.git" rev-parse dev)" "$(git -C "$repo" rev-parse dev)"
expect "merge issued from the session worktree: the feature branch is still checked out there" \
  "$(git -C "$wt" branch --show-current)" feata
expect "merge issued from the session worktree: the session branch is published too" \
  "$(git -C "$repo.git" rev-parse feata)" "$(git -C "$wt" rev-parse HEAD)"
expect "merge issued from the session worktree: the main checkout is handed back on its own branch" \
  "$(git -C "$repo" branch --show-current)" main

start_ship ship-behind dev feata
peer=$(peer_push "$repo" dev peer.txt "landed first")
ship_fetch "$wt" "$repo" >/dev/null
out=$(ship_merge "$wt" "$repo" feata "$production" dev no)
expect "integration behind its remote: the merge still reports a commit" \
  "$(field "$out" merged)" "$(git -C "$repo" rev-parse dev)"
if git -C "$repo" merge-base --is-ancestor "$peer" dev; then
  note_pass "integration behind its remote: it was fast-forwarded first, so the pushed merge is not stale"
else
  note_fail "integration behind its remote: the merge was built on the stale tip"
fi

start_ship ship-diverged dev feata
git -C "$repo" switch -q dev
git -C "$repo" commit -q --allow-empty -m "local-only commit on dev"
git -C "$repo" switch -q main
before=$(git -C "$repo" rev-parse dev)
peer_push "$repo" dev peer.txt "landed first" >/dev/null
ship_fetch "$wt" "$repo" >/dev/null
out=$(ship_merge "$wt" "$repo" feata "$production" dev no)
expect "integration that cannot fast-forward: no merge is reported" "$(field "$out" merged)" ""
expect "integration that cannot fast-forward: the branch is left exactly as it was" \
  "$(git -C "$repo" rev-parse dev)" "$before"
expect "integration that cannot fast-forward: the main checkout is handed back on its own branch" \
  "$(git -C "$repo" branch --show-current)" main

start_ship ship-rejected dev feata
ship_fetch "$wt" "$repo" >/dev/null
peer_push "$repo" dev peer.txt "landed between the fetch and the push" >/dev/null
out=$(ship_merge "$wt" "$repo" feata "$production" dev no)
expect "push rejected after the merge commit exists: it is reported as such" \
  "$(field "$out" merged)" push-rejected
expect "push rejected after the merge commit exists: local dev is reset to its remote" \
  "$(git -C "$repo" rev-parse dev)" "$(git -C "$repo" rev-parse refs/remotes/origin/dev)"
expect "push rejected after the merge commit exists: no unpushed merge is left behind" \
  "$(merges "$repo" dev)" 0
expect "push rejected after the merge commit exists: the main checkout is handed back on its own branch" \
  "$(git -C "$repo" branch --show-current)" main

start_ship ship-conflict dev feata
printf 'ours\n' > "$wt/seed.txt"
git -C "$wt" commit -qam "rewrite seed from the session"
peer_push "$repo" dev seed.txt theirs >/dev/null
ship_fetch "$wt" "$repo" >/dev/null
out=$(ship_merge "$wt" "$repo" feata "$production" dev no)
expect "merge conflict: it is reported as a conflict" "$(field "$out" merged)" conflict
expect "merge conflict: the conflicting path is named" \
  "$(printf '%s\n' "$out" | grep -c '^seed\.txt$')" 1
expect "merge conflict: dev carries no merge commit" "$(merges "$repo" dev)" 0
expect "merge conflict: dev is left where its remote has it"   "$(git -C "$repo" rev-parse dev)" "$(git -C "$repo" rev-parse refs/remotes/origin/dev)"
expect "merge conflict: the aborted merge leaves the main checkout clean" \
  "$(git -C "$repo" status --porcelain)" ""
expect "merge conflict: the user is still on the feature branch" \
  "$(git -C "$wt" branch --show-current)" feata
expect "merge conflict: the main checkout is handed back on its own branch" \
  "$(git -C "$repo" branch --show-current)" main

start_ship ship-single "" feata
main_before=$(git -C "$repo" rev-parse main)
ship_fetch "$wt" "$repo" >/dev/null
out=$(ship_target "$wt" "$repo" feata "$production" "$integration")
expect "repo with no dev or develop: the target is a dev that does not exist yet" \
  "$(field "$out" target)" dev
expect "repo with no dev or develop: the branch has to be created" "$(field "$out" create)" yes
expect "repo with no dev or develop: the commits are counted from production" \
  "$(field "$out" commits)" 1
out=$(ship_merge "$wt" "$repo" feata "$production" dev yes)
expect "repo with no dev or develop: dev is created and carries the merge" \
  "$(field "$out" merged)" "$(git -C "$repo" rev-parse dev)"
expect "repo with no dev or develop: dev is pushed" \
  "$(git -C "$repo.git" rev-parse dev)" "$(git -C "$repo" rev-parse dev)"
expect "repo with no dev or develop: dev carries exactly the one merge" "$(merges "$repo" dev)" 1
expect "repo with no dev or develop: production itself receives no merge" \
  "$(git -C "$repo" rev-parse main)" "$main_before"
expect "repo with no dev or develop: production on the remote is untouched too" \
  "$(git -C "$repo.git" rev-parse main)" "$main_before"
expect "repo with no dev or develop: the main checkout is handed back on its own branch" \
  "$(git -C "$repo" branch --show-current)" main

# The second session in that same repo finds the branch the first one published.
wtb="$WORK/ship-single-featb"
integration=$(field "$(run_block "$repo" "$ROLES_BLOCK")" integration)
create_worktree "$repo" featb "$wtb" "$integration" >/dev/null
printf 'more\n' > "$wtb/more.txt"
git -C "$wtb" add more.txt
git -C "$wtb" commit -qm "add more"
ship_fetch "$wtb" "$repo" >/dev/null
out=$(ship_target "$wtb" "$repo" featb "$production" "$integration")
expect "second ship in that repo: dev is already the resolved integration branch" \
  "$(field "$out" target)" dev
expect "second ship in that repo: nothing is created" "$(field "$out" create)" no
out=$(ship_merge "$wtb" "$repo" featb "$production" dev no)
expect "second ship in that repo: it merges into the branch the first one made" \
  "$(field "$out" merged)" "$(git -C "$repo" rev-parse dev)"

start_ship ship-occupied dev feata
occupied="$WORK/ship-occupied-devtree"
git -C "$repo" worktree add -q "$occupied" dev
before=$(git -C "$repo" rev-parse dev)
ship_fetch "$wt" "$repo" >/dev/null
out=$(ship_merge "$wt" "$repo" feata "$production" dev no)
expect "integration branch checked out in another worktree: no merge is reported" \
  "$(field "$out" merged)" ""
expect "integration branch checked out in another worktree: git names the holding tree" \
  "$(printf '%s\n' "$out" | grep -c 'already used by worktree')" 1
expect "integration branch checked out in another worktree: the branch is untouched" \
  "$(git -C "$repo" rev-parse dev)" "$before"

# Two sessions in a repo with no integration branch both resolve create=yes, and
# the loser's push of the dev it just made locally is rejected. The branch must
# not survive that: an unpublished dev is one nobody can pull, yet the next
# resolution would answer integration=dev from it.
start_ship ship-create-rejected "" feata
ship_fetch "$wt" "$repo" >/dev/null
peer=$(mktemp -d "$WORK/peer-XXXXXX")
git clone -q -b main "$repo.git" "$peer"
fixture_git_config "$peer"
printf 'first\n' > "$peer/peer.txt"
git -C "$peer" add peer.txt
git -C "$peer" commit -qm "the other session publishes dev"
git -C "$peer" push -q origin HEAD:refs/heads/dev
out=$(ship_merge "$wt" "$repo" feata "$production" dev yes)
expect "created dev rejected on publish: it is reported as such" \
  "$(field "$out" merged)" create-rejected
expect "created dev rejected on publish: the unpublished local branch is deleted" \
  "$(git -C "$repo" branch --list dev)" ""
expect "created dev rejected on publish: the main checkout is handed back on its own branch" \
  "$(git -C "$repo" branch --show-current)" main
expect "created dev rejected on publish: the dev that won is untouched" \
  "$(git -C "$repo.git" rev-parse dev)" "$(git -C "$peer" rev-parse HEAD)"

# Every command in these blocks targets the main checkout with `git -C`, so where
# ship stands when it issues them must not change the answer. Phase 0 puts it in
# the session worktree; a conversation that skips that step stands in the main
# checkout instead, and that is the cwd the cases above never exercise.
start_ship ship-from-main dev feata
ship_fetch "$repo" "$repo" >/dev/null
out=$(ship_target "$repo" "$repo" feata "$production" "$integration")
expect "blocks issued from the main checkout: the same merge target" "$(field "$out" target)" dev
expect "blocks issued from the main checkout: the same commit count" "$(field "$out" commits)" 1
out=$(ship_merge "$repo" "$repo" feata "$production" dev no)
expect "blocks issued from the main checkout: the merge still lands on dev" \
  "$(field "$out" merged)" "$(git -C "$repo" rev-parse dev)"
expect "blocks issued from the main checkout: dev carries the merge" "$(merges "$repo" dev)" 1
expect "blocks issued from the main checkout: it is handed back on the branch it started on" \
  "$(git -C "$repo" branch --show-current)" main
expect "blocks issued from the main checkout: the session worktree is untouched" \
  "$(git -C "$wt" branch --show-current)" feata

finalize
