# gc-primitives Cross-Language Contract Specification (SPEC)

> [中文](SPEC.md) · English

**Status**: Final · 2026-11-12 · Located at the repository root
**Applies to**: Java `0.1.0` (published to Maven Central), C++ `0.1.0`, Python `0.1.0`
**Relationship**: **Ports of one shared conceptual contract**, not three independent rewrites. Behavioral consistency is guaranteed by contract tests; **performance numbers are not part of this specification** — each language's benchmark results live in its own README.

All three language READMEs reference this file. Every Markdown file in the repository has a Chinese version and an English version; English filenames end in `.en.md`.

---

## 1. Positioning and Benefit Claims

The library makes one promise: turn "object pool + reuse context" into composable primitives, without being tied to any scenario — callers decide the latency/throughput trade-off.

Benefit claims must be written separately per language and never mixed:

| Language | Actual benefit | Must not be described as |
| --- | --- | --- |
| Java | No object allocation on a free-slot hit; lower allocation rate and young GC pressure | — |
| C++ | Fewer `malloc`/`free` calls and better cache locality after reuse | "saving GC" — C++ has no GC |
| Python | Cross-language contract consistency, clear semantics, teaching/comparison value | "faster than the interpreter" — see below |

**Note on Python**: CPython primarily uses reference counting (an object is freed immediately when its reference count hits zero), with a generational GC layered on top solely to collect reference cycles. On top of that, pymalloc arenas and small-object free-lists (the interpreter already pools `list` / `dict` / `float`, etc.) mean reuse is happening underneath. A hand-written pure-Python object pool often just overlaps with those built-in caches and can even be slower due to the extra Python function call. The Python port is therefore explicitly a **pure semantic port with no performance promise**.

## 2. Five Core Contracts

| ID | Contract | Consequence of violation |
| --- | --- | --- |
| C1 | Every handle obtained from `borrow()` must be explicitly closed | An unreturned lease is a leak, precisely detectable via the `active` count |
| C2 | The handle and the borrowed object belong to the borrowing thread only; no cross-thread transfer | Throws an exception (kept identically in all three languages) |
| C3 | The number of idle objects per thread is bounded by `capacity`; excess is discarded | Bounded memory footprint, no unbounded residency |
| C4 | On return, the library invokes the reset hook to restore the object to a clean state | Dirty data must never reach the next borrow |
| C5 | Misuse is **always strictly validated**, with no switch and no Debug/Release split | Throws immediately; never undefined behavior |

C5 covers: double return, cross-thread return, cross-thread use, `get()` after close, factory returning an empty value, and `capacity <= 0`.

> The library cannot intercept "still referenced externally after return" at runtime. It is the caller's responsibility not to retain a reference to the object after closing. All three language docs must state this.

## 3. Type and Naming Mapping

| Concept | Java | C++ | Python |
| --- | --- | --- | --- |
| Pool | `Pool<T>` | `rbc::gc::Pool<T, Factory, Recycler>` | `Pool` |
| Lease | `Lease<T>` (try-with-resources) | `Lease` (move-only, RAII destructor) | `Lease` (`with` context manager) |
| Reset hook | `Recycler<T>` | Template parameter `Recycler`, `noexcept` by convention | `recycler` callable |
| Factory | `Supplier<T>` | Template parameter `Factory`, returning `T*` | `factory` callable |
| Entry point | `Pools.threadLocal(...)` | Direct construction / `rbc::gc::make_pool(...)` | Direct `Pool(...)` construction |
| Exception | `PoolStateException` | `rbc::gc::pool_error : std::logic_error` | `PoolStateError` |

`::` is simply C++'s namespace separator, equivalent to the dot in a Java package name; it exists to avoid `Pool` name collisions and is not an operator.

**C++ namespace**: `rbc::gc::Pool`.
**Instance semantics**: in all three languages a **global `Pool` object holds thread-local state** — one instance is used across threads, each with its own bounded idle stack; it is not "one Pool per thread".

## 4. Method Name Mapping (Diagnostics Contract)

| Java | C++ | Python | Meaning |
| --- | --- | --- | --- |
| `borrow()` | `borrow()` | `borrow()` | Borrow |
| `capacity()` | `capacity()` | `capacity()` | Per-thread bound |
| `idleCount()` | `idle_count()` | `idle_count()` | Idle objects on the current thread |
| `activeLeases()` | `active_leases()` | `active_leases()` | Unreturned leases |
| `borrowCount()` | `borrow_count()` | `borrow_count()` | Total borrows |
| `returnCount()` | `return_count()` | `return_count()` | Total returns |
| `assertNoActiveLeases()` | `assert_no_active_leases()` | `assert_no_active_leases()` | Turn a leak into a test failure |

Python uses snake_case to match the semantics rather than copying camelCase; this table is the item-by-item verification basis.

