# gc-primitives 跨语言契约规范（SPEC）

> 中文 · [English](SPEC.en.md)

**状态**：正式版 · 2026-11-12 · 已落位仓库根
**适用实现**：Java、C++、Python、Rust、Go、Swift、Zig
**关系**：**同一套概念契约移植**，不是各语言重写一遍。行为一致性由契约测试保证；**性能数字不写入本规范**，各语言基准结果写进各自 README。

七语言 README 均引用本文件。仓库内每个 Markdown 都有中文版与英文版，英文版文件名以 `.en.md` 结尾。

---

## 1. 定位与收益口径

对外只讲一件事：把「对象池 + 复用上下文」做成可组合原语，不限场景，由调用方决定延迟与吞吐的取舍。

七语言的收益口径必须分开写，不能混：

| 语言 | 实际收益 | 不能这么写 |
| --- | --- | --- |
| Java | 命中空闲槽时不分配对象，压低分配速率与 young GC | — |
| C++ | 少 `malloc`/`free`、复用后缓存局部性更好 | 「省 GC」——C++ 没有 GC |
| Rust | 更少的堆分配、复用后的缓存局部性；**误用在编译期被消掉** | 「省 GC」——Rust 也没有 GC |
| Python | 跨语言契约一致、语义清晰、教学与对照价值 | 「比解释器快」——见下 |
| Go | 命中分片空闲槽时不分配对象，压低分配速率与 GC 压力；**零中心仓库、零凭据** | 不做「比 `sync.Pool` 快」的量化承诺（首版无基准） |
| Swift | 减少堆分配/释放与 retain-release 次数，复用后缓存局部性更好 | 「省 GC」——Swift 用 ARC，没有 GC |
| Zig | 命中空闲槽时完全不调用 `allocator.create`，对象显式释放、绝不泄漏 | 「省 GC」——Zig 没有 GC 也没有隐式分配 |

**Python 特别说明**：CPython 主力是引用计数（引用归零即就地释放），另挂分代 GC 专门清循环引用，再加 pymalloc 的 arena 与小对象 free-list（list / dict / float 等解释器自己就池化）。纯 Python 再手写一层对象池，常常只是和内置缓存重叠，甚至因为多一层 Python 函数调用更慢。所以 Python 版明确定位为**纯语义移植，不承诺性能收益**。

**Rust 特别说明**：没有 GC，靠所有权在编译期管内存。本版额外承诺 **零 `unsafe`、零依赖**（`#![forbid(unsafe_code)]`），并把其他语言靠运行时校验的一部分误用上移到类型系统，见第 8.1 节。

**Go 特别说明**：Go 有 GC，但 goroutine 会在 OS 线程之间迁移，没有线程本地存储。所以 Go 版是 **C2/C3 的并发变体**（按 `GOMAXPROCS` 分片的有界栈 + 全局原子计数），跨 goroutine 误用靠文档约定而非运行时检测，见第 8.2 节；收益口径只写「更少的堆分配」，不写死性能数字。


**Swift 特别说明**：ARC 不是 GC，对象引用归零即释放。约束 `T: AnyObject` 是因为 Swift 的值类型 getter 会拷贝，调用方的修改会静默丢失；`deinit` 不能抛错，所以忘记 `close()` 的对象**直接丢弃而不复用**，见第 11.1 节。

**Zig 特别说明**：无 GC、无隐式分配，所有内存来自调用方显式 `Allocator`。Zig 独有的 `destroy` 钩子负责释放被丢弃的对象，`std.testing.allocator` 在 CI 里抓每一个漏掉的对象，见第 11.2 节。

## 2. 五条核心契约

| 编号 | 契约 | 违反后果 |
| --- | --- | --- |
| C1 | 每次借出必须显式结束（关闭句柄 / 离开作用域） | 未归还即泄漏，`active` 计数可精确发现 |
| C2 | 句柄与借出的对象只归借用线程使用，不跨线程传递 | 抛异常或返回错误（Rust 在编译期消掉；Go / Swift / Zig 为并发变体，见 8.2 与第 11 章） |
| C3 | 每线程空闲对象数有上限 `capacity`，超出直接丢弃 | 内存占用有界，不无限常驻 |
| C4 | 归还时由库调用复位钩子，把对象恢复到干净状态 | 脏数据不得进入下一次借出 |
| C5 | 误用**始终强制校验**，不设开关、不分 Debug/Release | 立即抛异常 / 返回错误，不做未定义行为 |

