# Branch roles (shared by work, work-review and ship)

One resolution block, three error states, and the command that cuts a session's worktree off the integration branch — all used by `work`, `work-review` and `ship`. Modifying branch-resolution behavior means editing this file — the callers hold only their scope-specific tails (when to branch, what to measure a diff against, what a ship merges into).

A caller consumes a section by reading its text and issuing it as the caller's own Bash call. There is no cross-file source mechanism in this pipeline and this path is not executable — pasting the block *is* the mechanism. Each block assigns every variable it reads, because Claude Code Bash calls share no shell state, and each block prints what it resolved: printed output is the only thing that survives from one call to the next.

Callers cite several sections apiece; read this file once per invocation and hold the blocks, rather than re-reading at each citation. A resolved name spliced back into a later block goes inside single quotes — the ladder's last rung returns whatever branch name the repo happens to carry, and single quotes are what keep a backtick in one from running.

## The two roles

The **protected set** is the branches a session must never commit onto — production and integration together. The **integration branch** is the single branch to create the session branch from, measure `base_ref` against, and merge back into.

One value cannot serve both. Where `main` is production and `develop` is integration, a lone default-branch value resolves to `main`: `work` started on `develop` finds no match and never branches, so every checkpoint commit lands on the shared integration branch, and `base_ref` becomes `merge-base(develop, main)` — under git-flow the last release — so every downstream diff spans the release instead of the session. Both halves of that bug come from collapsing two answers into one variable.

## Resolve the branch roles

```bash
PRODUCTION_BRANCH=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
if [ -z "$PRODUCTION_BRANCH" ] && git show-ref --verify --quiet refs/heads/main; then PRODUCTION_BRANCH=main; fi
if [ -z "$PRODUCTION_BRANCH" ] && git show-ref --verify --quiet refs/heads/master; then PRODUCTION_BRANCH=master; fi
if [ -z "$PRODUCTION_BRANCH" ]; then PRODUCTION_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null); fi

if git show-ref --verify --quiet refs/heads/dev || git show-ref --verify --quiet refs/remotes/origin/dev; then
  INTEGRATION_BRANCH=dev
elif git show-ref --verify --quiet refs/heads/develop || git show-ref --verify --quiet refs/remotes/origin/develop; then
  INTEGRATION_BRANCH=develop
else
  INTEGRATION_BRANCH="$PRODUCTION_BRANCH"
fi

PROTECTED_BRANCHES="$PRODUCTION_BRANCH"
[ "$INTEGRATION_BRANCH" = "$PRODUCTION_BRANCH" ] || PROTECTED_BRANCHES="$PRODUCTION_BRANCH $INTEGRATION_BRANCH"

CURRENT_BRANCH=$(git branch --show-current)
ON_PROTECTED=no
for branch in $PROTECTED_BRANCHES; do
  [ "$branch" = "$CURRENT_BRANCH" ] && ON_PROTECTED=yes
done

printf 'production=%s\nintegration=%s\nprotected=%s\ncurrent=%s\non_protected=%s\n' \
  "$PRODUCTION_BRANCH" "$INTEGRATION_BRANCH" "$PROTECTED_BRANCHES" "$CURRENT_BRANCH" "$ON_PROTECTED"
```

Production resolves down a four-rung ladder: `refs/remotes/origin/HEAD`, then a local `main`, then a local `master`, then whatever branch HEAD points at. The last rung is what makes a repo whose default branch is `trunk` — or anything else a team chose — resolve at all; it comes back empty only on a detached HEAD, which is the error state below.

`dev` is probed before `develop`, and local before remote-tracking for each. The precedence is a documented choice, not an accident of ordering: the feature was asked for in terms of `dev`, so `dev` wins in a repo carrying both. A repo with neither has no distinct integration branch — integration is production, the protected set collapses to one entry, and every single-branch repo behaves exactly as it did before this file existed.

Resolution reads local refs only. Do not fetch or pull first: that turns a local branch decision into a network operation with its own failure modes and silently moves the base the session is measured from.

