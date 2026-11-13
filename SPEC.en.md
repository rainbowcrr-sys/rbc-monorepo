# gc-primitives Cross-Language Contract Specification (SPEC)

> [中文](SPEC.md) · English

**Status**: Final · 2026-11-12 · Located at the repository root
**Applies to**: Java, C++, Python, Rust, Go, Swift, Zig
**Relationship**: **Ports of one shared conceptual contract**, not five independent rewrites. Behavioral consistency is guaranteed by contract tests; **performance numbers are not part of this specification** — each language's benchmark results live in its own README.

All seven language READMEs reference this file. Every Markdown file in the repository has a Chinese version and an English version; English filenames end in `.en.md`.

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
| Go | No object allocation on a shard free-slot hit; lower allocation rate and GC pressure; **no central registry, no credentials** | No quantified "faster than `sync.Pool`" claim (no benchmark in the first release) |
| Swift | Fewer heap allocations/deallocations and retain-release operations; better cache locality after reuse | "saving GC" — Swift uses ARC, there is no GC |
| Zig | A free-slot hit performs no `allocator.create` at all; objects are released explicitly and never leaked | "saving GC" — Zig has no GC and no implicit allocation |

**Note on Python**: CPython primarily uses reference counting (an object is freed immediately when its reference count hits zero), with a generational GC layered on top solely to collect reference cycles. On top of that, pymalloc arenas and small-object free-lists (the interpreter already pools `list` / `dict` / `float`, etc.) mean reuse is happening underneath. A hand-written pure-Python object pool often just overlaps with those built-in caches and can even be slower due to the extra Python function call. The Python port is therefore explicitly a **pure semantic port with no performance promise**.

**Note on Rust**: no GC — memory is managed at compile time via ownership. This port additionally promises **zero `unsafe`, zero dependencies** (`#![forbid(unsafe_code)]`) and moves part of the other languages' runtime checks into the type system; see section 8.1.

**Note on Go**: Go has a GC, but goroutines migrate between OS threads and there is no thread-local storage. The Go port is therefore an **explicit concurrency variant of C2/C3** (sharded bounded stacks by `GOMAXPROCS` + global atomic counters); cross-goroutine misuse is covered by a documented contract rather than a runtime check — see section 8.2. Only "fewer heap allocations" is claimed, with no hard-coded performance number.


**Note on Swift**: ARC is not GC — an object is freed when its reference count hits zero. `T: AnyObject` is required because a value-type getter returns a copy, which would silently discard the caller's mutations; `deinit` cannot throw, so an object whose `close()` was forgotten is **discarded rather than reused** — see section 11.1.

**Note on Zig**: no GC and no implicit allocation — all memory comes from the caller's explicit `Allocator`. The Zig-specific `destroy` hook releases discarded objects, and `std.testing.allocator` catches every missed object in CI — see section 11.2.

## 2. Five Core Contracts

| ID | Contract | Consequence of violation |
| --- | --- | --- |
| C1 | Every borrow must be explicitly ended (close the handle / leave the scope) | An unreturned lease is a leak, precisely detectable via the `active` count |
| C2 | The handle and the borrowed object belong to the borrowing thread only; no cross-thread transfer | Throws an exception or returns an error (eliminated at compile time in Rust; concurrency variants in Go / Swift / Zig, see 8.2 and section 11) |
| C3 | The number of idle objects per thread is bounded by `capacity`; excess is discarded | Bounded memory footprint, no unbounded residency |
| C4 | On return, the library invokes the reset hook to restore the object to a clean state | Dirty data must never reach the next borrow |
| C5 | Misuse is **always strictly validated**, with no switch and no Debug/Release split | Throws immediately / returns an error; never undefined behavior |

C5 covers: double return, cross-thread return, cross-thread use, `get()` after close, factory returning an empty value, and `capacity <= 0`.

> The library cannot intercept "still referenced externally after return" at runtime. It is the caller's responsibility not to retain a reference after the borrow ends. All seven language docs must state this; Rust's callback lease makes that situation impossible at compile time; Go has no destructor fallback and relies on the documented contract plus `AssertNoActiveLeases()`.

## 3. Type and Naming Mapping

