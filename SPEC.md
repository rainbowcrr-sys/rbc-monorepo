# gc-primitives 跨语言契约规范（SPEC）

> 中文 · [English](SPEC.en.md)

**状态**：正式版 · 2026-11-12 · 已落位仓库根
**适用实现**：Java `0.1.0`（已发布 Maven Central）、C++ `0.1.0`、Python `0.1.0`
**关系**：**同一套概念契约移植**，不是各语言重写一遍。行为一致性由契约测试保证；**性能数字不写入本规范**，各语言基准结果写进各自 README。

三语言 README 均引用本文件。仓库内所有 Markdown 均有中文版与英文版，英文版文件名以 `.en.md` 结尾。

---

## 1. 定位与收益口径

对外只讲一件事：把「对象池 + 复用上下文」做成可组合原语，不限场景，由调用方决定延迟与吞吐的取舍。

三语言的收益口径必须分开写，不能混：

| 语言 | 实际收益 | 不能这么写 |
| --- | --- | --- |
| Java | 命中空闲槽时不分配对象，压低分配速率与 young GC | — |
| C++ | 少 `malloc`/`free`、复用后缓存局部性更好 | 「省 GC」——C++ 没有 GC |
| Python | 跨语言契约一致、语义清晰、教学与对照价值 | 「比解释器快」——见下 |

**Python 特别说明**：CPython 主力是引用计数（引用归零即就地释放），另挂分代 GC 专门清循环引用，再加 pymalloc 的 arena 与小对象 free-list（list / dict / float 等解释器自己就池化）。纯 Python 再手写一层对象池，常常只是和内置缓存重叠，甚至因为多一层 Python 函数调用更慢。所以 Python 版明确定位为**纯语义移植，不承诺性能收益**。

## 2. 五条核心契约

| 编号 | 契约 | 违反后果 |
| --- | --- | --- |
| C1 | 每次 `borrow()` 得到的句柄必须显式关闭 | 未归还即泄漏，`active` 计数可精确发现 |
| C2 | 句柄与借出的对象只归借用线程使用，不跨线程传递 | 抛异常（三语言原样保留） |
| C3 | 每线程空闲对象数有上限 `capacity`，超出直接丢弃 | 内存占用有界，不无限常驻 |
| C4 | 归还时由库调用复位钩子，把对象恢复到干净状态 | 脏数据不得进入下一次借出 |
| C5 | 误用**始终强制校验**，不设开关、不分 Debug/Release | 立即抛异常，不做未定义行为 |

C5 覆盖：双重归还、跨线程归还、跨线程取用、关闭后取用、工厂返回空值、`capacity <= 0`。

> 库无法在运行时拦截「归还后仍被外部引用」这一情况，由调用方保证：关闭之后不得再持有该对象引用。三语言文档都要写明。

## 3. 类型与命名映射

| 概念 | Java | C++ | Python |
| --- | --- | --- | --- |
| 池 | `Pool<T>` | `rbc::gc::Pool<T, Factory, Recycler>` | `Pool` |
| 租约 | `Lease<T>`（try-with-resources） | `Lease`（move-only，RAII 析构） | `Lease`（`with` 上下文管理器） |
| 复位钩子 | `Recycler<T>` | 模板参数 `Recycler`，约定 `noexcept` | `recycler` 可调用对象 |
| 工厂 | `Supplier<T>` | 模板参数 `Factory`，返回 `T*` | `factory` 可调用对象 |
| 入口 | `Pools.threadLocal(...)` | 直接构造 / `rbc::gc::make_pool(...)` | 直接构造 `Pool(...)` |
| 异常 | `PoolStateException` | `rbc::gc::pool_error : std::logic_error` | `PoolStateError` |

`::` 只是 C++ 的分组名分隔符，相当于 Java 包名里的点，作用是避免 `Pool` 撞名，不是运算符。

**C++ 分组名**：`rbc::gc::Pool`。
**实例语义**：三语言都是**全局 `Pool` 对象内含线程本地状态**，一个实例跨线程使用，各自有界空闲栈；不是「每线程一个 Pool」。

## 4. 方法名映射（诊断契约）

| Java | C++ | Python | 语义 |
| --- | --- | --- | --- |
| `borrow()` | `borrow()` | `borrow()` | 借出 |
| `capacity()` | `capacity()` | `capacity()` | 每线程上限 |
| `idleCount()` | `idle_count()` | `idle_count()` | 当前线程空闲数 |
| `activeLeases()` | `active_leases()` | `active_leases()` | 未归还租约数 |
| `borrowCount()` | `borrow_count()` | `borrow_count()` | 累计借出 |
| `returnCount()` | `return_count()` | `return_count()` | 累计归还 |
| `assertNoActiveLeases()` | `assert_no_active_leases()` | `assert_no_active_leases()` | 测试期把泄漏转成失败 |

Python 用 snake_case 对齐语义，不照搬 camelCase；本表就是逐条映射的核对依据。

