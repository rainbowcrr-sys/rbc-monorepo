# gc-primitives · Zig 版

> 中文 · [English](README.en.md)

与 Java / C++ / Python / Rust / Go / Swift 同一套概念契约的 Zig 移植，行为规范见仓库根 [SPEC.md](../../SPEC.md) 第 11.2 节（[English](../../SPEC.en.md)）。

## 为什么 Zig 最需要对象池：没有 GC，也没有隐式分配

Zig **没有垃圾回收，也没有隐藏的分配器**：每一块内存都来自调用方显式传入的 `std.mem.Allocator`。所以「减少分配」在这里是最字面的一层：

- 命中空闲槽时完全不调用 `allocator.create`
- 被丢弃的对象通过 `destroy` 钩子显式释放，绝不泄漏
- `Pool(comptime T)` 是编译期泛型，零运行时开销、零虚表、零类型擦除
- 池自身只用 `std.ArrayListUnmanaged`，不持有任何隐式状态

**Zig 独有的 `destroy` 钩子**：其他语言靠 GC / ARC / Drop 回收被丢弃的对象，Zig 必须自己来。复位失败、超出容量、关闭池时的对象都会走 `destroy`，`std.testing.allocator` 会在测试里抓出每一个漏掉的对象。

## 导入

Zig 没有中心仓库、没有账号、没有 token。公开 Git 仓库 + tag 即可：

```bash
# 本地直接用
zig test src/root.zig
```

作为依赖（分发时用 tag tarball，见文末）：

```zig
const gc = @import("gc_primitives");
var pool = try gc.Pool(*Buffer).init(allocator, .{
    .capacity = 32,
    .factory = createBuffer,
    .recycler = resetBuffer,
    .destroy = destroyBuffer,
});
defer pool.deinit();
```

## 用法

```zig
const std = @import("std");
const gc = @import("gc_primitives");

const Buffer = struct {
    data: [32]u8 = undefined,
    len: usize = 0,
};

fn createBuffer(a: std.mem.Allocator) anyerror!?*Buffer {
    const b = try a.create(Buffer);
    b.* = .{};
    return b;
}
fn resetBuffer(b: *Buffer) anyerror!void { b.len = 0; }
fn destroyBuffer(a: std.mem.Allocator, b: *Buffer) void { a.destroy(b); }

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pool = try gc.Pool(*Buffer).init(allocator, .{
        .capacity = 8,
        .factory = createBuffer,
        .recycler = resetBuffer,
        .destroy = destroyBuffer,
    });
    defer pool.deinit();                 // 释放所有空闲对象

    var lease = try pool.borrow();
    defer lease.close() catch {};        // C1：必须显式归还
    const b = try lease.value();
    b.len = 3;

    try pool.assertNoActiveLeases();     // 测试期把泄漏转成错误
}
```

> Zig 没有析构函数，**忘记 `close()` 会同时留下活跃计数和未释放的对象**。`assertNoActiveLeases()` 与测试用 allocator 的泄漏检测会一起把它抓出来。

## 安全契约（C1–C5）

| 契约 | 实现 | 违反时 |
| --- | --- | --- |
| C1 显式归还 | `lease.close()`，推荐 `defer lease.close() catch {};` | 无析构兜底；`assertNoActiveLeases()` + allocator 泄漏检测 |
| C2 关闭后借用 | `pool.close()` 拒绝 `borrow()`，空闲对象全部 `destroy` | `error.PoolClosed` |
| C3 有界 | `ArrayListUnmanaged` 上限 `capacity`（默认 16），超出即 `destroy` | — |
| C4 归还复位 | `recycler` 每次归还调用一次 | 返回 error → **对象 `destroy`、错误透传、计数照常结算**，绝不回池 |
| C5 强制误用检测 | 双重 close、关闭后 `value()`、工厂返回 `null`、`capacity == 0` | 一律返回 error，**不用 `@panic`、无开关** |

**计数语义**：`return_count / active` 在 `close()` 最开头结算，所以 `recycler` 失败也不会留下「幽灵活跃租约」。

**错误集**：`PoolError`（`InvalidCapacity` / `FactoryFailed` / `LeaseClosed` / `DoubleClose` / `PoolClosed` / `ActiveLeases` / `OutOfMemory`）。`recycler` 与 `factory` 的自定义错误通过 `anyerror` 原样透传。

## 诊断 API

| Java | Zig |
| --- | --- |
| `borrow()` | `borrow() anyerror!Lease(T)` |
| `capacity()` | `stats().capacity` |
| `idleCount()` | `stats().idle` |
| `activeLeases()` | `stats().active` |
| `borrowCount()` / `returnCount()` | `stats().borrow_count` / `.return_count` |
| `assertNoActiveLeases()` | `assertNoActiveLeases() PoolError!void` |

另有 `stats().created`、`stats().closed`、`lease.isReturned()`。

## 并发模型

单 `Pool` 实例不跨线程共享（Zig 无内置锁、无 thread-local 抽象，线程由调用方负责）。计数是普通 `usize`，与其余实现一样靠「实例归属」约定。测试全部用**局部状态**，不依赖任何可变全局，因此 `zig test` 并发执行 test block 也不会串数据。

## 验证

```bash
cd zig/gc-primitives
zig test src/root.zig                # 编译 + 运行 11 项契约测试 + 内存泄漏检测
zig test -O ReleaseSafe src/root.zig # ReleaseSafe 再跑一遍
zig build test
```

CI 用 **Zig 0.14.0** 真跑上述三步。`std.testing.allocator` 会在每个 test 结束时检查所有分配是否释放——这是本版「不要一点 bug」最硬的一道保障。

## 分发（本轮未发版）

- Zig 无中心仓库：公开仓库 + `zig/gc-primitives/v0.1.0` tag + GitHub `zig-package` topic，索引 bot 自动收录
- 依赖写 tarball URL + `.hash`（`build.zig.zon` 在首次发布时补齐并带上指纹）
- 本轮按要求**只建目录与代码、不打 tag、不写任何凭据**；要发说一句「发 Zig 0.1.0」

每个 Markdown 都有中英双语版本，英文版以 `.en.md` 结尾。
