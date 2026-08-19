# The two JSON reads the cases make, and the one interpreter that makes them.
#
# They live here for the reason ixion/skills/ixion-conventions/references/session-handoff.md
# gives for citing its field idioms rather than restating them: five case files
# each spelling their own read is how a suite ends up with five spellings of it.
# The interpreter probe is that reference's, verbatim — `python3` first,
# `python` second, each asked to run an empty program before it is trusted.
#
# Both reads are silent about an unreadable file, because every caller polls an
# artifact a live agent is still writing: `null` and no lines are what "not
# written yet" looks like from the outside, and the loops are built to keep
# waiting on exactly that.
for PY in python3 python; do "$PY" -c '' 2>/dev/null && break; done

# json_field <file> <top-level key> — the field's value, or the four characters
# `null` when the key is absent, its value is JSON null, or the file does not
# parse. That is the spelling the reference fixed and every reader compares
# against.
json_field() {
  "$PY" -c 'import json, sys; value = json.load(open(sys.argv[1])).get(sys.argv[2]); print("null" if value is None else value)' \
    "$1" "$2" 2>/dev/null || echo null
}

# json_lines <file> <python expression over the parsed document `doc`> — each
# item the expression yields on its own line, so `grep` and `wc` do the matching
# and counting that a query language would fold into the query itself. The
# expression is evaluated because it is a literal in this suite's own source;
# the alternative is inventing a path mini-language, which is a query language
# again.
json_lines() {
  "$PY" -c 'import json, sys; doc = json.load(open(sys.argv[1])); sys.stdout.writelines(f"{item}\n" for item in eval(sys.argv[2]))' \
    "$1" "$2" 2>/dev/null
}
