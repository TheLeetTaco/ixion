#!/usr/bin/env bash
# Guards the finding-synthesis extraction against the duplicates a de-duplication
# change is recorded as producing.
#
# docs/solutions/mistakes/dedup-change-spawns-new-duplicates-System-20260804.md
# records four recurrences of one mistake: a change that removes duplicated text
# grows fresh copies while the author's attention is on the old ones. Its fourth
# recurrence is the direct precedent for this file — that session's own checks
# confirmed every site cited the new reference and no site restated the catalog
# inline, and both passed while a freshly-authored rival shape sat uncaught
# wearing the new template's vocabulary.
#
# So this harness watches the two shapes those checks could not see:
#
#   1. A leftover or re-authored copy in ONE caller (gating). Fingerprint
#      sentences from the reference must occur exactly once under ixion/. A
#      caller-to-caller diff is blind to this — one copy is not a shared line.
#   2. Dead vocabulary (gating). The word `Deferred`, retired by this session's
#      first phase, must not come back. That phase verified its own removal
#      once; this runs on every future invocation.
#   3. One sentence grown in BOTH callers (advisory, never fails). The
#      reference's own prevention — "diff the callers against each other".
#      Uniqueness is blind to this, because neither copy is in the reference.
#
# What bounds this harness: check 1 compares a fixed, small, enumerated set of
# sentences taken from one file. It is not a general structural comparison of
# the callers against the reference, and widening it into a template
# conformance checker is out of scope — the shape a caller renders is a
# reviewer's judgment, not a string match.
#
# Each gating check is paired with synthetic fixtures proving it fires on a real
# offender and stays quiet on a lookalike, so absence is never reported as a
# pass. No API credential, no network, no tmux; runs in seconds.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REFERENCE="$ROOT/ixion/skills/ixion-conventions/references/finding-synthesis.md"
. "$ROOT/tests/integration/lib/assert.sh"

[ -f "$REFERENCE" ] || { note_fail "reference not found: $REFERENCE"; finalize; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ixion-synthesis-XXXXXX")
trap 'rm -rf "$WORK"' EXIT
FIXTURE="$WORK/fixture"
mkdir -p "$FIXTURE"

# --- check 1 (gating): no fingerprint sentence has a second home -------------

# One sentence per unit the extraction moved, chosen from the finished
# reference rather than named in advance: a sentence picked before the
# house-style rewrite could have been paraphrased away, and the check would then
# demand one occurrence of text that exists nowhere. The presence assertion
# below turns that into a loud selection error instead of a phantom duplicate.
FINGERPRINTS=$(cat <<'EOF'
construct a synthetic P1 against that reviewer's agent file noting the gap
a code review has no `phase-2/t1` to open, a plan review has no `src/auth.rs:42` anywhere in the spec
Severity is not promoted by corroboration; a P3 that three reviewers flagged is still a P3.
users sometimes deviate from best practice out of laziness, not principle
EOF
)

# occurrences <sentence> <path...> -> how many times it appears across those trees.
# -o rather than -l so a second copy inside one file counts too.
occurrences() {
  local sentence=$1
  shift
  grep -rFo -- "$sentence" "$@" | wc -l
}

while IFS= read -r sentence; do
  if [ "$(occurrences "$sentence" "$REFERENCE")" -eq 0 ]; then
    note_fail "fingerprint selection error, absent from the reference (reselect it from the current text): $sentence"
    continue
  fi

  found=$(occurrences "$sentence" "$ROOT/ixion")
  if [ "$found" -eq 1 ]; then
    note_pass "one home under ixion/: $sentence"
  else
    note_fail "$found copies under ixion/, expected 1: $sentence"
  fi

  printf '%s\n' "$sentence" > "$FIXTURE/second-copy.md"
  if [ "$(occurrences "$sentence" "$ROOT/ixion" "$FIXTURE")" -eq 2 ]; then
    note_pass "a planted second copy is counted: $sentence"
  else
    note_fail "a planted second copy went uncounted: $sentence"
  fi
  rm "$FIXTURE/second-copy.md"
done <<< "$FINGERPRINTS"

# A rewrite of the severity fingerprint that says the same thing in different
# words. The check must read it as prose that legitimately differs, not as a
# copy — otherwise it fires on every paraphrase in the repo.
severity_fingerprint=$(printf '%s\n' "$FINGERPRINTS" | grep '^Severity ')
printf 'Severity is never promoted by corroboration; a P3 that three reviewers flagged remains a P3.\n' \
  > "$FIXTURE/lookalike.md"
if [ "$(occurrences "$severity_fingerprint" "$ROOT/ixion" "$FIXTURE")" -eq 1 ]; then
  note_pass "a reworded sentence is not counted as a copy"
else
  note_fail "a reworded sentence was counted as a copy"
fi
rm "$FIXTURE/lookalike.md"

# --- check 2 (gating): the retired deferral vocabulary stays retired ---------

# Word-bounded and case-sensitive: `deferred` survives legitimately in the
# elegance catalog's Test Afterthought row and in `status: deferred`. Only the
# capitalized severity-tier spelling was retired.
deferrals() { grep -rnw Deferred "$1"; }

offenders=$(deferrals "$ROOT/ixion")
if [ -z "$offenders" ]; then
  note_pass "the retired \`Deferred\` tier appears nowhere under ixion/"
else
  note_fail "\`Deferred\` is back:
$offenders"
fi

printf -- '- **Deferred** — revisit after the MVP ships.\n' > "$FIXTURE/tier.md"
if [ -n "$(deferrals "$FIXTURE")" ]; then
  note_pass "a planted \`Deferred\` tier is caught"
else
  note_fail "a planted \`Deferred\` tier went unnoticed"
fi
rm "$FIXTURE/tier.md"

# --- check 3 (advisory): one sentence grown in both callers ------------------

# Deliberately not gating, and no later edit should make it so: both callers are
# SUPPOSED to share their citation lines, so a gating version would trip on
# correct work. The reader decides which shared line is prose that belongs in
# the reference and which is a citation doing its job.
#
# The recorded prevention diffs the callers over one change's added lines; this
# compares the files as they stand, because a harness that runs on every future
# invocation has no such change to diff against — and every added shared line is
# also a present shared line.
prose_lines() {
  sed 's/^[ \t]*//' "$1" | grep -vE '^(#|```)' | awk 'NF >= 8' | sort -u
}

echo ""
echo "ADVISORY — lines both review skills carry verbatim (this check never fails the harness):"
# The floor of eight words is where these files stop sharing structure and start
# sharing sentences: headings, tool names and JSON delimiters are shared by
# construction, because both files are the same kind of document.
comm -12 <(prose_lines "$ROOT/ixion/skills/plan-review/SKILL.md") \
         <(prose_lines "$ROOT/ixion/skills/work-review/SKILL.md") \
  | sed 's/^/  /'
echo "Report a shared line as a finding — an explanation both callers need belongs in the"
echo "reference they cite. Do not delete one side silently; a citation line is meant to be here."

finalize
