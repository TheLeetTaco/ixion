#!/usr/bin/env bash
# Offline proof of the two runnable blocks in language-standards: the advisory
# gate and the dependency-age lookup.
#
# Same shape as tests/session-resolution-harness.sh: each block is extracted
# from the skill by heading title and executed verbatim, so what is under test
# is the text chunks and plan-creation copy. Nothing real is reached. cargo,
# cargo-deny, cargo-audit and curl are shadowed by fakes first on PATH that log
# their argv, which is what lets a case assert *which* advisory tool ran rather
# than only what the block printed (docs/solutions/patterns/shadow-the-binary-
# instead-of-seaming-the-caller-System-20260820.md).
#
# python: the age block filters crates.io's JSON with a single-line python
# program, and the canned JSON is dated relative to now by one too. Without an
# interpreter the age cases report `SKIPPED:` — absence is never a pass.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SKILL="$ROOT/ixion/skills/language-standards/SKILL.md"
. "$ROOT/tests/integration/lib/assert.sh"
. "$ROOT/tests/integration/lib/section.sh"

GATE_BLOCK=$(section "$SKILL" "Advisory gate")
AGE_BLOCK=$(section "$SKILL" "Dependency Age")
[ -n "$GATE_BLOCK" ] || note_fail "no bash block under section \"Advisory gate\" in $SKILL"
[ -n "$AGE_BLOCK" ] || note_fail "no bash block under section \"Dependency Age\" in $SKILL"
[ "$fail" = 0 ] || finalize

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ixion-rust-gates-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

PY=
for py in python3 python; do "$py" -c '' 2>/dev/null && { PY=$py; break; }; done

# The case PATH carries none of the host's directories, only a wrapper per tool
# the blocks and fakes call, each exec'ing the host's copy by absolute path. A
# real cargo-audit beside curl or python cannot come along with them, so
# "absent" means absent whatever the host's PATH layout.
TOOLS="$WORK/tools"
mkdir "$TOOLS"
for tool in bash cat grep $PY; do
  printf '#!%s\nexec %q "$@"\n' "$BASH" "$(command -v "$tool")" > "$TOOLS/$tool"
  chmod +x "$TOOLS/$tool"
done

# stub <case dir> <name> <body> -> an executable fake on that case's PATH.
stub() {
  printf '#!/usr/bin/env bash\n%s\n' "$3" > "$1/bin/$2"
  chmod +x "$1/bin/$2"
}

# new_case <name> <binaries...> -> a crate dir whose bin/ holds cargo (which
# dispatches `cargo <sub>` to cargo-<sub>, as the real one does) plus the
# named fakes. Every fake appends its argv to calls.
new_case() {
  local dir="$WORK/$1" bin
  shift
  mkdir -p "$dir/bin"
  : > "$dir/calls"
  stub "$dir" cargo 'exec "cargo-$1" "$@"'
  for bin in "$@"; do
    case $bin in
      cargo-deny)  stub "$dir" cargo-deny 'echo "deny $*" >> "$CALLS"; exit "${DENY_EXIT:-0}"' ;;
      cargo-audit) stub "$dir" cargo-audit 'echo "audit $*" >> "$CALLS"' ;;
      curl)        stub "$dir" curl 'echo "curl $*" >> "$CALLS"; [ -z "${CURL_FAIL:-}" ] || exit 22; cat "$VERSIONS"' ;;
    esac
  done
  printf '%s\n' "$dir"
}

# run <case dir> <block> -> OUT, RC and CALLS for that run.
run() {
  OUT=$(cd "$1" && printf '%s\n' "$2" | PATH="$1/bin:$TOOLS" CALLS="$1/calls" VERSIONS="$1/versions.json" bash 2>&1)
  RC=$?
  CALLS=$(cat "$1/calls")
}

ran() { printf '%s\n' "$CALLS" | grep -c "^$1 "; }

expect() {
  if [ "$2" = "$3" ]; then note_pass "$1"; else note_fail "$1 (expected '$3', got '$2')"; fi
}

# matches <label> <value> <glob>
matches() {
  case $2 in $3) note_pass "$1" ;; *) note_fail "$1 (got '$2')" ;; esac
}

ADVISORIES='[advisories]
ignore = []'
LICENSES_ONLY='[licenses]
allow = ["MIT"]'

# --- advisory gate -----------------------------------------------------------

dir=$(new_case deny-configured cargo-deny cargo-audit)
printf '%s\n' "$ADVISORIES" > "$dir/deny.toml"
run "$dir" "$GATE_BLOCK"
expect "deny.toml with [advisories]: cargo deny ran" "$(ran deny)" 1
expect "deny.toml with [advisories]: cargo audit did not run" "$(ran audit)" 0
expect "deny.toml with [advisories]: cargo deny checks advisories only" "$CALLS" "deny deny check advisories"
matches "deny.toml with [advisories]: output names cargo deny" "$OUT" '*cargo deny*'

