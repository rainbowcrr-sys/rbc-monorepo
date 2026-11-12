# gc-primitives 跨语言契约规范（SPEC）

> 中文 · [English](SPEC.en.md)

**状态**：正式版 · 2026-11-12 · 已落位仓库根
**适用实现**：Java、C++、Python、Rust
**关系**：**同一套概念契约移植**，不是各语言重写一遍。行为一致性由契约测试保证；**性能数字不写入本规范**，各语言基准结果写进各自 README。

四语言 README 均引用本文件。仓库内每个 Markdown 都有中文版与英文版，英文版文件名以 `.en.md` 结尾。

---

## 1. 定位与收益口径

对外只讲一件事：把「对象池 + 复用上下文」做成可组合原语，不限场景，由调用方决定延迟与吞吐的取舍。

四语言的收益口径必须分开写，不能混：

| 语言 | 实际收益 | 不能这么写 |
| --- | --- | --- |
| Java | 命中空闲槽时不分配对象，压低分配速率与 young GC | — |
| C++ | 少 `malloc`/`free`、复用后缓存局部性更好 | 「省 GC」——C++ 没有 GC |
| Rust | 更少的堆分配、复用后的缓存局部性；**误用在编译期被消掉** | 「省 GC」——Rust 也没有 GC |
| Python | 跨语言契约一致、语义清晰、教学与对照价值 | 「比解释器快」——见下 |

**Python 特别说明**：CPython 主力是引用计数（引用归零即就地释放），另挂分代 GC 专门清循环引用，再加 pymalloc 的 arena 与小对象 free-list（list / dict / float 等解释器自己就池化）。纯 Python 再手写一层对象池，常常只是和内置缓存重叠，甚至因为多一层 Python 函数调用更慢。所以 Python 版明确定位为**纯语义移植，不承诺性能收益**。

**Rust 特别说明**：没有 GC，靠所有权在编译期管内存。本版额外承诺 **零 `unsafe`、零依赖**（`#![forbid(unsafe_code)]`），并把其他三语言靠运行时校验的一部分误用上移到类型系统，见第 8.1 节。

## 2. 五条核心契约

| 编号 | 契约 | 违反后果 |
| --- | --- | --- |
| C1 | 每次借出必须显式结束（关闭句柄 / 离开作用域） | 未归还即泄漏，`active` 计数可精确发现 |
| C2 | 句柄与借出的对象只归借用线程使用，不跨线程传递 | 抛异常或返回错误（Rust 在编译期消掉） |
| C3 | 每线程空闲对象数有上限 `capacity`，超出直接丢弃 | 内存占用有界，不无限常驻 |
| C4 | 归还时由库调用复位钩子，把对象恢复到干净状态 | 脏数据不得进入下一次借出 |
| C5 | 误用**始终强制校验**，不设开关、不分 Debug/Release | 立即抛异常 / 返回错误，不做未定义行为 |

C5 覆盖：双重归还、跨线程归还、跨线程取用、关闭后取用、工厂返回空值、`capacity <= 0`。

> 库无法在运行时拦截「归还后仍被外部引用」这一情况，由调用方保证：结束之后不得再持有该对象引用。四语言文档都要写明；Rust 的回调租约让这一条在编译期就不可能发生。

## 3. 类型与命名映射

| 概念 | Java | C++ | Python | Rust |
| --- | --- | --- | --- | --- |
| 池 | `Pool<T>` | `rbc::gc::Pool<T, Factory, Recycler>` | `Pool` | `Pool<T>` |
| 租约 | `Lease<T>`（try-with-resources） | `Lease`（move-only，RAII 析构） | `Lease`（`with` 上下文管理器） | 无独立句柄，`with_borrow(f)` 作用域回调 |
| 复位钩子 | `Recycler<T>` | 模板参数 `Recycler`，约定 `noexcept` | `recycler` 可调用对象 | `FnMut(&mut T) -> Result<(), PoolError>` |
| 工厂 | `Supplier<T>` | 模板参数 `Factory`，返回 `T*` | `factory` 可调用对象 | `FnMut() -> Option<T>` |
| 入口 | `Pools.threadLocal(...)` | 直接构造 / `rbc::gc::make_pool(...)` | 直接构造 `Pool(...)` | `Pool::new(...)` / `Pool::with_defaults(...)` |
| 异常 / 错误 | `PoolStateException` | `rbc::gc::pool_error : std::logic_error` | `PoolStateError` | `PoolError`（`Result`，不 panic） |

`::` 只是 C++ 的分组名分隔符，相当于 Java 包名里的点，作用是避免 `Pool` 撞名，不是运算符。Rust crate 名 `gc-primitives`，导入名 `gc_primitives`（Cargo 把连字符转成下划线，是编译器规则）。

