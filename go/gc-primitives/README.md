# gc-primitives · Go 版

> 中文 · [English](README.en.md)

与 Java / C++ / Python / Rust 同一套概念契约的 Go 移植，行为规范见仓库根 [SPEC.md](../../SPEC.md)（[English](../../SPEC.en.md)）。

> 目录：`go/gc-primitives/`（顶层按语言、内层按项目）。
> **Go 没有中心仓库、没有账号、没有 API Token、没有上传步骤**——模块版本就是 Git tag，`go get` 直接从 GitHub 拉源码，pkg.go.dev 从 `proxy.golang.org` 自动索引。

## 导入

模块路径就是仓库内的目录路径，必须完全一致：

```bash
go get github.com/rainbowcrr-sys/rbc-monorepo/go/gc-primitives@v0.1.0
```

目录名带连字符，Go 包名不能带，所以显式起别名最清楚：

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
    defer l.Close()                       // C1：必须显式归还

    *l.Get() = append(*l.Get(), "hello"...)
    fmt.Println(string(*l.Get()))
}
```

包名 `gcprimitives`，基线 **Go 1.21**（泛型 + `sync/atomic` 新类型），Apache-2.0，**零第三方依赖**。

## 与另外四语言最重要的差异：并发变体

Go 没有线程本地存储：goroutine 会在 OS 线程之间迁移，`thread_local` 语义不成立。所以 SPEC 的 C2「线程归属」和 C3「每线程有界」在本版是**明确标注的并发变体**，不是严格移植：

| SPEC 契约 | Go 版做法 |
| --- | --- |
| 每线程有界空闲栈 | 按 `GOMAXPROCS(0)` 分片的 `sync.Mutex` + 有界栈，每分片最多 `capacity` 个空闲对象，进程级上限 `capacity × GOMAXPROCS` |
| 跨线程归还 / 取用即抛异常 | Go 无法可靠识别 goroutine 身份，**不做运行时检测**；文档约定：租约只归借用它的 goroutine 使用，不得跨 goroutine 传递 |
| `idleCount()` 当前线程空闲数 | `IdleCount()` 返回**所有分片**空闲对象的快照（非全局线性一致值） |
| 全局诊断计数 | `atomic.Int64`，跨 goroutine 精确 |

借用用 `p.next` 原子自增轮询选分片，工厂调用在分片锁外执行，慢工厂不会阻塞同一分片的其他借用者。

## API 对照

| Java | Rust | Go |
| --- | --- | --- |
| `Pools.threadLocal(...)` | `Pool::new(...)` | `gcprimitives.New[T](capacity, factory, recycler)` |
| `Lease<T>` | 回调作用域 | `*Lease[T]`（`defer Close()`） |
| `borrow()` | `with_borrow(f)` | `Borrow() (*Lease[T], error)` |
| `Supplier<T>` | `FnMut() -> Option<T>` | `Factory[T] func() (T, bool)`（`false` = 造不出来） |
| `Recycler<T>` | `FnMut(&mut T) -> Result` | `Recycler[T] func(*T) error`（非 nil = 复位失败） |
| `PoolStateException` | `PoolError` | 误用直接 `panic`；可恢复错误返回 `error` |
| `capacity()` | `capacity()` | `Capacity()` / `ShardCount()` |
| `idleCount()` | `idle_count()` | `IdleCount()`（全分片快照） |
| `activeLeases()` | `active_leases()` | `ActiveLeases()` |
| `borrowCount()` / `returnCount()` | 同名 | `BorrowCount()` / `ReturnCount()` |
| `assertNoActiveLeases()` | `assert_no_active_leases()` | `AssertNoActiveLeases() error` |

## 契约细则

- **始终强制校验**：双重 `Close()` → `panic`；`Close()` 后 `Get()` → `panic`。不设开关、不分 debug/release
- **`capacity <= 0`** → `ErrInvalidCapacity`；`factory` / `recycler` 为 nil → `ErrNilHook`（Go 特有）
- **工厂返回 `false`** → `ErrFactoryFailed`，不产生租约、计数不变（对齐「factory 返回空值」）
- **复位失败**：`Close()` 返回该 `error`，脏对象**直接丢弃、绝不回池**，计数照常结算。关心复位失败的调用方不要只写 `defer l.Close()` 而忽略错误
- **未归还的租约** Go 没有析构兜底，靠 `ActiveLeases()` 精确发现，测试期用 `AssertNoActiveLeases()` 转成错误
- **使用约定**：`Lease` 不可复制、不可跨 goroutine 使用；`Get()` 返回的指针在 `Close()` 之后不得再持有

## 验证

```bash
cd go/gc-primitives
go test -race ./...     # 契约测试 + Example + 竞态检测
go vet ./...
gofmt -l .              # 应无输出
```

CI 真跑 **Go 1.21** 与 **stable** 两套工具链，全部通过后才打 tag。发布流水线里还有一个「使用方」job：`go mod init` → `go get ...@v0.1.0` → `go run .`，验证别人真的能下载并使用。

## 分发与 tag 例外

其他四语言用双下划线 tag（`gc-primitives__java__v*` 等），**Go 用不了**：多模块仓库里，子目录模块的版本 tag 必须带目录前缀，这是 Go 工具链的硬性规则。

```
go/gc-primitives/v0.1.0
```

所以 Go 单列例外，SPEC 第 10 节写明。别人 `go get ...@v0.1.0` 时，Go 会自动去找这个带前缀的 tag。

**没有「注册」这回事**：仓库公开、`go.mod` 路径与 GitHub 路径一致、tag 带 `v`、有 LICENSE 且导出符号有规范注释，就满足 pkg.go.dev 的收录条件。打完 tag 后工作流会请求一次 `proxy.golang.org/<模块路径>/@v/v0.1.0.info` 触发缓存与索引；若页面仍显示 Not Found，打开 https://pkg.go.dev/github.com/rainbowcrr-sys/rbc-monorepo/go/gc-primitives 点一下 **Request** 即可，几分钟后出现，**无需登录、无需账号**。

版本与另外四语言各自独立，不被已发布的 Java `0.1.1` 锁住。Go 的已发布版本同样不可覆盖。
