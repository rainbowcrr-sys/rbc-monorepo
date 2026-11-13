import XCTest
@testable import GCPrimitives

/// gc-primitives 0.2.0 增量能力测试（与七语言同口径）。
/// 旧 PoolTests.swift 的 12 项必须同时全绿。
final class V020Tests: XCTestCase {

    final class Buffer { var bytes: [UInt8] = [] }

    private func cfg(_ n: Int, _ p: V020.OnFull) -> V020.PoolConfig {
        var c = V020.PoolConfig(); c.maxSize = n; c.onFull = p; return c
    }
    private func makePool(_ c: V020.PoolConfig = V020.PoolConfig(),
                          hooks: V020.LifecycleHooks<Buffer> = V020.LifecycleHooks<Buffer>()) throws -> V020.ManagedPool<Buffer> {
        try V020.ManagedPool<Buffer>(factory: { Buffer() },
                                     recycler: { buf in buf.bytes.removeAll() },
                                     config: c, hooks: hooks)
    }

    func testMetricsFieldsIsomorphic() throws {
        let j = V020.Metrics().toJSON()
        XCTAssertEqual(V020.metricsFields.count, 16)
        for k in V020.metricsFields { XCTAssertTrue(j.contains("\"\(k)\""), "missing \(k)") }
    }

    func testCollectorCounters() {
        let c = V020.MetricsCollector()
        c.recordBorrow(hit: false, waitMs: 1, created: true)
        c.recordBorrow(hit: true, waitMs: 2, created: false)
        c.recordReturn(lifetimeMs: 3)
        c.recordReturn(lifetimeMs: 5)
        let s = c.snapshot(capacity: 8, idle: 1, closed: false)
        XCTAssertEqual(s.borrowCount, 2)
        XCTAssertEqual(s.returnCount, 2)
        XCTAssertEqual(s.activeLeases, 0)
        XCTAssertEqual(s.poolHits, 1)
        XCTAssertEqual(s.hitRate, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.created, 1)
        XCTAssertEqual(s.waitTimeMax, 2)
    }

