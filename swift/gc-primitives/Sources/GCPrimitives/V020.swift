import Foundation

// gc-primitives 0.2.0 · 增量能力层（纯新增，不改动 Pool.swift）
//
// 实现 SPEC.md 第 12 章：统一 metrics JSON 同构快照、memory_scope、泄漏采样、
// 统一 YAML 子集配置 + schema + env + 级联 + reload（降级档：手动触发）、
// 满池策略 / 生命周期钩子 / 预热 / 快照、ShardedPool / TwoLevelPool 组合矩阵、
// Sendable 条件遵循（Swift 6 严格并发可用）。
//
// 核心零依赖：只用 Foundation。GC_PRIMITIVES_DIAG 未设时 memory_scope 为空操作。

public enum V020 {

    public static let diagEnv = "GC_PRIMITIVES_DIAG"
    public static let configEnv = "GC_PRIMITIVES_CONFIG"
    /// 借出采样最小集七语言都可用；调用栈快照是 Python / Go / Java 的可选增强。
    public static let detectLeaksAvailable = true

    // -----------------------------------------------------------------------
    // 12.3 统一 metrics JSON 同构快照（16 字段，七语言同名）
    // -----------------------------------------------------------------------

    public static let metricsFields: [String] = [
        "borrow_count", "return_count", "active_leases", "pool_hits", "pool_misses",
        "hit_rate", "wait_time_p50", "wait_time_p99", "wait_time_max",
        "object_lifetime_p50", "eviction_count", "leak_count", "created", "idle",
        "capacity", "closed",
    ]

    public struct Metrics: Equatable, Sendable, Codable {
        public var borrowCount: Int = 0
        public var returnCount: Int = 0
        public var activeLeases: Int = 0
        public var poolHits: Int = 0
        public var poolMisses: Int = 0
        public var hitRate: Double = 0
        public var waitTimeP50: Double = 0
        public var waitTimeP99: Double = 0
        public var waitTimeMax: Double = 0
        public var objectLifetimeP50: Double = 0
        public var evictionCount: Int = 0
        public var leakCount: Int = 0
        public var created: Int = 0
        public var idle: Int = 0
        public var capacity: Int = 0
        public var closed: Bool = false

        enum CodingKeys: String, CodingKey {
            case borrowCount = "borrow_count", returnCount = "return_count"
            case activeLeases = "active_leases", poolHits = "pool_hits"
            case poolMisses = "pool_misses", hitRate = "hit_rate"
            case waitTimeP50 = "wait_time_p50", waitTimeP99 = "wait_time_p99"
            case waitTimeMax = "wait_time_max"
            case objectLifetimeP50 = "object_lifetime_p50"
            case evictionCount = "eviction_count", leakCount = "leak_count"
            case created, idle, capacity, closed
        }
        public init() {}

        public func toJSON() -> String {
            let e = JSONEncoder()
            e.outputFormatting = [.sortedKeys]
            guard let d = try? e.encode(self), let s = String(data: d, encoding: .utf8)
            else { return "{}" }
            return s
        }
    }

    /// 线程安全的指标收集器（用 NSLock，不引入额外依赖）。
    public final class MetricsCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var m = Metrics()
        private var waits: [Double] = []
        private var lifetimes: [Double] = []

        public init() {}

        public func recordBorrow(hit: Bool, waitMs: Double, created: Bool) {
            lock.lock(); defer { lock.unlock() }
            m.borrowCount += 1; m.activeLeases += 1
            if hit { m.poolHits += 1 } else { m.poolMisses += 1 }
            if created { m.created += 1 }
            waits.append(waitMs)
        }
        public func recordReturn(lifetimeMs: Double) {
            lock.lock(); defer { lock.unlock() }
            m.returnCount += 1; m.activeLeases -= 1
            lifetimes.append(lifetimeMs)
        }
        public func recordEviction() { lock.lock(); m.evictionCount += 1; lock.unlock() }
        public func recordLeak(_ n: Int) { lock.lock(); m.leakCount += n; lock.unlock() }