| Concept | Java | C++ | Python | Rust | Go |
| --- | --- | --- | --- | --- | --- |
| Pool | `Pool<T>` | `rbc::gc::Pool<T, Factory, Recycler>` | `Pool` | `Pool<T>` | `Pool[T]` (sharded) |
| Lease | `Lease<T>` (try-with-resources) | `Lease` (move-only, RAII destructor) | `Lease` (`with` context manager) | No standalone handle: `with_borrow(f)` scoped callback | `*Lease[T]` (`defer Close()`) |
| Reset hook | `Recycler<T>` | Template parameter `Recycler`, `noexcept` by convention | `recycler` callable | `FnMut(&mut T) -> Result<(), PoolError>` | `Recycler[T] func(*T) error` |
| Factory | `Supplier<T>` | Template parameter `Factory`, returning `T*` | `factory` callable | `FnMut() -> Option<T>` | `Factory[T] func() (T, bool)` |
| Entry point | `Pools.threadLocal(...)` | Direct construction / `rbc::gc::make_pool(...)` | Direct `Pool(...)` construction | `Pool::new(...)` / `Pool::with_defaults(...)` | `gcprimitives.New[T](...)` |
| Exception / error | `PoolStateException` | `rbc::gc::pool_error : std::logic_error` | `PoolStateError` | `PoolError` (`Result`, never panic) | misuse `panic`; recoverable failures `error` |

`::` is simply C++'s namespace separator, equivalent to the dot in a Java package name; it exists to avoid `Pool` name collisions and is not an operator. The Rust crate is `gc-primitives` with import name `gc_primitives` (Cargo turns the hyphen into an underscore — a compiler rule). The Go package name is `gcprimitives`: a hyphenated directory cannot be a package name, so an explicit import alias is used.

**Instance semantics**: in Java / C++ / Python / Rust a **global `Pool` object holds thread-local state** — one instance is used across threads, each with its own bounded idle stack; it is not "one Pool per thread". The Rust port shares it as `Arc<Pool<T>>`, with factory/reset closures requiring `Send + 'static`. **Go exception**: no thread-local state; shards are used instead, see 8.2.

## 4. Method Name Mapping (Diagnostics Contract)

| Java | C++ / Python | Rust | Go | Meaning |
| --- | --- | --- | --- | --- |
| `borrow()` | `borrow()` | `with_borrow(f)` | `Borrow() (*Lease[T], error)` | Borrow (scoped in Rust) |
| `capacity()` | `capacity()` | `capacity()` | `Capacity()` / `ShardCount()` | Per-thread / per-shard bound |
| `idleCount()` | `idle_count()` | `idle_count()` | `IdleCount()` | Idle count (Go: all-shard snapshot) |
| `activeLeases()` | `active_leases()` | `active_leases()` | `ActiveLeases()` | Unreturned borrows |
| `borrowCount()` | `borrow_count()` | `borrow_count()` | `BorrowCount()` | Total borrows |
| `returnCount()` | `return_count()` | `return_count()` | `ReturnCount()` | Total returns |
| `assertNoActiveLeases()` | `assert_no_active_leases()` | `assert_no_active_leases() -> Result` | `AssertNoActiveLeases() error` | Turn a leak into a test failure |

Python and Rust use snake_case to match the semantics rather than copying camelCase; Go uses PascalCase for exported identifiers. This table is the item-by-item verification basis.

**Counter implementation**: Java uses `LongAdder`; C++ uses `std::atomic`; Rust uses `AtomicU64` fields on each `Pool` instance (`SeqCst`, precise across threads); Python guards integers with `threading.Lock`; Go uses `atomic.Int64` (precise across goroutines). `idle_count()` reads only the current thread's state in Java / C++ / Python / Rust; Go's `IdleCount()` returns a snapshot across all shards.

## 5. Return Path and Reset Failure

| Language | Reset convention | If reset fails |
| --- | --- | --- |
| Java | `Recycler` should not throw | Consistent with the documented convention; no extra design |
| C++ | Reset call is `noexcept` by convention | Invoked inside a `noexcept` boundary; a throw triggers `std::terminate` — the constraint lives at the contract level |
| Python | No `noexcept` concept | The exception propagates, but the **object is discarded and never returned to the pool**; the lease is still invalidated and counters still settle |
| Rust | Reset hook returns `Result<(), PoolError>` | On `Err` the **object is discarded and the error propagates**; counters still settle; never returned to the pool |
| Go | `Recycler[T]` returns `error` | On a non-nil error the **object is discarded and `Close()` returns it**; counters still settle; never returned to the pool |

