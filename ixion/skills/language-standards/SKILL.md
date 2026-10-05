---
name: language-standards
description: Rust standards and idioms. Load when reviewing, implementing, or debugging code to apply the language's conventions.
user-invocable: false
---

# Rust Language Standards

Bolded names below (**Clone to Satisfy Borrowck**, **Shallow Wrapper**, ...) are catalog entries in `ixion-conventions/references/elegance.md`. Lead findings with those names; they are defined there, not here.

## Ownership & API Design

- Accept borrows, return owned: `&str` over `String`, `&[T]` over `Vec<T>` in signatures
- A `.clone()` added to silence the borrow checker is fighting the grain — **Clone to Satisfy Borrowck**. Restructure ownership instead.
- Take the least-powerful receiver that works: `&self` over `&mut self` over `self`
- Accept `impl AsRef<Path>` / `impl Into<String>` at ergonomic boundaries, concrete types internally
- Return `impl Trait` or concrete types; `Box<dyn Trait>` only when dynamism is the point

## Error Handling

- Libraries: `thiserror` enums callers can match on. Binaries: `anyhow` with `.context(...)` at each fallible boundary.
- `Result<T, String>` or `Box<dyn Error>` in a library API is **Stringly-Typed Errors**
- No `unwrap()`/`expect()` outside tests; where infallibility is provable, `expect("why this cannot fail")`
- `?` over `match` for propagation — match only to handle variants differently

## Type-Driven Design

- Newtypes carry an invariant enforced at construction; a newtype with no invariant is a **Shallow Wrapper**
- Make invalid states unrepresentable: an enum of valid shapes over a struct of optionals; a builder with many interacting options is **Config Soup**
- Enums over boolean flags — `Mode::DryRun` reads at the call site, `true` does not
- Parse, don't validate: convert unstructured input to a typed value once, at the boundary

## Idiomatic Patterns

- Iterator chains over index loops; break a chain past ~4 combinators into named `let` steps
- `From`/`TryFrom` for conversions, not ad-hoc `to_x()` methods
- `impl Trait` in argument and return position; named generics when the caller must name the type
- Derive, don't hand-write: `Debug`, `Clone`, `PartialEq`, `Default` where semantics are the default ones

## Concurrency

- `Send`/`Sync` bounds explicit at API boundaries — don't let auto-traits silently define the contract
- No blocking in async: no `std::fs`, sync channel recv, or long-held sync locks inside `async fn`
- `spawn_blocking` for CPU-bound work
- A guard held over an await point is **MutexGuard Across .await**
- Shared mutability via `Rc<RefCell<T>>` usually papers over an ownership cycle — **Rc\<RefCell\<T\>\> Masking a Design Cycle**

## Testing

- Unit tests in `#[cfg(test)] mod tests` beside the code; integration tests in `tests/`
- Tests return `Result` and use `?` — over `#[should_panic]` and unwrap ladders
- Doc examples compile and run under `cargo test`; keep them true
- Test through the public API; a private fn that needs its own tests may want to be a module

## Tooling Gates

Each gate names the tier it runs at: **per-chunk** (a subagent, file-scoped, mid-implementation), **per-phase** (the orchestrator, after a wave), **session** (the orchestrator, once at the end).

A gate whose binary is missing skips loudly rather than failing the phase, and that skip path fires on every non-Rust repo, so routine `SKIPPED:` lines are expected rather than gate flakiness.

