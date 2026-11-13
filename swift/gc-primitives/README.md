# gc-primitives · Swift 版

> 中文 · [English](README.en.md)

与 Java / C++ / Python / Rust / Go / Zig 同一套概念契约的 Swift 移植，行为规范见仓库根 [SPEC.md](../../SPEC.md) 第 11.1 节（[English](../../SPEC.en.md)）。
> ⚠️ **0.1.x 不推荐使用，请使用 0.2.0**（旧版缺少并发、诊断、配置与可观测能力，且不再获得修复）。


## 为什么 Swift 也需要对象池：ARC，不是 GC

Swift **没有垃圾回收**，用的是 **ARC（自动引用计数）**：对象引用归零立即释放。所以这里不写「省 GC」，只写：

- 减少堆上的 `alloc` / `dealloc` 次数
- 减少高频路径上 retain / release 的引用计数操作
- 复用后缓存局部性更好，且复用的是同一个引用，避免反复申请

**`T` 必须是引用类型（`T: AnyObject`）**。Swift 的 getter 返回值类型的**拷贝**，如果允许 `struct`，调用方对 `lease.value` 的修改会静默丢失、根本回不到池里。约束成 class 正好对应「堆对象」语义，也让 `recycler` 能原地复位。

## 导入

SwiftPM 是**零注册、零凭据**的分发：一个公开 Git 仓库 + `Package.swift` + 语义化 tag 就够了。

```swift
// Package.swift
dependencies: [
    .package(
        url: "https://github.com/rainbowcrr-sys/rbc-monorepo.git",
        .upToNextMajor(from: "0.1.0")
    )
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "GCPrimitives", package: "rbc-monorepo")
    ])
]
```

> **monorepo 子目录说明**：SwiftPM 的 `.package(url:)` 指向仓库根，要求 `Package.swift` 在根。本版放在 `swift/gc-primitives/`，直接依赖根仓库需要把该目录做成独立 Git 仓库，或用本地 path 依赖。首轮先以「可独立 `swift test` 的包」交付，分发方式在发版时再定（见文末）。

## 用法

```swift
import GCPrimitives

final class Buffer {
    var bytes: [UInt8] = []
}

let pool = try Pool<Buffer>(
    capacity: 32,
    factory: { Buffer() },
    recycler: { buf in buf.bytes.removeAll() }   // 归还时复位
)

let lease = try pool.borrow()
defer { try? lease.close() }                     // C1：必须显式归还
try lease.value.bytes.append(contentsOf: [1, 2, 3])
print(try lease.value.bytes)

try pool.assertNoActiveLeases()                  // 测试期把泄漏转成错误
```

`lease.value` 是 throwing getter；关闭后再读抛 `PoolError.leaseClosed`。

## 安全契约（C1–C5）

| 契约 | 实现 | 违反时 |
| --- | --- | --- |
| C1 显式归还 | `lease.close()`，推荐 `defer { try? lease.close() }` | 忘记 close 时 `deinit` 兜底：**结算计数、直接丢弃对象**，绝不回池 |
| C2 关闭后借用 | `pool.close()` 拒绝 `borrow()`，空闲对象立即清空 | `PoolError.poolClosed` |
| C3 有界 | `NSLock` 保护的有界栈，上限 `capacity`（默认 16） | — |
| C4 归还复位 | `recycler` 每次归还调用一次 | 抛错 → **对象丢弃、错误透传、计数照常结算**，绝不回池 |
| C5 强制误用检测 | 双重 close、关闭后读 `value`、工厂返回 nil、`capacity <= 0` | 一律 `PoolError`，**无开关、不用 `fatalError`** |

**计数语义**：`returnCount / active` 在 `close()` 最开头结算，所以 `recycler` 抛错也不会留下「幽灵活跃租约」。

**deinit 兜底的取舍**：Swift 的 `deinit` 不能 `throws`，无法在兜底路径里安全执行可能抛错的 `recycler`。所以忘记 `close()` 的对象**直接丢弃**而不复用——计数仍然精确，脏对象绝不会到下一个借用者手里。这是与 C++ RAII 的关键差异，写进 SPEC 11.2。

## 并发模型：锁保护变体

Swift 没有稳定的跨平台 thread-local API，所以本版用**单个 `NSLock` 保护的有界栈 + 锁内计数**，而不是每线程一份状态。跨线程使用同一个 `Lease` 不做运行时检测，由文档约定「租约只归借用它的线程使用」。CI 里用 `DispatchQueue.concurrentPerform` 100 次并发借还验证计数精确。

## 诊断 API

| Java | Swift |
| --- | --- |
| `borrow()` | `borrow() throws -> Lease<T>` |
| `capacity()` | `capacity` / `stats().capacity` |
| `idleCount()` | `stats().idle` |
| `activeLeases()` | `stats().active` |
| `borrowCount()` / `returnCount()` | `stats().borrowCount` / `.returnCount` |
| `assertNoActiveLeases()` | `assertNoActiveLeases() throws` |

另有 `stats().created`、`stats().closed`、`lease.returned`。

## 验证

```bash
cd swift/gc-primitives
swift test
```

CI 在 **macOS（Xcode Swift）与 Ubuntu Linux（Swift 5.9+）** 两套环境各跑一遍，共 12 项 XCTest，覆盖上表每一条契约 + 并发 + deinit 兜底。

## 分发（`0.1.0` 已发布）

**SwiftPM 依赖**（推荐）：

```swift
.package(url: "https://github.com/rainbowcrr-sys/gc-primitives-swift.git", from: "0.1.0")
```

独立分发仓库 https://github.com/rainbowcrr-sys/gc-primitives-swift 的根目录放 `Package.swift`，tag 为 `v0.1.0`。

- **源码主副本**：本目录 `swift/gc-primitives/`，CI 在 macOS + Ubuntu 各跑 12 项 XCTest
- **monorepo 发布 tag**：`swift/gc-primitives/v0.1.0`，Release 附源码 tarball
- **验证页**：https://swiftpackageindex.com/rainbowcrr-sys/gc-primitives-swift （首次收录可在 https://swiftpackageindex.com/add-a-package 提交）

> **为什么多一个仓库**：SwiftPM 要求 `Package.swift` 在仓库根，且版本 tag 只能是纯语义化版本（`v0.1.0`），不认 `swift/gc-primitives/v0.1.0` 这种子目录前缀；而 `v0.1.0` 已被 Java 首发占用，不能复用。两处代码内容一致，发版时同步。

零注册、零 token、零凭据。

每个 Markdown 都有中英双语版本，英文版以 `.en.md` 结尾。
