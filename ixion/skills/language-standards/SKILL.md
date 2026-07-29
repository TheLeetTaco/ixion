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

- `cargo check --locked` — per-chunk. `--locked` exits 0 when `Cargo.lock` is present and current and refuses clearly when it would have to write one, so a verification run cannot silently resolve a different dependency graph than the one reviewed; it also refuses in a repo with no committed lockfile, normal for a library crate, where these gates do not apply.
- `cargo clippy --all-targets --all-features --locked -- -D warnings` — per-phase. No `#[allow]` without a one-line justification. Without `--all-targets` a violation in a test or example is never reported; without `--all-features` feature-gated code is invisible to the lint pass.
- `cargo fmt --check` — per-phase. Do not add `--all`: measured on a two-member workspace, `cargo fmt` already flags every member from any working directory (rustfmt #2488), so the flag would be ceremony.
- `cargo test --locked` — per-phase; includes doc-tests. Do not add `--all-targets` here — it silently drops the `Doc-tests` runner (cargo #11015, #6669); `cargo test --doc` is the companion when you want doc-tests alone.
- `cargo check --all-features --locked` and `cargo check --no-default-features --locked` — per-phase, but only on the final phase and on any phase whose `files[]` includes `Cargo.toml` or a feature-gated module: each feature set defeats the build cache, so running both unconditionally costs about four compilations per phase, roughly forty on a ten-phase spec. `--all-features` catches code rotting behind a feature nobody enables by default; `--no-default-features` catches code that only compiles because a default feature happened to be on.
- `cargo audit || cargo audit --stale` — session, because the fetch is networked and per-phase would make every phase network-dependent. The fallback form checks fresh advisories and falls back to the cached database only when the fetch fails; unconditional `--stale` would report clean against a frozen advisory set indefinitely.
- `cargo machete --with-metadata` — session, because it is noisy enough that repeating it per wave trains the reader to ignore it. Finds unused dependencies; `--with-metadata` cuts false positives. (`cargo udeps` rejected: nightly-only.)

Never, at any tier: `cargo deny`, MSRV checks, coverage thresholds, benchmarks, cross-compilation — CI's job, not a wave's. A gate whose binary is missing skips loudly rather than failing the phase, and that skip path fires on every non-Rust repo, so routine `SKIPPED:` lines are expected rather than gate flakiness.

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
