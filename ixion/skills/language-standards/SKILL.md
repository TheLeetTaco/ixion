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

- `cargo clippy -- -D warnings` — clean, no `#[allow]` without a one-line justification
- `cargo fmt --check`
- `cargo test` — includes doc-tests

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