**计数实现**：Java 用 `LongAdder`；C++ 用**全局 `std::atomic` 精确计数**，接受每次借还一次原子加；Python 用 `threading.Lock` 保护整数，只要求语义一致。

## 5. 归还路径与复位失败

| 语言 | 复位约定 | 复位失败时 |
| --- | --- | --- |
| Java | `Recycler` 不应抛异常 | 与文档约定一致，不额外设计 |
| C++ | 复位调用约定 `noexcept` | 在 `noexcept` 边界内调用，若抛异常会 `std::terminate`；与 Java 版「复位逻辑不应抛异常」同口径，约束放契约层 |
| Python | 无 `noexcept` 概念 | 异常照常抛出，但**对象不归还、直接丢弃**，租约仍失效，计数照常结算；绝不把脏对象放回池 |

**C++ 析构路径的补充说明**：C++ 析构函数抛异常会 `std::terminate`，因此 `Lease` 析构时若发现跨线程误用（句柄被移到别的线程析构），表现为 `std::terminate()` 而非异常——「始终强制校验」依然成立，只是不静默放过。显式 `close()` 走完整校验并抛 `pool_error`。

**Python 归还机制**：靠 `with` 的 `__exit__`（或显式 `close()`），不做析构兜底自动归还；`with` 体内抛异常时仍先归还，再让原异常冒泡。

## 6. 线程归属校验

三语言原样保留「跨线程归还 / 跨线程取用即抛异常」。

- C++：每个 Lease 存 `std::thread::id`，归还时比对，**接受**这个热路径开销
- Python：`threading.local` 有界栈，只保证线程隔离；**asyncio 同一线程内的多任务不隔离**，文档必须写明限制，不假装覆盖
- 不做「strict 开关」、不默认放宽、不只留双重归还检测

## 7. 明确排除项

- **不写死任何性能数字**。Java 版 106.8MB → 53.4MB 那类实测只进 Java README 与 Release Notes，不进本规范，避免把 Python 绑死
- 不把「命中时零新对象构造」写成三语言硬指标
- 不规定各语言必须达到某个吞吐/延迟值
- 不要求三语言 API 字面同名，只要求**行为契约**一致 + 本文件里的映射表可核对

## 8. 逐语言勾选

| 契约项 | Java 0.1.0 | C++ 0.1.0 | Python 0.1.0 |
| --- | --- | --- | --- |
| C1 显式归还 | ✅ try-with-resources | ✅ RAII 析构 + `close()` | ✅ `with` / `close()` |
| C2 线程归属 | ✅ | ✅ `thread::id` | ✅ `threading.get_ident()` |
| C3 有界 | ✅ | ✅ | ✅ |
| C4 归还复位 | ✅ | ✅ | ✅ |
| C5 强制误用检测 | ✅ | ✅ | ✅ |
| 诊断方法映射 | ✅ | ✅ | ✅ snake_case |
| 契约测试 | ✅ JUnit 5 | ✅ 21 项，零第三方依赖 | ✅ 14 项，`unittest` |
| 基准 | ✅ JMH + ThreadMXBean | ✅ Google Benchmark（可选编译） | ⬜ 不承诺收益 |

## 9. 版本与分发

**版本节奏**：三语言各自独立版本号，C++ 与 Python 都从 `0.1.0` 起，不被已发布的 Java `0.1.0` 锁住；Java `0.1.0` 永久不可覆盖，改动需升 `0.1.1` / `0.2.0`。

| 语言 | 包名 / 坐标 | 渠道 | 基线 |
| --- | --- | --- | --- |
| Java | `net.de5.rainbowcrrsys:gc-primitives:0.1.0` | Maven Central（已发布） | Java 11 + Gradle 8.10.2 |
| C++ | `gc-primitives`，命名空间 `rbc::gc` | vcpkg + Conan | C++17，header-only |
| Python | `gc-primitives`（导入名 `gc_primitives`） | PyPI | Python 3.9+ |

许可证：三语言统一 Apache-2.0。

## 10. 仓库落位

```
rbc-monorepo/
├── README.md / README.en.md         根说明（中 / 英）
├── SPEC.md / SPEC.en.md             本规范（中 / 英）
├── gc-primitives/                   Java 主库（已发布）
├── example/ benchmarks/             Java 侧既有模块
├── cpp/
│   ├── include/rbc/gc/pool.hpp      header-only 本体
│   ├── include/rbc/gc.hpp           umbrella 头
│   ├── tests/contract_test.cpp      契约测试
│   ├── bench/                       Google Benchmark
│   ├── CMakeLists.txt / vcpkg.json / conanfile.py
│   └── README.md / README.en.md
└── python/
    ├── gc_primitives/               __init__.py / _pool.py
    ├── tests/test_contract.py
    ├── pyproject.toml
    └── README.md / README.en.md
```

目录名 `cpp/` 与 `python/`，与已有 `gc-primitives/` 平级；共用同一仓库的 CI、tag 节奏与 `rbc-` 组织前缀。每个 Markdown 都有一份中文（默认文件名）与一份英文（`.en.md`），两版顶部互相链接。
