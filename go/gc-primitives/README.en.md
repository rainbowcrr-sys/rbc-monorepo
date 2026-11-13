# gc-primitives · Go Port

> [中文](README.md) · English

A Go port of the same conceptual contract as the Java / C++ / Python / Rust implementations. See the repository-root [SPEC.en.md](../../SPEC.en.md) ([中文](../../SPEC.md)) for the behavioral specification.
> ⚠️ **0.1.x is deprecated — use 0.2.0** (older releases lack the concurrency, diagnostics, configuration and observability capabilities and receive no further fixes).


> Directory: `go/gc-primitives/` (top level by language, inner level by project).
> **Go has no central registry, no account, no API token, and no upload step** — a module version is just a Git tag. `go get` pulls source directly from GitHub, and pkg.go.dev indexes it automatically from `proxy.golang.org`.

## Import

The module path must exactly match the repository directory path:

```bash
go get github.com/rainbowcrr-sys/rbc-monorepo/go/gc-primitives@v0.1.0
```

The directory name contains a hyphen but a Go package name cannot, so an explicit alias is clearest:

```go
package main

import (
    "fmt"

    gcprimitives "github.com/rainbowcrr-sys/rbc-monorepo/go/gc-primitives"
)

func main() {
    p, err := gcprimitives.New(8,
        func() ([]byte, bool) { return make([]byte, 0, 32), true },
        func(b *[]byte) error { *b = (*b)[:0]; return nil })
    if err != nil { panic(err) }

    l, err := p.Borrow()
    if err != nil { panic(err) }
    defer l.Close()                       // C1: every borrow must be closed

    *l.Get() = append(*l.Get(), "hello"...)
    fmt.Println(string(*l.Get()))
}
```

Package name `gcprimitives`, baseline **Go 1.21** (generics + the newer `sync/atomic` types), Apache-2.0, **zero third-party dependencies**.

## The Most Important Difference: A Concurrency Variant

Go has no thread-local storage: goroutines migrate between OS threads, so `thread_local` semantics do not exist. C2 (thread ownership) and C3 (per-thread bound) are therefore an **explicitly documented concurrency variant**, not a strict port:

| SPEC contract | Go port |
| --- | --- |
| Per-thread bounded idle stack | Sharded bounded stacks, one per `GOMAXPROCS(0)`, each guarded by a `sync.Mutex`; at most `capacity` idle objects per shard, process-wide bound `capacity × GOMAXPROCS` |
| Cross-thread return/use throws | Go cannot reliably identify a goroutine, so there is **no runtime check**; the documented contract is that a lease belongs to the borrowing goroutine and must not be passed across goroutines |
| `idleCount()` for the current thread | `IdleCount()` returns a snapshot across **all shards** (not a globally linearizable value) |
| Global diagnostics | `atomic.Int64`, precise across goroutines |

Borrows pick a shard with an atomic round-robin counter, and the factory is called outside the shard lock so a slow factory does not block other borrowers of the same shard.

## API Mapping

| Java | Rust | Go |
| --- | --- | --- |
| `Pools.threadLocal(...)` | `Pool::new(...)` | `gcprimitives.New[T](capacity, factory, recycler)` |
| `Lease<T>` | callback scope | `*Lease[T]` (`defer Close()`) |
| `borrow()` | `with_borrow(f)` | `Borrow() (*Lease[T], error)` |
| `Supplier<T>` | `FnMut() -> Option<T>` | `Factory[T] func() (T, bool)` (`false` = creation failed) |
| `Recycler<T>` | `FnMut(&mut T) -> Result` | `Recycler[T] func(*T) error` (non-nil = reset failed) |
| `PoolStateException` | `PoolError` | Misuse panics immediately; recoverable failures return `error` |
| `capacity()` | `capacity()` | `Capacity()` / `ShardCount()` |
| `idleCount()` | `idle_count()` | `IdleCount()` (all-shard snapshot) |
| `activeLeases()` | `active_leases()` | `ActiveLeases()` |
| `borrowCount()` / `returnCount()` | same | `BorrowCount()` / `ReturnCount()` |
| `assertNoActiveLeases()` | `assert_no_active_leases()` | `AssertNoActiveLeases() error` |

## Contract Details

- **Always strictly validated**: a double `Close()` panics; `Get()` after `Close()` panics. No switch, no debug/release split
- **`capacity <= 0`** → `ErrInvalidCapacity`; nil `factory` / `recycler` → `ErrNilHook` (Go-specific)
- **Factory returning `false`** → `ErrFactoryFailed`, no lease created and counters unchanged (aligned with "factory returned an empty value")
- **Reset failure**: `Close()` returns that `error`, the dirty object is **discarded and never returned to the pool**, and counters still settle. Callers that care about reset failures should not just `defer l.Close()` and ignore the error
- **Unreturned leases**: Go has no destructor fallback; `ActiveLeases()` detects them precisely, and `AssertNoActiveLeases()` turns them into a test error
- **Usage contract**: a `Lease` must not be copied or used across goroutines; the pointer from `Get()` must not be retained after `Close()`

## Verification

```bash
cd go/gc-primitives
go test -race ./...     # contract tests + Example + race detector
go vet ./...
gofmt -l .              # should print nothing
```

CI actually runs two toolchains, **Go 1.21** and **stable**, before any tag is cut. The release pipeline also has a consumer job: `go mod init` → `go get ...@v0.1.0` → `go run .`, proving that other people can really download and use the module.

## Distribution and the Tag Exception

The other four languages use double-underscore tags (`gc-primitives__java__v*`, etc.). **Go cannot**: in a multi-module repository, a submodule's version tag must carry the directory prefix — a hard rule of the Go toolchain.

```
go/gc-primitives/v0.1.0
```

Go is therefore a documented exception (see SPEC section 10). When someone runs `go get ...@v0.1.0`, the go command looks for that prefixed tag automatically.

**There is nothing to "register"**: a public repository, a `go.mod` path matching the GitHub path, a `v`-prefixed tag, a LICENSE, and proper doc comments on exported symbols are all pkg.go.dev needs. After the tag is pushed, the workflow requests `proxy.golang.org/<module path>/@v/v0.1.0.info` once to warm the cache and trigger indexing. If the page still says Not Found, open https://pkg.go.dev/github.com/rainbowcrr-sys/rbc-monorepo/go/gc-primitives and click **Request** — it appears within minutes, **no login and no account required**.

The version is independent from the other four languages and is not locked to the published Java `0.1.1`. Published Go versions cannot be overwritten either.