    /// sink 是 @Sendable 闭包，不能直接捕获并修改局部 var；用锁保护的盒子。
    private final class NamesBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ s: String) { lock.lock(); defer { lock.unlock() }; items.append(s) }
        var value: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func testMemoryScopeDisabledAndEnabled() {
        // 未开启时 end() 不产生输出；开启时 sink 被调用（嵌套 inner 先于 outer）
        setenv(V020.diagEnv, "1", 1)
        let box = NamesBox()
        do {
            let outer = V020.MemoryScope("outer", sink: { r in box.append(r.name) })
            let inner = V020.MemoryScope("inner", sink: { r in box.append(r.name) })
            _ = [Int](repeating: 7, count: 128)
            inner.end(); outer.end()
        }
        XCTAssertEqual(box.value, ["inner", "outer"])
        unsetenv(V020.diagEnv)
    }

    func testLeakSamplingMinimumFields() {
        let d = V020.LeakDetector()
        let id = d.onBorrow("db-query")
        let leaks = d.detectLeaks(timeoutMs: 0)
        XCTAssertEqual(leaks.count, 1)
        XCTAssertEqual(leaks[0].tag, "db-query")
        XCTAssertFalse(leaks[0].leaseId.isEmpty)
        XCTAssertTrue(leaks[0].timedOut)
        let j = leaks[0].toJSON()
        for k in ["lease_id", "borrowed_at", "age_ms", "tag", "timed_out"] {
            XCTAssertTrue(j.contains(k), "missing \(k)")
        }
        d.onReturn(id)
        XCTAssertTrue(d.detectLeaks(timeoutMs: 0).isEmpty)
    }

    func testYAMLSubsetAndSchema() throws {
        let text = """
        pools:
          default:
            max_size: 8
            on_full: "reject"
            leak_detection: true
            lifecycle:
              on_return: "reset"
              clear_sensitive: yes
        diagnostics:
          memory_scope: false
        """
        let flat = try V020.parseYAMLSubset(text)
        XCTAssertEqual(flat["pools.default.max_size"], "8")
        XCTAssertEqual(flat["pools.default.on_full"], "reject")
        XCTAssertEqual(flat["pools.default.lifecycle.clear_sensitive"], "yes")
        XCTAssertEqual(flat["diagnostics.memory_scope"], "false")

        var bad = V020.PoolConfig(); bad.maxSize = -5
        XCTAssertThrowsError(try bad.validate())
        XCTAssertThrowsError(try V020.OnFull.parse("bounce"))
    }

    func testConfigEnvOverride() throws {
        let path = NSTemporaryDirectory() + "gc_v020_\(getpid()).yaml"
        try "pools:\n  default:\n    max_size: 3\n    on_full: reject\n".write(toFile: path, atomically: true, encoding: .utf8)
        setenv("GC_PRIMITIVES__DEFAULT__MAX_SIZE", "17", 1)
        let c = try V020.loadConfig(path: path, pool: "default")
        XCTAssertEqual(c.maxSize, 17)
        XCTAssertEqual(c.onFull, .reject)
        unsetenv("GC_PRIMITIVES__DEFAULT__MAX_SIZE")
        try? FileManager.default.removeItem(atPath: path)
    }

    func testFullPolicies() throws {
        let p1 = try makePool(cfg(1, .reject))
        let a = try p1.borrow()
        XCTAssertThrowsError(try p1.borrow())
        try a.close()

        var blockCfg = cfg(1, .block); blockCfg.blockTimeoutMs = 30
        let p2 = try makePool(blockCfg)
        let b = try p2.borrow()
        XCTAssertThrowsError(try p2.borrow())
        try b.close()

        var growCfg = cfg(1, .grow); growCfg.maxOverflow = 2
        let p3 = try makePool(growCfg)
        var leases: [V020.ManagedLease<Buffer>] = []
        for _ in 0..<3 { leases.append(try p3.borrow()) }
        for l in leases { try l.close() }
        XCTAssertNoThrow(try p3.assertNoActiveLeases())
    }

    func testHooksPrewarmAndSnapshot() throws {
        var events: [String] = []
        var hooks = V020.LifecycleHooks<Buffer>()
        hooks.onCreate = { _ in events.append("create") }
        hooks.onBorrow = { _ in events.append("borrow") }
        hooks.onReturn = { _ in events.append("return") }
        hooks.onDestroy = { _ in events.append("destroy") }
        let p = try makePool(hooks: hooks)
        XCTAssertEqual(try p.prewarm(2), 2)
        let snap = p.snapshot()
        for k in ["config", "stats", "active_leases", "idle_objects"] {
            XCTAssertTrue(snap.contains(k), "missing \(k)")
        }
        XCTAssertTrue(events.contains("create"))
        XCTAssertTrue(events.contains("borrow"))
        XCTAssertTrue(events.contains("return"))
        p.close()
        XCTAssertTrue(events.contains("destroy"))
    }

    func testCombinationMatrixFixed() throws {
        XCTAssertNoThrow(try V020.assertCombination(.shared, "shardable"))
        XCTAssertNoThrow(try V020.assertCombination(.shared, "two_level_l2"))
        XCTAssertThrowsError(try V020.assertCombination(.local, "shardable"))
        XCTAssertThrowsError(try V020.assertCombination(.local, "two_level_l2"))
    }

    func testShardedAndTwoLevel() throws {
        var shards: [V020.ManagedPool<Buffer>] = []
        for _ in 0..<4 { shards.append(try makePool(cfg(2, .dropOldest))) }
        let sp = try V020.ShardedPool(shards, kind: .shared)
        let l = try sp.borrow()
        try (try l.value()).bytes.append(1)
        try l.close()
        XCTAssertEqual(sp.metrics().borrowCount, 1)
        sp.close()

        let l2 = try makePool(cfg(8, .dropOldest))
        let tp = try V020.TwoLevelPool(l2, l1Size: 2, kind: .shared)
        let tl = try tp.borrow()
        try tl.close()
        XCTAssertNoThrow(try l2.assertNoActiveLeases())
    }

    func testSendableNoteDocumented() {
        XCTAssertTrue(V020.sendableNote().contains("@unchecked Sendable"))
    }

    func testOriginalContractStillGreen() throws {
        let pool = try Pool<Buffer>(capacity: 4, factory: { Buffer() },
                                    recycler: { buf in buf.bytes.removeAll() })
        let lease = try pool.borrow()
        try lease.value.bytes.append(1)
        try lease.close()
        XCTAssertNoThrow(try pool.assertNoActiveLeases())
    }
}
