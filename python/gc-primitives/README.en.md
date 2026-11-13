# gc-primitives · Python Port

> [中文](README.md) · English
> ⚠️ **0.1.x is deprecated — use 0.2.0** (older releases lack the concurrency, diagnostics, configuration and observability capabilities and receive no further fixes).


> Directory: `python/gc-primitives/` (top level by language, inner level by project).

A pure-Python semantic port of the same conceptual contract as the Java / C++ versions. See the repository-root [SPEC.en.md](../../SPEC.en.md) ([中文](../../SPEC.md)) for the behavioral specification.

> **No performance promise.** This port exists for cross-language contract consistency, clear semantics, and teaching/comparison — not for being "faster than the interpreter". The reason is below.

## Why a Pure-Python Object Pool Promises No Speedup

CPython primarily uses **reference counting**: each object tracks who refers to it and is freed immediately when that count reaches zero, rather than waiting for a GC pass. A **generational GC** is layered on top solely to collect cycles that reference counting cannot handle (A points to B, B points to A). On top of that, pymalloc arenas and small-object free-lists (the interpreter already pools `list` / `dict` / `float`, etc.) mean reuse is happening underneath. A hand-written pure-Python object pool often just overlaps with those built-in caches and can even be slower because of the extra Python function call.

So the value of this port is: **the same contract holds in a third language**, and it can be compared item by item against the Java / C++ versions.

## Import

```python
from gc_primitives import Pool

pool = Pool(list, list.clear, capacity=8)   # factory, recycler, capacity

with pool.borrow() as xs:
    xs.append("hello")
# __exit__ returns it automatically; list.clear resets the object here
```

`with pool.borrow() as x` corresponds to Java's try-with-resources and C++'s RAII destructor.
**You must use `with` explicitly (or call `lease.close()` explicitly)** — the Python port does not auto-return via a destructor fallback.

Stateless objects can omit the reset hook:

```python
from gc_primitives import Pool, noop_recycler

pool = Pool(object, noop_recycler)   # the recycler argument can also be omitted entirely
```

## API Mapping (snake_case matches semantics, not camelCase)

| Java | C++ | Python |
| --- | --- | --- |
| `Pool<T>` / `Pools.threadLocal(...)` | `rbc::gc::Pool<T, F, R>` | `Pool` |
| `Lease<T>` | `Pool::Lease` | `Lease` |
| `Recycler<T>` / `Supplier<T>` | Template parameters `Recycler` / `Factory` | `recycler` / `factory` callables |
| `PoolStateException` | `pool_error` | `PoolStateError` |
| `borrow()` | `borrow()` | `borrow()` |
| `capacity()` / `idleCount()` | `capacity()` / `idle_count()` | `capacity()` / `idle_count()` |
| `activeLeases()` | `active_leases()` | `active_leases()` |
| `borrowCount()` / `returnCount()` | `borrow_count()` / `return_count()` | `borrow_count()` / `return_count()` |
| `assertNoActiveLeases()` | `assert_no_active_leases()` | `assert_no_active_leases()` |

## Contract Details (Python-specific)

- **Concurrency uses a `threading.local` bounded stack**, guaranteeing thread isolation only.
  ⚠️ **Multiple asyncio tasks on the same thread are NOT isolated**: a coroutine switch does not switch threads, and this library does not recognize task boundaries. For task-level isolation, use a separate Pool per task yourself, or wait for a future ContextVar-based option.
- **Reset failure**: the exception propagates as usual, but the **object is discarded and never returned to the pool**; the lease is still invalidated and counters still settle. Unlike Java/C++, there is no "reset must not throw" convention — Python has no `noexcept`, so contamination is isolated at the contract level instead.
- **`factory` returning `None`** throws `PoolStateError`; `capacity <= 0` throws `ValueError`.
- **Misuse is always strictly validated**: double return, cross-thread return/use, and `get()` after close all throw `PoolStateError`.
- No interception of "still referenced externally after return" — after `close()`, do not retain the object obtained via `with ... as x`.

## Tests

Standard-library `unittest` only — no dependencies to install:

```bash
python3 -m unittest discover -s python/gc-primitives/tests -v
```

14 contract tests correspond item by item to the Java / C++ versions, with extra coverage for "return still happens when the `with` body raises" and "reset failure discards the object".

## Distribution

PyPI: `gc-primitives`, import name `gc_primitives`, Python 3.9+, Apache-2.0, version `0.2.0`.

```bash
pip install gc-primitives
```

Building:

```bash
cd python/gc-primitives && python3 -m build
```

The version is independent from Java / C++ and is not locked to any other language's published version.