**Counter implementation**: Java uses `LongAdder`; C++ uses **precise global `std::atomic` counting**, accepting one atomic add per borrow/return; Python guards integers with `threading.Lock` and only requires semantic equivalence.

## 5. Return Path and Reset Failure

| Language | Reset convention | If reset fails |
| --- | --- | --- |
| Java | `Recycler` should not throw | Consistent with the documented convention; no extra design |
| C++ | Reset call is `noexcept` by convention | Invoked inside a `noexcept` boundary; a throw triggers `std::terminate`. Same stance as Java's "reset logic should not throw" — the constraint lives at the contract level |
| Python | No `noexcept` concept | The exception propagates, but the **object is discarded and never returned to the pool**; the lease is still invalidated and counters still settle. A dirty object must never re-enter the pool |

**C++ destructor note**: throwing from a C++ destructor causes `std::terminate`. Therefore, if cross-thread misuse is detected during `Lease` destruction (the handle was moved to and destroyed on another thread), the result is `std::terminate()` rather than an exception — "always strictly validated" still holds, just without silently letting it pass. An explicit `close()` performs full validation and throws `pool_error`.

**Python return mechanism**: via `with`'s `__exit__` (or an explicit `close()`); there is no destructor-based automatic return. If the `with` body raises, the object is still returned first, then the original exception propagates.

## 6. Thread Ownership Validation

All three languages keep "cross-thread return / cross-thread use throws immediately" unchanged.

- C++: each Lease stores a `std::thread::id` and compares it on return; this hot-path cost is **accepted**
- Python: a `threading.local` bounded stack guarantees thread isolation only; **multiple asyncio tasks on the same thread are not isolated** — the docs must state this limitation and not pretend otherwise
- No "strict switch", no default relaxation, no reduction to double-return detection only

## 7. Explicit Exclusions

- **No hard-coded performance numbers**. Measurements like Java's 106.8MB → 53.4MB live only in the Java README and Release Notes, not in this specification, so Python is not bound by them
- "Zero new object construction on a hit" is not a hard three-language requirement
- No mandatory throughput/latency target for any language
- The three APIs need not be literally identical in naming; only **behavioral contract** consistency plus the verifiable mapping tables in this file are required

## 8. Per-Language Checklist

| Contract item | Java 0.1.0 | C++ 0.1.0 | Python 0.1.0 |
| --- | --- | --- | --- |
| C1 Explicit return | ✅ try-with-resources | ✅ RAII destructor + `close()` | ✅ `with` / `close()` |
| C2 Thread ownership | ✅ | ✅ `thread::id` | ✅ `threading.get_ident()` |
| C3 Bounded | ✅ | ✅ | ✅ |
| C4 Reset on return | ✅ | ✅ | ✅ |
| C5 Strict misuse detection | ✅ | ✅ | ✅ |
| Diagnostics mapping | ✅ | ✅ | ✅ snake_case |
| Contract tests | ✅ JUnit 5 | ✅ 21 checks, zero third-party deps | ✅ 14 tests, `unittest` |
| Benchmark | ✅ JMH + ThreadMXBean | ✅ Google Benchmark (optional build) | ⬜ No performance claim |

## 9. Versioning and Distribution

**Versioning**: each language has its own independent version number; C++ and Python both start at `0.1.0` and are not locked to the published Java `0.1.0`. Java `0.1.0` can never be overwritten; changes require `0.1.1` / `0.2.0`.

| Language | Package / coordinates | Channel | Baseline |
| --- | --- | --- | --- |
| Java | `net.de5.rainbowcrrsys:gc-primitives:0.1.0` | Maven Central (published) | Java 11 + Gradle 8.10.2 |
| C++ | `gc-primitives`, namespace `rbc::gc` | vcpkg + Conan | C++17, header-only |
| Python | `gc-primitives` (import name `gc_primitives`) | PyPI | Python 3.9+ |

License: Apache-2.0 across all three languages.

## 10. Repository Layout

```
rbc-monorepo/
├── README.md / README.en.md         root docs (中文 / English)
├── SPEC.md / SPEC.en.md             this spec (中文 / English)
├── gc-primitives/                   Java main library (published)
├── example/ benchmarks/             existing Java modules
├── cpp/
│   ├── include/rbc/gc/pool.hpp      header-only core
│   ├── include/rbc/gc.hpp           umbrella header
│   ├── tests/contract_test.cpp      contract tests
│   ├── bench/                       Google Benchmark
│   ├── CMakeLists.txt / vcpkg.json / conanfile.py
│   └── README.md / README.en.md
└── python/
    ├── gc_primitives/               __init__.py / _pool.py
    ├── tests/test_contract.py
    ├── pyproject.toml
    └── README.md / README.en.md
```

The `cpp/` and `python/` directories sit alongside the existing `gc-primitives/`, sharing the repository's CI, tag cadence, and `rbc-` organization prefix. Every Markdown file has a Chinese version (default filename) and an English version (`.en.md`); the two versions link to each other at the top of the file.