dir=$(new_case deny-without-advisories cargo-deny cargo-audit)
printf '%s\n' "$LICENSES_ONLY" > "$dir/deny.toml"
run "$dir" "$GATE_BLOCK"
expect "deny.toml without [advisories]: cargo audit ran" "$(ran audit)" 1
expect "deny.toml without [advisories]: cargo deny did not run" "$(ran deny)" 0

dir=$(new_case no-deny-toml cargo-deny cargo-audit)
run "$dir" "$GATE_BLOCK"
expect "no deny.toml: cargo audit ran" "$(ran audit)" 1
matches "no deny.toml: output names cargo audit" "$OUT" '*cargo audit*'

dir=$(new_case deny-missing cargo-audit)
printf '%s\n' "$ADVISORIES" > "$dir/deny.toml"
run "$dir" "$GATE_BLOCK"
expect "[advisories] but no cargo-deny: cargo audit ran" "$(ran audit)" 1
matches "[advisories] but no cargo-deny: the skipped deny gate is named" "$OUT" '*SKIPPED: cargo-deny not installed*'

dir=$(new_case neither)
printf '%s\n' "$ADVISORIES" > "$dir/deny.toml"
run "$dir" "$GATE_BLOCK"
matches "neither binary: no advisory gate ran" "$OUT" 'SKIPPED: no advisory gate installed'
expect "neither binary: exit 0" "$RC" 0

dir=$(new_case deny-violation cargo-deny cargo-audit)
printf '%s\n' "$ADVISORIES" > "$dir/deny.toml"
DENY_EXIT=1 run "$dir" "$GATE_BLOCK"
[ "$RC" != 0 ] && note_pass "cargo deny failing fresh and cached: the gate fails" \
  || note_fail "cargo deny failing fresh and cached: the gate fails (exit $RC)"
expect "cargo deny failing fresh: the cached-database retry ran" "$(ran deny)" 2
expect "cargo deny failing fresh: the retry checks advisories only" "$(printf '%s
' "$CALLS" | tail -1)" "deny deny check advisories --disable-fetch"

# --- dependency age ----------------------------------------------------------

# age <case> <requirement> <num:days-ago[:yanked]...> -> runs the age block for
# crate "demo" against canned versions dated relative to now. NEXT_PAGE, when
# set, is the page's meta.next_page: crates.io's sign that older releases exist.
age() {
  local name=$1 req=$2 block dir
  shift 2
  dir=$(new_case "age-$name" curl)
  "$PY" -c 'import datetime, json, os, sys; now = datetime.datetime.now(datetime.timezone.utc); print(json.dumps({"versions": [{"num": n, "created_at": (now - datetime.timedelta(days=int(d))).strftime("%Y-%m-%dT%H:%M:%S.%fZ"), "yanked": y == "yanked"} for n, d, y in ((s + "::").split(":")[:3] for s in sys.argv[1:])], "meta": {"next_page": os.environ.get("NEXT_PAGE")}}))' "$@" \
    > "$dir/versions.json"
  block=$(printf '%s\n' "$AGE_BLOCK" | sed "s|<the crate name>|demo|; s|<the current requirement, e.g. 1.4; empty when adding the dependency>|$req|")
  run "$dir" "$block"
}

if [ -z "$PY" ]; then
  echo "SKIPPED: the dependency-age block needs python, and none is installed"
else
  age new "" 2.0.0-rc.1:20 1.5.0:3 1.4.3:30:yanked 1.4.2:20 1.4.1:30:yanked
  matches "age: newest non-yanked, non-pre-release release at least 14 days old" "$OUT" 'demo@1.4.2 *'
  expect "age: output is one line" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" 1
  matches "age: the lookup is bounded by per_page" "$CALLS" '*per_page=*'
  case $CALLS in *@*) note_fail "age: the request carries no email address (curl argv '$CALLS')" ;;
    *) note_pass "age: the request carries no email address" ;; esac

  age bump 1 2.1.0:30 1.5.0:3 1.4.2:20
  matches "age: a bump stays inside the current requirement" "$OUT" 'demo@1.4.2 *'

  age tilde '~1.4' 1.5.0:20 1.4.2:20
  matches "age: a tilde requirement holds the minor" "$OUT" 'demo@1.4.2 *'

  age range '>=1.2, <1.5' 1.4.2:20
  expect "age: a requirement it cannot honour exits 4, not a traceback" "$RC" 4

  NEXT_PAGE='?per_page=100&seek=older' age truncated 1 2.1.0:30 2.0.0:30
  expect "age: nothing eligible on a page with older releases behind it exits 5" "$RC" 5
  matches "age: a truncated page names the next page to fetch" "$OUT" '*next page: ?per_page=100&seek=older*'

  age too-young "" 1.5.0:3 1.4.2:13
  none=$RC
  CURL_FAIL=1 age lookup-failed "" 1.4.2:20
  failed=$RC
  [ "$none" != 0 ] && [ "$failed" != 0 ] && [ "$none" != "$failed" ] \
    && note_pass "age: no eligible version and a failed lookup exit non-zero with distinct codes" \
    || note_fail "age: no eligible version and a failed lookup exit non-zero with distinct codes (got $none and $failed)"
fi

finalize