**C++ destructor note**: throwing from a C++ destructor causes `std::terminate`. Therefore, if cross-thread misuse is detected during `Lease` destruction, the result is `std::terminate()` rather than an exception — "always strictly validated" still holds. An explicit `close()` performs full validation and throws `pool_error`.

**Python return mechanism**: via `with`'s `__exit__` (or an explicit `close()`); no destructor-based automatic return. If the `with` body raises, the object is still returned first, then the original exception propagates.

**Rust return mechanism**: `with_borrow` returns explicitly after the closure completes, so reset errors can propagate to the caller. If the closure `panic!`s, `BorrowGuard` settles counters and best-effort returns the object during unwinding, guarded by `catch_unwind` so it never causes a second panic.

**Go return mechanism**: via `defer l.Close()` or an explicit `Close()`, with **no destructor fallback**. `Close()` returns an `error`; callers who care about reset failures must not ignore it.

## 6. Thread Ownership Validation

Java / C++ / Python keep "cross-thread return / cross-thread use throws immediately" unchanged. In Rust those misuse cases **cannot occur at compile time** because the object reference never leaves the closure; isolation is provided naturally by `thread_local!`.

- C++: each Lease stores a `std::thread::id` and compares it on return; this hot-path cost is accepted
- Python: a `threading.local` bounded stack guarantees thread isolation only; **multiple asyncio tasks on the same thread are not isolated** — the docs must state this limitation
- Rust: `thread_local!` + `RefCell`, one idle stack per thread; thread exit releases cached objects via TLS destruction
- **Go**: a goroutine cannot be reliably identified, so cross-goroutine return/use is **not checked at runtime**; the documented contract is that a lease belongs to the borrowing goroutine — see section 8.2
- No "strict switch", no default relaxation, no reduction to double-return detection only

## 7. Explicit Exclusions

- **No hard-coded performance numbers**. Measurements like Java's 106.8MB → 53.4MB live only in the Java README and Release Notes, not in this specification, so Python / Rust are not bound by them
- "Zero new object construction on a hit" is not a hard eight-language requirement
- No mandatory throughput/latency target for any language
- The eight APIs need not be literally identical in naming; only **behavioral contract** consistency plus the verifiable mapping tables in this file are required

## 8. Per-Language Checklist

| Contract item | Java | C++ | Python | Rust | Go |
| --- | --- | --- | --- | --- | --- |
| C1 Explicit return | ✅ try-with-resources | ✅ RAII destructor + `close()` | ✅ `with` / `close()` | ✅ `with_borrow` scope auto-returns | ✅ `defer Close()` |
| C2 Thread ownership | ✅ runtime | ✅ `thread::id` | ✅ `threading.get_ident()` | ✅ compile time + TLS isolation | ⚠ concurrency variant, see 8.2 |
| C3 Bounded | ✅ | ✅ | ✅ | ✅ | ✅ bounded per shard |
| C4 Reset on return | ✅ | ✅ | ✅ | ✅ | ✅ |
| C5 Strict misuse detection | ✅ runtime | ✅ runtime | ✅ runtime | ✅ 3 cases at compile time + 4 at runtime | ✅ `panic` + `error` |
| Diagnostics mapping | ✅ | ✅ snake_case | ✅ snake_case | ✅ snake_case + `Result` | ✅ PascalCase + `error` |
| Contract tests | ✅ JUnit 5 | ✅ 21 checks, zero third-party deps | ✅ 14 tests, `unittest` | ✅ integration + unit + doctests; CI runs 1.70 and stable | ✅ 10 tests + Example, `-race`, CI runs 1.21 and stable |
| Benchmark | ✅ JMH + ThreadMXBean | ✅ Google Benchmark (optional build) | ⬜ No performance claim | ⬜ No benchmark in first release | ⬜ No benchmark in first release |

### 8.1 Compile-Time Strengthening (Rust-specific)

The Rust port is "SPEC alignment + compile-time strengthening", not a separate design:

| Runtime check in the other implementations | Rust handling |
| --- | --- |
| Double return | **Impossible at compile time** — no handle that can be closed twice |
| Cross-thread return / cross-thread use | **Impossible at compile time** — `&mut T` lives only inside the closure |
| `get()` after close | **Impossible at compile time** — the reference dies with the closure |
| "Still referenced externally after return" | **Impossible at compile time** — the reference cannot escape the closure |

