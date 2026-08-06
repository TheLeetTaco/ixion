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
TREE_BLOCK=$(section "Probe the working tree")
RECORDED_BLOCK=$(section "Verify a recorded integration branch")
SWITCH_BLOCK=$(section "Switch to the integration branch")

check_section() {
  [ -n "$2" ] || note_fail "no bash block under section \"$1\" in $REFERENCE"
}
check_section "Resolve the branch roles" "$ROLES_BLOCK"
check_section "Probe the working tree" "$TREE_BLOCK"
check_section "Verify a recorded integration branch" "$RECORDED_BLOCK"
check_section "Switch to the integration branch" "$SWITCH_BLOCK"
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

repo=$(new_repo clean-tree main)
out=$(run_block "$repo" "$TREE_BLOCK")
expect "committed tree with nothing pending: reported clean" "$(field "$out" tree)" clean

repo=$(new_repo untracked-tree main)
echo scratch > "$repo/scratch.txt"
out=$(run_block "$repo" "$TREE_BLOCK")
expect "untracked file only: reported dirty" "$(field "$out" tree)" dirty

repo=$(new_repo staged-tree main)
echo more >> "$repo/seed.txt"
git -C "$repo" add seed.txt
out=$(run_block "$repo" "$TREE_BLOCK")
expect "staged but uncommitted change: reported dirty" "$(field "$out" tree)" dirty

repo=$(new_repo ixion-state-tree main)
mkdir -p "$repo/.ixion/plugin/sessions/s"
echo '{}' > "$repo/.ixion/plugin/sessions/s/progress.json"
out=$(run_block "$repo" "$TREE_BLOCK")
expect "only Ixion's own session state untracked: reported clean" "$(field "$out" tree)" clean

echo scratch > "$repo/scratch.txt"
out=$(run_block "$repo" "$TREE_BLOCK")
expect "Ixion session state alongside a user file: still reported dirty" "$(field "$out" tree)" dirty

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

repo=$(new_repo branch-dir-collision main)
mkdir "$repo/dev"
echo doc > "$repo/dev/notes.md"
git -C "$repo" add dev/notes.md
git -C "$repo" commit -qm "add dev directory"
git -C "$repo" branch dev
run_block "$repo" "$(fill "$SWITCH_BLOCK" '<integration branch>' dev)" >/dev/null 2>&1
expect "branch name colliding with a directory: switches branches, not paths" \
  "$(git -C "$repo" branch --show-current)" dev

# The same name as a path but no such branch — where `git checkout` would
# silently restore the path over the user's edit and `git switch` refuses.
repo=$(new_repo stale-name-collision main)
mkdir "$repo/dev"
echo committed > "$repo/dev/notes.md"
git -C "$repo" add dev/notes.md
git -C "$repo" commit -qm "add dev directory"
echo edited > "$repo/dev/notes.md"
if run_block "$repo" "$(fill "$SWITCH_BLOCK" '<integration branch>' dev)" >/dev/null 2>&1; then
  note_fail "deleted integration branch matching a path: switch succeeded instead of refusing"
else
  note_pass "deleted integration branch matching a path: switch refuses"
fi
expect "deleted integration branch matching a path: the uncommitted edit survives" \
  "$(cat "$repo/dev/notes.md")" edited

finalize