**实例语义**：四语言都是**全局 `Pool` 对象内含线程本地状态**，一个实例跨线程使用，各自有界空闲栈；不是「每线程一个 Pool」。Rust 版通过 `Arc<Pool<T>>` 共享，工厂/复位闭包要求 `Send + 'static`。

## 4. 方法名映射（诊断契约）

| Java | C++ / Python | Rust | 语义 |
| --- | --- | --- | --- |
| `borrow()` | `borrow()` | `with_borrow(f)` | 借出（Rust 为作用域式） |
| `capacity()` | `capacity()` | `capacity()` | 每线程上限 |
| `idleCount()` | `idle_count()` | `idle_count()` | 当前线程空闲数 |
| `activeLeases()` | `active_leases()` | `active_leases()` | 未归还借出数 |
| `borrowCount()` | `borrow_count()` | `borrow_count()` | 累计借出 |
| `returnCount()` | `return_count()` | `return_count()` | 累计归还 |
| `assertNoActiveLeases()` | `assert_no_active_leases()` | `assert_no_active_leases() -> Result` | 测试期把泄漏转成失败 |

Python 与 Rust 用 snake_case 对齐语义，不照搬 camelCase；本表就是逐条映射的核对依据。

**计数实现**：Java 用 `LongAdder`；C++ 用全局 `std::atomic`；Rust 用 per-`Pool` 实例的 `AtomicU64`（`SeqCst`，跨线程精确）；Python 用 `threading.Lock` 保护整数，只要求语义一致。`idle_count()` 四语言都只读当前线程的状态。

## 5. 归还路径与复位失败

| 语言 | 复位约定 | 复位失败时 |
| --- | --- | --- |
| Java | `Recycler` 不应抛异常 | 与文档约定一致，不额外设计 |
| C++ | 复位调用约定 `noexcept` | 在 `noexcept` 边界内调用，若抛异常会 `std::terminate`；约束放契约层 |
| Python | 无 `noexcept` 概念 | 异常照常抛出，但**对象不归还、直接丢弃**，租约仍失效，计数照常结算；绝不把脏对象放回池 |
| Rust | 复位钩子返回 `Result<(), PoolError>` | `Err` 时**对象丢弃、错误透传**，计数照常结算；绝不回池 |

**C++ 析构路径的补充说明**：C++ 析构函数抛异常会 `std::terminate`，因此 `Lease` 析构时若发现跨线程误用，表现为 `std::terminate()` 而非异常——「始终强制校验」依然成立。显式 `close()` 走完整校验并抛 `pool_error`。

**Python 归还机制**：靠 `with` 的 `__exit__`（或显式 `close()`），不做析构兜底；`with` 体内抛异常时仍先归还，再让原异常冒泡。

**Rust 归还机制**：`with_borrow` 的闭包返回后显式归还，因此复位错误能透传给调用方；若闭包 `panic!`，`BorrowGuard` 在展开时结算计数并尽力归还，用 `catch_unwind` 兜住，不制造二次 panic。

## 6. 线程归属校验

Java / C++ / Python 原样保留「跨线程归还 / 跨线程取用即抛异常」；Rust 因为对象引用逃不出闭包，这类误用**在编译期不可能发生**，改为靠 `thread_local!` 天然隔离。

- C++：每个 Lease 存 `std::thread::id`，归还时比对，接受这个热路径开销
- Python：`threading.local` 有界栈，只保证线程隔离；**asyncio 同一线程内的多任务不隔离**，文档必须写明限制
- Rust：`thread_local!` + `RefCell`，每线程独立空闲栈；线程退出由 TLS 析构自动丢弃
- 不做「strict 开关」、不默认放宽、不只留双重归还检测

## 7. 明确排除项

- **不写死任何性能数字**。Java 版 106.8MB → 53.4MB 那类实测只进 Java README 与 Release Notes，不进本规范，避免把 Python / Rust 绑死
- 不把「命中时零新对象构造」写成四语言硬指标
- 不规定各语言必须达到某个吞吐/延迟值
- 不要求四语言 API 字面同名，只要求**行为契约**一致 + 本文件里的映射表可核对

## 8. 逐语言勾选