**Runtime checks that remain (4, all returning `PoolError`)**: reentrancy, `capacity == 0`, factory returning `None`, reset failure.

**Other hard constraints**: `#![forbid(unsafe_code)]` at the crate root; zero dependencies; `Result<T, PoolError>` throughout with no `panic!` for business errors; TLS state indexed by a globally unique pool id and type-erased via `Box<dyn Any>` to support multiple `T`; MSRV 1.70 actually verified in CI.

### 8.2 Concurrency Variant (Go-specific)

Go has no thread-local storage: goroutines migrate between OS threads, so `thread_local` semantics do not exist. This port is an **explicitly documented concurrency variant**, not a strict port of C2/C3:

| SPEC contract | Go handling |
| --- | --- |
| Per-thread bounded idle stack (C3) | Sharded `sync.Mutex` + bounded stacks, one per `GOMAXPROCS(0)`; at most `capacity` idle objects per shard, process-wide bound `capacity × GOMAXPROCS` |
| Thread ownership validation (C2) | Go cannot reliably identify a goroutine, so there is **no runtime check**; the documented contract is that a lease belongs to the borrowing goroutine and must not be passed across goroutines |
| `idle_count()` on the current thread | `IdleCount()` returns a snapshot across all shards, not a linearizable global value |
| Global diagnostics | `atomic.Int64`, precise across goroutines |

**Other conventions**: a factory returning `false` counts as "factory returned an empty value"; a non-nil `error` from the recycler discards the object and propagates the error; a double `Close()` or `Get()` after `Close()` always panics; `capacity <= 0` and nil hooks return errors. Go has no destructor fallback, so an unclosed lease is detected by `AssertNoActiveLeases()` in tests. Borrows pick a shard with an atomic round-robin counter, and the factory runs outside the shard lock.

## 9. Versioning and Distribution

**Versioning**: each language has its own independent version number, not locked to the published Java version. Maven Central and PyPI never allow a published version number to be uploaded again; a GitHub Release tag should not be recreated either.

| Language | Package / coordinates | Channel | Baseline |
| --- | --- | --- | --- |
| Java | `net.de5.rainbowcrrsys:gc-primitives` | Maven Central | Java 11 + Gradle 8.10.2 |
| C++ | `gc-primitives`, namespace `rbc::gc` | GitHub Release (header-only tarball) / vcpkg / Conan | C++17 |
| Python | `gc-primitives` (import name `gc_primitives`) | PyPI | Python 3.9+ |
| Rust | `gc-primitives` (import name `gc_primitives`) | crates.io (Trusted Publishing / OIDC) | Rust 1.70+, edition 2021 |
| Go | `github.com/rainbowcrr-sys/rbc-monorepo/go/gc-primitives` | Git tag + `proxy.golang.org` / pkg.go.dev (**no central registry, no credentials**) | Go 1.21+ |
| Swift | `GCPrimitives` (SwiftPM) | Git tag (**no registration, no credentials**) | Swift 5.9+ |
| Zig | `gc_primitives` | Git tag + Zig Index (**no registration, no credentials**) | Zig 0.14.0 |

License: Apache-2.0 across all seven languages.

> crates.io exception: Trusted Publishing can only be configured for a crate that **already exists**, so the first Rust release needs a one-time API token (stored only as a GitHub Secret, never in a repository file). OIDC takes over after the trusted publisher is registered.

## 10. Repository Layout and Tag Convention

The top level is organized by **language**, the inner level by **project** — adding a new project does not require a new repository:

```
rbc-monorepo/
├── README.md / README.en.md          root docs (中文 / English)
├── SPEC.md / SPEC.en.md              this spec (中文 / English)
├── LICENSE                           Apache-2.0
├── build.gradle / settings.gradle / gradle.properties
├── .github/workflows/                six release pipelines + Rust / Go / Swift / Zig CI + deployment status check
├── java/
│   ├── gc-primitives/                Java main library (single jar)
│   ├── example/                      runnable sample, not published
│   └── benchmarks/                   JMH benchmark, not published
├── cpp/gc-primitives/                include / tests / bench / CMake / vcpkg / Conan / bilingual README
├── python/gc-primitives/             gc_primitives / tests / pyproject / bilingual README
├── rust/gc-primitives/               Cargo.toml / src / tests / bilingual README
├── go/gc-primitives/                 go.mod / *.go / tests / bilingual README
├── swift/gc-primitives/              Package.swift / Sources / Tests / bilingual README
└── zig/gc-primitives/                build.zig / src / tests / bilingual README
```

