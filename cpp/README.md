# gc-primitives · C++ 版

与 Java 版同一套概念契约的 C++17 移植，行为规范见仓库根 [SPEC.md](../SPEC.md)。

> C++ 没有 GC，这里的收益是**更少的 `malloc`/`free` 与更好的缓存局部性**，不叫「省 GC」。

## 特点

- **header-only**：`#include <rbc/gc.hpp>` 即可，零链接、零运行时依赖
- **C++17**：只用标准库，不依赖 pmr / concepts / span
- **线程本地有界**：一个 `Pool` 实例跨线程使用，每线程各自一份有界空闲栈，借还无锁、无跨线程同步
- **move-only RAII 租约**：析构自动归还，`Lease` 按值返回、活在栈上，命中空闲槽时零堆分配
- **始终强制误用检测**：双重归还、跨线程归还/取用、关闭后 `get()`、工厂返回 `nullptr` 一律抛 `rbc::gc::pool_error`

## 导入

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
    auto lease = pool.borrow();      // 命中空闲槽时不 new
    std::string& s = lease.get();
    s.append("hello");
}                                    // 析构归还，reset_string 在这里清空
```

或者用便捷工厂（工厂/复位用 lambda 或函数对象）：

```cpp
auto pool = rbc::gc::make_pool<std::string>(
    [] { return new std::string(); },
    [](std::string& s) noexcept { s.clear(); },
    16);
```

无状态对象可以省掉复位钩子：

```cpp
rbc::gc::Pool<int> ints;   // 默认工厂 new T()，no-op recycler，容量 64
auto lease = ints.borrow();
```

## API 对照

| Java | C++ |
| --- | --- |
| `Pool<T>` | `rbc::gc::Pool<T, Factory, Recycler>` |
| `Lease<T>` | `Pool::Lease`（move-only） |
| `Recycler<T>` | 模板参数 `Recycler`，签名 `void(T&) noexcept` |
| `Supplier<T>` | 模板参数 `Factory`，签名 `T*()` |
| `Pools.threadLocal(...)` | 直接构造 / `rbc::gc::make_pool(...)` |
| `PoolStateException` | `rbc::gc::pool_error : std::logic_error` |
| `borrow()` / `capacity()` / `idleCount()` | `borrow()` / `capacity()` / `idle_count()` |
| `activeLeases()` / `borrowCount()` / `returnCount()` | `active_leases()` / `borrow_count()` / `return_count()` |
| `assertNoActiveLeases()` | `assert_no_active_leases()` |

计数用全局 `std::atomic` 精确统计，接受每次借还一次原子加的开销。

## 契约细则（C++ 特有）

- **Factory 返回 `T*`**，池负责 `delete`；返回 `nullptr` 即抛 `pool_error`
- **Recycler 约定 `noexcept`**。复位钩子在 `noexcept` 边界内调用，若抛异常会 `std::terminate`——析构路径抛异常在 C++ 会终止，所以这条约束放在契约层，不靠运行时捕获
- **析构路径的跨线程误用**：`Lease` 在借用线程之外析构属于契约违反，析构函数不能抛，因此表现为 `std::terminate()` 而非异常，不静默放过
- **Pool 生命周期**：`Pool` 对象须长于借用它的线程；线程退出时会释放它自己缓存的空闲对象
- **不拦截「归还后仍被外部引用」**：`close()` 之后不得再持有 `get()` 返回的引用，这一条由调用方保证

## 构建与验证

```bash
cmake -S cpp -B cpp/build -DGC_PRIMITIVES_BUILD_BENCH=OFF
cmake --build cpp/build
ctest --test-dir cpp/build --output-on-failure
```

不装 CMake 也能直接验：

```bash
g++ -std=c++17 -Wall -Wextra -Wpedantic -pthread \
    -I cpp/include cpp/tests/contract_test.cpp -o /tmp/contract_test
/tmp/contract_test     # 末行输出 contract_test OK
```

Google Benchmark（需先装 `benchmark`，CMake 找不到会自动跳过，不影响库本体）：

```bash
cmake -S cpp -B cpp/build -DGC_PRIMITIVES_BUILD_BENCH=ON
cmake --build cpp/build --target allocation_bench
./cpp/build/allocation_bench --benchmark_min_time=1s
```

基准结果写在本 README 的 Release Notes，**不写进 SPEC**——SPEC 只定行为契约，不绑死性能数字。

## 分发

| 渠道 | 文件 |
| --- | --- |
| vcpkg | `vcpkg.json`（header-only，`dependencies: []`） |
| Conan | `conanfile.py`（`package_id` 清空，无二进制变体） |
| CMake | `install()` 导出 `rbc::gc_primitives` target |

版本 `0.1.0`，与 Java 版各自独立，Apache-2.0。
