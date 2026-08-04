# Branch roles (shared by work, work-review and ship)

One resolution block and three error states that `work`, `work-review` and `ship` all use. Modifying branch-resolution behavior means editing this file — the callers hold only their scope-specific tails (when to branch, what to measure a diff against, what a PR targets).

A caller consumes a section by reading its text and issuing it as the caller's own Bash call. There is no cross-file source mechanism in this pipeline and this path is not executable — pasting the block *is* the mechanism. Each block assigns every variable it reads, because Claude Code Bash calls share no shell state, and each block prints what it resolved: printed output is the only thing that survives from one call to the next.

## The two roles

The **protected set** is the branches a session must never commit onto — production and integration together. The **integration branch** is the single branch to create the session branch from, measure `base_ref` against, and target with a PR.

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

## Error states

Three conditions decided here so no caller re-decides them.

### Probe the working tree

```bash
DIRTY=$(git status --porcelain -- ':(top,exclude).ixion')
if [ -n "$DIRTY" ]; then
  printf 'tree=dirty\n%s\n' "$DIRTY"
else
  printf 'tree=clean\n'
fi
```

`--porcelain` reports modified, staged and untracked entries alike. Only the tracked ones would actually be overwritten by a switch — untracked files ride across untouched — but an untracked file still means the user has work in flight, and this probe is the last moment before the session starts committing, so it counts too.

The pathspec carves out the one exception. Ixion writes its own session state into the user's repo at `.ixion/`, so in a repo that doesn't gitignore that path the probe would report dirty on Ixion's own bookkeeping and no session in a two-branch repo could ever start. `:(top,exclude)` is anchored at the repo root, so the carve-out holds from any subdirectory a caller runs in. Excluding it here is what stops each caller re-deciding whether the tool's own state counts as the user's uncommitted work.

On `tree=dirty`, name the files and stop so the user can commit or stash them. Never switch, never stash, never clean — the tree may hold work unrelated to this session, and the `## Constraints` prohibition on destructive git commands applies here exactly as it does inside a dispatch. Stopping is the whole handling: falling through to branch from production instead would record a `base_ref` against production and reproduce, for those sessions, the stale-base bug this file exists to remove.

### Detached HEAD

`current=` comes back empty from the resolution block, because `git branch --show-current` prints nothing when HEAD is detached. `git rev-parse --abbrev-ref HEAD` prints the literal string `HEAD` there instead, which is why the block uses the former and why no caller ever compares a branch name against `HEAD`. `on_protected` is `no`, but that is not permission to proceed: refuse the automatic switch and surface the state. A commit made on a detached HEAD is reachable from no ref, so switching away strands it even though the tree reports clean.

### Verify a recorded integration branch

```bash
RECORDED_INTEGRATION="<integration_branch recorded in session.json>"
if git show-ref --verify --quiet "refs/heads/$RECORDED_INTEGRATION" || git show-ref --verify --quiet "refs/remotes/origin/$RECORDED_INTEGRATION"; then
  printf 'recorded=usable\nintegration=%s\n' "$RECORDED_INTEGRATION"
else
  printf 'recorded=stale\n'
fi
```

`base_ref` is an immutable commit id and needs no such check; `integration_branch` is a mutable ref name, and an integration branch merged and deleted between `work` and `ship` is an ordinary outcome rather than a corruption. `recorded=stale` means fall through to fresh resolution instead of handing a dead ref to `gh`.

### Switch to the integration branch

```bash
git switch "<integration branch>"
```

Run this only after the tree probes clean and `current=` is non-empty. `git switch` never reads its argument as a pathspec, so a repo containing a directory named `dev` still switches branches; `git checkout` is ambiguous there, which is why no branch operation in this pipeline uses it.
