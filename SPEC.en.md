# gc-primitives Cross-Language Contract Specification (SPEC)

> [中文](SPEC.md) · English

**Status**: Final · 2026-11-12 · Located at the repository root
**Applies to**: Java, C++, Python, Rust
**Relationship**: **Ports of one shared conceptual contract**, not four independent rewrites. Behavioral consistency is guaranteed by contract tests; **performance numbers are not part of this specification** — each language's benchmark results live in its own README.

All four language READMEs reference this file. Every Markdown file in the repository has a Chinese version and an English version; English filenames end in `.en.md`.

---

## 1. Positioning and Benefit Claims

The library makes one promise: turn "object pool + reuse context" into composable primitives, without being tied to any scenario — callers decide the latency/throughput trade-off.

Benefit claims must be written separately per language and never mixed:

| Language | Actual benefit | Must not be described as |
| --- | --- | --- |
| Java | No object allocation on a free-slot hit; lower allocation rate and young GC pressure | — |
| C++ | Fewer `malloc`/`free` calls and better cache locality after reuse | "saving GC" — C++ has no GC |
| Rust | Fewer heap allocations, better cache locality, **misuse eliminated at compile time** | "saving GC" — Rust has no GC either |
| Python | Cross-language contract consistency, clear semantics, teaching/comparison value | "faster than the interpreter" — see below |

**Note on Python**: CPython primarily uses reference counting (an object is freed immediately when its reference count hits zero), with a generational GC layered on top solely to collect reference cycles. On top of that, pymalloc arenas and small-object free-lists (the interpreter already pools `list` / `dict` / `float`, etc.) mean reuse is happening underneath. A hand-written pure-Python object pool often just overlaps with those built-in caches and can even be slower due to the extra Python function call. The Python port is therefore explicitly a **pure semantic port with no performance promise**.

**Note on Rust**: no GC — memory is managed at compile time via ownership. This port additionally promises **zero `unsafe`, zero dependencies** (`#![forbid(unsafe_code)]`) and moves part of the other languages' runtime checks into the type system; see section 8.1.

## 2. Five Core Contracts

| ID | Contract | Consequence of violation |
| --- | --- | --- |
| C1 | Every borrow must be explicitly ended (close the handle / leave the scope) | An unreturned lease is a leak, precisely detectable via the `active` count |
| C2 | The handle and the borrowed object belong to the borrowing thread only; no cross-thread transfer | Throws an exception or returns an error (eliminated at compile time in Rust) |
| C3 | The number of idle objects per thread is bounded by `capacity`; excess is discarded | Bounded memory footprint, no unbounded residency |
| C4 | On return, the library invokes the reset hook to restore the object to a clean state | Dirty data must never reach the next borrow |
| C5 | Misuse is **always strictly validated**, with no switch and no Debug/Release split | Throws immediately / returns an error; never undefined behavior |

C5 covers: double return, cross-thread return, cross-thread use, `get()` after close, factory returning an empty value, and `capacity <= 0`.

> The library cannot intercept "still referenced externally after return" at runtime. It is the caller's responsibility not to retain a reference after the borrow ends. All four language docs must state this; Rust's callback lease makes that situation impossible at compile time.

## 3. Type and Naming Mapping

| Concept | Java | C++ | Python | Rust |
| --- | --- | --- | --- | --- |
| Pool | `Pool<T>` | `rbc::gc::Pool<T, Factory, Recycler>` | `Pool` | `Pool<T>` |
| Lease | `Lease<T>` (try-with-resources) | `Lease` (move-only, RAII destructor) | `Lease` (`with` context manager) | No standalone handle: `with_borrow(f)` scoped callback |
| Reset hook | `Recycler<T>` | Template parameter `Recycler`, `noexcept` by convention | `recycler` callable | `FnMut(&mut T) -> Result<(), PoolError>` |
| Factory | `Supplier<T>` | Template parameter `Factory`, returning `T*` | `factory` callable | `FnMut() -> Option<T>` |
| Entry point | `Pools.threadLocal(...)` | Direct construction / `rbc::gc::make_pool(...)` | Direct `Pool(...)` construction | `Pool::new(...)` / `Pool::with_defaults(...)` |
| Exception / error | `PoolStateException` | `rbc::gc::pool_error : std::logic_error` | `PoolStateError` | `PoolError` (`Result`, never panic) |

`::` is simply C++'s namespace separator, equivalent to the dot in a Java package name; it exists to avoid `Pool` name collisions and is not an operator. The Rust crate is `gc-primitives` with import name `gc_primitives` (Cargo turns the hyphen into an underscore — a compiler rule).