C5 覆盖：双重归还、跨线程归还、跨线程取用、关闭后取用、工厂返回空值、`capacity <= 0`。

> 库无法在运行时拦截「归还后仍被外部引用」这一情况，由调用方保证：结束之后不得再持有该对象引用。七语言文档都要写明；Rust 的回调租约让这一条在编译期就不可能发生；Go 没有析构兜底，靠文档约定与 `AssertNoActiveLeases()` 兜底。

## 3. 类型与命名映射

| 概念 | Java | C++ | Python | Rust | Go |
| --- | --- | --- | --- | --- | --- |
| 池 | `Pool<T>` | `rbc::gc::Pool<T, Factory, Recycler>` | `Pool` | `Pool<T>` | `Pool[T]`（分片） |
| 租约 | `Lease<T>`（try-with-resources） | `Lease`（move-only，RAII 析构） | `Lease`（`with` 上下文管理器） | 无独立句柄，`with_borrow(f)` 作用域回调 | `*Lease[T]`（`defer Close()`） |
| 复位钩子 | `Recycler<T>` | 模板参数 `Recycler`，约定 `noexcept` | `recycler` 可调用对象 | `FnMut(&mut T) -> Result<(), PoolError>` | `Recycler[T] func(*T) error` |
| 工厂 | `Supplier<T>` | 模板参数 `Factory`，返回 `T*` | `factory` 可调用对象 | `FnMut() -> Option<T>` | `Factory[T] func() (T, bool)` |
| 入口 | `Pools.threadLocal(...)` | 直接构造 / `rbc::gc::make_pool(...)` | 直接构造 `Pool(...)` | `Pool::new(...)` / `Pool::with_defaults(...)` | `gcprimitives.New[T](...)` |
| 异常 / 错误 | `PoolStateException` | `rbc::gc::pool_error : std::logic_error` | `PoolStateError` | `PoolError`（`Result`，不 panic） | 误用 `panic`；可恢复错误 `error` |

`::` 只是 C++ 的分组名分隔符，相当于 Java 包名里的点，作用是避免 `Pool` 撞名，不是运算符。Rust crate 名 `gc-primitives`，导入名 `gc_primitives`（Cargo 把连字符转成下划线，是编译器规则）。Go 包名 `gcprimitives`：目录名带连字符不能当包名，导入时显式起别名。

**实例语义**：Java / C++ / Python / Rust 四种实现都是**全局 `Pool` 对象内含线程本地状态**，一个实例跨线程使用，各自有界空闲栈；不是「每线程一个 Pool」。Rust 版通过 `Arc<Pool<T>>` 共享，工厂/复位闭包要求 `Send + 'static`。**Go 例外**：没有线程本地状态，改为按 `GOMAXPROCS` 分片，见 8.2。

## 4. 方法名映射（诊断契约）

| Java | C++ / Python | Rust | Go | 语义 |
| --- | --- | --- | --- | --- |
| `borrow()` | `borrow()` | `with_borrow(f)` | `Borrow() (*Lease[T], error)` | 借出（Rust 为作用域式） |
| `capacity()` | `capacity()` | `capacity()` | `Capacity()` / `ShardCount()` | 每线程/每分片上限 |
| `idleCount()` | `idle_count()` | `idle_count()` | `IdleCount()` | 空闲数（Go 为全分片快照） |
| `activeLeases()` | `active_leases()` | `active_leases()` | `ActiveLeases()` | 未归还借出数 |
| `borrowCount()` | `borrow_count()` | `borrow_count()` | `BorrowCount()` | 累计借出 |
| `returnCount()` | `return_count()` | `return_count()` | `ReturnCount()` | 累计归还 |
| `assertNoActiveLeases()` | `assert_no_active_leases()` | `assert_no_active_leases() -> Result` | `AssertNoActiveLeases() error` | 测试期把泄漏转成失败 |

