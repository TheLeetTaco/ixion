# Spec Content Guidelines

Session ids, the session directory layout, the `active.json` pointer and the collision tiebreak live in `ixion/skills/ixion-conventions/references/session-handoff.md` — every skill in the pipeline resolves sessions from that file, so the format has one home rather than one per skill. Read it for the id you claim and the directory you write into; what follows is only about what goes *inside* `spec.json`.

## Repo-relative file paths

Every path inside `spec.json` is repo-relative (`src/auth.rs:42-55`), never absolute. The spec is checked against real code, and absolute paths rot the moment someone else opens the session.

## Test scenarios

Each task lists enumerable scenarios. A scenario is concrete enough that the implementer turns it directly into a test case. If you can't write one, the task is not ready — surface it as an `open_question` on the spec.
