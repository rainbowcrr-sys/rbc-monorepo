# gc-primitives

> 中文 · [English](README.en.md)

减少分配与复用的对象池原语库，**同一套概念契约的 Java / C++ / Python 实现**。不绑定业务场景，由调用方自行决定延迟与吞吐的取舍。

首个版本 `0.1.0` 只做一件事：把「对象池 + 复用上下文」做成一组可组合的原语。

## 三语言实现

三语言**同一套概念契约移植**，行为对照与逐条映射见 **[SPEC.md](SPEC.md)**（[English](SPEC.en.md)）。

| 语言 | 目录 | 导入 | 分发 | 状态 |
| --- | --- | --- | --- | --- |
| Java 11 | [`gc-primitives/`](gc-primitives/) | `net.de5.rainbowcrrsys:gc-primitives:0.1.0` | Maven Central | ✅ 已发布 |
| C++17 | [`cpp/`](cpp/) | `#include <rbc/gc.hpp>`（header-only） | vcpkg / Conan | ✅ 实现完成 |
| Python 3.9+ | [`python/`](python/) | `from gc_primitives import Pool` | PyPI | ✅ 实现完成 |

三语言各自独立版本号，统一 Apache-2.0。收益口径分开写：Java 压分配速率、C++ 少 `malloc`/`free`、**Python 版不承诺性能收益**（纯语义移植，原因见 [`python/README.md`](python/README.md)）。

以下为 **Java 版**文档；C++ 与 Python 的用法见各自 README。仓库内所有 Markdown 均有中文版与英文版，文件名以 `.en.md` 结尾的是英文版。

## 导入

```groovy
// Gradle
implementation 'net.de5.rainbowcrrsys:gc-primitives:0.1.0'
```

```xml
<!-- Maven -->
<dependency>
  <groupId>net.de5.rainbowcrrsys</groupId>
  <artifactId>gc-primitives</artifactId>
  <version>0.1.0</version>
</dependency>
```

基线：Java 11。许可证：Apache-2.0。

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

`gc-primitives` 发布的只有一个 jar；`example` 是可运行示例，`benchmarks` 是 JMH 基准，两者都不进发布物。

## API 契约

| 类型 | 作用 |
| --- | --- |
| `Pool<T>` | 借出入口，附带 `activeLeases()` / `borrowCount()` / `returnCount()` / `assertNoActiveLeases()` 诊断 |
| `Lease<T>` | `AutoCloseable` 租约，`get()` 取对象，`close()` 归还 |
| `Recycler<T>` | 归还时的复位钩子，恢复对象到可再次借出的状态 |
| `Pools` | 静态工厂：`threadLocal(factory, recycler, capacity)` |

实现策略：**线程本地 + 有界**。借还无锁、无跨线程同步；命中空闲槽时不分配对象，连 `Lease` 句柄本身也从线程本地栈复用，正常路径接近零分配。每线程最多保留 `capacity` 个空闲对象（默认 64），超出的归还对象直接丢弃。

误用**始终强制校验**，立即抛 `PoolStateException`：

- 双重归还 / 关闭后 `get()`
- 跨线程归还 / 跨线程取用
- `factory` 返回 `null`
- `capacity <= 0` 抛 `IllegalArgumentException`

未归还的租约由 `activeLeases()` 精确计数，测试期用 `assertNoActiveLeases()` 把泄漏直接变成失败。

**使用契约**：租约与借出的对象只归借用线程使用；关闭之后不得再持有该对象引用。这两点由调用方保证，库无法在运行时替你拦截「归还后仍被外部引用」的情况。

## 仓库结构

```
rbc-monorepo/
├── gc-primitives/          主库，单 jar，按 pool/lease/recycler 语义分包
│   ├── src/main/java/net/de5/rainbowcrrsys/gcprimitives/
│   └── src/test/java/...  JUnit 5
├── example/                可运行示例 + 九项契约自测
├── benchmarks/             JMH 基准（独立模块）
├── cpp/                    C++17 header-only 实现
├── python/                 Python 3.9+ 语义移植
├── .github/workflows/      CI 工作流
├── SPEC.md / SPEC.en.md    跨语言契约规范（中 / 英）
├── LICENSE                 Apache-2.0
└── build.gradle / settings.gradle / gradle.properties
```

后续新库在同一命名空间下以 `rbc-` 前缀追加模块，`gc-primitives` 名称保留不变。

## 本地构建

环境需要 **Gradle 8.10.2**（用 Java 11 运行）。仓库不附带 wrapper jar，如需 `./gradlew` 可先执行一次：

```bash
gradle wrapper --gradle-version 8.10.2
```

常用命令：

```bash
gradle :gc-primitives:test          # 单元测试
gradle :example:run                # 运行示例与契约自测，末行输出 QuickStart OK
gradle :example:allocCheck         # 分配字节数快检
gradle :benchmarks:jmh             # JMH + -prof gc
gradle :gc-primitives:build        # jar / sourcesJar / javadocJar
```

## 验证「真的省了 GC」

基准对照 `allocateFresh`（每次 `new StringBuilder`）与 `borrowPooled`（池化借用），用 JMH 的 `-prof gc` 输出分配速率与 GC 次数：

```bash
gradle :benchmarks:jmh
# 或自定义参数
gradle :benchmarks:run --args="AllocationBenchmark -f 1 -wi 3 -i 5 -prof gc"
```

不跑 JMH 也可以先用 `ThreadMXBean` 做一次分配字节数快检：

```bash
gradle :example:allocCheck
```

本机 Java 11 实测（N = 1,000,000 次，预热 3 轮）：

| 路径 | 已分配字节 | 构成 |
| --- | --- | --- |
| 每次 `new StringBuilder` | 约 106.8 MB | StringBuilder + 内部缓冲 + 结果 String |
| 池化借用 | 约 53.4 MB | 只剩 `toString()` 产出的结果 String |

池化把对象本身与其内部缓冲的分配整段消掉，分配量降到约 50%；剩下的部分属于业务返回值，不是池该优化的范围。正式结论仍以 `-prof gc` 的 `gc.alloc.rate` / `gc.count` 为准，发布前把一组基线结果记入 Release Notes，让每个版本的效果可对照。

## 路线图

- `0.2.0`：primitive 特化（消除装箱分配）、可复用 `byte[]` / `char[]` 缓冲
- 后续：栈式复用上下文、更丰富的诊断事件

`0.x` 阶段 API 未冻结，破坏性变更会体现在次版本号上。

## 许可证

Apache License 2.0，见 [LICENSE](LICENSE)。