A future project `test` becomes `java/test/`, `cpp/test/`, `python/test/`, `rust/test/`, `go/test/`, `swift/test/`, `zig/test/`, with Gradle adding `include(':java:test')` and a `projectDir` in `settings.gradle`.

**Tag format**: the library name contains a hyphen, so a double underscore is used — `gc-primitives__java__v*`, `gc-primitives__python__v*`, `gc-primitives__cpp__v*`, `gc-primitives__rust__v*`. A new project uses `test__java__v*`, etc., so tags never collide. Upload-style pipelines verify "tag version == declared version in code" and refuse to publish on mismatch. Historical tags `v0.1.0` / `py-v0.1.0` / `cpp-v0.1.0` are kept but retired from the trigger rules.

**Go tag exception (hard rule)**: in a multi-module repository a submodule's version tag must carry the directory prefix; the Go toolchain does not understand the double-underscore format. Go therefore uses `go/gc-primitives/v0.1.0` (or `go/test/v0.1.0` for a new project). When a user runs `go get ...@v0.1.0`, the go command automatically looks for that prefixed tag. There is no upload step: pushing the tag *is* the release. The workflow only warms `proxy.golang.org`, triggers pkg.go.dev indexing, and proves the module is consumable with a real `go get` + `go run` consumer job.

## 11. Supplementary Specification for the Two New Ports (Swift / Zig)

Sections 1–10 hold the contract for Java, C++, Python, Rust and Go. This section records the two later implementations: they **also align with C1–C5**, but because their runtime models differ, C2 (thread ownership) is an explicitly labelled variant rather than a strict port. For readability, the main mapping tables in §3 / §4 / §8 stay at five columns; item-by-item mappings for these two ports live here.

### 11.1 Swift (ARC allocation optimization)

**Positioning**: Swift uses ARC, not GC. Only "fewer heap allocations/deallocations, fewer retain-release operations, better cache locality after reuse" is claimed — never "saves GC".

**`T: AnyObject` constraint**: a Swift getter on a value type returns a copy; allowing `struct` would silently discard every mutation made to `lease.value`, so the object would never come back to the pool as expected. Restricting to classes matches heap-object semantics and lets `recycler` reset in place.

**deinit fallback**: Swift's `deinit` cannot `throw`, so the fallback path cannot safely run a potentially throwing `recycler`. An object whose `close()` was forgotten is therefore **discarded rather than reused** — counters stay exact and a dirty object can never reach the next borrower. This is the key difference from C++ RAII.

**Concurrency model**: no stable cross-platform thread-local API, so one `NSLock`-protected bounded stack with counters taken inside the lock is used instead. Cross-thread use of the same `Lease` is not checked at runtime; it is a documented contract. CI verifies counter precision with 100 concurrent borrow/close operations via `DispatchQueue.concurrentPerform`.

**Verification**: macOS (Xcode Swift) and Ubuntu (Swift 5.9) each run 12 XCTest cases covering C1–C5, concurrency, and the deinit fallback.

### 11.2 Zig (no GC, no implicit allocation)

**Positioning**: all memory comes from the caller's explicit `std.mem.Allocator`; a free-slot hit performs no `allocator.create` at all. `Pool(comptime T)` is a compile-time generic with zero vtable, zero type erasure, and zero runtime overhead.

**The Zig-specific `destroy` hook**: objects discarded on reset failure, beyond capacity, or at pool close are all released explicitly through `destroy`; `std.testing.allocator` catches every object that was missed. Other languages lean on a GC / ARC / Drop — here it must be done by hand.

**No destructor**: Zig has no destructor, so forgetting `close()` leaves both an active count and an unfreed object. `assertNoActiveLeases()` and the allocator's leak detection catch it together.

**Error model**: the `PoolError` set (`InvalidCapacity` / `FactoryFailed` / `LeaseClosed` / `DoubleClose` / `PoolClosed` / `ActiveLeases` / `OutOfMemory`) plus `anyerror` to propagate user-defined errors; no `@panic`, no switch. A factory returning `null` counts as "factory returned an empty value".

**Verification**: Zig 0.14.0 actually runs `zig test` (Debug + ReleaseSafe) and `zig build test`. Eleven tests pass with no memory leaks. Tests use local state only, so `zig test` running test blocks concurrently cannot corrupt data.