## Create or reuse the session worktree

Every session gets a worktree of its own, branched from the integration branch at the path `session-handoff.md`'s "Derive the session worktree" block computes.

```bash
SLUG='<slug= from the "Derive the session worktree" block>'
WORKTREE='<worktree= from that same block>'
INTEGRATION='<integration= from the branch-roles block>'

git worktree add -b "$SLUG" "$WORKTREE" "$INTEGRATION"
BRANCH=absent
[ -d "$WORKTREE" ] && BRANCH=$(git -C "$WORKTREE" branch --show-current)
printf 'worktree=%s\nbranch=%s\n' "$WORKTREE" "$BRANCH"
```

`branch=` equal to `slug=` means the worktree is this session's and the session continues inside it — whether this call created it or found it already there. That covers a resumed session and a concurrent claim with one answer, and it is why the `add` is issued before anything is probed: git permits a branch to be checked out in at most one worktree at a time, so two invocations racing to start one session collide on the branch name and exactly one of them wins. The loser reads `branch=` and reuses. A read-then-create on a shared record would leave a window between the two where both invocations believe they won.

Anything else is a failure to surface with git's own message, which the `add` has already printed: `branch=absent` where the integration ref does not exist or the parent directory is unwritable, and a branch name that is not the slug where the path is somebody else's checkout.

The `add` passes an explicit start point, so nothing is checked out or switched in the checkout the skill was invoked from. That tree is never touched, which is why a session can start while it is dirty.

Every worktree pays for its own dependency install and build output — `node_modules`, `target/`, a virtualenv — and under unconditional worktrees every session pays it rather than only the large ones. Remind the user to install dependencies in the new tree.

## Error states

Three conditions decided here so no caller re-decides them.

### Detached HEAD

An empty `current=` is a detached HEAD: stop and surface it. It costs each caller something different and both are silent. `ship` reads `on_protected=`, which is `no` there — nothing matched, because there is no branch name to match — and taking that as "already on a feature branch, carry on" commits onto a HEAD reachable from no ref, which the next switch strands. `work` reads `integration=`, and the production ladder's last rung is the same `symbolic-ref` that just came back empty, so there is no start point to branch a worktree from.

`git branch --show-current` prints nothing when HEAD is detached, which is why the block uses it over `git rev-parse --abbrev-ref HEAD`; that one prints the literal string `HEAD`, and no caller ever compares a branch name against `HEAD`.

### Verify a recorded integration branch

```bash
RECORDED_INTEGRATION='<integration_branch recorded in session.json>'
if git show-ref --verify --quiet "refs/heads/$RECORDED_INTEGRATION" || git show-ref --verify --quiet "refs/remotes/origin/$RECORDED_INTEGRATION"; then
  printf 'recorded=usable\nintegration=%s\n' "$RECORDED_INTEGRATION"
else
  printf 'recorded=stale\n'
fi
```

`base_ref` is an immutable commit id and needs no such check; `integration_branch` is a mutable ref name, and an integration branch merged and deleted between `work` and `ship` is an ordinary outcome rather than a corruption. `recorded=stale` means fall through to fresh resolution instead of merging into a branch that is no longer there.

### Integration branch checked out in another worktree

Git permits a branch to be checked out in at most one worktree, so the merge that ends a session cannot simply switch to the integration branch wherever the caller happens to be standing. `ship` issues its merge against the main checkout — `git -C "$REPO_ROOT"`, the one tree that is not a session's — and that is enough whenever the integration branch is either unoccupied or already checked out there.

It is not enough when some other worktree holds it — one the user added themselves to keep the integration branch under an eye while a session runs. The switch then fails with git's own message:

```
fatal: 'dev' is already used by worktree at '/path/to/that/worktree'
```

Stop there and surface that path. Nothing has been merged yet, so there is nothing to unwind: the user finishes or removes the named worktree and re-runs. Do not merge into a substitute branch, and do not remove somebody else's worktree to clear the way.