Python 与 Rust 用 snake_case 对齐语义，不照搬 camelCase；Go 按导出标识符习惯用 PascalCase。本表就是逐条映射的核对依据。

**计数实现**：Java 用 `LongAdder`；C++ 用全局 `std::atomic`；Rust 用 per-`Pool` 实例的 `AtomicU64`（`SeqCst`，跨线程精确）；Python 用 `threading.Lock` 保护整数；Go 用 `atomic.Int64`（跨 goroutine 精确）。`idle_count()` 在 Java / C++ / Python / Rust 四种实现里只读当前线程状态；Go 的 `IdleCount()` 返回全分片快照。

## 5. 归还路径与复位失败

| 语言 | 复位约定 | 复位失败时 |
| --- | --- | --- |
| Java | `Recycler` 不应抛异常 | 与文档约定一致，不额外设计 |
| C++ | 复位调用约定 `noexcept` | 在 `noexcept` 边界内调用，若抛异常会 `std::terminate`；约束放契约层 |
| Python | 无 `noexcept` 概念 | 异常照常抛出，但**对象不归还、直接丢弃**，租约仍失效，计数照常结算；绝不把脏对象放回池 |
| Rust | 复位钩子返回 `Result<(), PoolError>` | `Err` 时**对象丢弃、错误透传**，计数照常结算；绝不回池 |
| Go | `Recycler[T]` 返回 `error` | 非 nil 时**对象丢弃、错误由 `Close()` 返回**，计数照常结算；绝不回池 |

**C++ 析构路径的补充说明**：C++ 析构函数抛异常会 `std::terminate`，因此 `Lease` 析构时若发现跨线程误用，表现为 `std::terminate()` 而非异常——「始终强制校验」依然成立。显式 `close()` 走完整校验并抛 `pool_error`。

**Python 归还机制**：靠 `with` 的 `__exit__`（或显式 `close()`），不做析构兜底；`with` 体内抛异常时仍先归还，再让原异常冒泡。

**Rust 归还机制**：`with_borrow` 的闭包返回后显式归还，因此复位错误能透传给调用方；若闭包 `panic!`，`BorrowGuard` 在展开时结算计数并尽力归还，用 `catch_unwind` 兜住，不制造二次 panic。

**Go 归还机制**：靠 `defer l.Close()` 或显式 `Close()`，**没有析构兜底**；`Close()` 返回 `error`，关心复位失败的调用方不能忽略它。

## 6. 线程归属校验

Java / C++ / Python 原样保留「跨线程归还 / 跨线程取用即抛异常」；Rust 因为对象引用逃不出闭包，这类误用**在编译期不可能发生**，改为靠 `thread_local!` 天然隔离。

- C++：每个 Lease 存 `std::thread::id`，归还时比对，接受这个热路径开销
- Python：`threading.local` 有界栈，只保证线程隔离；**asyncio 同一线程内的多任务不隔离**，文档必须写明限制
- Rust：`thread_local!` + `RefCell`，每线程独立空闲栈；线程退出由 TLS 析构自动丢弃
- **Go**：无法可靠识别 goroutine 身份，跨 goroutine 归还/取用**不做运行时检测**，改为文档约定「租约只归借用它的 goroutine 使用」；见第 8.2 节
- 不做「strict 开关」、不默认放宽、不只留双重归还检测

## 7. 明确排除项

- **不写死任何性能数字**。Java 版 106.8MB → 53.4MB 那类实测只进 Java README 与 Release Notes，不进本规范，避免把 Python / Rust 绑死
- 不把「命中时零新对象构造」写成七语言硬指标
- 不规定各语言必须达到某个吞吐/延迟值
- 不要求七语言 API 字面同名，只要求**行为契约**一致 + 本文件里的映射表可核对

## 8. 逐语言勾选

