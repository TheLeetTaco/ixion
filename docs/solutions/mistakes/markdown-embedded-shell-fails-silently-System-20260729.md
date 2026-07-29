---
module: System
date: 2026-07-29
problem_type: mistake
component: tooling
symptoms:
  - "A bash block in a skill consumes $VAR that no block ever assigns"
  - "Path expands to /session.json because the variable is empty"
  - "git log --grep on a commit trailer returns nothing, with no error"
root_cause: config_error
resolution_type: tooling_addition
severity: high
tags: [skill-authoring, bash, shell-state, git-trailer, silent-failure, markdown]
---

# Shell embedded in skill markdown fails silently, twice over

## Symptom

Two unrelated-looking defects with the same underlying cause — shell that lives in markdown is never executed while it is being written, so nothing catches it.

**1. Unassigned variable.** `ixion/skills/work/SKILL.md` referenced `$SESSION_DIR` six times and assigned it zero times:

```bash
git diff "$(jq -r .base_ref "$SESSION_DIR/session.json")"..HEAD
```

```
$ grep -rn "SESSION_DIR=" ixion/
(no matches)
$ bash -c 'unset SESSION_DIR; echo "[$SESSION_DIR/session.json]"'
[/session.json]
```

The path silently becomes `/session.json`, `jq` errors, and the diff runs against an empty ref — inside a step marked **BLOCKING**. It was fixed, and then the *fix pass itself* introduced the same defect in a new block, this time `$BASE_REF` in a step added after the sweep had already run.

**2. Indented commit trailer.** A recovery step looked commits up by trailer:

```bash
git log --format=%H --grep="^Ixion-Chunk: <chunk id>$" "$BASE_REF"..HEAD
```

Written as a second line of the same `-m`, inside an indented markdown code block, the trailer inherits that indentation and the anchored grep matches nothing — no error, just empty output feeding a path whose whole job is telling a lost record from lost work.

## Investigation

### Attempted (Failed)

1. Reading the blocks for correctness. Both read fine. `$SESSION_DIR` looks like a variable someone set earlier; the trailer looks like a trailer.
2. Assuming an earlier block's assignment carries forward. It does not — Claude Code Bash calls do not share shell state between invocations, so each fenced block starts clean. A block that reads `$VAR` set two steps up is as broken as one referencing a variable that never existed.
3. Fixing the instances found by review, and treating the class as closed. The second `$BASE_REF` instance appeared *after* that sweep, in code the sweep motivated.

### Discovery

Both were found by mechanical checks, not by reading:

```bash
# trailer: fold vs separate -m
git commit -m "goal
   Ixion-Chunk: phase-1"                      # indented
git log --grep='^Ixion-Chunk: phase-1$' | wc -l   # -> 0

git commit -m "goal" -m "Ixion-Chunk: phase-2"    # column zero
git log --grep='^Ixion-Chunk: phase-2$' | wc -l   # -> 1
```

## Root Cause

Skill markdown is documentation that happens to be executable by a downstream agent. Nothing runs it at authoring time: no shellcheck, no CI, no import. Every class of error that a real script would surface on first execution — unbound variables, quoting, whitespace significance — survives review here because the only reader is a human skimming prose.

The two instances share that cause but differ in mechanism:

- `$SESSION_DIR` / `$BASE_REF`: **shell state does not cross tool-call boundaries.** Each fenced block is its own process.
- Indented trailer: **markdown indentation is preserved into the commit message**, and git trailer conventions are column-sensitive.

Both fail *silently* — empty expansion and empty grep result, neither of which is an error.

## Solution

### Make every block self-contained

```bash
# BAD - assigned in a different fenced block
git log --grep="..." "$BASE_REF"..HEAD

# GOOD - resolves what it consumes
BASE_REF=$(jq -r .base_ref .ixion/plugin/sessions/<session-id>/session.json)
git log --grep="..." "$BASE_REF"..HEAD
```

### Give a trailer its own `-m`

```bash
# BAD - trailer inherits the code block's indentation
git commit -m "<goal>
   Ixion-Chunk: <id>"

# GOOD - lands at column zero
git commit -m "<goal>" -m "Ixion-Chunk: <id>"
```

### The durable artifact: a block scanner

Extract every ```bash block and diff the `$VAR` uses against the `VAR=` assignments in that same block:

```bash
node -e '
const fs=require("fs");
for (const f of process.argv.slice(1)) {
  const lines=fs.readFileSync(f,"utf8").split(/\r?\n/);
  let inb=false,blk=[],start=0;
  lines.forEach((l,i)=>{
    if(/^\s*```bash/.test(l)){inb=true;blk=[];start=i+1;return;}
    if(inb&&/^\s*```\s*$/.test(l)){
      const t=blk.join("\n");
      const used=new Set([...t.matchAll(/\$\{?([A-Z][A-Z0-9_]{2,})\}?/g)].map(m=>m[1]));
      const asgn=new Set([...t.matchAll(/^\s*([A-Z][A-Z0-9_]{2,})=/gm)].map(m=>m[1]));
      const env=new Set(["PWD","HOME","PATH","IFS","PIPESTATUS","TMPDIR","ARGUMENTS"]);
      const bad=[...used].filter(v=>!asgn.has(v)&&!env.has(v));
      if(bad.length) console.log(`${f}:${start}  consumes without assigning: ${bad.join(", ")}`);
      inb=false;return;
    }
    if(inb)blk.push(l);
  });
}' ixion/skills/*/SKILL.md
```

Angle-bracket placeholders (`<session-id>`) are safer than variables for values an agent substitutes — they cannot silently expand to empty.

## Prevention

- Run the block scanner after editing any skill's shell, and again after a fix pass — the second instance here was introduced by the fix for the first.
- Treat each fenced block as a fresh process. If it reads a variable, it assigns it.
- Prefer `<angle-bracket>` placeholders over `$VARS` for agent-substituted values.
- When a command's correctness depends on whitespace or column position (git trailers, heredocs, YAML), verify it in a scratch repo rather than reasoning about it.
- Be suspicious of any command whose failure mode is empty output rather than a non-zero exit.

## Related Issues

- `docs/solutions/mistakes/verification-gate-passes-on-unmodified-tree-System-20260729.md` — the same "nothing executes it at authoring time" blind spot, applied to the gates themselves.
- `docs/solutions/patterns/cross-invocation-state-needs-a-persisted-home-System-20260729.md` — why `$SESSION_DIR` existed at all.

## Environment

- **Environment:** development
- **Repo:** Ixion plugin (`ixion/skills/`)
- **Shipped in:** `ae14cdf`
