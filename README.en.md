# gc-primitives

> [中文](README.md) · English

An object-pooling primitives library that reduces allocation and enables reuse — **one shared conceptual contract implemented in Java, C++, Python, Rust, and Go**. It is not tied to any business scenario; callers decide the latency/throughput trade-off themselves.

The first version does exactly one thing: it turns "object pool + reuse context" into a set of composable primitives. See **[SPEC.en.md](SPEC.en.md)** ([中文](SPEC.md)) for the behavior matrix and full mapping.

## Implementations in Seven Languages

| Language | Project directory | Import | Distribution | Status |
| --- | --- | --- | --- | --- |
| Java 11 | [`java/gc-primitives/`](java/gc-primitives/) | `net.de5.rainbowcrrsys:gc-primitives` | Maven Central | ✅ `0.2.0` |
| C++17 | [`cpp/gc-primitives/`](cpp/gc-primitives/) | `#include <rbc/gc.hpp>` (header-only) | GitHub Release / vcpkg / Conan | ✅ `0.2.0` |
| Python 3.9+ | [`python/gc-primitives/`](python/gc-primitives/) | `from gc_primitives import Pool` | PyPI | ✅ `0.2.0` |
| Rust 1.70+ | [`rust/gc-primitives/`](rust/gc-primitives/) | `use gc_primitives::Pool` | crates.io | ✅ `0.2.0` |
| Go 1.21+ | [`go/gc-primitives/`](go/gc-primitives/) | `go get github.com/rainbowcrr-sys/rbc-monorepo/go/gc-primitives` | Git tag + pkg.go.dev (no registry, no credentials) | ✅ `0.2.0` |
| Swift 5.9+ | [`swift/gc-primitives/`](swift/gc-primitives/) | `GCPrimitives` (SwiftPM) | Standalone repo [`gc-primitives-swift`](https://github.com/rainbowcrr-sys/gc-primitives-swift) + Git tag (no registration, no credentials) | ✅ `0.2.0` |
| Zig 0.14 | [`zig/gc-primitives/`](zig/gc-primitives/) | `gc_primitives` | GitHub Release tarball + Zig Index (no registration, no credentials) | ✅ `0.2.0` |

> ⚠️ **The entire 0.1.x line is deprecated.** `0.1.0` / `0.1.1` artifacts remain downloadable (registries are immutable — they cannot be deleted or rewritten), but they **lack the concurrency, diagnostics, configuration and observability added in 0.2.0 and receive no further fixes**. Use `0.2.0`.

Each language has its own independent version number; all are Apache-2.0. Benefit claims are kept separate: Java lowers allocation rate, C++ and Rust cut heap allocations, Go cuts heap allocations with zero credentials, Swift cuts ARC heap allocations and retain-release traffic, Zig performs zero `allocator.create` on a free-slot hit, and **the Python port makes no performance claim** (a pure semantic port; see [`python/gc-primitives/README.en.md`](python/gc-primitives/README.en.md)). The Rust port additionally promises **zero `unsafe`, zero dependencies**; the Go port is a concurrency variant of C2/C3 (no thread-local storage), see section 8.2 of `SPEC.en.md`; Swift / Zig are in section 11.

Below is the **Java** documentation. For C++ / Python / Rust / Go / Swift / Zig, see their respective READMEs. Every Markdown file in this repository has a Chinese version and an English version; English filenames end in `.en.md`.

## Repository Layout Convention

The top level is organized by **language**, the inner level by **project** — adding a new project does not require a new repository:

```
java/gc-primitives/     cpp/gc-primitives/     python/gc-primitives/     rust/gc-primitives/     go/gc-primitives/     swift/gc-primitives/     zig/gc-primitives/
java/example/           java/benchmarks/       (Java sibling modules, not published)
java/test/   cpp/test/   python/test/   rust/test/   go/test/   swift/test/   zig/test/   ← future project example
```

The root holds only README, SPEC, LICENSE, `.github/`, `.gitignore`, and the Gradle root configuration (`build.gradle` / `settings.gradle` / `gradle.properties`). A new project `test` simply adds one directory under each language; Gradle adds `include(':java:test')` plus a `projectDir` in `settings.gradle`.

## Tag Convention

The library name `gc-primitives` already contains a hyphen, so a **double underscore** is used as separator to avoid ambiguous splitting:

| Language | Tag pattern | Workflow | Example |
| --- | --- | --- | --- |
| Java | `gc-primitives__java__v*` | `publish.yml` | `gc-primitives__java__v0.1.1` |
| Python | `gc-primitives__python__v*` | `publish-pypi.yml` | `gc-primitives__python__v0.1.1` |
| C++ | `gc-primitives__cpp__v*` | `release-cpp.yml` | `gc-primitives__cpp__v0.1.1` |
| Rust | `gc-primitives__rust__v*` | `publish-rust.yml` | `gc-primitives__rust__v0.1.0` |
| Go (exception) | `go/gc-primitives/v*` | `publish-go.yml` | `go/gc-primitives/v0.1.0` |
| Swift (exception) | `v*` (standalone distribution repo) | `publish-swift.yml` | `v0.1.0` |
| Zig (exception) | `zig/gc-primitives/v*` | `publish-zig.yml` | `zig/gc-primitives/v0.1.0` |

Swift also has a monorepo tag `swift/gc-primitives/v0.1.0` that triggers the workflow and carries the Release asset; the SwiftPM version tag must be a plain semantic version, so it lives in the standalone distribution repository. Upload-style pipelines verify "tag version == declared version in code" and refuse to publish on a mismatch; **Go / Swift / Zig are the exceptions** — a subdirectory module/package tag must carry the directory prefix, and there is no version declaration field, so verification is done by a real consumer fetch + run job instead. Historical tags `v0.1.0` / `py-v0.1.0` / `cpp-v0.1.0` are kept but retired from the trigger rules. Maven Central and PyPI never allow a published version to be overwritten; changing code requires a version bump.

## Import (Java)

```groovy
// Gradle
implementation 'net.de5.rainbowcrrsys:gc-primitives:0.1.1'
```

```xml
<!-- Maven -->
<dependency>
  <groupId>net.de5.rainbowcrrsys</groupId>
  <artifactId>gc-primitives</artifactId>
  <version>0.1.1</version>
</dependency>
```

Baseline: Java 11. `0.1.1` is a pure engineering refactor (directory and Gradle path changes) — **the classes inside the jar are identical to `0.1.0`**; `0.1.0` remains importable too. License: Apache-2.0.

## Quick Start

```java
import net.de5.rainbowcrrsys.gcprimitives.*;

Pool<StringBuilder> pool =
    Pools.threadLocal(StringBuilder::new, sb -> sb.setLength(0), 8);

try (Lease<StringBuilder> lease = pool.borrow()) {
    StringBuilder sb = lease.get();
    sb.append("hello");
    // use sb
} // returned automatically; Recycler clears sb here
```

`gc-primitives` publishes a single jar; `java/example` is a runnable sample and `java/benchmarks` is the JMH benchmark — neither is part of the published artifact.

## API Contract

| Type | Purpose |
| --- | --- |
| `Pool<T>` | Borrowing entry point, with diagnostics: `activeLeases()` / `borrowCount()` / `returnCount()` / `assertNoActiveLeases()` |
| `Lease<T>` | An `AutoCloseable` lease; `get()` retrieves the object, `close()` returns it |
| `Recycler<T>` | Reset hook invoked on return, restoring the object to a reusable state |
| `Pools` | Static factory: `threadLocal(factory, recycler, capacity)` |

Implementation strategy: **thread-local + bounded**. Borrow/return is lock-free with no cross-thread synchronization; on a free-slot hit no object is allocated, and even the `Lease` handle itself is reused from a thread-local stack. Each thread keeps at most `capacity` idle objects (default 64); excess returned objects are discarded.

Misuse is **always strictly validated** and immediately throws `PoolStateException`: double return / `get()` after close, cross-thread return / cross-thread use, `factory` returning `null`; `capacity <= 0` throws `IllegalArgumentException`.

Unreturned leases are counted precisely by `activeLeases()`; use `assertNoActiveLeases()` in tests to turn a leak into a failure.

**Usage contract**: the lease and the borrowed object belong to the borrowing thread only; after closing, do not retain a reference to the object. The Rust port makes these misuse cases impossible at compile time via a callback closure — see section 8.1 of `SPEC.en.md`; the Go port relies on a documented contract and `AssertNoActiveLeases()`, see section 8.2; the Swift / Zig concurrency variants, deinit fallback and explicit-release differences are in section 11.

## Local Build

Requires **Gradle 8.10.2** (running on Java 11). The repository does not ship a wrapper jar; to get `./gradlew`, run `gradle wrapper --gradle-version 8.10.2` once.

Common commands (module paths were updated to `:java:*` together with the directory layout):

```bash
gradle :java:gc-primitives:test          # unit tests
gradle :java:example:run                 # run the sample and contract self-checks; prints QuickStart OK
gradle :java:example:allocCheck          # quick allocation-byte check
gradle :java:benchmarks:jmh              # JMH + -prof gc
gradle :java:gc-primitives:build         # jar / sourcesJar / javadocJar
```

## Verifying That It Really Saves GC

The benchmark compares `allocateFresh` (a `new StringBuilder` every time) with `borrowPooled` (pooled borrow), using JMH's `-prof gc` to report allocation rate and GC count:

```bash
gradle :java:benchmarks:jmh
# or with custom arguments
gradle :java:benchmarks:run --args="AllocationBenchmark -f 1 -wi 3 -i 5 -prof gc"
```

Without JMH, a quick allocation-byte check using `ThreadMXBean` is available: `gradle :java:example:allocCheck`.

Measured locally on Java 11 (N = 1,000,000, 3 warmup rounds): `new StringBuilder` each time used approx. 106.8 MB, pooled borrow approx. 53.4 MB (only the result String from `toString()` remains). Pooling eliminates the object and its internal buffer allocation entirely, cutting allocated bytes by about 50%. For formal conclusions use `gc.alloc.rate` / `gc.count` from `-prof gc`.

## Roadmap

- `0.2.0`: primitive specialization (eliminating boxing allocation), reusable `byte[]` / `char[]` buffers
- Later: stack-style reuse contexts, richer diagnostic events

During `0.x` the API is not frozen; breaking changes will be reflected in the minor version.

## License

Apache License 2.0, see [LICENSE](LICENSE).