| 契约项 | Java | C++ | Python | Rust | Go |
| --- | --- | --- | --- | --- | --- |
| C1 显式归还 | ✅ try-with-resources | ✅ RAII 析构 + `close()` | ✅ `with` / `close()` | ✅ `with_borrow` 作用域自动归还 | ✅ `defer Close()` |
| C2 线程归属 | ✅ 运行时 | ✅ `thread::id` | ✅ `threading.get_ident()` | ✅ 编译期 + TLS 隔离 | ⚠ 并发变体，见 8.2 |
| C3 有界 | ✅ | ✅ | ✅ | ✅ | ✅ 每分片有界 |
| C4 归还复位 | ✅ | ✅ | ✅ | ✅ | ✅ |
| C5 强制误用检测 | ✅ 运行时 | ✅ 运行时 | ✅ 运行时 | ✅ 编译期消 3 项 + 运行时 4 项 | ✅ `panic` + `error` |
| 诊断方法映射 | ✅ | ✅ snake_case | ✅ snake_case | ✅ snake_case + `Result` | ✅ PascalCase + `error` |
| 契约测试 | ✅ JUnit 5 | ✅ 21 项，零第三方依赖 | ✅ 14 项，`unittest` | ✅ 集成 + 单元 + doctest，CI 跑 1.70 与 stable | ✅ 10 项 + Example，`-race`，CI 跑 1.21 与 stable |
| 基准 | ✅ JMH + ThreadMXBean | ✅ Google Benchmark（可选编译） | ⬜ 不承诺收益 | ⬜ 首版不做基准 | ⬜ 首版不做基准 |

### 8.1 编译期强化（Rust 专属）

Rust 版是「SPEC 对齐 + 编译期强化」，不是另起炉灶：

| 其他实现的运行时拦截 | Rust 的处理 |
| --- | --- |
| 双重归还 | **编译期不存在**——没有可 `close()` 两次的句柄 |
| 跨线程归还 / 跨线程取用 | **编译期不存在**——`&mut T` 只在闭包内有效，对象不跨线程 |
| 关闭后 `get()` | **编译期不存在**——闭包结束引用即失效 |
| 「归还后仍被外部引用」 | **编译期不存在**——引用无法从闭包里带出 |

**仍保留的运行时校验（4 项，全部返回 `PoolError`）**：禁止重入、`capacity == 0`、工厂返回 `None`、复位失败。

**其余硬约束**：crate 根 `#![forbid(unsafe_code)]`；零依赖；全程 `Result<T, PoolError>`，业务错误不用 `panic!`；TLS 状态按全局唯一 pool id 索引、用 `Box<dyn Any>` 类型擦除以支持多种 `T`；MSRV 1.70 在 CI 真实验证。

### 8.2 并发变体（Go 专属）

Go 没有线程本地存储：goroutine 会在 OS 线程之间迁移，`thread_local` 语义不成立。本版是**明确标注的并发变体**，不是对 C2/C3 的严格移植：

| SPEC 契约 | Go 处理 |
| --- | --- |
| 每线程有界空闲栈（C3） | 按 `GOMAXPROCS(0)` 分片的 `sync.Mutex` + 有界栈，每分片最多 `capacity` 个空闲对象，进程级上限 `capacity × GOMAXPROCS` |
| 线程归属校验（C2） | Go 无法可靠识别 goroutine 身份，**不做运行时检测**；文档约定：租约只归借用它的 goroutine 使用，不得跨 goroutine 传递 |
| `idle_count()` 当前线程空闲数 | `IdleCount()` 返回全分片空闲对象快照，不是线性一致全局值 |
| 全局诊断计数 | `atomic.Int64`，跨 goroutine 精确 |

**其它约定**：工厂返回 `false` 视为「工厂返回空值」；复位钩子返回非 nil `error` 时对象丢弃、错误透传；双重 `Close()` 与关闭后 `Get()` 一律 `panic`；`capacity <= 0`、nil 钩子返回 `error`。Go 没有析构兜底，未 `Close()` 的租约靠 `AssertNoActiveLeases()` 在测试期发现。借用用原子自增轮询选分片，工厂调用在分片锁外执行。