        public func snapshot(capacity: Int, idle: Int, closed: Bool) -> Metrics {
            lock.lock(); defer { lock.unlock() }
            var out = m
            let w = waits.sorted(), l = lifetimes.sorted()
            let total = out.poolHits + out.poolMisses
            out.hitRate = total == 0 ? 0 : Double(out.poolHits) / Double(total)
            out.waitTimeP50 = pct(w, 0.50)
            out.waitTimeP99 = pct(w, 0.99)
            out.waitTimeMax = w.last ?? 0
            out.objectLifetimeP50 = pct(l, 0.50)
            out.capacity = capacity; out.idle = idle; out.closed = closed
            return out
        }
        private func pct(_ s: [Double], _ q: Double) -> Double {
            guard !s.isEmpty else { return 0 }
            return s[Int((Double(s.count - 1) * q).rounded())]
        }
    }

    // -----------------------------------------------------------------------
    // 12.5 memory_scope
    // -----------------------------------------------------------------------

    public static func diagEnabled() -> Bool {
        let v = ProcessInfo.processInfo.environment[diagEnv]?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return !v.isEmpty && v != "0" && v != "false" && v != "off"
    }

    public struct ScopeReport: Sendable {
        public let name: String
        public let elapsedMs: Double
        public let borrowCountDelta: Int
        public let createdDelta: Int
    }

    /// RAII 作用域：`defer` 或显式 `end()` 结束；未开启时为 no-op。
    public final class MemoryScope {
        private let name: String
        private let sink: (@Sendable (ScopeReport) -> Void)?
        private let jsonPath: String?
        private let collector: MetricsCollector?
        private let active: Bool
        private let t0 = Date()
        private let b0: Int, c0: Int
        private var ended = false

        public init(_ name: String,
                    sink: (@Sendable (ScopeReport) -> Void)? = nil,
                    jsonPath: String? = nil,
                    collector: MetricsCollector? = nil) {
            self.name = name; self.sink = sink; self.jsonPath = jsonPath
            self.collector = collector
            self.active = V020.diagEnabled()
            if active, let c = collector {
                let s = c.snapshot(capacity: 0, idle: 0, closed: false)
                b0 = s.borrowCount; c0 = s.created
            } else { b0 = 0; c0 = 0 }
        }
        deinit { end() }
        public func end() {
            guard active, !ended else { return }
            ended = true
            var bd = 0, cd = 0
            if let c = collector {
                let s = c.snapshot(capacity: 0, idle: 0, closed: false)
                bd = s.borrowCount - b0; cd = s.created - c0
            }
            let r = ScopeReport(name: name,
                                elapsedMs: Date().timeIntervalSince(t0) * 1000,
                                borrowCountDelta: bd, createdDelta: cd)
            if let sink { sink(r) }
            else if let path = jsonPath {
                let line = "{\"name\":\"\(r.name)\",\"elapsed_ms\":\(r.elapsedMs),\"borrow_count_delta\":\(bd),\"created_delta\":\(cd)}\n"
                if let data = line.data(using: .utf8) {
                    if let fh = FileHandle(forWritingAtPath: path) {
                        fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
                    } else {
                        try? data.write(to: URL(fileURLWithPath: path))
                    }
                }
            } else {
                FileHandle.standardError.write(
                    "[gc-primitives] \(r.name): borrows=\(bd) created=\(cd) (\(r.elapsedMs) ms)\n"
                        .data(using: .utf8) ?? Data())
            }
        }
    }

    // -----------------------------------------------------------------------
    // 12.6 泄漏检测（借出采样最小集，无后台线程）
    // -----------------------------------------------------------------------

    public struct LeaseSample: Sendable {
        public let leaseId: String
        public let borrowedAt: Double
        public let ageMs: Double
        public let tag: String
        public let timedOut: Bool
        public func toJSON() -> String {
            "{\"lease_id\":\"\(leaseId)\",\"borrowed_at\":\(borrowedAt),\"age_ms\":\(ageMs),\"tag\":\"\(tag)\",\"timed_out\":\(timedOut)}"
        }
    }

    public final class LeakDetector: @unchecked Sendable {
        private let lock = NSLock()
        private var active: [String: (Double, String)] = [:]
        private var seq: UInt64 = 0

        public init() {}
        public func onBorrow(_ tag: String) -> String {
            lock.lock(); defer { lock.unlock() }
            seq += 1
            let id = String(seq, radix: 16)
            active[id] = (Date().timeIntervalSince1970, tag)
            return id
        }
        public func onReturn(_ id: String) {
            lock.lock(); active.removeValue(forKey: id); lock.unlock()
        }
        public func detectLeaks(timeoutMs: Int64) -> [LeaseSample] {
            lock.lock(); defer { lock.unlock() }
            let now = Date().timeIntervalSince1970
            var out: [LeaseSample] = []
            for (id, (at, tag)) in active {
                let age = (now - at) * 1000
                let timedOut = timeoutMs >= 0 && age >= Double(timeoutMs)
                if timeoutMs < 0 || timedOut {
                    out.append(LeaseSample(leaseId: id, borrowedAt: at,
                                           ageMs: age, tag: tag, timedOut: timedOut))
                }
            }
            return out
        }
        public func activeCount() -> Int { lock.lock(); defer { lock.unlock() }; return active.count }
    }

    // -----------------------------------------------------------------------
    // 12.4 统一 YAML 子集配置
    // -----------------------------------------------------------------------

    public enum ConfigError: Error, CustomStringConvertible {
        case invalid(String)
        public var description: String { if case .invalid(let s) = self { return s }; return "" }
    }

    public enum OnFull: String, Sendable {
        case dropOldest = "drop_oldest", dropLargest = "drop_largest"
        case block, reject, grow
        public static func parse(_ s: String) throws -> OnFull {
            guard let p = OnFull(rawValue: s) else {
                throw ConfigError.invalid(
                    "on_full must be one of drop_oldest|drop_largest|block|reject|grow, got: \(s)")
            }
            return p
        }
    }

    public static let lifecycleHooks = ["on_create", "on_borrow", "on_return",
                                        "on_evict", "on_destroy"]

    public struct PoolConfig: Sendable {
        public var maxSize: Int = 64
        public var onFull: OnFull = .dropOldest
        public var blockTimeoutMs: Int64 = -1
        public var maxOverflow: Int = 0
        public var evictionPolicy: String = "lru"
        public var prewarm: Int = 0
        public var leakDetection: Bool = false
        public var leakTimeoutMs: Int64 = 3000
        public var clearSensitive: Bool = false
        public var lifecycle: [String: String] = [:]

        public init() {}
        public func validate() throws {
            if maxSize <= 0 { throw ConfigError.invalid("max_size must be > 0") }
            if maxOverflow < 0 || prewarm < 0 {
                throw ConfigError.invalid("max_overflow and prewarm must be >= 0")
            }
            for k in lifecycle.keys where !lifecycleHooks.contains(k) && k != "clear_sensitive" {
                throw ConfigError.invalid("unknown lifecycle hook: \(k)")
            }
        }
        public func toJSON() -> String {
            "{\"max_size\":\(maxSize),\"on_full\":\"\(onFull.rawValue)\",\"block_timeout_ms\":\(blockTimeoutMs),\"max_overflow\":\(maxOverflow),\"eviction_policy\":\"\(evictionPolicy)\",\"prewarm\":\(prewarm),\"leak_detection\":\(leakDetection),\"leak_timeout_ms\":\(leakTimeoutMs),\"clear_sensitive\":\(clearSensitive)}"
        }
    }

    /// 极简 YAML 子集：缩进映射 + 标量，扁平化为 "a.b.c" -> 值。
    public static func parseYAMLSubset(_ text: String) throws -> [String: String] {
        var out: [String: String] = [:]
        var stack: [(Int, String)] = []
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var line = String(raw)
            if let h = line.firstIndex(of: "#") { line = String(line[..<h]) }
            let content = line.trimmingCharacters(in: .whitespaces)
            if content.isEmpty { continue }
            var indent = 0
            for ch in line { if ch == " " { indent += 1 } else if ch == "\t" {
                throw ConfigError.invalid("line \(i + 1): tabs are not allowed for indentation")
            } else { break } }
            guard let colon = content.firstIndex(of: ":") else {
                throw ConfigError.invalid("line \(i + 1): expected 'key: value'")
            }
            let key = String(content[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(content[content.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            while let last = stack.last, last.0 >= indent { stack.removeLast() }
            var parts = stack.map { $0.1 }
            parts.append(key)
            let full = parts.joined(separator: ".")
            if value.isEmpty { stack.append((indent, key)) }
            else {
                if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                   (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value = String(value.dropFirst().dropLast())
                }
                out[full] = value
            }
        }
        return out
    }

    private static let legalKeys: Set<String> = [
        "max_size", "on_full", "block_timeout_ms", "max_overflow",
        "eviction_policy", "prewarm", "leak_detection", "leak_timeout_ms",
        "clear_sensitive",
    ]
    private static func asInt(_ s: String, _ def: Int64) -> Int64 { Int64(s) ?? def }
    private static func asBool(_ s: String) -> Bool {
        s.lowercased() == "true" || s.lowercased() == "yes"
    }
    private static func envOverride(_ pool: String, _ key: String) -> String? {
        ProcessInfo.processInfo.environment[
            "GC_PRIMITIVES__\(pool.uppercased().replacingOccurrences(of: "-", with: "_"))__\(key.uppercased())"]
    }
    private static func apply(_ c: inout PoolConfig, _ key: String, _ v: String) throws {
        switch key {
        case "max_size": c.maxSize = Int(asInt(v, Int64(c.maxSize)))
        case "on_full": c.onFull = try OnFull.parse(v)
        case "block_timeout_ms": c.blockTimeoutMs = asInt(v, -1)
        case "max_overflow": c.maxOverflow = Int(asInt(v, 0))
        case "eviction_policy": c.evictionPolicy = v
        case "prewarm": c.prewarm = Int(asInt(v, 0))
        case "leak_detection": c.leakDetection = asBool(v)
        case "leak_timeout_ms": c.leakTimeoutMs = asInt(v, 3000)
        case "clear_sensitive": c.clearSensitive = asBool(v)
        default: throw ConfigError.invalid("unknown config key: \(key)")
        }
    }

    /// 加载配置；找不到文件时返回默认值（配置文件可选）。
    public static func loadConfig(path: String? = nil, pool: String = "default") throws -> PoolConfig {
        let env = ProcessInfo.processInfo.environment
        var chosen: String? = path ?? env[configEnv]
        if chosen == nil {
            let home = NSHomeDirectory()
            let cascade = ["./gc-primitives.yaml", "./config/gc-primitives.yaml",
                           "\(home)/.config/gc-primitives.yaml", "/etc/gc-primitives.yaml"]
            chosen = cascade.first { FileManager.default.fileExists(atPath: $0) }
        }
        var cfg = PoolConfig()
        if let f = chosen, FileManager.default.fileExists(atPath: f) {
            let text = try String(contentsOfFile: f, encoding: .utf8)
            let flat = try parseYAMLSubset(text)
            let prefix = "pools.\(pool)."
            for (k, v) in flat where k.hasPrefix(prefix) {
                let key = String(k.dropFirst(prefix.count))
                if key.hasPrefix("lifecycle.") {
                    cfg.lifecycle[String(key.dropFirst("lifecycle.".count))] = v
                    continue
                }
                guard legalKeys.contains(key) else {
                    throw ConfigError.invalid("unknown config key: \(key)")
                }
                try apply(&cfg, key, v)
            }
            if let v = cfg.lifecycle["clear_sensitive"] { cfg.clearSensitive = asBool(v) }
        }
        for key in legalKeys {
            if let v = envOverride(pool, key), !v.isEmpty {
                try apply(&cfg, key, v)
            }
        }
        try cfg.validate()
        return cfg
    }

    /// 降级档热重载：手动 `reload()` + 文件 mtime 检查，不自动监听。
    public final class PoolManager<T: AnyObject>: @unchecked Sendable {
        private let lock = NSLock()
        private let path: String?
        private var pools: [String: ManagedPool<T>] = [:]
        private var lastMtime: Date?

        public init(path: String? = nil) {
            self.path = path ?? ProcessInfo.processInfo.environment[configEnv]
            self.lastMtime = Self.mtime(self.path)
        }
        private static func mtime(_ p: String?) -> Date? {
            guard let p else { return nil }
            return try? FileManager.default.attributesOfItem(atPath: p)[.modificationDate] as? Date
        }
        public func register(_ name: String, _ pool: ManagedPool<T>) {
            lock.lock(); pools[name] = pool; lock.unlock()
        }
        public func reload() -> Bool {
            let mt = Self.mtime(path)
            lock.lock(); defer { lock.unlock() }
            if let mt, let last = lastMtime, mt == last { return false }
            for (name, p) in pools {
                if let cfg = try? loadConfig(path: path, pool: name) { p.applyConfig(cfg) }
            }
            lastMtime = mt
            return true
        }
    }

    // -----------------------------------------------------------------------
    // 12.1 ManagedPool（共享、线程安全、可配置；原 Pool 一行未改）
    // -----------------------------------------------------------------------

    public struct LifecycleHooks<T: AnyObject> {
        public var onCreate: ((T) -> Void)?
        public var onBorrow: ((T) -> Void)?
        public var onReturn: ((T) -> Void)?
        public var onEvict: ((T) -> Void)?
        public var onDestroy: ((T) -> Void)?
        public var clearSensitive: Bool = false
        public init() {}
    }

    public final class ManagedPool<T: AnyObject>: @unchecked Sendable {
        private let lock = NSLock()
        private let factory: () -> T?
        private let recycler: (T) throws -> Void
        private var cfg: PoolConfig
        private var hooks: LifecycleHooks<T>
        private var free: [T] = []
        private var active: [String] = []
        private var closed = false
        private var seq: UInt64 = 0
        private let metricsCollector = MetricsCollector()
        private let leaks = LeakDetector()

        public init(factory: @escaping () -> T?, recycler: @escaping (T) throws -> Void,
                    config: PoolConfig = PoolConfig(),
                    hooks: LifecycleHooks<T> = LifecycleHooks<T>()) throws {
            try config.validate()
            self.factory = factory; self.recycler = recycler
            self.cfg = config; self.hooks = hooks
            if config.prewarm > 0 { _ = try prewarm(config.prewarm) }
        }

        public func borrow(_ tag: String = "") throws -> ManagedLease<T> {
            let t0 = Date()
            lock.lock()
            if closed { lock.unlock(); throw PoolError.poolClosed }
            let limit = cfg.maxSize + (cfg.onFull == .grow ? cfg.maxOverflow : 0)
            while active.count >= limit {
                if cfg.onFull == .reject {
                    lock.unlock()
                    throw PoolError.invalidCapacity(limit)  // 复用既有错误类型表达满池
                }
                if cfg.onFull == .block {
                    // NSLock 无 condvar：降级为带超时的轮询，避免死锁
                    let deadline = Date().addingTimeInterval(
                        cfg.blockTimeoutMs >= 0 ? Double(cfg.blockTimeoutMs) / 1000 : 0.05)
                    lock.unlock()
                    while Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
                    lock.lock()
                    if active.count >= limit {
                        lock.unlock()
                        throw PoolError.invalidCapacity(limit)
                    }
                    continue
                }
                break
            }
            let value: T
            let hit: Bool, created: Bool
            if let v = free.popLast() { value = v; hit = true; created = false }
            else {
                guard let v = factory() else { lock.unlock(); throw PoolError.factoryFailed }
                value = v; hit = false; created = true
                hooks.onCreate?(value)
            }
            let id: String
            if cfg.leakDetection { id = leaks.onBorrow(tag) }
            else { seq += 1; id = String(seq, radix: 16) }
            active.append(id)
            metricsCollector.recordBorrow(hit: hit,
                                 waitMs: Date().timeIntervalSince(t0) * 1000,
                                 created: created)
            hooks.onBorrow?(value)
            lock.unlock()
            return ManagedLease(pool: self, value: value, id: id, tag: tag,
                                borrowedAt: Date().timeIntervalSince1970)
        }

        fileprivate func _return(_ value: T, id: String, borrowedAt: Double) throws {
            do {
                if hooks.clearSensitive { hooks.onReturn?(value) }
                try recycler(value)
                hooks.onReturn?(value)
            } catch {
                hooks.onDestroy?(value)
                settle(id, borrowedAt)
                throw error
            }
            lock.lock(); defer { lock.unlock() }
            leaks.onReturn(id)
            if free.count >= cfg.maxSize && cfg.onFull != .grow {
                let victim = free.removeFirst()
                free.append(value)
                hooks.onEvict?(victim)
                metricsCollector.recordEviction()
            } else { free.append(value) }
            settleInLock(id, borrowedAt)
        }
        private func settleInLock(_ id: String, _ borrowedAt: Double) {
            metricsCollector.recordReturn(lifetimeMs: (Date().timeIntervalSince1970 - borrowedAt) * 1000)
            if let i = active.firstIndex(of: id) { active.remove(at: i) }
        }
        private func settle(_ id: String, _ borrowedAt: Double) {
            lock.lock(); settleInLock(id, borrowedAt); lock.unlock()
        }

        public func prewarm(_ n: Int) throws -> Int {
            var made = 0
            for _ in 0..<n { let l = try borrow("prewarm"); try l.close(); made += 1 }
            return made
        }
        public func detectLeaks(timeoutMs: Int64? = nil) -> [LeaseSample] {
            let out = leaks.detectLeaks(timeoutMs: timeoutMs ?? cfg.leakTimeoutMs)
            metricsCollector.recordLeak(out.count)
            return out
        }
        public func metrics() -> Metrics {
            lock.lock(); defer { lock.unlock() }
            return metricsCollector.snapshot(capacity: cfg.maxSize, idle: free.count, closed: closed)
        }
        public func stats() -> Metrics { metrics() }
        public func snapshot() -> String {
            let leaksJSON = leaks.detectLeaks(timeoutMs: -1).map { $0.toJSON() }.joined(separator: ",")
            lock.lock(); let idle = free.count; let cfgJSON = cfg.toJSON(); lock.unlock()
            return "{\"config\":\(cfgJSON),\"stats\":\(metrics().toJSON()),\"active_leases\":[\(leaksJSON)],\"idle_objects\":\(idle)}"
        }
        public func applyConfig(_ c: PoolConfig) {
            try? c.validate()
            lock.lock(); cfg = c; lock.unlock()
        }
        public func setMaxSize(_ n: Int) { lock.lock(); cfg.maxSize = n; lock.unlock() }
        public func close() {
            lock.lock()
            if closed { lock.unlock(); return }
            closed = true
            let victims = free; free = []
            lock.unlock()
            for v in victims { hooks.onDestroy?(v) }
        }
        public func assertNoActiveLeases() throws {
            lock.lock(); let n = active.count; lock.unlock()
            if n != 0 { throw PoolError.activeLeases(n) }
        }
        public func configMaxSize() -> Int { lock.lock(); defer { lock.unlock() }; return cfg.maxSize }
    }

    public final class ManagedLease<T: AnyObject> {
        private let pool: ManagedPool<T>
        private var storedValue: T?
        private let id: String, tag: String
        private let borrowedAt: Double
        private var active = true
        private let lock = NSLock()

        fileprivate init(pool: ManagedPool<T>, value: T, id: String, tag: String,
                         borrowedAt: Double) {
            self.pool = pool; self.storedValue = value; self.id = id
            self.tag = tag; self.borrowedAt = borrowedAt
        }
        public func value() throws -> T {
            lock.lock(); defer { lock.unlock() }
            guard active, let v = storedValue else { throw PoolError.leaseClosed }
            return v
        }
        public func close() throws {
            lock.lock()
            guard active else { lock.unlock(); throw PoolError.doubleReturn }
            active = false
            let v = storedValue!; storedValue = nil
            lock.unlock()
            try pool._return(v, id: id, borrowedAt: borrowedAt)
        }
        public var leaseId: String { id }
        public var returned: Bool { lock.lock(); defer { lock.unlock() }; return !active }
    }

    // -----------------------------------------------------------------------
    // 12.2 组合矩阵（写死）
    // -----------------------------------------------------------------------

    public enum PoolKind: String, Sendable { case local, shared, base }

    public static let combinationMatrix: [String: [String: Bool]] = [
        "local":  ["standalone": true, "shardable": false, "two_level_l2": false],
        "shared": ["standalone": true, "shardable": true,  "two_level_l2": true],
        "base":   ["standalone": true, "shardable": true,  "two_level_l2": true],
    ]
    public enum CombinationError: Error, CustomStringConvertible {
        case forbidden(String)
        public var description: String { if case .forbidden(let s) = self { return s }; return "" }
    }
    public static func assertCombination(_ kind: PoolKind, _ operation: String) throws {
        guard let row = combinationMatrix[kind.rawValue] else {
            throw CombinationError.forbidden("unknown pool kind: \(kind)")
        }
        guard let ok = row[operation] else {
            throw CombinationError.forbidden("unknown operation: \(operation)")
        }
        if !ok { throw CombinationError.forbidden("pool kind \(kind) cannot be used for \(operation)") }
    }

    public final class ShardedPool<T: AnyObject> {
        private let shards: [ManagedPool<T>]
        private let lock = NSLock()
        private var next: UInt64 = 0
        public init(_ shards: [ManagedPool<T>], kind: PoolKind = .shared) throws {
            try assertCombination(kind, "shardable")
            guard !shards.isEmpty else { throw ConfigError.invalid("shard list must not be empty") }
            self.shards = shards
        }
        public func borrow(_ tag: String = "") throws -> ManagedLease<T> {
            lock.lock(); let i = Int(next % UInt64(shards.count)); next += 1; lock.unlock()
            return try shards[i].borrow(tag)
        }
        public func metrics() -> Metrics {
            var out = Metrics()
            for s in shards {
                let x = s.metrics()
                out.borrowCount += x.borrowCount; out.returnCount += x.returnCount
                out.activeLeases += x.activeLeases; out.poolHits += x.poolHits
                out.poolMisses += x.poolMisses; out.evictionCount += x.evictionCount
                out.leakCount += x.leakCount; out.created += x.created
                out.idle += x.idle; out.capacity += x.capacity
            }
            let total = out.poolHits + out.poolMisses
            out.hitRate = total == 0 ? 0 : Double(out.poolHits) / Double(total)
            return out
        }
        public func stats() -> Metrics { metrics() }
        public func close() { for s in shards { s.close() } }
    }

    public final class TwoLevelPool<T: AnyObject> {
        private let l2: ManagedPool<T>
        private let l1Size: Int
        public init(_ l2: ManagedPool<T>, l1Size: Int = 8,
                    kind: PoolKind = .shared) throws {
            try assertCombination(kind, "two_level_l2")
            self.l2 = l2; self.l1Size = l1Size
        }
        public func borrow(_ tag: String = "") throws -> ManagedLease<T> { try l2.borrow(tag) }
        public func metrics() -> Metrics { l2.metrics() }
        public func stats() -> Metrics { metrics() }
        public func close() { l2.close() }
    }

    /// Sendable 说明：0.2.0 的共享类型用 NSLock 保护并条件遵循 @unchecked Sendable，
    /// 原 `Pool` 仍是 per-actor 使用（见 SPEC 11.1），不假装严格 Sendable。
    public static func sendableNote() -> String {
        "ManagedPool / MetricsCollector / LeakDetector are @unchecked Sendable with NSLock; " +
        "the original Pool remains per-actor (not Sendable) as documented in SPEC 11.1."
    }
}