**Instance semantics**: in all four languages a **global `Pool` object holds thread-local state** — one instance is used across threads, each with its own bounded idle stack; it is not "one Pool per thread". The Rust port shares it as `Arc<Pool<T>>`, with factory/reset closures requiring `Send + 'static`.

## 4. Method Name Mapping (Diagnostics Contract)

| Java | C++ / Python | Rust | Meaning |
| --- | --- | --- | --- |
| `borrow()` | `borrow()` | `with_borrow(f)` | Borrow (scoped in Rust) |
| `capacity()` | `capacity()` | `capacity()` | Per-thread bound |
| `idleCount()` | `idle_count()` | `idle_count()` | Idle objects on the current thread |
| `activeLeases()` | `active_leases()` | `active_leases()` | Unreturned borrows |
| `borrowCount()` | `borrow_count()` | `borrow_count()` | Total borrows |
| `returnCount()` | `return_count()` | `return_count()` | Total returns |
| `assertNoActiveLeases()` | `assert_no_active_leases()` | `assert_no_active_leases() -> Result` | Turn a leak into a test failure |

Python and Rust use snake_case to match the semantics rather than copying camelCase; this table is the item-by-item verification basis.

**Counter implementation**: Java uses `LongAdder`; C++ uses `std::atomic`; Rust uses `AtomicU64` fields on each `Pool` instance (`SeqCst`, precise across threads); Python guards integers with `threading.Lock` and only requires semantic equivalence. `idle_count()` reads only the current thread's state in all four languages.

## 5. Return Path and Reset Failure

| Language | Reset convention | If reset fails |
| --- | --- | --- |
| Java | `Recycler` should not throw | Consistent with the documented convention; no extra design |
| C++ | Reset call is `noexcept` by convention | Invoked inside a `noexcept` boundary; a throw triggers `std::terminate` — the constraint lives at the contract level |
| Python | No `noexcept` concept | The exception propagates, but the **object is discarded and never returned to the pool**; the lease is still invalidated and counters still settle |
| Rust | Reset hook returns `Result<(), PoolError>` | On `Err` the **object is discarded and the error propagates**; counters still settle; never returned to the pool |

**C++ destructor note**: throwing from a C++ destructor causes `std::terminate`. Therefore, if cross-thread misuse is detected during `Lease` destruction, the result is `std::terminate()` rather than an exception — "always strictly validated" still holds. An explicit `close()` performs full validation and throws `pool_error`.

**Python return mechanism**: via `with`'s `__exit__` (or an explicit `close()`); no destructor-based automatic return. If the `with` body raises, the object is still returned first, then the original exception propagates.

**Rust return mechanism**: `with_borrow` returns explicitly after the closure completes, so reset errors can propagate to the caller. If the closure `panic!`s, `BorrowGuard` settles counters and best-effort returns the object during unwinding, guarded by `catch_unwind` so it never causes a second panic.

## 6. Thread Ownership Validation

Java / C++ / Python keep "cross-thread return / cross-thread use throws immediately" unchanged. In Rust those misuse cases **cannot occur at compile time** because the object reference never leaves the closure; isolation is provided naturally by `thread_local!`.

- C++: each Lease stores a `std::thread::id` and compares it on return; this hot-path cost is accepted
- Python: a `threading.local` bounded stack guarantees thread isolation only; **multiple asyncio tasks on the same thread are not isolated** — the docs must state this limitation
- Rust: `thread_local!` + `RefCell`, one idle stack per thread; thread exit releases cached objects via TLS destruction
- No "strict switch", no default relaxation, no reduction to double-return detection only

## 7. Explicit Exclusions

- **No hard-coded performance numbers**. Measurements like Java's 106.8MB → 53.4MB live only in the Java README and Release Notes, not in this specification, so Python / Rust are not bound by them
- "Zero new object construction on a hit" is not a hard four-language requirement
- No mandatory throughput/latency target for any language
- The four APIs need not be literally identical in naming; only **behavioral contract** consistency plus the verifiable mapping tables in this file are required

## 8. Per-Language Checklist