## 9. 版本与分发

**版本节奏**：七语言各自独立版本号，不被已发布的 Java 版本锁住。Maven Central 与 PyPI 上传过的版本号永久不可覆盖，改动需升版本号；GitHub Release 同名 tag 也不建议重建。

| 语言 | 包名 / 坐标 | 渠道 | 基线 |
| --- | --- | --- | --- |
| Java | `net.de5.rainbowcrrsys:gc-primitives` | Maven Central | Java 11 + Gradle 8.10.2 |
| C++ | `gc-primitives`，命名空间 `rbc::gc` | GitHub Release（header-only tarball）/ vcpkg / Conan | C++17 |
| Python | `gc-primitives`（导入名 `gc_primitives`） | PyPI | Python 3.9+ |
| Rust | `gc-primitives`（导入名 `gc_primitives`） | crates.io（Trusted Publishing / OIDC） | Rust 1.70+，edition 2021 |
| Go | `github.com/rainbowcrr-sys/rbc-monorepo/go/gc-primitives` | Git tag + `proxy.golang.org` / pkg.go.dev（**无中心仓库、无凭据**） | Go 1.21+ |
| Swift | `GCPrimitives`（SwiftPM） | Git tag（**零注册零凭据**） | Swift 5.9+ |
| Zig | `gc_primitives` | Git tag + Zig Index（**零注册零凭据**） | Zig 0.14.0 |

许可证：七语言统一 Apache-2.0。

> crates.io 例外：Trusted Publishing 只能配置在**已存在的 crate** 上，所以 Rust 首发需用一次性 API Token（只存 GitHub Secret，不进仓库文件），登记 trusted publisher 之后才切换为 OIDC。

## 10. 仓库落位与 tag 约定

顶层按**语言**分目录，内层按**项目**分目录；新增项目无需新建仓库：

```
rbc-monorepo/
├── README.md / README.en.md          根说明（中 / 英）
├── SPEC.md / SPEC.en.md              本规范（中 / 英）
├── LICENSE                           Apache-2.0
├── build.gradle / settings.gradle / gradle.properties
├── .github/workflows/                六条发布流水线 + Rust / Go / Swift / Zig CI + 部署状态查询
├── java/
│   ├── gc-primitives/                Java 主库（单 jar）
│   ├── example/                      可运行示例，不进发布物
│   └── benchmarks/                   JMH 基准，不进发布物
├── cpp/gc-primitives/                include / tests / bench / CMake / vcpkg / Conan / README 双语
├── python/gc-primitives/             gc_primitives / tests / pyproject / README 双语
├── rust/gc-primitives/               Cargo.toml / src / tests / README 双语
├── go/gc-primitives/                 go.mod / *.go / tests / README 双语
├── swift/gc-primitives/              Package.swift / Sources / Tests / README 双语
└── zig/gc-primitives/                build.zig / src / tests / README 双语
```

以后新项目 `test` 就是 `java/test/`、`cpp/test/`、`python/test/`、`rust/test/`、`go/test/`、`swift/test/`、`zig/test/`，Gradle 在 `settings.gradle` 追加 `include(':java:test')` 与 `projectDir`。

**tag 格式**：库名含连字符，用双下划线分隔——`gc-primitives__java__v*`、`gc-primitives__python__v*`、`gc-primitives__cpp__v*`、`gc-primitives__rust__v*`。新项目则是 `test__java__v*` 等，绝不撞车。上传类流水线各自校验「tag 版本 == 代码声明版本」，不一致拒绝发布。历史 tag `v0.1.0` / `py-v0.1.0` / `cpp-v0.1.0` 保留但已从触发规则退役。

**Go tag 例外（硬性规则）**：多模块仓库里子目录模块的版本 tag 必须带目录前缀，Go 工具链不认双下划线格式，所以 Go 用 `go/gc-primitives/v0.1.0`（新项目 `go/test/v0.1.0`）。用户写 `go get ...@v0.1.0` 时，go 命令会自动去找这个带前缀的 tag。Go 没有上传步骤：打 tag = 发布，工作流只负责触发 `proxy.golang.org` 缓存与 pkg.go.dev 索引，并用「使用方」job 真实 `go get` + `go run` 验证。