### 11.3 Distribution and tags

| Language | Package / path | Channel | Registration needed |
| --- | --- | --- | --- |
| Swift | `GCPrimitives` (SwiftPM) | Git tag in the standalone repo `gc-primitives-swift` | ❌ no registration, no credentials |
| Zig | `gc_primitives` | GitHub Release tarball + Zig Index | ❌ no registration, no credentials |

**Swift hard rule**: SwiftPM requires `Package.swift` at the **repository root** and only accepts plain semantic-version tags (`0.1.0` / `v0.1.0`); it does **not** accept path-prefixed tags such as `swift/gc-primitives/v0.1.0`. `v0.1.0` was already taken by the first Java release and cannot be reused. The Swift source therefore stays in the monorepo at `swift/gc-primitives/` (canonical copy + CI) and is mirrored to a separate public repository, `rainbowcrr-sys/gc-primitives-swift`, with `Package.swift` at its root and a `v0.1.0` tag. The monorepo tag `swift/gc-primitives/v0.1.0` only triggers the release workflow and carries the Release asset. Neither repository needs registration or credentials.

**Zig hard rule**: Zig has no central registry, but consumers pull a tarball with `zig fetch`, so the package root must contain `build.zig.zon` (`.name` / `.version` / `.fingerprint` / `.minimum_zig_version` / `.paths`) and `build.zig` must expose a module via `addModule`, otherwise a downstream `@import` cannot resolve. The first release adds the zon, tags `zig/gc-primitives/v0.1.0`, and attaches a tarball containing only the package directory. CI runs `zig fetch` on that asset, then builds and runs a separate consumer package against it. The repository carries the `zig-package` topic for automatic Zig Index inclusion.

Tags: monorepo `swift/gc-primitives/v0.1.0` and `zig/gc-primitives/v0.1.0`; the SwiftPM side additionally has `v0.1.0` in `gc-primitives-swift`.

**Status of this iteration**: both ports published `0.1.0` with green CI; no credentials written anywhere.
Every Markdown file has a Chinese version (default filename) and an English version (`.en.md`); the two versions link to each other at the top of the file.

## 12. The 0.2.0 Capability Set (Purely Additive)

0.2.0 is **purely additive**: the existing `Pool` / `Lease` constructor signatures and default behaviour do not change by a single line; code written against 0.1.x keeps running untouched. Every capability below ships as a new type, an optional parameter, or an optional loader.

### 12.1 Capabilities and merge rules

| Capability | Delivery | Notes |
| --- | --- | --- |
| Concurrency trio | Python `AsyncPool` / `borrow_async()` / `async with`; Rust `SharedPool` (`Send + Sync`) and `LocalPool`; Go `Borrow(ctx)` | All original sync / thread-local / context-free APIs stay |
| Full-pool policy | `on_full`: `drop_oldest` / `drop_largest` / `block` / `reject` / `grow` + `block_timeout_ms` / `max_overflow` | Default behaviour unchanged |
| Leak detection | manual `detect_leaks()` + borrow sampling | **No background thread, zero resident overhead** |
| Lifecycle hooks | `on_create` / `on_borrow` / `on_return` / `on_evict` / `on_destroy` / `clear_sensitive` | Clear sensitive data on return |
| Warm-up | `prewarm(n)` / parallel variant | — |
| Sharding | `ShardedPool` | — |
| Two-level pool | `TwoLevelPool` | — |
| Snapshot | `snapshot()` returns config + stats + active_leases | — |
| Memory scope | `memory_scope(name)`, callback + JSON output | No-op with zero allocation when `GC_PRIMITIVES_DIAG` is unset |
| Health metrics | `stats()` / `metrics()` **unified JSON-isomorphic snapshot** | Identical field names in all seven languages; no built-in Prometheus / OTel |
| Unified config | Unified YAML (snake_case) + schema validation + `PoolManager` + env overrides + cascading lookup + hot reload | Loader ships with the main package, no new version number |
| Framework adapters | Zero-dependency thin examples in each README | Main package depends on no framework |

**Merge rules**: "unified metrics/telemetry" and "health metrics API" from the original list are one capability domain and are implemented once; "runtime reconfiguration" is folded into the config file's hot reload instead of being built separately. The original "framework integration" table included Node (Express/Fastify); per the deleted `node/` directory, **seven languages only**.