| Contract item | Java | C++ | Python | Rust |
| --- | --- | --- | --- | --- |
| C1 Explicit return | ✅ try-with-resources | ✅ RAII destructor + `close()` | ✅ `with` / `close()` | ✅ `with_borrow` scope auto-returns |
| C2 Thread ownership | ✅ runtime | ✅ `thread::id` | ✅ `threading.get_ident()` | ✅ compile time + TLS isolation |
| C3 Bounded | ✅ | ✅ | ✅ | ✅ |
| C4 Reset on return | ✅ | ✅ | ✅ | ✅ |
| C5 Strict misuse detection | ✅ runtime | ✅ runtime | ✅ runtime | ✅ 3 cases at compile time + 4 at runtime |
| Diagnostics mapping | ✅ | ✅ snake_case | ✅ snake_case | ✅ snake_case + `Result` |
| Contract tests | ✅ JUnit 5 | ✅ 21 checks, zero third-party deps | ✅ 14 tests, `unittest` | ✅ integration + unit + doctests; CI runs 1.70 and stable |
| Benchmark | ✅ JMH + ThreadMXBean | ✅ Google Benchmark (optional build) | ⬜ No performance claim | ⬜ No benchmark in first release |

### 8.1 Compile-Time Strengthening (Rust-specific)

The Rust port is "SPEC alignment + compile-time strengthening", not a separate design:

| Runtime check in the other three languages | Rust handling |
| --- | --- |
| Double return | **Impossible at compile time** — no handle that can be closed twice |
| Cross-thread return / cross-thread use | **Impossible at compile time** — `&mut T` lives only inside the closure |
| `get()` after close | **Impossible at compile time** — the reference dies with the closure |
| "Still referenced externally after return" | **Impossible at compile time** — the reference cannot escape the closure |

**Runtime checks that remain (4, all returning `PoolError`)**: reentrancy, `capacity == 0`, factory returning `None`, reset failure.

**Other hard constraints**: `#![forbid(unsafe_code)]` at the crate root; zero dependencies; `Result<T, PoolError>` throughout with no `panic!` for business errors; TLS state indexed by a globally unique pool id and type-erased via `Box<dyn Any>` to support multiple `T`; MSRV 1.70 actually verified in CI.

## 9. Versioning and Distribution

**Versioning**: each language has its own independent version number, not locked to the published Java version. Maven Central and PyPI never allow a published version number to be uploaded again; a GitHub Release tag should not be recreated either.

| Language | Package / coordinates | Channel | Baseline |
| --- | --- | --- | --- |
| Java | `net.de5.rainbowcrrsys:gc-primitives` | Maven Central | Java 11 + Gradle 8.10.2 |
| C++ | `gc-primitives`, namespace `rbc::gc` | GitHub Release (header-only tarball) / vcpkg / Conan | C++17 |
| Python | `gc-primitives` (import name `gc_primitives`) | PyPI | Python 3.9+ |
| Rust | `gc-primitives` (import name `gc_primitives`) | crates.io (Trusted Publishing / OIDC) | Rust 1.70+, edition 2021 |

License: Apache-2.0 across all four languages.

> crates.io exception: Trusted Publishing can only be configured for a crate that **already exists**, so the first Rust release needs a one-time API token (stored only as a GitHub Secret, never in a repository file). OIDC takes over after the trusted publisher is registered.

## 10. Repository Layout and Tag Convention

The top level is organized by **language**, the inner level by **project** — adding a new project does not require a new repository:

```
rbc-monorepo/
├── README.md / README.en.md          root docs (中文 / English)
├── SPEC.md / SPEC.en.md              this spec (中文 / English)
├── LICENSE                           Apache-2.0
├── build.gradle / settings.gradle / gradle.properties
├── .github/workflows/                four release pipelines + Rust CI + deployment status check
├── java/
│   ├── gc-primitives/                Java main library (single jar)
│   ├── example/                      runnable sample, not published
│   └── benchmarks/                   JMH benchmark, not published
├── cpp/gc-primitives/                include / tests / bench / CMake / vcpkg / Conan / bilingual README
├── python/gc-primitives/             gc_primitives / tests / pyproject / bilingual README
└── rust/gc-primitives/               Cargo.toml / src / tests / bilingual README
```

A future project `test` becomes `java/test/`, `cpp/test/`, `python/test/`, `rust/test/`, with Gradle adding `include(':java:test')` and a `projectDir` in `settings.gradle`.

**Tag format**: the library name contains a hyphen, so a double underscore is used — `gc-primitives__java__v*`, `gc-primitives__python__v*`, `gc-primitives__cpp__v*`, `gc-primitives__rust__v*`. A new project uses `test__java__v*`, etc., so tags never collide. All four pipelines verify "tag version == declared version in code" and refuse to publish on mismatch. Historical tags `v0.1.0` / `py-v0.1.0` / `cpp-v0.1.0` are kept but retired from the trigger rules.

Every Markdown file has a Chinese version (default filename) and an English version (`.en.md`); the two versions link to each other at the top of the file.