## 11. 新增两语言补充规范（Swift / Zig）

Java、C++、Python、Rust、Go 的契约正文见第 1–10 节。本节补记后加的两种实现：它们**同样对齐 C1–C5**，但因运行时模型不同，C2「线程归属」都是明确标注的变体，不假装严格移植。为便于阅读，§3 / §4 / §8 的主映射表保持五列，两语言的逐项映射集中在本节。

### 11.1 Swift（ARC 分配优化）

**定位**：Swift 用 ARC，不是 GC。收益口径只写「减少堆分配/释放与 retain-release 次数、复用后缓存局部性更好」，不写「省 GC」。

**`T: AnyObject` 约束**：Swift getter 返回值类型会拷贝；若允许 `struct`，调用方对 `lease.value` 的修改会静默丢失、根本回不到池里。约束成 class 正好对应堆对象语义，也让 `recycler` 能原地复位。

**deinit 兜底**：Swift 的 `deinit` 不能 `throws`，无法在兜底路径安全执行可能抛错的 `recycler`。忘记 `close()` 的对象**直接丢弃、不复用**，计数仍精确，脏对象绝不流到下一个借用者。这是与 C++ RAII 的关键差异。

**并发模型**：无稳定跨平台 thread-local，用单个 `NSLock` 保护有界栈 + 锁内计数；跨线程使用同一 `Lease` 不做运行时检测，由文档约定。CI 用 `DispatchQueue.concurrentPerform` 100 次并发借还验证计数精确。

**验证**：macOS（Xcode Swift）+ Ubuntu（Swift 5.9）各跑 12 项 XCTest，覆盖 C1–C5、并发与 deinit 兜底。

### 11.2 Zig（无 GC、无隐式分配）

**定位**：所有内存来自调用方显式 `std.mem.Allocator`，命中空闲槽时完全不调用 `allocator.create`。`Pool(comptime T)` 是编译期泛型，零虚表、零类型擦除、零运行时开销。

**Zig 独有的 `destroy` 钩子**：复位失败、超出容量、关闭池时丢弃的对象都通过 `destroy` 显式释放；`std.testing.allocator` 在测试里抓每一个漏掉的对象。其他语言靠 GC / ARC / Drop，这里必须自己来。

**无析构**：Zig 没有析构函数，忘记 `close()` 会同时留下活跃计数与未释放的对象；`assertNoActiveLeases()` 与 allocator 泄漏检测一起把它抓出来。

**错误模型**：`PoolError` 错误集（`InvalidCapacity` / `FactoryFailed` / `LeaseClosed` / `DoubleClose` / `PoolClosed` / `ActiveLeases` / `OutOfMemory`）+ `anyerror` 透传用户自定义错误；不用 `@panic`、无开关。工厂返回 `null` 视为「工厂返回空值」。

**验证**：Zig 0.14.0 真跑 `zig test`（Debug + ReleaseSafe）与 `zig build test`，11 项测试全部通过且无内存泄漏。测试只用局部状态，`zig test` 并发执行 test block 不串数据。

### 11.3 分发与 tag

| 语言 | 包名 / 路径 | 渠道 | 是否需要注册 |
| --- | --- | --- | --- |
| Swift | `GCPrimitives`（SwiftPM） | 独立分发仓库 `gc-primitives-swift` 的 Git tag | ❌ 零注册零凭据 |
| Zig | `gc_primitives` | GitHub Release tarball + Zig Index | ❌ 零注册零凭据 |

**Swift 的硬性规则**：SwiftPM 要求 `Package.swift` 在**仓库根**，版本 tag 只能是纯语义化版本（`0.1.0` / `v0.1.0`），**不接受** `swift/gc-primitives/v0.1.0` 这类路径前缀；而 `v0.1.0` 已被 Java 首发占用，不能复用。因此 Swift 源码保留在 monorepo 的 `swift/gc-primitives/`（主副本 + CI），另镜像到独立公开仓库 `rainbowcrr-sys/gc-primitives-swift`（根放 `Package.swift`）并在那里打 `v0.1.0`。monorepo 的 `swift/gc-primitives/v0.1.0` 只用于触发发布流水线与挂 Release 资产。两个仓库都零注册零凭据。

