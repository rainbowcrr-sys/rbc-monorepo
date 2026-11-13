# gc-primitives · Swift Port

> [中文](README.md) · English

A Swift port of the same conceptual contract as the Java / C++ / Python / Rust / Go / Zig implementations. See section 11.1 of the repository-root [SPEC.en.md](../../SPEC.en.md) ([中文](../../SPEC.md)).
> ⚠️ **0.1.x is deprecated — use 0.2.0** (older releases lack the concurrency, diagnostics, configuration and observability capabilities and receive no further fixes).


## Why Swift needs a pool at all: ARC, not GC

Swift has **no garbage collector** — it uses **ARC (automatic reference counting)**, where an object is freed as soon as its reference count hits zero. So this README never says "saves GC". It claims only:

- Fewer heap `alloc` / `dealloc` operations
- Fewer retain/release reference-counting operations on hot paths
- Better cache locality after reuse, and reuse of the same reference instead of repeated allocation

**`T` must be a reference type (`T: AnyObject`).** A Swift getter on a value type returns a **copy**, so allowing `struct` would silently discard every mutation the caller makes to `lease.value` — the object would never come back to the pool in the state expected. Restricting to classes matches "heap object" semantics and lets `recycler` reset in place.

## Import

SwiftPM distribution is **zero registration, zero credentials**: a public Git repository + `Package.swift` + a semantic version tag is all that is needed.

```swift
// Package.swift
dependencies: [
    .package(
        url: "https://github.com/rainbowcrr-sys/rbc-monorepo.git",
        .upToNextMajor(from: "0.1.0")
    )
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "GCPrimitives", package: "rbc-monorepo")
    ])
]
```

> **Monorepo subdirectory note**: `.package(url:)` points at the repository root and expects `Package.swift` there. This port lives in `swift/gc-primitives/`, so consuming it directly from the root repository requires either a dedicated Git repository for that directory or a local path dependency. This iteration ships as a standalone `swift test`-able package; the distribution route is decided at release time (see below).

## Usage

```swift
import GCPrimitives

final class Buffer {
    var bytes: [UInt8] = []
}

let pool = try Pool<Buffer>(
    capacity: 32,
    factory: { Buffer() },
    recycler: { buf in buf.bytes.removeAll() }   // reset on return
)

let lease = try pool.borrow()
defer { try? lease.close() }                     // C1: every borrow must be returned
try lease.value.bytes.append(contentsOf: [1, 2, 3])
print(try lease.value.bytes)

try pool.assertNoActiveLeases()                  // turns a leak into a test failure
```

`lease.value` is a throwing getter; reading it after close throws `PoolError.leaseClosed`.

## The Safety Contract (C1–C5)

| Contract | Implementation | On violation |
| --- | --- | --- |
| C1 Explicit return | `lease.close()`, recommended `defer { try? lease.close() }` | Forgotten close: `deinit` fallback **settles counters and drops the object**, never caches it |
| C2 Borrow after close | `pool.close()` rejects `borrow()` and clears idle objects | `PoolError.poolClosed` |
| C3 Bounded | `NSLock`-protected bounded stack, cap `capacity` (default 16) | — |
| C4 Reset on return | `recycler` runs once per successful return | On throw: **object discarded, error propagated, counters still settle**, never returned to the pool |
| C5 Strict misuse detection | Double close, `value` after close, factory returning nil, `capacity <= 0` | Always `PoolError`; **no switch, no `fatalError`** |

**Counter semantics**: `returnCount / active` settle at the very start of `close()`, so a throwing `recycler` cannot leave a phantom active lease.

**The deinit tradeoff**: Swift's `deinit` cannot `throw`, so the fallback path cannot safely run a potentially throwing `recycler`. An object whose `close()` was forgotten is therefore **discarded rather than reused** — counters stay exact and a dirty object can never reach the next borrower. This is the key difference from C++ RAII and is recorded in SPEC 11.2.

## Concurrency Model: Lock-Protected Variant

Swift has no stable cross-platform thread-local API, so this port uses **one `NSLock`-protected bounded stack with counters taken inside the lock**, instead of per-thread state. Cross-thread use of the same `Lease` is not checked at runtime; the documented contract is that a lease belongs to the thread that borrowed it. CI verifies counter precision with 100 concurrent borrow/close operations via `DispatchQueue.concurrentPerform`.

## Diagnostics API

| Java | Swift |
| --- | --- |
| `borrow()` | `borrow() throws -> Lease<T>` |
| `capacity()` | `capacity` / `stats().capacity` |
| `idleCount()` | `stats().idle` |
| `activeLeases()` | `stats().active` |
| `borrowCount()` / `returnCount()` | `stats().borrowCount` / `.returnCount` |
| `assertNoActiveLeases()` | `assertNoActiveLeases() throws` |

Also `stats().created`, `stats().closed`, and `lease.returned`.

## Verification

```bash
cd swift/gc-primitives
swift test
```

CI runs on **macOS (Xcode Swift) and Ubuntu Linux (Swift 5.9+)**. There are 12 XCTest cases covering every row above plus concurrency and the deinit fallback.

## Distribution (`0.1.0` published)

**SwiftPM dependency** (recommended):

```swift
.package(url: "https://github.com/rainbowcrr-sys/gc-primitives-swift.git", from: "0.1.0")
```

The standalone distribution repo https://github.com/rainbowcrr-sys/gc-primitives-swift keeps `Package.swift` at its root and is tagged `v0.1.0`.

- **Canonical source**: this directory, `swift/gc-primitives/`; CI runs 12 XCTest cases on both macOS and Ubuntu
- **Monorepo release tag**: `swift/gc-primitives/v0.1.0`, with a source tarball attached to the Release
- **Verification page**: https://swiftpackageindex.com/rainbowcrr-sys/gc-primitives-swift (first-time indexing can be requested at https://swiftpackageindex.com/add-a-package )

> **Why a second repository**: SwiftPM requires `Package.swift` at the repository root and only accepts plain semantic-version tags (`v0.1.0`); it does not understand subdirectory prefixes like `swift/gc-primitives/v0.1.0`, and `v0.1.0` was already taken by the first Java release. Both copies hold identical code and are synced at release time.

No registration, no token, no credentials.

Every Markdown file has a Chinese and an English version; English filenames end in `.en.md`.
