# gc-primitives · Rust Port

> [中文](README.md) · English

A Rust port of the same conceptual contract as the Java / C++ / Python versions. See the repository-root [SPEC.en.md](../../SPEC.en.md) ([中文](../../SPEC.md)) for the behavioral specification.

> Rust has no GC. The benefit here is **fewer heap allocations and better cache locality after reuse**.
> The hard promise of this crate is **zero `unsafe`, zero dependencies**: `#![forbid(unsafe_code)]` sits at the crate root.

## Why a Callback Lease

The other three languages return a `Lease<T>` handle that is returned automatically via try-with-resources / RAII / `with`. Rust's ownership system does not allow such a handle to escape freely while the object is later reused — doing it by force requires locks or `unsafe`.

So the Rust port uses a **scoped callback**:

```rust
pool.with_borrow(|value: &mut T| -> R { ... }) -> Result<R, PoolError>
```

The object reference **cannot escape the closure**, therefore:

| Runtime check in the other three languages | Rust port |
| --- | --- |
| Double return | Impossible at compile time (no handle to close twice) |
| Cross-thread return | Impossible at compile time (the object never crosses threads) |
| `get()` after close | Impossible at compile time (the reference dies with the closure) |

This moves half of C5 ("always strict misuse detection") into the type system — stronger than throwing at runtime.

## Import

```toml
[dependencies]
gc-primitives = "0.1.0"
```

```rust
use gc_primitives::Pool;

let pool = Pool::new(8, || Some(String::new()), |s| {
    s.clear();                 // reset on return
    Ok(())
})?;

let len = pool.with_borrow(|s| {
    s.push_str("hello");
    s.len()
})?;
assert_eq!(len, 5);

pool.assert_no_active_leases()?;
# Ok::<(), gc_primitives::PoolError>(())
```

Stateless objects can skip the factory/reset hooks:

```rust
let pool = gc_primitives::Pool::<Vec<u8>>::with_defaults(8)?;
pool.with_borrow(|buf| buf.push(1))?;
# Ok::<(), gc_primitives::PoolError>(())
```

Crate name `gc-primitives`, import name `gc_primitives` (Cargo turns the hyphen into an underscore — a compiler rule, not a rename). MSRV **Rust 1.70**, edition 2021.

## API Mapping

| Java | C++ | Python | Rust |
| --- | --- | --- | --- |
| `Pool<T>` / `Pools.threadLocal(...)` | `rbc::gc::Pool<T,F,R>` | `Pool` | `Pool<T>` / `Pool::new` / `Pool::with_defaults` |
| `Lease<T>` | `Pool::Lease` | `Lease` | No standalone handle (callback closure) |
| `borrow()` | `borrow()` | `borrow()` | `with_borrow(f)` |
| `Recycler<T>` | `Recycler` | `recycler` | `recycler: FnMut(&mut T) -> Result<(), PoolError>` |
| `Supplier<T>` | `Factory` | `factory` | `factory: FnMut() -> Option<T>` |
| `PoolStateException` | `pool_error` | `PoolStateError` | `PoolError` (`Result`, never panic) |
| `capacity()` | `capacity()` | `capacity()` | `capacity()` |
| `idleCount()` | `idle_count()` | `idle_count()` | `idle_count()` (current thread only) |
| `activeLeases()` | `active_leases()` | `active_leases()` | `active_leases()` |
| `borrowCount()` / `returnCount()` | `borrow_count()` / `return_count()` | same | `borrow_count()` / `return_count()` |
| `assertNoActiveLeases()` | `assert_no_active_leases()` | `assert_no_active_leases()` | `assert_no_active_leases() -> Result` |

Counters are `AtomicU64` fields on each `Pool` instance — **precise across threads**. `idle_count()` reads the current thread's `thread_local!` state.

## Contract Details (Rust-specific)

- **Runtime checks that remain mandatory**: reentrancy (`PoolError::ReentrantBorrow`), `capacity == 0` (`InvalidCapacity`), factory returning `None` (`FactoryReturnedNone`), reset failure (`ResetFailed`)
- **Reset failure**: the object is **discarded, never returned to the pool**; the error propagates to the caller and counters still settle — matching the Python port's contamination isolation
- **Closure `panic!`**: `BorrowGuard` settles counters and best-effort returns the object during unwinding, guarded by `catch_unwind` so it never causes a second panic
- **Thread-local + bounded**: `thread_local!` + `RefCell`, at most `capacity` idle objects per thread; excess is dropped. Thread exit releases its cached objects via TLS destruction
- **`Arc` sharing**: factory/reset closures require `Send + 'static` and live behind `Mutex`, so `Pool<T>` is `Send + Sync` and can be shared as `Arc<Pool<T>>`; each thread uses its own idle stack
- **TLS state is indexed by pool id** and type-erased with `Box<dyn Any>`, so pools of different `T` share one thread_local static. Ids are globally unique, so the downcast always succeeds
- The library cannot intercept "still referenced externally after return" — but under the callback model that situation cannot arise in the first place

## Verification

```bash
cd rust/gc-primitives
cargo test                    # unit + integration + doctests
cargo test --all-targets
cargo clippy --all-targets -- -D warnings
cargo fmt -- --check
```

CI actually runs **two toolchains, Rust 1.70 (MSRV) and stable**, so the declared MSRV is not just a number in `Cargo.toml`.

## Distribution

crates.io: `gc-primitives`, version `0.1.0`, Apache-2.0, zero dependencies.

Publishing uses **crates.io Trusted Publishing (OIDC)**: on a `gc-primitives__rust__v*` tag, the workflow exchanges GitHub's short-lived OIDC identity for a temporary upload credential and runs `cargo publish`. **No long-lived API token is stored in the repository.** A one-time trusted publisher registration on the crates.io website is required before the first release.

The version is independent from Java / C++ / Python and is not locked to the published Java `0.1.0`.
