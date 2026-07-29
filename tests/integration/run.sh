#!/usr/bin/env bash
# Integration test runner.
#
# Usage:
#   bash tests/integration/run.sh                # run every cases/*.test.sh
#   bash tests/integration/run.sh plugin-loads   # run cases/00-plugin-loads*
#   bash tests/integration/run.sh fly-work       # run cases/*fly-work*
#
# These tests spawn real claude in real tmux against the local plugin.
# They make real Anthropic API calls. ANTHROPIC_API_KEY must be set.
#
# Cost / time discipline:
#   - 00-plugin-loads is a smoke test; cheap, ~30s.
#   - 01-fly-work and 02-fly-plan invoke real skills end-to-end.
#     Plan on 1-5 minutes per case and real token spend.
#
# Parallelism:
#   IXION_TEST_JOBS=N   run up to N cases concurrently (default 1 — serial).
#   Cases are already isolated: per-case mktemp sandboxes and unique tmux
#   session names. Parallel runs multiply concurrent API spend and rate-limit
#   pressure; N=2-3 is a sensible ceiling. Output is buffered per case to
#   tests/integration/.logs/<case>.log and printed sequentially at the end
#   of each batch so PASS/FAIL blocks never interleave.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CASES_DIR="$REPO_ROOT/tests/integration/cases"
filter="${1:-}"

# Pre-flight checks -----------------------------------------------------------
fail_pre=0
if ! command -v tmux >/dev/null 2>&1; then
  echo "ERROR: tmux not found in PATH" >&2; fail_pre=1
fi
if ! command -v claude >/dev/null 2>&1; then
  echo "ERROR: claude not found in PATH" >&2; fail_pre=1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not found in PATH (used by schema-validating cases)" >&2; fail_pre=1
fi
if ! command -v bunx >/dev/null 2>&1; then
  echo "ERROR: bunx not found in PATH (used to run ajv-cli)" >&2; fail_pre=1
fi
if ! command -v cargo >/dev/null 2>&1; then
  echo "ERROR: cargo not found in PATH (used to build and gate the Rust fixture in the chain case)" >&2; fail_pre=1
fi
# What the suite needs is a credential `claude` can authenticate with, not an API
# key specifically. Demanding ANTHROPIC_API_KEY locked out every Claude
# subscription user, who has no API key and would have to buy a second,
# pay-as-you-go billing path to run these at all.
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "ERROR: no Anthropic credential — these are real-API tests" >&2
  echo "  set ANTHROPIC_API_KEY, or CLAUDE_CODE_OAUTH_TOKEN from 'claude setup-token'" >&2
  fail_pre=1
fi
[ "$fail_pre" = "1" ] && exit 2

# Discover cases --------------------------------------------------------------
shopt -s nullglob
cases=("$CASES_DIR"/*.test.sh)
shopt -u nullglob

if [ ${#cases[@]} -eq 0 ]; then
  echo "No cases found in $CASES_DIR"; exit 1
fi

jobs="${IXION_TEST_JOBS:-1}"
LOG_DIR="$REPO_ROOT/tests/integration/.logs"

# Apply the filter up front so batching sees only the cases that will run.
selected=()
for case_file in "${cases[@]}"; do
  name="$(basename "$case_file" .test.sh)"
  if [ -n "$filter" ] && [[ "$name" != *"$filter"* ]]; then
    continue
  fi
  selected+=("$case_file")
done

run_count=${#selected[@]}
pass_count=0
fail_count=0

if [ "$jobs" -le 1 ]; then
  for case_file in "${selected[@]}"; do
    name="$(basename "$case_file" .test.sh)"
    echo "=========================================================="
    echo "RUN: $name"
    echo "=========================================================="
    if bash "$case_file"; then
      pass_count=$((pass_count + 1))
      echo "OK: $name"
    else
      fail_count=$((fail_count + 1))
      echo "FAIL: $name"
    fi
    echo ""
  done
else
  mkdir -p "$LOG_DIR"
  i=0
  while [ "$i" -lt "$run_count" ]; do
    batch=("${selected[@]:$i:$jobs}")
    pids=()
    names=()
    for case_file in "${batch[@]}"; do
      name="$(basename "$case_file" .test.sh)"
      names+=("$name")
      echo "LAUNCH: $name"
      bash "$case_file" > "$LOG_DIR/$name.log" 2>&1 &
      pids+=($!)
    done
    for j in "${!pids[@]}"; do
      name="${names[$j]}"
      if wait "${pids[$j]}"; then status=OK; pass_count=$((pass_count + 1)); else status=FAIL; fail_count=$((fail_count + 1)); fi
      echo "=========================================================="
      echo "RUN: $name"
      echo "=========================================================="
      cat "$LOG_DIR/$name.log"
      echo "$status: $name"
      echo ""
    done
    i=$((i + jobs))
  done
fi

echo "=========================================================="
echo "Cases: $run_count run, $pass_count passed, $fail_count failed."
echo "=========================================================="
[ "$fail_count" = "0" ] && exit 0 || exit 1
