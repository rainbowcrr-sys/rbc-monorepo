# gc-primitives

> [中文](README.md) · English

An object-pooling primitives library that reduces allocation and enables reuse — **one shared conceptual contract implemented in Java, C++, and Python**. It is not tied to any business scenario; callers decide the latency/throughput trade-off themselves.

The first version, `0.1.0`, does exactly one thing: it turns "object pool + reuse context" into a set of composable primitives.

## Implementations in three languages

All three languages are **ports of the same conceptual contract**. See **[SPEC.en.md](SPEC.en.md)** ([中文](SPEC.md)) for the behavior matrix and the full mapping.

| Language | Directory | Import | Distribution | Status |
| --- | --- | --- | --- | --- |
| Java 11 | [`gc-primitives/`](gc-primitives/) | `net.de5.rainbowcrrsys:gc-primitives:0.1.0` | Maven Central | ✅ Published |
| C++17 | [`cpp/`](cpp/) | `#include <rbc/gc.hpp>` (header-only) | vcpkg / Conan | ✅ Implemented |
| Python 3.9+ | [`python/`](python/) | `from gc_primitives import Pool` | PyPI | ✅ Implemented |

Each language has its own independent version number; all are Apache-2.0. The benefit claims are kept separate: Java lowers allocation rate, C++ cuts `malloc`/`free`, and **the Python port makes no performance claim** (a pure semantic port; see [`python/README.en.md`](python/README.en.md) for why).

Below is the **Java** documentation. For C++ and Python, see their respective READMEs. Every Markdown file in this repository has a Chinese version (default filename) and an English version (filename ending in `.en.md`).

## Import

```groovy
// Gradle
implementation 'net.de5.rainbowcrrsys:gc-primitives:0.1.0'
```

```xml
<!-- Maven -->
<dependency>
  <groupId>net.de5.rainbowcrrsys</groupId>
  <artifactId>gc-primitives</artifactId>
  <version>0.1.0</version>
</dependency>
```

Baseline: Java 11. License: Apache-2.0.

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

`gc-primitives` publishes a single jar. `example` is a runnable sample and `benchmarks` is the JMH benchmark; neither is part of the published artifact.

## API Contract

| Type | Purpose |
| --- | --- |
| `Pool<T>` | Borrowing entry point, with diagnostics: `activeLeases()` / `borrowCount()` / `returnCount()` / `assertNoActiveLeases()` |
| `Lease<T>` | An `AutoCloseable` lease; `get()` retrieves the object, `close()` returns it |
| `Recycler<T>` | Reset hook invoked on return, restoring the object to a reusable state |
| `Pools` | Static factory: `threadLocal(factory, recycler, capacity)` |

Implementation strategy: **thread-local + bounded**. Borrow/return is lock-free with no cross-thread synchronization; on a free-slot hit no object is allocated, and even the `Lease` handle itself is reused from a thread-local stack, so the normal path is close to zero allocation. Each thread keeps at most `capacity` idle objects (default 64); excess returned objects are discarded.

Misuse is **always strictly validated** and immediately throws `PoolStateException`:

- Double return / `get()` after close
- Cross-thread return / cross-thread use
- `factory` returning `null`
- `capacity <= 0` throws `IllegalArgumentException`

Unreturned leases are counted precisely by `activeLeases()`; use `assertNoActiveLeases()` in tests to turn a leak into a failure.

**Usage contract**: the lease and the borrowed object belong to the borrowing thread only; after closing, do not retain a reference to the object. These two rules are the caller's responsibility — the library cannot intercept "still referenced externally after return" at runtime.

## Repository Layout

```
rbc-monorepo/
├── gc-primitives/          main library, single jar, subpackages by pool/lease/recycler
│   ├── src/main/java/net/de5/rainbowcrrsys/gcprimitives/
│   └── src/test/java/...   JUnit 5
├── example/                runnable sample + nine contract self-checks
├── benchmarks/             JMH benchmark (separate module)
├── cpp/                    C++17 header-only implementation
├── python/                 Python 3.9+ semantic port
├── .github/workflows/      CI workflows
├── SPEC.md / SPEC.en.md    cross-language contract spec (中文 / English)
├── LICENSE                 Apache-2.0
└── build.gradle / settings.gradle / gradle.properties
```

Future libraries will be added under the same namespace as modules with the `rbc-` prefix; `gc-primitives` keeps its name.

## Local Build

Requires **Gradle 8.10.2** (running on Java 11). The repository does not ship a wrapper jar; to get `./gradlew`, run once:

```bash
gradle wrapper --gradle-version 8.10.2
```

Common commands:

```bash
gradle :gc-primitives:test          # unit tests
gradle :example:run                # run the sample and contract self-checks; prints QuickStart OK
gradle :example:allocCheck         # quick allocation-byte check
gradle :benchmarks:jmh             # JMH + -prof gc
gradle :gc-primitives:build        # jar / sourcesJar / javadocJar
```

## Verifying That It Really Saves GC

The benchmark compares `allocateFresh` (a `new StringBuilder` every time) with `borrowPooled` (pooled borrow), using JMH's `-prof gc` to report allocation rate and GC count:

```bash
gradle :benchmarks:jmh
# or with custom arguments
gradle :benchmarks:run --args="AllocationBenchmark -f 1 -wi 3 -i 5 -prof gc"
```

Without JMH, a quick allocation-byte check using `ThreadMXBean` is also available:

```bash
gradle :example:allocCheck
```

Measured locally on Java 11 (N = 1,000,000 iterations, 3 warmup rounds):

| Path | Allocated bytes | Composition |
| --- | --- | --- |
| `new StringBuilder` each time | approx. 106.8 MB | StringBuilder + internal buffer + result String |
| Pooled borrow | approx. 53.4 MB | Only the result String from `toString()` |

Pooling eliminates the allocation of the object and its internal buffer entirely, cutting allocated bytes by about 50%; what remains is the business return value, outside the pool's scope. For formal conclusions rely on `gc.alloc.rate` / `gc.count` from `-prof gc`; record a baseline in the Release Notes before publishing so each version can be compared.

## Roadmap

- `0.2.0`: primitive specialization (eliminating boxing allocation), reusable `byte[]` / `char[]` buffers
- Later: stack-style reuse contexts, richer diagnostic events

During `0.x` the API is not frozen; breaking changes will be reflected in the minor version.

## License

Apache License 2.0, see [LICENSE](LICENSE).
