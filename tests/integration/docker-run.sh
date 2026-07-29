#!/usr/bin/env bash
# Run the integration suite in a container. Exists so the suite is runnable on
# Windows, where tmux is unavailable, without each host re-deriving the setup.
#
#   tests/integration/docker-run.sh                 # whole suite
#   tests/integration/docker-run.sh 07              # one case, by filename prefix
#   IXION_TEST_SHELL=1 tests/integration/docker-run.sh   # drop into the container
#
# Credential: exports ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN from the
# environment if set, otherwise reads a `claude_token=` line from a gitignored
# `.env` at the repo root. Subscription users get that token from
# `claude setup-token` — no Console API key needed.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
IMAGE="${IXION_TEST_IMAGE:-ixion-test:latest}"
filter="${1:-}"

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found in PATH" >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo "ERROR: docker daemon unreachable — is Docker Desktop running?" >&2; exit 2; }

# Resolve a credential. Precedence: explicit env, then .env.
CRED_VAR="" CRED_VAL=""
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  CRED_VAR=ANTHROPIC_API_KEY CRED_VAL=$ANTHROPIC_API_KEY
elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  CRED_VAR=CLAUDE_CODE_OAUTH_TOKEN CRED_VAL=$CLAUDE_CODE_OAUTH_TOKEN
elif [ -f "$REPO_ROOT/.env" ]; then
  # tr strips the CR a Windows editor leaves behind, which would otherwise ride
  # into the token and fail auth with no useful diagnostic.
  CRED_VAL=$(grep -m1 -E '^claude_token=' "$REPO_ROOT/.env" | cut -d= -f2- | tr -d ' \r\n' || true)
  [ -n "$CRED_VAL" ] && CRED_VAR=CLAUDE_CODE_OAUTH_TOKEN
fi

if [ -z "$CRED_VAR" ]; then
  echo "ERROR: no Anthropic credential found" >&2
  echo "  export ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN," >&2
  echo "  or put 'claude_token=<token>' in $REPO_ROOT/.env (gitignored)." >&2
  echo "  Subscription users: run 'claude setup-token' to mint one." >&2
  exit 2
fi

# Pass the secret by file rather than -e, so it never lands in `docker inspect`
# or a shell history. Deleted on exit, including on failure.
ENV_FILE=$(mktemp)
trap 'rm -f "$ENV_FILE"' EXIT
chmod 600 "$ENV_FILE"
printf '%s=%s\n' "$CRED_VAR" "$CRED_VAL" > "$ENV_FILE"

# Anything the docker *client* opens (--env-file, the host half of -v) is read by
# a Windows binary under Git Bash, which cannot resolve an MSYS path like
# /tmp/tmp.AbC or /d/repo. cygpath exists only there, so this is a no-op on Linux
# and macOS. Paths inside the container stay POSIX and must not be converted.
host_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}
ENV_FILE_HOST=$(host_path "$ENV_FILE")
REPO_ROOT_HOST=$(host_path "$REPO_ROOT")

docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "Building $IMAGE (first run only)..."
  docker build -f "$REPO_ROOT/tests/integration/Dockerfile" -t "$IMAGE" "$REPO_ROOT/tests/integration"
}

# The suite's own trap saves pane scrollback and preserves its sandbox under
# TMPDIR — the most informative diagnostics it produces, and both die with the
# container. Sandboxes stay on the container filesystem while the test runs
# (cargo builds there; a bind mount would crawl) and get copied out at the end.
ARTIFACTS="$REPO_ROOT/tests/integration/.artifacts"
mkdir -p "$ARTIFACTS"
ARTIFACTS_HOST=$(host_path "$ARTIFACTS")
# Runs on the test's exit path, so a normal FAIL still yields diagnostics; a
# SIGKILLed container loses them, which is the one case this cannot cover.
harvest='rc=$?; cp -a /tmp/ixion-int-*.pane.txt /artifacts/ 2>/dev/null || true; cp -a /tmp/ixion-int-*/ /artifacts/ 2>/dev/null || true; exit $rc'

if [ -n "${IXION_TEST_SHELL:-}" ]; then
  inner='bash install_claude_code.sh </dev/null >/dev/null 2>&1; exec bash'
elif [ -n "$filter" ]; then
  case_file=$(cd "$REPO_ROOT/tests/integration/cases" && ls "$filter"*.test.sh 2>/dev/null | head -1 || true)
  [ -n "$case_file" ] || { echo "ERROR: no case matching '$filter' in tests/integration/cases/" >&2; exit 2; }
  echo "Running case: $case_file"
  echo "Artifacts:    $ARTIFACTS"
  inner="bash install_claude_code.sh </dev/null && bash tests/integration/cases/$case_file; $harvest"
else
  inner="bash install_claude_code.sh </dev/null && bash tests/integration/run.sh; $harvest"
fi

# MSYS_NO_PATHCONV stops Git Bash rewriting container-side paths into Windows
# ones; harmless on Linux and macOS, required on Windows.
MSYS_NO_PATHCONV=1 exec docker run --rm ${IXION_TEST_SHELL:+-it} \
  --env-file "$ENV_FILE_HOST" \
  -v "$REPO_ROOT_HOST:/work" -w /work \
  -v "$ARTIFACTS_HOST:/artifacts" \
  "$IMAGE" bash -lc "$inner"
