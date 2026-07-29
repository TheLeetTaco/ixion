---
module: System
date: 2026-07-29
problem_type: mistake
component: tooling
symptoms:
  - "Frontmatter key added to a file type where nothing reads it"
  - "Skill or agent declares a dependency it is never instructed to load"
  - "A pattern cited as 'the proven mechanism' proves nothing in its new location"
root_cause: wrong_api
resolution_type: workflow_improvement
severity: medium
tags: [frontmatter, conventions, wiring, skills, agents, opencode, installer]
---

# A wiring pattern copied by resemblance, without checking what consumes it

## Symptom

One change set out to make a shared standard (`language-standards`) reachable by the skills and agents that need it. The mechanism it copied was real and worked — in the place it was copied *from*. Two of the three places it was copied *to* got something inert:

1. `ixion/skills/plan-creation/SKILL.md` gained `skills: [language-standards]` in its frontmatter, cited in the spec as "the mechanism this repo already proved." Nothing in the repo reads that key on a `SKILL.md`.
2. `ixion/agents/reviewer-elegance.md` gained the same key — correct there — but not the body instruction that makes it fire. The file mentioned `language-standards` exactly once, at the frontmatter line. Every other reviewer mentioned it two to four times.

Both passed review at the spec stage. The exemplar genuinely does work: `reviewer-code-quality.md` pairs `skills: [ixion-conventions, language-standards]` at line 6 with an explicit "Before reviewing, load the `language-standards` skill" at line 67.

## Investigation

### Attempted (Failed)

1. Confirming the key was present in all the intended files. It was — `grep -l '^skills:'` returned every file the spec named. Presence was never the question.
2. Reasoning from the exemplar. `reviewer-code-quality` is a real, working instance of the pattern, and the new files resembled it closely. Resemblance is exactly what the check needs to look past.
3. Counting reviewers that declared the standard. All six did. The count hid that one of them declared it and was never told to act on it.

### Discovery

Grepping for the *consumer* rather than the declaration:

```bash
grep -rn 'skills' install_opencode.py install_claude_code.sh \
  ixion/.claude-plugin/plugin.json .github/workflows/validate.yml
```

`install_opencode.py` parses the key — and only for agents:

```python
# For agents: extract skills before stripping, inject into body
if transform_type == "agents":
    skills = extract_skills(fm_lines)
    body = skills_to_body_prefix(skills) + body
```

The transform table settles it. `TRANSFORMS["agents"]["remove"]` includes `"skills"` — the installer injects the key into the body *and then strips it*, because the body instruction is what the model actually reads. `TRANSFORMS["skills"]["remove"]` is only `["allowed-tools"]`, so on a `SKILL.md` the key is neither read nor removed: it rides into the output as dead frontmatter.

## Root Cause

The pattern's power was never in the frontmatter key. It was in the installer step that converts the key into a body instruction, plus (for the Claude Code target) an author-written instruction doing the same job by hand. Copying the *declaration* without the *conversion* copies the visible half of a two-part mechanism.

The second failure is the same shape one level down: on an agent, where the key genuinely is consumed, omitting the paired body instruction still leaves the load unanchored for the Claude Code target — which is why every other reviewer has both.

This is easy to miss precisely because the exemplar is correct. The check "does my new file look like the working one?" returns yes for both defects.

## Solution

### The rule

Before copying a declaration, wiring key, or frontmatter field into a new *kind* of file, find what reads it there. Not what reads it in the file you copied from.

```bash
# name the key, then hunt its consumer across every target and toolchain
grep -rn '<key>' install_*.* .github/workflows/ *.json
# and check whether the consumer is gated on file type
grep -n 'transform_type\|if .*type ==' install_opencode.py
```

If no consumer exists for that file type, the line is inert. Delete it, or record in a comment why it is there speculatively — an unexplained inert key reads as load-bearing to the next person.

### For this repo specifically

- `skills:` frontmatter is **agent-only**. A `SKILL.md` loads a shared reference through an inline instruction in its body, the way `work/SKILL.md:170` reads the Elegance Dispatch Bar.
- On an agent, `skills:` is necessary but not sufficient for the Claude Code target: pair it with an explicit body instruction naming the skill and the sections that matter, as `reviewer-code-quality.md:67` does.

### Verify by consumer count, not declaration count

```bash
# BAD - proves the declaration exists
grep -l '^skills:.*language-standards' ixion/agents/*.md | wc -l   # 6, looks uniform

# GOOD - proves each file also acts on it
for f in ixion/agents/reviewer-*.md; do
  printf '%-40s %s\n' "$(basename "$f")" "$(grep -c 'language-standards' "$f")"
done
# a file showing 1 has the declaration and no instruction
```

## Prevention

- When a spec calls something "the proven pattern," check what *makes* it work before reproducing it — proven in one file type is not proven in another.
- Grep for the consumer of a key, not for other files that declare it. Declarations copy; consumers do not.
- Watch for consumers gated on file type (`if transform_type == ...`). A gate like that is exactly where a pattern stops transferring.
- When a mechanism has two halves, assert on the *cheaper-to-forget* half. Frontmatter is easy to copy; the paired instruction is what gets dropped.
- A count of files declaring something is not evidence of uniform behavior. Count mentions per file; an outlier at 1 is a declaration nobody acts on.

## Related Issues

- `docs/solutions/mistakes/verification-gate-passes-on-unmodified-tree-System-20260729.md` — the other habit from the same session: an assertion that looks right and proves nothing. Both share a root shape — checking for a *resemblance* instead of the *mechanism*.

## Environment

- **Environment:** development
- **Repo:** Ixion plugin (`ixion/skills/`, `ixion/agents/`, `install_opencode.py`)
- **Shipped in:** `e1969c0` (key removed), `c5826e1` (missing instruction added)
- **Open question:** whether Claude Code itself honours `skills:` in `SKILL.md` frontmatter is unresolved — nothing in this repo settles it. The key was removed because nothing here consumes it; if the host runtime does, restore it *with a comment recording why*.
