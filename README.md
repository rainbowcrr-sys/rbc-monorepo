# gc-primitives

> 中文 · [English](README.en.md)

减少分配与复用的对象池原语库，**同一套概念契约的 Java / C++ / Python / Rust / Go 实现**。不绑定业务场景，由调用方自行决定延迟与吞吐的取舍。

首个版本只做一件事：把「对象池 + 复用上下文」做成一组可组合的原语。行为对照与逐条映射见 **[SPEC.md](SPEC.md)**（[English](SPEC.en.md)）。

## 七语言实现

| 语言 | 项目目录 | 导入 | 分发 | 状态 |
| --- | --- | --- | --- | --- |
| Java 11 | [`java/gc-primitives/`](java/gc-primitives/) | `net.de5.rainbowcrrsys:gc-primitives` | Maven Central | ✅ `0.2.0` |
| C++17 | [`cpp/gc-primitives/`](cpp/gc-primitives/) | `#include <rbc/gc.hpp>`（header-only） | GitHub Release / vcpkg / Conan | ✅ `0.2.0` |
| Python 3.9+ | [`python/gc-primitives/`](python/gc-primitives/) | `from gc_primitives import Pool` | PyPI | ✅ `0.2.0` |
| Rust 1.70+ | [`rust/gc-primitives/`](rust/gc-primitives/) | `use gc_primitives::Pool` | crates.io | ✅ `0.2.0` |
| Go 1.21+ | [`go/gc-primitives/`](go/gc-primitives/) | `go get github.com/rainbowcrr-sys/rbc-monorepo/go/gc-primitives` | Git tag + pkg.go.dev（无中心仓库、无凭据） | ✅ `0.2.0` |
| Swift 5.9+ | [`swift/gc-primitives/`](swift/gc-primitives/) | `GCPrimitives`（SwiftPM） | 独立仓库 [`gc-primitives-swift`](https://github.com/rainbowcrr-sys/gc-primitives-swift) + Git tag（零注册零凭据） | ✅ `0.2.0` |
| Zig 0.14 | [`zig/gc-primitives/`](zig/gc-primitives/) | `gc_primitives` | GitHub Release tarball + Zig Index（零注册零凭据） | ✅ `0.2.0` |

> ⚠️ **0.1.x 全系列不推荐使用**。各渠道里的 `0.1.0` / `0.1.1` 制品仍可下载（平台不可变、无法删除或改写），但**缺少 0.2.0 的并发、诊断、配置与可观测能力，且不再获得任何修复**。请一律使用 `0.2.0`。

七语言各自独立版本号，统一 Apache-2.0。收益口径分开写：Java 压分配速率、C++ 与 Rust 少堆分配、Go 更少的堆分配且零凭据、Swift 减少 ARC 堆分配与 retain-release、Zig 命中空闲槽时零 `allocator.create`、**Python 版不承诺性能收益**（纯语义移植，原因见 [`python/gc-primitives/README.md`](python/gc-primitives/README.md)）。Rust 版额外承诺 **零 `unsafe`、零依赖**；Go 版是 C2/C3 的并发变体（无线程本地存储），见 `SPEC.md` 第 8.2 节；Swift / Zig 见第 11 章。

以下为 **Java 版**文档；C++ / Python / Rust / Go / Swift / Zig 的用法见各自 README。仓库内每个 Markdown 都有中文版与英文版，英文版文件名以 `.en.md` 结尾。

## 仓库结构约定

顶层按**语言**分，内层按**项目**分；新增项目不用建新仓库：

```
java/gc-primitives/     cpp/gc-primitives/     python/gc-primitives/     rust/gc-primitives/     go/gc-primitives/     swift/gc-primitives/     zig/gc-primitives/
java/example/           java/benchmarks/       （Java 侧兄弟模块，不进发布物）
java/test/   cpp/test/   python/test/   rust/test/   go/test/   swift/test/   zig/test/   ← 以后新项目示例
```

根只留 README、SPEC、LICENSE、`.github/`、`.gitignore` 与 Gradle 根配置（`build.gradle` / `settings.gradle` / `gradle.properties`）。新项目 `test` 就是往各语言目录下加一层，Gradle 在 `settings.gradle` 里追加 `include(':java:test')` 与 `projectDir`。

## tag 约定

库名 `gc-primitives` 自带连字符，用**双下划线**分隔避免切分歧义：

| 语言 | tag 格式 | 工作流 | 示例 |
| --- | --- | --- | --- |
| Java | `gc-primitives__java__v*` | `publish.yml` | `gc-primitives__java__v0.2.0` |
| Python | `gc-primitives__python__v*` | `publish-pypi.yml` | `gc-primitives__python__v0.2.0` |
| C++ | `gc-primitives__cpp__v*` | `release-cpp.yml` | `gc-primitives__cpp__v0.2.0` |
| Rust | `gc-primitives__rust__v*` | `publish-rust.yml` | `gc-primitives__rust__v0.2.0` |
| Go（例外） | `go/gc-primitives/v*` | `publish-go.yml` | `go/gc-primitives/v0.2.0` |
| Swift（例外） | `v*`（独立分发仓库） | `publish-swift.yml` | `v0.2.0` |
| Zig（例外） | `zig/gc-primitives/v*` | `publish-zig.yml` | `zig/gc-primitives/v0.2.0` |

Swift 另有 monorepo tag `swift/gc-primitives/v0.2.0` 用于触发流水线与挂 Release 资产；SwiftPM 的版本 tag 必须是纯语义化版本，所以放在独立分发仓库。上传类流水线都校验「tag 版本 == 代码里声明的版本」，不一致直接拒绝发布；**Go / Swift / Zig 是例外**——子目录模块/包的 tag 必须带目录前缀，且模块没有版本声明字段，改由「使用方拉取 + 运行」验证。历史 tag `v0.1.0` / `py-v0.1.0` / `cpp-v0.1.0` 保留但已从触发规则退役。另有一个纯 `v0.2.0` tag，仅作为 zigpkg.dev 等按仓库收录的索引站识别当前版本的 semver 锚点，不触发任何流水线。Maven Central 与 PyPI 的版本永久不可覆盖，改了代码必须升版本号。

## 导入（Java）

```groovy
// Gradle
implementation 'net.de5.rainbowcrrsys:gc-primitives:0.2.0'
```

```xml
<!-- Maven -->
<dependency>
  <groupId>net.de5.rainbowcrrsys</groupId>
  <artifactId>gc-primitives</artifactId>
  <version>0.2.0</version>
</dependency>
```

基线：Java 11。**当前 `0.2.0`**；`0.1.1` 是纯工程重构版（目录与 Gradle 路径调整），其 jar 内的 class 与 `0.1.0` 完全一致。许可证：Apache-2.0。

## Quick Start

```java
import net.de5.rainbowcrrsys.gcprimitives.*;

Pool<StringBuilder> pool =
    Pools.threadLocal(StringBuilder::new, sb -> sb.setLength(0), 8);

try (Lease<StringBuilder> lease = pool.borrow()) {
    StringBuilder sb = lease.get();
    sb.append("hello");
    // 使用 sb
} // 自动归还，Recycler 在这里把 sb 清空
```

`gc-primitives` 发布的只有一个 jar；`java/example` 是可运行示例，`java/benchmarks` 是 JMH 基准，两者都不进发布物。

## API 契约

| 类型 | 作用 |
| --- | --- |
| `Pool<T>` | 借出入口，附带 `activeLeases()` / `borrowCount()` / `returnCount()` / `assertNoActiveLeases()` 诊断 |
| `Lease<T>` | `AutoCloseable` 租约，`get()` 取对象，`close()` 归还 |
| `Recycler<T>` | 归还时的复位钩子，恢复对象到可再次借出的状态 |
| `Pools` | 静态工厂：`threadLocal(factory, recycler, capacity)` |

实现策略：**线程本地 + 有界**。借还无锁、无跨线程同步；命中空闲槽时不分配对象，连 `Lease` 句柄本身也从线程本地栈复用，正常路径接近零分配。每线程最多保留 `capacity` 个空闲对象（默认 64），超出的归还对象直接丢弃。

误用**始终强制校验**，立即抛 `PoolStateException`：双重归还 / 关闭后 `get()`、跨线程归还 / 跨线程取用、`factory` 返回 `null`；`capacity <= 0` 抛 `IllegalArgumentException`。

未归还的租约由 `activeLeases()` 精确计数，测试期用 `assertNoActiveLeases()` 把泄漏直接变成失败。

**使用契约**：租约与借出的对象只归借用线程使用；关闭之后不得再持有该对象引用。这两点由调用方保证。Rust 版靠回调闭包让这类误用在编译期就不可能发生，见 `SPEC.md` 第 8.1 节；Go 版靠文档约定与 `AssertNoActiveLeases()`，见第 8.2 节；Swift / Zig 的并发变体与 deinit / 显式释放差异见第 11 章。

## 本地构建

环境需要 **Gradle 8.10.2**（用 Java 11 运行）。仓库不附带 wrapper jar，如需 `./gradlew` 可先执行一次 `gradle wrapper --gradle-version 8.10.2`。

常用命令（模块路径已随目录改为 `:java:*`）：

```bash
gradle :java:gc-primitives:test          # 单元测试
gradle :java:example:run                 # 运行示例与契约自测，末行输出 QuickStart OK
gradle :java:example:allocCheck          # 分配字节数快检
gradle :java:benchmarks:jmh              # JMH + -prof gc
gradle :java:gc-primitives:build         # jar / sourcesJar / javadocJar
```

## 验证「真的省了 GC」

基准对照 `allocateFresh`（每次 `new StringBuilder`）与 `borrowPooled`（池化借用），用 JMH 的 `-prof gc` 输出分配速率与 GC 次数：

```bash
gradle :java:benchmarks:jmh
# 或自定义参数
gradle :java:benchmarks:run --args="AllocationBenchmark -f 1 -wi 3 -i 5 -prof gc"
```

不跑 JMH 也可以先用 `ThreadMXBean` 做一次分配字节数快检：`gradle :java:example:allocCheck`。

本机 Java 11 实测（N = 1,000,000 次，预热 3 轮）：每次 `new StringBuilder` 约 106.8 MB，池化借用约 53.4 MB（只剩 `toString()` 产生的结果 String）。池化把对象本身与其内部缓冲的分配整段消掉，分配量降到约 50%。正式结论以 `-prof gc` 的 `gc.alloc.rate` / `gc.count` 为准。

## 路线图

- `0.2.0`：primitive 特化（消除装箱分配）、可复用 `byte[]` / `char[]` 缓冲
- 后续：栈式复用上下文、更丰富的诊断事件

`0.x` 阶段 API 未冻结，破坏性变更会体现在次版本号上。

## 许可证

Apache License 2.0，见 [LICENSE](LICENSE)。
