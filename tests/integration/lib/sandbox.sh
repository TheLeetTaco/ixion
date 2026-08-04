# Sandbox dir helpers. Each test case runs claude in its own temp cwd so
# the real ~/Documents/.../ixion/plugin/.ixion state is never touched.
#
# Nothing here sources another lib or reaches for tmux, claude or a credential,
# which is what lets tests/branch-resolution-harness.sh share add_bare_origin
# while staying runnable offline.

# add_bare_origin <repo> <production branch>
#
# Gives <repo> a real origin — a bare repo at "<repo>.git" — so
# `refs/remotes/origin/HEAD` resolves and the caller exercises the scripted
# first rung of the branch-resolution ladder instead of the local-ref fallback.
# It is a plain path, not a URL, so nothing here touches the network.
add_bare_origin() {
  git init -q --bare "$1.git"
  git -C "$1" remote add origin "$1.git"
  git -C "$1" push -q origin --all
  git -C "$1" remote set-head origin "$2"
}

# make_sandbox <test-name> [<integration-branch>] -> echoes path to a fresh tmpdir.
#
# The tmpdir is git-init'd (claude reads git context at startup) with the
# production branch pinned to `main`: a runner whose init.defaultBranch is
# `master` would otherwise give branch assertions a different answer than CI.
#
# Every sandbox gets an origin, not just the branch-resolution cases. The ".git"
# sibling name add_bare_origin uses is load-bearing here: it matches
# tests/cleanup.sh's 'ixion-int-*' glob, so the bare repo is removed with the
# sandbox it serves.
#
# Passing <integration-branch> also seeds that branch with a commit production
# does not carry, which is what lets a test tell "branched from integration"
# apart from "branched from production". HEAD is left on production so the
# caller starts where a user starts. Omitting the argument leaves the
# single-branch shape every existing case was written against.
make_sandbox() {
  local name="$1"
  local integration="${2:-}"
  local production=main
  local dir
  dir=$(mktemp -d -t "ixion-int-${name}-XXXXXX")
  (
    cd "$dir"
    git init -q -b "$production"
    git config user.email "test@ixion.local"
    git config user.name "Ixion Test"
    # A signing host would otherwise fail every commit below, taking the
    # branch topology with it.
    git config commit.gpgsign false
    # Session state is tool output, not source. Untracked .ixion/ would read
    # as a dirty tree to work's pre-switch probe and halt the session.
    printf '%s\n' '.ixion/' > .gitignore
    git add .gitignore
    git commit -q -m "init"

    if [ -n "$integration" ]; then
      git switch -q -c "$integration"
      : > INTEGRATION.md
      git add INTEGRATION.md
      git commit -q -m "integration-only commit"
      git switch -q "$production"
    fi
  )
  add_bare_origin "$dir" "$production"
  echo "$dir"
}

# preserve_sandbox <dir>
# Print the sandbox path so the operator can find it for post-run debugging.
# Sandboxes are NOT auto-deleted — run `tests/cleanup.sh` when ready to
# remove them. Keeping the sandbox lets you inspect spec.json,
# progress.json, review.findings.json, and the implementation files
# after the test exits, regardless of how it exited (including SIGKILL,
# silent stops, or partial failures).
preserve_sandbox() {
  local dir="$1"
  [ -n "$dir" ] && [ -d "$dir" ] && echo "Sandbox preserved: $dir (run tests/cleanup.sh to remove)"
}
