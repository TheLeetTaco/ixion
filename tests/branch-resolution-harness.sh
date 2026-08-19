#!/usr/bin/env bash
# Offline proof of the branch-resolution blocks in the canonical reference.
# Each git topology named in phase-1's task scenarios is built as a throwaway
# repo under a temp dir and torn down on exit: no network, no API credential,
# no residue. The blocks are extracted from the reference by heading title, so
# the harness runs the same text callers paste into their own Bash calls.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REFERENCE="$ROOT/ixion/skills/ixion-conventions/references/git-branches.md"
. "$ROOT/tests/integration/lib/assert.sh"
# sandbox.sh for fixture_git_config and add_bare_origin. It sources nothing and
# shells out to nothing but git, so sharing the recipe costs this harness none of
# the tmux or credential dependencies the rest of lib/ carries.
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

ROLES_BLOCK=$(section "Resolve the branch roles")
RECORDED_BLOCK=$(section "Verify a recorded integration branch")
CREATE_BLOCK=$(section "Create or reuse the session worktree")
REMOVE_BLOCK=$(section "Remove the session worktree")

check_section() {
  [ -n "$2" ] || note_fail "no bash block under section \"$1\" in $REFERENCE"
}
check_section "Resolve the branch roles" "$ROLES_BLOCK"
check_section "Verify a recorded integration branch" "$RECORDED_BLOCK"
check_section "Create or reuse the session worktree" "$CREATE_BLOCK"
check_section "Remove the session worktree" "$REMOVE_BLOCK"
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

finalize
