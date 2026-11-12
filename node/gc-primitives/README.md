# gc-primitives · Node / TypeScript 版

> 中文 · [English](README.en.md)

与 Java / C++ / Python / Rust / Go 同一套概念契约的 Node 移植，行为规范见仓库根 [SPEC.md](../../SPEC.md) 第 11.1 节（[English](../../SPEC.en.md)）。

**本版首轮只做「安全契约」**：C1–C5 的强制误用检测、有界复用、归还复位与诊断计数。异步工厂、`withLease` 回调、Worker Threads 专项测试留到后续版本，见文末「暂未实现」。

## 导入

```bash
npm install @rainbowcrr-sys/gc-primitives
```

包是纯 ESM、自带 `.d.ts`、`@types/node` 与 `typescript` 只在开发期使用，**运行时零第三方依赖**。基线 Node ≥ 18（CI 真跑 18 / 20 / 22）。

```ts
import { Pool } from '@rainbowcrr-sys/gc-primitives';

const pool = new Pool<{ buf: string[] }>({
  capacity: 32,
  factory: () => ({ buf: [] }),
  recycler: (obj) => { obj.buf.length = 0; },   // 归还时复位
});

const lease = pool.borrow();
try {
  lease.value.buf.push('hello');
  console.log(lease.value.buf);
} finally {
  lease.return();                                  // C1：必须显式归还
}

pool.assertNoActiveLeases();                        // 测试期把泄漏转成异常
```

Node 20+ / TypeScript 5.2+ 还可以用 `using`：

```ts
{
  using lease = pool.borrow();
  lease.value.buf.push('world');
} // 自动调用 DISPOSE 钩子归还
```

## 安全契约（本轮重点）

| 契约 | 实现 | 违反时 |
| --- | --- | --- |
| C1 显式归还 | `lease.return()` / `close()` / `dispose()` / `using` | 无析构兜底，靠 `assertNoActiveLeases()` 发现 |
| C2 关闭后借用 | `pool.close()` 后拒绝 `borrow()`，空闲对象立即清空 | 抛 `PoolStateError` |
| C3 有界 | 空闲数组上限 `capacity`（默认 16），超出直接丢弃 | — |
| C4 归还复位 | `recycler` 每次归还调用一次 | 抛错 → **对象丢弃、错误透传、计数照常结算**，绝不回池 |
| C5 强制误用检测 | 双重归还、归还后读 `value`、工厂返回空值、`capacity <= 0`、钩子非函数 | 一律抛 `PoolStateError`，**无开关、不分 debug/release、不调用 `process.exit`** |

**计数语义**：`borrowCount / returnCount / active` 在 `return()` 的最开头结算，所以即使 `recycler` 抛错也不会留下「幽灵活跃租约」。`created` 只统计真正由工厂新建的对象。

**「归还后仍被外部引用」**：JavaScript 无法在运行时拦截，由调用方保证 `return()` 之后不再持有 `lease.value`。这一点五语言文档一致。

## 诊断 API（SPEC 第 4 节映射）

| Java | Go | Node |
| --- | --- | --- |
| `borrow()` | `Borrow()` | `borrow()` |
| `capacity()` | `Capacity()` | `capacity` / `stats().capacity` |
| `idleCount()` | `IdleCount()` | `stats().idle` |
| `activeLeases()` | `ActiveLeases()` | `stats().active` |
| `borrowCount()` / `returnCount()` | `BorrowCount()` / `ReturnCount()` | `stats().borrowCount` / `.returnCount` |
| `assertNoActiveLeases()` | `AssertNoActiveLeases() error` | `assertNoActiveLeases()`（抛 `PoolStateError`） |

另有 `stats().created` 与 `stats().closed`，以及 `lease.returned`、`pool.closed`。

## 并发模型：单线程变体

Node 的事件循环是单线程，**池内部不需要锁**；但 `worker_threads` 的每个 worker 有独立 V8 堆，所以：

- **每个 worker 各自 `new Pool(...)`**，不要跨 worker 共享同一个池
- 不做跨 worker 的运行时误用检测（无法可靠识别 realm），改由文档约定，见 SPEC 11.1
- `FinalizationRegistry` 不做泄漏兜底：GC 时机不确定，会引入不可复现的行为；改用确定性的 `assertNoActiveLeases()`

## 验证

```bash
cd node/gc-primitives
npm install
npm run build     # tsc → dist/*.js + *.d.ts
npm test          # node:test 直接 import dist/，验证真正会发布的产物
```

CI 在 **Node 18 / 20 / 22** 三套运行时各跑一遍 `build + test`，并额外做 `tsc --noEmit` 类型检查。测试共 13 项，覆盖上表每一条契约。

## 分发（本轮未发版）

- 包名 `@rainbowcrr-sys/gc-primitives`（scope 与 GitHub owner 对齐）
- `publish-npm.yml` 已备好，走 **npm Trusted Publishing / OIDC**，零长期 token
- **首次发布有鸡生蛋问题**：OIDC 要求包先存在于 npm，所以首发需要一次性 Granular Token（只存 GitHub Secret，不进仓库文件），之后登记 Trusted Publisher 即可全自动
- tag 前缀 `node-gc-primitives-v0.1.0`

> 本轮按要求**只建文件夹与代码、不发版、不写任何凭据**。等你说「发 Node 0.1.0」再走首发流程。

## 暂未实现（后续版本）

- 异步工厂 `borrowAsync()` / `Promise` 复位钩子
- `withLease(pool, fn)` 回调式自动归还
- Worker Threads 专项集成测试
- ESM + CJS 双格式输出（当前纯 ESM）
- 基准测试（不写死性能数字）

每个 Markdown 都有中英双语版本，英文版以 `.en.md` 结尾。