- `cargo check --locked` — per-chunk. `--locked` exits 0 when `Cargo.lock` is present and current and refuses clearly when it would have to write one, so a verification run cannot silently resolve a different dependency graph than the one reviewed; it also refuses in a repo with no committed lockfile, normal for a library crate, where these gates do not apply.
- `cargo clippy --all-targets --locked -- -D warnings`, taking `--all-features` as well on a crate that declares features — per-phase. No `#[allow]` without a one-line justification. Without `--all-targets` a violation in a test or example is never reported. `--all-features` is what makes feature-gated code visible to the lint pass and is exactly nothing on a crate whose `Cargo.toml` has no `[features]` table, so a spec that omits it there is right rather than sloppy. Carrying it unconditionally also cancels the scoping on the two `cargo check` runs below: clippy compiles, so an always-on `--all-features` here has already paid the cost those two are restricted to avoid.
- `cargo fmt --check` — per-phase. Do not add `--all`: measured on a two-member workspace, `cargo fmt` already flags every member from any working directory (rustfmt #2488), so the flag would be ceremony.
- `cargo test --locked` — per-phase; includes doc-tests. Do not add `--all-targets` here — it silently drops the `Doc-tests` runner (cargo #11015, #6669); `cargo test --doc` is the companion when you want doc-tests alone.
- `cargo check --all-features --locked` and `cargo check --no-default-features --locked` — per-phase, but only on a crate that declares features, and there only on the final phase and on any phase whose `files[]` includes `Cargo.toml` or a feature-gated module: each feature set defeats the build cache, so running both unconditionally costs about four compilations per phase, roughly forty on a ten-phase spec. `--all-features` catches code rotting behind a feature nobody enables by default; `--no-default-features` catches code that only compiles because a default feature happened to be on.
- The **Advisory gate** block below — session, because the fetch is networked and per-phase would make every phase network-dependent. It runs `cargo deny check` only when `deny.toml` declares an `[advisories]` table, because that table is the project saying deny owns advisories, and without a policy file deny fails correct work (measured: cargo-deny 0.19.6 exits 4, `licenses FAILED`, on a freshly generated crate); otherwise `cargo audit` runs, never both, so one ignore list governs. It decides when it runs rather than when the spec is written, since a phase of the same spec may create `deny.toml`. Each tool checks fresh advisories and falls back to the cached database only when the fetch fails; unconditional `--stale` would report clean against a frozen advisory set indefinitely, and `--disable-fetch` with no cached database exits 1 rather than passing against nothing.
- `cargo machete --with-metadata` — session, because it is noisy enough that repeating it per wave trains the reader to ignore it. Finds unused dependencies; `--with-metadata` cuts false positives. (`cargo udeps` rejected: nightly-only.)

Never, at any tier: MSRV checks, coverage thresholds, benchmarks, cross-compilation — CI's job, not a wave's; **CI Baseline** below says what that job runs.

### Advisory gate

```bash
DENY_ADVISORIES=$(grep -s '^\[advisories\]' deny.toml)
if [ -n "$DENY_ADVISORIES" ] && command -v cargo-deny >/dev/null 2>&1; then
  echo "advisories: cargo deny"
  cargo deny check || cargo deny check --disable-fetch
elif command -v cargo-audit >/dev/null 2>&1; then
  [ -z "$DENY_ADVISORIES" ] || echo "SKIPPED: cargo-deny not installed; deny.toml asks for it"
  echo "advisories: cargo audit"
  cargo audit || cargo audit --stale
else
  echo "SKIPPED: no advisory gate installed"
fi
```

Record its output verbatim: the first line names which tool ran, and `SKIPPED:` is the only thing telling a skip from a pass.

## Dependency Age

Applies when a chunk adds or bumps a direct dependency, in `Cargo.toml` or in `Cargo.lock` alone (`cargo update -p` changes only the lock). Never tree-wide: transitive freshness is the dependency bot's job under **CI Baseline**. Lock the newest stable, non-yanked release published at least 14 days ago, because malicious releases are mostly caught and yanked within days and the cooldown lets that happen before you install one. A bump must also satisfy the current requirement; a new major version is outside this rule.

```bash
for PY in python3 python; do "$PY" -c '' 2>/dev/null && break; done
NAME='<the crate name>'
REQ='<the current requirement, e.g. 1.4; empty when adding the dependency>'
curl -fsS --retry 1 -A 'ixion-dependency-age (https://github.com/TheLeetTaco/ixion)' "https://crates.io/api/v1/crates/$NAME/versions?per_page=100" \
  | "$PY" -c 'import datetime, json, sys; name, req = sys.argv[1:3]; num = lambda s: tuple(map(int, s.split("+")[0].split("."))); cut = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=14)).strftime("%Y-%m-%dT%H:%M:%S"); floor = num(req.lstrip("^~= ")) if req else (); major = floor[:next((i + 1 for i, x in enumerate(floor) if x), len(floor))]; versions = json.loads(sys.stdin.read() or "{}").get("versions") or sys.exit(2); ok = [v for v in versions if not v["yanked"] and "-" not in v["num"] and v["created_at"] <= cut and num(v["num"])[:len(major)] == major and num(v["num"]) >= floor] or sys.exit(3); best = max(ok, key=lambda v: num(v["num"])); print(name + "@" + best["num"], best["created_at"])' "$NAME" "$REQ"
```

It prints one line, `name@version created_at`. Exit 3 means no release qualifies; exit 2 means the lookup failed, with curl's reason on stderr (`--retry 1` covers one 429 or 5xx). crates.io refuses a request with no User-Agent; keep it naming the tool, never a person or an email.

Pin what it printed:

- `cargo add <name>@<version>`, or set a bumped requirement to `<version>`, then `cargo update -p <name> --precise <version>`. A requirement is only a floor — Cargo resolves it to the newest compatible release, which is the one the cooldown rejected. An exact `@=<version>` requirement is for binaries only; in a library it forces that version on every dependent.
- Confirm `Cargo.lock` carries exactly `<version>` and `git diff Cargo.lock` adds only the crate and its new transitive dependencies, then commit `Cargo.lock` with the change.

A younger release is allowed only when the **Advisory gate** reports an advisory against the locked version and the release falls inside that advisory's patched range as the tool printed it. If no release satisfies both, or the lookup fails while the advisory stands, stop and report it unresolved rather than choosing. A lookup failure with no advisory keeps the locked version on a bump; a new dependency is added and reported `age unverified`.

The chunk's return carries, per dependency, the printed line, `age unverified`, or the advisory id that licensed a younger release. Cargo's `registry.global-min-publish-age` replaces this lookup once it leaves nightly (`-Zmin-publish-age`).

## CI Baseline

Applies when a spec or diff creates or edits CI config in a Rust project: `.github/workflows/`, `.github/dependabot.yml` or `renovate.json`. The pipeline runs:

- `cargo fmt --check` and `cargo clippy --all-targets --locked -- -D warnings`
- `cargo llvm-cov --locked --fail-under-lines 80` as the test step (tarpaulin if the project already uses it), plus `cargo test --doc --locked` for the doc-tests llvm-cov skips
- cargo-deny when `deny.toml` declares `[advisories]` — the **Advisory gate**'s condition
- a scheduled advisory audit, so advisories published against unchanged code still surface
- Renovate `minimumReleaseAge` or Dependabot `cooldown` at 14 days, covering `github-actions` too — the tree-wide half of **Dependency Age**

80% and 14 days are defaults, not questions; the user's explicit choices override any item. The workflow and bot config to copy are in `references/ci-baseline.md`.

## Anti-Patterns to Flag

- `.collect::<Vec<_>>()` mid-chain only to iterate again — stay lazy
- `clone()` in hot loops; `String` concatenation in loops (build once with `join` or `write!`)
- Unbuffered file/stdout I/O in loops — `BufReader`/`BufWriter`
- `as` casts where `From`/`TryFrom` exists — silent truncation
- `pub` fields on types with invariants
- Accidental `Copy` derive on large types — every move becomes a memcpy
- Structural failures lead with the catalog name: **Clone to Satisfy Borrowck**, **Stringly-Typed Errors**, **Rc\<RefCell\<T\>\> Masking a Design Cycle**, **MutexGuard Across .await**

## Debugging Checklist

When investigating Rust issues, check:
- A returned borrow pinning `&mut self` — lifetimes surprising callers
- A `MutexGuard` (or any guard) held across an `.await` — deadlocks under load
- Accidental `Copy` on large types masking unintended duplication
- Integer `as` casts truncating silently
- `Ordering::Relaxed` where acquire/release is needed
- A blocking call inside async starving the runtime