**Zig 的硬性规则**：Zig 没有中心仓库，但下游用 `zig fetch` 拉取 tarball，包根必须有 `build.zig.zon`（`.name` / `.version` / `.fingerprint` / `.minimum_zig_version` / `.paths`），且 `build.zig` 要用 `addModule` 暴露 module，否则下游 `@import` 拿不到。首发补齐 zon，在 `zig/gc-primitives/v0.1.0` 打 tag，Release 挂只含包目录的 tarball；CI 用 `zig fetch` 取到 hash 后再建一个独立消费包真编译运行，证明该 tarball 能被当依赖拉。仓库已加 `zig-package` topic，Zig Index 自动收录。

tag：monorepo `swift/gc-primitives/v0.1.0` 与 `zig/gc-primitives/v0.1.0`；SwiftPM 侧另有 `gc-primitives-swift` 的 `v0.1.0`。

**本轮状态**：两版 `0.1.0` 均已发布，CI 全绿；未写任何凭据。
每个 Markdown 都有一份中文（默认文件名）与一份英文（`.en.md`），两版顶部互相链接。

## 12. 0.2.0 能力域（纯增量）

0.2.0 是**纯增量版本**：现有 `Pool` / `Lease` 的构造签名与默认行为一行不改，已发布的 0.1.x 代码零改动即可继续运行。以下能力全部以「新增类型 / 可选参数 / 可选加载器」形式提供。

### 12.1 能力清单与合并口径

| 能力 | 交付形态 | 说明 |
| --- | --- | --- |
| 并发三件套 | Python `AsyncPool` / `borrow_async()` / `async with`；Rust `SharedPool`(`Send + Sync`) 与 `LocalPool`；Go `Borrow(ctx)` | 原同步 / thread-local / 无 context API 全部保留 |
| 满池策略 | `on_full`: `drop_oldest` / `drop_largest` / `block` / `reject` / `grow` + `block_timeout_ms` / `max_overflow` | 默认行为不变 |
| 泄漏检测 | `detect_leaks()` 手动触发 + 借出采样 | **不起后台线程、零常驻开销** |
| 生命周期钩子 | `on_create` / `on_borrow` / `on_return` / `on_evict` / `on_destroy` / `clear_sensitive` | 归还时清敏感数据 |
| 预热 | `prewarm(n)` / 并行预热变体 | — |
| 分片 | `ShardedPool` | — |
| 两级池 | `TwoLevelPool` | — |
| 池快照 | `snapshot()` 返回 config + stats + active_leases | — |
| 内存作用域 | `memory_scope(name)`，回调 + JSON 输出 | `GC_PRIMITIVES_DIAG` 未设时为空操作，零分配零开销 |
| 健康指标 | `stats()` / `metrics()` **统一 JSON 同构快照** | 七语言字段名完全一致；不内置 Prometheus / OTel |
| 统一配置 | 统一 YAML（snake_case）+ schema 校验 + `PoolManager` + 环境变量覆盖 + 级联查找 + 热重载 | 加载器随主包同发，不新增版本号 |
| 框架适配 | 各 README 的零依赖薄适配示例 | 主包不依赖任何框架 |

**合并口径**：原清单里「统一 metrics/telemetry」与「健康指标 API」是同一能力域，只做一套；「动态调参」并入配置文件的运行时重载，不单独实现。原「框架集成」含 Node（Express/Fastify），按已删的 `node/` 处理，**只做七语言**。

### 12.2 组合矩阵（写死，不可自由嵌套）

| | 单独使用 | 再分片 | 作 TwoLevelPool 的 L2 |
| --- | --- | --- | --- |
| `LocalPool`（Rust thread-local） | ✅ | ❌ | ❌ |
| `SharedPool`（Rust `Send + Sync`） | ✅ | ✅ | ✅ |
| 其余语言的基础 `Pool` | ✅ | ✅ | ✅ |

