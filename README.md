# gc-primitives

减少分配与复用的对象池原语库，**同一套概念契约的 Java / C++ / Python 实现**。不绑定业务场景，由调用方自行决定延迟与吞吐的取舍。

首个版本 `0.1.0` 只做一件事：把「对象池 + 复用上下文」做成一组可组合的原语。

## 三语言实现

三语言**同一套概念契约移植**，行为对照与逐条映射见 **[SPEC.md](SPEC.md)**。

| 语言 | 目录 | 导入 | 分发 | 状态 |
| --- | --- | --- | --- | --- |
| Java 11 | [`gc-primitives/`](gc-primitives/) | `net.de5.rainbowcrrsys:gc-primitives:0.1.0` | Maven Central | ✅ 已发布 |
| C++17 | [`cpp/`](cpp/) | `#include <rbc/gc.hpp>`（header-only） | vcpkg / Conan | ✅ 实现完成 |
| Python 3.9+ | [`python/`](python/) | `from gc_primitives import Pool` | PyPI | ✅ 实现完成 |

三语言各自独立版本号，统一 Apache-2.0。收益口径分开写：Java 压分配速率、C++ 少 `malloc`/`free`、**Python 版不承诺性能收益**（纯语义移植，原因见 `python/README.md`）。

以下为 **Java 版**文档；C++ 与 Python 的用法见各自 README。

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
├── .github/workflows/      打 tag 触发 Central Portal 发布
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

## 发布到 Maven Central

走 **Central Portal Publisher API**：Gradle 先把带 GPG 签名的产物发布到本地 `build/central-staging/`，打包成 `*-bundle.zip`，再由 `upload-central.sh` 以 `multipart/form-data` POST 到 `/api/v1/publisher/upload`，最后轮询 `/api/v1/publisher/status` 到终态。Portal 没有标准的 Maven 上传端点，所以不能用 `maven-publish` 直连。

### 一次性准备（这四步只能在网页/本机做）

**1. 验证 namespace**

登录 https://central.sonatype.com → Namespaces → Add Namespace，填 `net.de5.rainbowcrrsys`，复制给出的 Verification Key，在域名 `rainbowcrrsys.de5.net` 上加一条 TXT 记录（值就是那串 Key），回 Portal 点 Verify，状态变 `Verified`。注意校验读的是**这个域名本身**的 TXT，不是 `de5.net` 根域。

> 如果 `de5.net` 的 DNS 不由你控制、加不了 TXT，这条路走不通：把 groupId 改成 `io.github.rainbowcrr-sys`（Portal 里靠建一个指定名字的临时公开仓库验证，不需要域名），同步改 `build.gradle` 的 `group` 和 Java 包名即可。

**2. 生成 User Token**

Portal → 右上角账号 → View Account → Generate User Token，得到一组 username / password。弹窗关掉后不再完整显示，立刻存好。这不是你的登录密码。API 细节见 [Portal Publisher API 文档](https://central.sonatype.org/publish/publish-portal-api/)。

**3. 生成 GPG 密钥并上传公钥**

Central 要求每个产物都有 `.asc` 签名，且公钥必须在公共 keyserver 上。

```bash
gpg --full-generate-key                       # RSA 4096，邮箱用你能收信的
gpg --list-secret-keys --keyid-format=long
gpg --keyserver keyserver.ubuntu.com --send-keys <长KEYID>   # 或 keys.openpgp.org / pgp.mit.edu
gpg --armor --export-secret-keys <长KEYID> > private-key.asc  # 全文含 BEGIN/END 行，用完删掉
```

**4. 配 GitHub Secrets**

仓库 Settings → Secrets and variables → Actions，新增 4 条：

| Secret | 值 |
| --- | --- |
| `CENTRAL_USERNAME` | 第 2 步的 token username |
| `CENTRAL_PASSWORD` | 第 2 步的 token password |
| `SIGNING_KEY` | `private-key.asc` 全文 |
| `SIGNING_PASSWORD` | 该私钥口令 |

凭据只走 Secrets / 环境变量，不写进仓库任何文件。

### 发版

```bash
git tag v0.1.0
git push origin v0.1.0
```

也可以在 Actions 里手动 `workflow_dispatch` 触发，并选 `publishing_type`：

- `AUTOMATIC`（默认）：校验通过即自动发布到 Maven Central，打完 tag 不用再管
- `USER_MANAGED`：只上传，状态停在 `VALIDATED`，到 https://central.sonatype.com/publishing/deployments 人工点 Publish

工作流会先跑测试与示例构建，再执行 `:gc-primitives:bundleCentral`（产出 jar / sources / javadoc / pom + 每个的 `.asc` 与校验和），最后上传并轮询状态；`FAILED` 会打印 Portal 的错误详情并让任务失败。**已发布的版本永久不可删除或覆盖**，首次发版建议先用 `USER_MANAGED` 看一眼。

发布成功后到 https://central.sonatype.com/artifact/net.de5.rainbowcrrsys/gc-primitives 查看，同步到 `repo1.maven.org` 约 30 分钟，搜索索引可能再晚几小时。

POM 里的仓库地址按 `rbc-monorepo` 命名，如实际仓库名不同，改 `gc-primitives/build.gradle` 的 `scm` 段即可。

## 路线图

- `0.2.0`：primitive 特化（消除装箱分配）、可复用 `byte[]` / `char[]` 缓冲
- 后续：栈式复用上下文、更丰富的诊断事件

`0.x` 阶段 API 未冻结，破坏性变更会体现在次版本号上。

## 许可证

Apache License 2.0，见 [LICENSE](LICENSE)。
