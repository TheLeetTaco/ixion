# Sandbox dir helpers. Each test case runs claude in its own temp cwd so
# the real ~/Documents/.../flywheel/plugin/.flywheel state is never touched.

# make_sandbox <test-name> -> echoes path to a fresh tmpdir.
# The tmpdir is git-init'd (claude reads git context at startup) and gets
# a minimal CLAUDE.md so the harness has something to load.
make_sandbox() {
  local name="$1"
  local dir
  dir=$(mktemp -d -t "flywheel-int-${name}-XXXXXX")
  (
    cd "$dir"
    git init -q
    git config user.email "test@flywheel.local"
    git config user.name "Flywheel Test"
    : > .gitignore
    git add .gitignore
    git commit -q -m "init" >/dev/null 2>&1 || true
  )
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

# cleanup_sandbox <dir>
# DEPRECATED — kept only so existing tests don't break. Behaves like
# preserve_sandbox: prints the path instead of deleting. Update callers
# to use preserve_sandbox directly.
cleanup_sandbox() {
  preserve_sandbox "$1"
}