`TwoLevelPool` 只建在 `SharedPool`（或等价的共享池）之上；CI 按此矩阵跑，禁止组合在构造期直接报错。

### 12.3 统一 metrics JSON 同构快照（字段名逐字一致）

```json
{
  "borrow_count": 0, "return_count": 0, "active_leases": 0,
  "pool_hits": 0, "pool_misses": 0, "hit_rate": 0.0,
  "wait_time_p50": 0.0, "wait_time_p99": 0.0, "wait_time_max": 0.0,
  "object_lifetime_p50": 0.0, "eviction_count": 0, "leak_count": 0,
  "created": 0, "idle": 0, "capacity": 0, "closed": false
}
```

七语言 `stats()` / `metrics()` 必须返回同名字段；没有采集能力的实现补 `0` / `0.0`，不许省略字段。

### 12.4 统一 YAML 与加载器

- **格式**：七语言统一 YAML，字段名**统一 snake_case**，配置复制即可跨语言迁移
- **依赖**：核心零依赖 + 可选加载器（内置极简 YAML 子集解析，只支持示例里的标量与二层嵌套键，不支持 YAML 全集）；不启用加载器也能用核心池
- **交付**：加载器**随主包同发、不新增版本号**（Python extras / Rust feature / C++ 可选头 / 其余同仓子模块），仍是 7 个 `0.2.0`
- **校验**：`max_size <= 0`、`on_full` 非法值、未知键 → 加载期报错并列出合法值
- **优先级**：环境变量 `GC_PRIMITIVES__<POOL>__<KEY>` > 配置文件 > 代码默认值
- **级联查找**：`./gc-primitives.yaml` → `./config/gc-primitives.yaml` → `~/.config/gc-primitives.yaml` → `/etc/gc-primitives.yaml`，`GC_PRIMITIVES_CONFIG` 可覆盖
- **多池**：`PoolManager.from_config()` 统一创建 / 关闭
- **热重载分档**（连热重载一起做，但机制不同，如实标注）：
  - Python / Rust / Go / Java：文件变更自动监听生效
  - C++ / Zig / Swift：提供 `reload()` + 文件 mtime 检查**手动触发**，标成降级档

### 12.5 内存作用域与诊断输出

- **Rust 保持零 unsafe**：`memory_scope` 用差值型（池内借还/新建计数 + 可选自定义 allocator 包装），**不挂** `#[global_allocator]`；精度低于字节级，零依赖承诺不破
- **输出**：默认 stderr，可传回调、可写 JSON 文件
- **开关**：`GC_PRIMITIVES_DIAG` 未设时为空操作。C++ / Rust 靠宏与 feature，Python / Go / Java 靠运行期判断，语义一致、机制不同
- **嵌套**：`outer` / `inner` 各自统计，差值归属 innermost

### 12.6 泄漏检测与借出采样

- 只暴露 `detect_leaks()` 与借出栈快照，**不起后台线程、零常驻开销**
- **统一最小集**：七语言都给 `lease_id` / `borrowed_at` / 超时判定 / 用户 `tag`
- 调用栈快照只在 Python / Go / Java 自带；Rust / C++ / Swift / Zig 不强制（避免与零依赖 / header-only 冲突）

### 12.7 版本与旧版政策

七语言同步升 `0.2.0`。文档主表**只列 0.2.0**，明确标注 **0.1.x 不推荐使用**；旧 tag 不删、不打广告。已发布到 PyPI / crates.io / Maven Central 的 0.1.x 制品**不可变、无法追加标注**，只能通过新版文档与 Release 说明告知；GitHub Release 的 0.1.x 描述已追加不推荐提示。

### 12.8 验收

四层全验：七语言 CI 全绿 → 同一份契约用例跨语言对齐 → 真下载 / 真安装后写使用方代码跑通 → 全仓敏感扫描 + 双语文档校验。

每个 Markdown 都有一份中文（默认文件名）与一份英文（`.en.md`），两版顶部互相链接。