### 12.2 Combination matrix (fixed, no free nesting)

| | Standalone | Shardable | As `TwoLevelPool` L2 |
| --- | --- | --- | --- |
| `LocalPool` (Rust thread-local) | ✅ | ❌ | ❌ |
| `SharedPool` (Rust `Send + Sync`) | ✅ | ✅ | ✅ |
| Base `Pool` in other languages | ✅ | ✅ | ✅ |

`TwoLevelPool` is built only on `SharedPool` (or an equivalent shared pool); CI runs against this matrix and forbidden combinations fail at construction time.

### 12.3 Unified metrics JSON-isomorphic snapshot (identical field names)

```json
{
  "borrow_count": 0, "return_count": 0, "active_leases": 0,
  "pool_hits": 0, "pool_misses": 0, "hit_rate": 0.0,
  "wait_time_p50": 0.0, "wait_time_p99": 0.0, "wait_time_max": 0.0,
  "object_lifetime_p50": 0.0, "eviction_count": 0, "leak_count": 0,
  "created": 0, "idle": 0, "capacity": 0, "closed": false
}
```

`stats()` / `metrics()` in all seven languages must return these exact keys; implementations without sampling supply `0` / `0.0` rather than omitting a field.

### 12.4 Unified YAML and loader

- **Format**: one YAML dialect for all seven languages, **unified snake_case** keys; a config file can be copied across languages
- **Dependencies**: zero-dependency core + optional loader (a built-in minimal YAML-subset parser supporting only the scalars and two-level nested keys shown in the example, not full YAML); the core pool works without the loader
- **Delivery**: the loader **ships with the main package and adds no version number** (Python extras / Rust feature / optional C++ header / in-repo submodule elsewhere) — still seven `0.2.0` packages
- **Validation**: `max_size <= 0`, an invalid `on_full`, or an unknown key fails at load time with a list of legal values
- **Precedence**: `GC_PRIMITIVES__<POOL>__<KEY` env vars > config file > code defaults
- **Cascading lookup**: `./gc-primitives.yaml` → `./config/gc-primitives.yaml` → `~/.config/gc-primitives.yaml` → `/etc/gc-primitives.yaml`; `GC_PRIMITIVES_CONFIG` overrides the search
- **Multiple pools**: `PoolManager.from_config()` creates and shuts down all pools together
- **Hot reload tiers** (hot reload is implemented, mechanisms differ, explicitly documented):
  - Python / Rust / Go / Java: automatic file-watch reload
  - C++ / Zig / Swift: `reload()` + an mtime check triggered manually — labelled the degraded tier

### 12.5 Memory scope and diagnostic output

- **Rust stays zero-unsafe**: `memory_scope` is delta-based (in-pool borrow/return/create counters + an optional custom allocator wrapper) and **never installs** `#[global_allocator]`; precision is below byte-level, the zero-dependency promise holds
- **Output**: stderr by default; a callback or a JSON file can be supplied
- **Switch**: no-op when `GC_PRIMITIVES_DIAG` is unset. C++ / Rust use macros and features; Python / Go / Java use a runtime check — same semantics, different mechanism
- **Nesting**: `outer` / `inner` are counted separately, with the delta attributed to the innermost scope

### 12.6 Leak detection and borrow sampling

- Only `detect_leaks()` and borrow snapshots are exposed; **no background thread, zero resident overhead**
- **Unified minimum**: all seven languages provide `lease_id` / `borrowed_at` / timeout verdict / user `tag`
- Stack snapshots are built in for Python / Go / Java only; Rust / C++ / Swift / Zig are not required to (avoids conflicting with zero-dependency / header-only)

### 12.7 Versioning and legacy policy

All seven languages move to `0.2.0` together. The documentation tables list **only 0.2.0** and explicitly state that **0.1.x is deprecated**; old tags are neither deleted nor advertised. Artifacts already published to PyPI / crates.io / Maven Central are **immutable and cannot be annotated retroactively**, so the notice lives in the new docs and Release notes; the 0.1.x GitHub Release descriptions have been amended with a deprecation notice.

### 12.8 Verification

Four layers: all seven language CIs green → one shared contract case aligned across languages → real download / install followed by a working consumer program → repo-wide secret scan + bilingual doc validation.

Every Markdown file has a Chinese version (default filename) and an English version (`.en.md`); the two versions link to each other at the top of the file.
