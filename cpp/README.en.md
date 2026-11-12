# gc-primitives · C++ Port

> [中文](README.md) · English

A C++17 port of the same conceptual contract as the Java version. See the repository-root [SPEC.en.md](../SPEC.en.md) ([中文](../SPEC.md)) for the behavioral specification.

> C++ has no GC. The benefit here is **fewer `malloc`/`free` calls and better cache locality** — not "saving GC".

## Highlights

- **Header-only**: `#include <rbc/gc.hpp>` and you're done; no linking, no runtime dependencies
- **C++17**: standard library only; no pmr / concepts / span
- **Thread-local and bounded**: one `Pool` instance is used across threads, each with its own bounded idle stack; borrow/return is lock-free with no cross-thread synchronization
- **Move-only RAII lease**: the destructor returns the object automatically; `Lease` is returned by value and lives on the stack, so a free-slot hit performs zero heap allocation
- **Always strict misuse detection**: double return, cross-thread return/use, `get()` after close, and a factory returning `nullptr` all throw `rbc::gc::pool_error`

## Import

```cpp
#include <rbc/gc.hpp>
#include <string>

std::string* make_string() { return new std::string(); }
void reset_string(std::string& s) noexcept { s.clear(); }

using Pool = rbc::gc::Pool<std::string,
                           std::string* (*)(),
                           void (*)(std::string&)>;

Pool pool(8, &make_string, &reset_string);

{
    auto lease = pool.borrow();      // no new on a free-slot hit
    std::string& s = lease.get();
    s.append("hello");
}                                    // destructor returns; reset_string clears it here
```

Or use the convenience factory (factory/reset can be lambdas or function objects):

```cpp
auto pool = rbc::gc::make_pool<std::string>(
    [] { return new std::string(); },
    [](std::string& s) noexcept { s.clear(); },
    16);
```

Stateless objects can omit the reset hook:

```cpp
rbc::gc::Pool<int> ints;   // default factory new T(), no-op recycler, capacity 64
auto lease = ints.borrow();
```

## API Mapping

| Java | C++ |
| --- | --- |
| `Pool<T>` | `rbc::gc::Pool<T, Factory, Recycler>` |
| `Lease<T>` | `Pool::Lease` (move-only) |
| `Recycler<T>` | Template parameter `Recycler`, signature `void(T&) noexcept` |
| `Supplier<T>` | Template parameter `Factory`, signature `T*()` |
| `Pools.threadLocal(...)` | Direct construction / `rbc::gc::make_pool(...)` |
| `PoolStateException` | `rbc::gc::pool_error : std::logic_error` |
| `borrow()` / `capacity()` / `idleCount()` | `borrow()` / `capacity()` / `idle_count()` |
| `activeLeases()` / `borrowCount()` / `returnCount()` | `active_leases()` / `borrow_count()` / `return_count()` |
| `assertNoActiveLeases()` | `assert_no_active_leases()` |

Counters are precise global `std::atomic` values, accepting one atomic add per borrow/return.

## Contract Details (C++-specific)

- **Factory returns `T*`** and the pool takes ownership (`delete`); returning `nullptr` throws `pool_error`
- **Recycler is `noexcept` by convention**. The reset hook is called inside a `noexcept` boundary; a throw triggers `std::terminate` — throwing from a destructor path terminates in C++, so this constraint lives at the contract level instead of being caught at runtime
- **Cross-thread misuse on the destructor path**: destroying a `Lease` off its borrowing thread is a contract violation. A destructor cannot throw, so it results in `std::terminate()` rather than an exception — never silently ignored
- **Pool lifetime**: the `Pool` object must outlive the threads borrowing from it; when a thread exits, its cached idle objects are released
- **No interception of "still referenced externally after return"**: after `close()`, do not retain the reference returned by `get()`. This is the caller's responsibility

## Build and Verify

```bash
cmake -S cpp -B cpp/build -DGC_PRIMITIVES_BUILD_BENCH=OFF
cmake --build cpp/build
ctest --test-dir cpp/build --output-on-failure
```

Without CMake, you can verify directly:

```bash
g++ -std=c++17 -Wall -Wextra -Wpedantic -pthread \
    -I cpp/include cpp/tests/contract_test.cpp -o /tmp/contract_test
/tmp/contract_test     # prints contract_test OK on the last line
```

Google Benchmark (requires `benchmark` installed; CMake skips it automatically if missing, without affecting the library):

```bash
cmake -S cpp -B cpp/build -DGC_PRIMITIVES_BUILD_BENCH=ON
cmake --build cpp/build --target allocation_bench
./cpp/build/allocation_bench --benchmark_min_time=1s
```

Benchmark results belong in this README's Release Notes, **not in the SPEC** — the SPEC defines behavior only and does not hard-code performance numbers.

## Distribution

| Channel | File |
| --- | --- |
| vcpkg | `vcpkg.json` (header-only, `dependencies: []`) |
| Conan | `conanfile.py` (`package_id` cleared, no binary variants) |
| CMake | `install()` exports the `rbc::gc_primitives` target |

Version `0.1.0`, independent from the Java version, Apache-2.0.
