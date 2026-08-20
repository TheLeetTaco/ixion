---
module: System
date: 2026-08-20
problem_type: mistake
component: development_workflow
symptoms:
  - "A harness passes on Windows and fails on Linux against the same commit"
  - "Section extraction reports 'no bash block under section X' for a heading that is plainly there"
  - "A skill improvises its own version of a mechanism instead of pasting the block it cites"
root_cause: environment_configuration
resolution_type: configuration_fix
severity: high
tags: [line-endings, gitattributes, cross-platform, test-harness, false-green]
---

# A CRLF checkout silently breaks every heading-matched section

## Symptom

`tests/branch-resolution-harness.sh` reported `89 passed, 0 failed` on Windows and, against the identical commit, `0 passed, 3 failed` inside the Linux test container:

```
FAIL: no bash block under section "Resolve the branch roles" in .../git-branches.md
FAIL: no bash block under section "Verify a recorded integration branch" in .../git-branches.md
FAIL: no bash block under section "Create or reuse the session worktree" in .../git-branches.md
```

The headings were present and correctly spelled. `session-resolution-harness.sh` failed differently in the same run — two citations reported as naming a heading `elegance.md` "does not have", and a lint reporting the schemas' own `$id` lines as stray citations.

## Root cause

`.gitattributes` pinned `*.sh` to LF, with a comment explaining that CRLF breaks shell scripts on Linux. Everything else fell under `* text=auto`, so a Windows checkout produced CRLF `.md` and `.json` files.

Every mechanism in this repo that finds a section **by exact heading title** then compares `## Resolve the branch roles` against `## Resolve the branch roles\r` and finds nothing. The same carriage return defeats a `$`-anchored regex, which is why the `$id` filter stopped filtering.

Three failures, three different-looking messages, one cause.

## Why it was invisible

`docker-run.sh` bind-mounts the Windows checkout into the container and installs the plugin from it, so the integration tests had been driving an agent through CRLF-laden skill markdown. When a skill cannot extract the block it cites, it does not error — **it reimplements the mechanism from the surrounding prose**, which is how a run produced `integration_branch: "origin/main"` and a worktree parked under `.worktrees/`.

The harnesses could not see any of this because they were only ever run on the authoring platform.

## Resolution

Extend the existing LF pin to the file types that are also executable content:

```gitattributes
*.md   text eol=lf
*.json text eol=lf
```

The attribute must be **committed before** refreshing the working tree, and the refresh needs the files removed first — git's stat cache treats them as unchanged otherwise:

```bash
git add .gitattributes && git commit -m "..."      # first, or the next step reverts it
git ls-files -z -- '*.md' '*.json' | xargs -0 rm -f
git checkout -- '*.md' '*.json'
```

After this, both platforms reported identically.

## The general lesson

A test suite that has only ever run on the platform it was written on is evidence about that platform, not about the software. Run it where it ships — here, one `docker run` against the same tree turned three green harnesses into two red ones and exposed a bug that had been corrupting every integration run.