| 契约项 | Java | C++ | Python | Rust |
| --- | --- | --- | --- | --- |
| C1 显式归还 | ✅ try-with-resources | ✅ RAII 析构 + `close()` | ✅ `with` / `close()` | ✅ `with_borrow` 作用域自动归还 |
| C2 线程归属 | ✅ 运行时 | ✅ `thread::id` | ✅ `threading.get_ident()` | ✅ 编译期 + TLS 隔离 |
| C3 有界 | ✅ | ✅ | ✅ | ✅ |
| C4 归还复位 | ✅ | ✅ | ✅ | ✅ |
| C5 强制误用检测 | ✅ 运行时 | ✅ 运行时 | ✅ 运行时 | ✅ 编译期消 3 项 + 运行时 4 项 |
| 诊断方法映射 | ✅ | ✅ snake_case | ✅ snake_case | ✅ snake_case + `Result` |
| 契约测试 | ✅ JUnit 5 | ✅ 21 项，零第三方依赖 | ✅ 14 项，`unittest` | ✅ 集成 + 单元 + doctest，CI 跑 1.70 与 stable |
| 基准 | ✅ JMH + ThreadMXBean | ✅ Google Benchmark（可选编译） | ⬜ 不承诺收益 | ⬜ 首版不做基准 |

### 8.1 编译期强化（Rust 专属）

Rust 版是「SPEC 对齐 + 编译期强化」，不是另起炉灶：

| 其他三语言运行时拦截 | Rust 的处理 |
| --- | --- |
| 双重归还 | **编译期不存在**——没有可 `close()` 两次的句柄 |
| 跨线程归还 / 跨线程取用 | **编译期不存在**——`&mut T` 只在闭包内有效，对象不跨线程 |
| 关闭后 `get()` | **编译期不存在**——闭包结束引用即失效 |
| 「归还后仍被外部引用」 | **编译期不存在**——引用无法从闭包里带出 |

**仍保留的运行时校验（4 项，全部返回 `PoolError`）**：禁止重入、`capacity == 0`、工厂返回 `None`、复位失败。

**其余硬约束**：crate 根 `#![forbid(unsafe_code)]`；零依赖；全程 `Result<T, PoolError>`，业务错误不用 `panic!`；TLS 状态按全局唯一 pool id 索引、用 `Box<dyn Any>` 类型擦除以支持多种 `T`；MSRV 1.70 在 CI 真实验证。

## 9. 版本与分发

**版本节奏**：四语言各自独立版本号，不被已发布的 Java 版本锁住。Maven Central 与 PyPI 上传过的版本号永久不可覆盖，改动需升版本号；GitHub Release 同名 tag 也不建议重建。

| 语言 | 包名 / 坐标 | 渠道 | 基线 |
| --- | --- | --- | --- |
| Java | `net.de5.rainbowcrrsys:gc-primitives` | Maven Central | Java 11 + Gradle 8.10.2 |
| C++ | `gc-primitives`，命名空间 `rbc::gc` | GitHub Release（header-only tarball）/ vcpkg / Conan | C++17 |
| Python | `gc-primitives`（导入名 `gc_primitives`） | PyPI | Python 3.9+ |
| Rust | `gc-primitives`（导入名 `gc_primitives`） | crates.io（Trusted Publishing / OIDC） | Rust 1.70+，edition 2021 |

许可证：四语言统一 Apache-2.0。

> crates.io 例外：Trusted Publishing 只能配置在**已存在的 crate** 上，所以 Rust 首发需用一次性 API Token（只存 GitHub Secret，不进仓库文件），登记 trusted publisher 之后才切换为 OIDC。

## 10. 仓库落位与 tag 约定

顶层按**语言**分目录，内层按**项目**分目录；新增项目无需新建仓库：

```
rbc-monorepo/
├── README.md / README.en.md          根说明（中 / 英）
├── SPEC.md / SPEC.en.md              本规范（中 / 英）
├── LICENSE                           Apache-2.0
├── build.gradle / settings.gradle / gradle.properties
├── .github/workflows/                四条发布流水线 + Rust CI + 部署状态查询
├── java/
│   ├── gc-primitives/                Java 主库（单 jar）
│   ├── example/                      可运行示例，不进发布物
│   └── benchmarks/                   JMH 基准，不进发布物
├── cpp/gc-primitives/                include / tests / bench / CMake / vcpkg / Conan / README 双语
├── python/gc-primitives/             gc_primitives / tests / pyproject / README 双语
└── rust/gc-primitives/               Cargo.toml / src / tests / README 双语
```

以后新项目 `test` 就是 `java/test/`、`cpp/test/`、`python/test/`、`rust/test/`，Gradle 在 `settings.gradle` 追加 `include(':java:test')` 与 `projectDir`。

**tag 格式**：库名含连字符，用双下划线分隔——`gc-primitives__java__v*`、`gc-primitives__python__v*`、`gc-primitives__cpp__v*`、`gc-primitives__rust__v*`。新项目则是 `test__java__v*` 等，绝不撞车。四条流水线各自校验「tag 版本 == 代码声明版本」，不一致拒绝发布。历史 tag `v0.1.0` / `py-v0.1.0` / `cpp-v0.1.0` 保留但已从触发规则退役。

每个 Markdown 都有一份中文（默认文件名）与一份英文（`.en.md`），两版顶部互相链接。
