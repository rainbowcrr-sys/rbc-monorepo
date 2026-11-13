# gc-primitives · Rust 版

> 中文 · [English](README.en.md)

与 Java / C++ / Python 同一套概念契约的 Rust 移植，行为规范见仓库根 [SPEC.md](../../SPEC.md)（[English](../../SPEC.en.md)）。
> ⚠️ **0.1.x 不推荐使用，请使用 0.2.0**（旧版缺少并发、诊断、配置与可观测能力，且不再获得修复）。


> Rust 没有 GC。这里的收益是**更少的堆分配与复用后的缓存局部性**。
> 本 crate 的硬承诺是 **零 `unsafe`、零依赖**：`#![forbid(unsafe_code)]` 写在 crate 根。

## 为什么用回调租约

其他三语言返回 `Lease<T>` 句柄，靠 `try-with-resources` / RAII / `with` 自动归还。
Rust 的所有权系统不允许「把对象借出去、归还时还要复用」这种句柄随便逃逸，硬做就得上锁或 `unsafe`。

所以 Rust 版用**作用域回调**：

```rust
pool.with_borrow(|value: &mut T| -> R { ... }) -> Result<R, PoolError>
```

对象引用**逃不出闭包**，于是：

| 其他三语言运行时校验 | Rust 版 |
| --- | --- |
| 双重归还 | 编译期不存在（没有句柄可 close 两次） |
| 跨线程归还 | 编译期不存在（对象不跨线程） |
| 关闭后 `get()` | 编译期不存在（闭包结束引用即失效） |

这就把 C5「始终强制误用检测」里的一半上移到了类型系统，比运行时抛异常更硬。

## 导入

```toml
[dependencies]
gc-primitives = "0.2.0"
```

```rust
use gc_primitives::Pool;

let pool = Pool::new(8, || Some(String::new()), |s| {
    s.clear();                 // 归还时复位
    Ok(())
})?;

let len = pool.with_borrow(|s| {
    s.push_str("hello");
    s.len()
})?;
assert_eq!(len, 5);

pool.assert_no_active_leases()?;
# Ok::<(), gc_primitives::PoolError>(())
```

无状态对象可省掉工厂/复位：

```rust
let pool = gc_primitives::Pool::<Vec<u8>>::with_defaults(8)?;
pool.with_borrow(|buf| buf.push(1))?;
# Ok::<(), gc_primitives::PoolError>(())
```

crate 名 `gc-primitives`，导入名 `gc_primitives`（Cargo 会把连字符转成下划线，这是编译器规则，不是改名）。MSRV **Rust 1.70**，edition 2021。

## API 对照

| Java | C++ | Python | Rust |
| --- | --- | --- | --- |
| `Pool<T>` / `Pools.threadLocal(...)` | `rbc::gc::Pool<T,F,R>` | `Pool` | `Pool<T>` / `Pool::new` / `Pool::with_defaults` |
| `Lease<T>` | `Pool::Lease` | `Lease` | 无独立句柄（回调闭包） |
| `borrow()` | `borrow()` | `borrow()` | `with_borrow(f)` |
| `Recycler<T>` | `Recycler` | `recycler` | `recycler: FnMut(&mut T) -> Result<(), PoolError>` |
| `Supplier<T>` | `Factory` | `factory` | `factory: FnMut() -> Option<T>` |
| `PoolStateException` | `pool_error` | `PoolStateError` | `PoolError`（`Result`，不 panic） |
| `capacity()` | `capacity()` | `capacity()` | `capacity()` |
| `idleCount()` | `idle_count()` | `idle_count()` | `idle_count()`（仅本线程） |
| `activeLeases()` | `active_leases()` | `active_leases()` | `active_leases()` |
| `borrowCount()` / `returnCount()` | `borrow_count()` / `return_count()` | 同名 | `borrow_count()` / `return_count()` |
| `assertNoActiveLeases()` | `assert_no_active_leases()` | `assert_no_active_leases()` | `assert_no_active_leases() -> Result` |

计数用 per-`Pool` 实例的 `AtomicU64` **跨线程精确统计**；`idle_count()` 读本线程 `thread_local!` 状态。

## 契约细则（Rust 特有）

- **始终强制校验的运行时项**：禁止重入（`PoolError::ReentrantBorrow`）、`capacity == 0`（`InvalidCapacity`）、工厂返回 `None`（`FactoryReturnedNone`）、复位失败（`ResetFailed`）
- **复位失败**：对象**直接丢弃、绝不回池**，错误透传给调用方，计数照常结算；对齐 Python 版的污染隔离
- **闭包 `panic!`**：`BorrowGuard` 在展开时结算计数并尽力归还，用 `catch_unwind` 兜住，不制造二次 panic
- **线程本地 + 有界**：`thread_local!` + `RefCell`，每线程最多 `capacity` 个空闲对象；超出直接 `drop`。线程退出由 TLS 析构自动丢弃
- **`Arc` 共享**：工厂/复位闭包要求 `Send + 'static`，锁在 `Mutex` 里，因此 `Pool<T>` 是 `Send + Sync`，可 `Arc<Pool<T>>` 跨线程共享，各线程用各自的空闲栈
- **TLS 状态按 pool id 索引**，用 `Box<dyn Any>` 类型擦除，让不同 `T` 的池共用同一个 thread_local 静态量；id 全局唯一，`downcast` 必定成功
- 库无法拦截「归还后仍被外部引用」——但回调模式下这本来就不可能发生

## 验证

```bash
cd rust/gc-primitives
cargo test                    # 单元测试 + 集成测试 + doctest
cargo test --all-targets
cargo clippy --all-targets -- -D warnings
cargo fmt -- --check
```

CI 会真跑 **Rust 1.70**（MSRV）与 stable 两套工具链，声明的 MSRV 不是纸面数字。

## 分发

crates.io：`gc-primitives`，版本 `0.2.0`，Apache-2.0，零依赖。

发布分两阶段，因为 **crates.io 的 Trusted Publishing 只能给已存在的 crate 配置**：

1. **首次发布（历史，`0.1.0`）**：用 crates.io 上生成的、带 `publish-new` 权限的 API Token（只存 GitHub Secret `CARGO_REGISTRY_TOKEN`，不进仓库文件），打 `gc-primitives__rust__v0.1.0` 让工作流完成首发；**当前 `0.2.0` 及以后**打 `gc-primitives__rust__v0.2.0` 即自动 OIDC 发布，零长期凭据
2. **之后**：在 crate 的 Settings → Trusted Publishing 登记 GitHub 发布者，工作流改用一次性 OIDC 身份换临时凭证，长效 Token 即可删除

`publish-rust.yml` 对两阶段都兼容：优先 OIDC，失败时回退 Secret。登记字段为 owner `rainbowcrr-sys`、repository `rbc-monorepo`、workflow `publish-rust.yml`、environment `crates-io`。

版本与 Java / C++ / Python 各自独立，当前 `0.2.0`。
