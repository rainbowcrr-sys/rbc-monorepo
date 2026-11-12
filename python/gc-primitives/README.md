# gc-primitives · Python 版

> 中文 · [English](README.en.md)

> 目录：`python/gc-primitives/`（顶层按语言、内层按项目）。

与 Java / C++ 版同一套概念契约的纯 Python 语义移植，行为规范见仓库根 [SPEC.md](../../SPEC.md)（[English](../../SPEC.en.md)）。

> **不承诺性能收益。** 这一版的定位是跨语言契约一致性、语义清晰与教学对照，
> 不是「比解释器快」。原因见下。

## 为什么纯 Python 对象池不承诺加速

CPython 主力是**引用计数**：每个对象记着被谁指着，引用归零立刻就地释放，根本不攒着等 GC；
另外才挂了一个**分代 GC**，专门清引用计数搞不定的循环引用（A 指 B、B 指 A）。
再加上 pymalloc 的 arena 和小对象 free-list（`list` / `dict` / `float` 等解释器自己就池化），
底层已经在做复用了。纯 Python 再手写一层对象池，常常只是和内置缓存重叠，
甚至因为多一层 Python 函数调用更慢。

所以这一版的价值是：**同一套契约在第三个语言里也成立**，以及能跟 Java / C++ 版逐条对照。

## 导入

```python
from gc_primitives import Pool

pool = Pool(list, list.clear, capacity=8)   # factory, recycler, capacity

with pool.borrow() as xs:
    xs.append("hello")
# __exit__ 自动归还，list.clear 在这里把对象复位
```

`with pool.borrow() as x` 对应 Java 的 try-with-resources 与 C++ 的 RAII 析构。
**必须显式用 `with`（或显式 `lease.close()`）**，Python 版不做析构兜底自动归还。

无状态对象可以省掉复位钩子：

```python
from gc_primitives import Pool, noop_recycler

pool = Pool(object, noop_recycler)   # 也可直接省略 recycler 参数
```

## API 对照（snake_case 对齐语义，不照搬 camelCase）

| Java | C++ | Python |
| --- | --- | --- |
| `Pool<T>` / `Pools.threadLocal(...)` | `rbc::gc::Pool<T, F, R>` | `Pool` |
| `Lease<T>` | `Pool::Lease` | `Lease` |
| `Recycler<T>` / `Supplier<T>` | 模板参数 `Recycler` / `Factory` | `recycler` / `factory` 可调用对象 |
| `PoolStateException` | `pool_error` | `PoolStateError` |
| `borrow()` | `borrow()` | `borrow()` |
| `capacity()` / `idleCount()` | `capacity()` / `idle_count()` | `capacity()` / `idle_count()` |
| `activeLeases()` | `active_leases()` | `active_leases()` |
| `borrowCount()` / `returnCount()` | `borrow_count()` / `return_count()` | `borrow_count()` / `return_count()` |
| `assertNoActiveLeases()` | `assert_no_active_leases()` | `assert_no_active_leases()` |

## 契约细则（Python 特有）

- **并发用 `threading.local` 有界栈**，只保证线程隔离。
  ⚠️ **asyncio 同一线程内的多个任务不隔离**：协程切换不会触发线程切换，
  本库不会识别任务边界。需要任务级隔离请自己按 task 分 Pool，或等后续 ContextVar 方案。
- **复位失败**：异常照常抛出，但**对象直接丢弃、绝不回池**，租约仍然失效，计数照常结算。
  不像 Java/C++ 那样约定「复位不抛」——Python 没有 `noexcept`，因此选择在契约层隔离污染。
- **`factory` 返回 `None`** 即抛 `PoolStateError`；`capacity <= 0` 抛 `ValueError`。
- **误用始终强制校验**：双重归还、跨线程归还/取用、关闭后 `get()` 全抛 `PoolStateError`。
- 不拦截「归还后仍被外部引用」——`close()` 之后不得再持有 `with ... as x` 拿到的对象。

## 测试

只用标准库 `unittest`，无需安装任何依赖：

```bash
python3 -m unittest discover -s python/gc-primitives/tests -v
```

14 项契约测试与 Java / C++ 版逐条对应，额外覆盖 `with` 体内抛异常仍归还、复位失败丢弃对象。

## 分发

PyPI：`gc-primitives`，导入名 `gc_primitives`，Python 3.9+，Apache-2.0，版本 `0.1.1`。

```bash
pip install gc-primitives
```

打包：

```bash
cd python/gc-primitives && python3 -m build
```

版本与 Java / C++ 各自独立，不被 Java 或其他语言的已发布版本锁住。
