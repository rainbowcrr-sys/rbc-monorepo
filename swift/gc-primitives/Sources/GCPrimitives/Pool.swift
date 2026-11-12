import Foundation

// MARK: - Errors

/// Every contract violation is a thrown PoolError. Nothing calls fatalError,
/// nothing silently ignores misuse, and there is no "strict mode" switch.
/// This is the Swift port of contract C5 in SPEC.md.
public enum PoolError: Error, Equatable, CustomStringConvertible {
    case invalidCapacity(Int)
    case factoryFailed
    case leaseClosed
    case doubleReturn
    case poolClosed
    case activeLeases(Int)

    public var description: String {
        switch self {
        case .invalidCapacity(let n): return "capacity must be > 0, got \(n)"
        case .factoryFailed: return "factory returned nil"
        case .leaseClosed: return "lease is closed; value/close() after close()"
        case .doubleReturn: return "lease was closed twice"
        case .poolClosed: return "pool is closed; borrow() is no longer allowed"
        case .activeLeases(let n): return "\(n) borrow(s) not returned; every borrow() needs close()"
        }
    }
}

// MARK: - Diagnostics

/// A snapshot of the pool counters. Maps to SPEC section 4.
public struct PoolStats: Equatable, Sendable {
    public let capacity: Int
    public let idle: Int
    public let active: Int
    public let borrowCount: Int
    public let returnCount: Int
    public let created: Int
    public let closed: Bool
}

// MARK: - Pool

/// A bounded object pool for Swift, restricted to reference types (`T: AnyObject`).
///
/// Swift uses ARC (automatic reference counting), not a tracing GC. Pooling
/// here reduces heap allocations/deallocations and the associated retain /
/// release traffic; it does NOT claim to "save GC". Value types are excluded
/// because a Swift getter returns a copy, which would silently discard any
/// mutation made by the caller — see SPEC section 11.2.
///
/// Concurrency variant: Swift has no stable cross-platform thread-local API,
/// so a single `NSLock`-protected bounded stack is used instead of per-thread
/// state. Cross-thread lease use is covered by the documented contract rather
/// than a runtime check.
public final class Pool<T: AnyObject> {
    /// Returning nil is treated as "the factory could not create an object".
    public typealias Factory = () -> T?
    /// A throwing reset hook: the object is discarded and the error propagated.
    public typealias Recycler = (T) throws -> Void

    private let lock = NSLock()
    private var idle: [T] = []
    private let _capacity: Int
    private let factory: Factory
    private let recycler: Recycler

    private var _closed = false
    private var _created = 0
    private var _borrowCount = 0
    private var _returnCount = 0
    private var _active = 0

    public init(
        capacity: Int = 16,
        factory: @escaping Factory,
        recycler: @escaping Recycler = { _ in }
    ) throws {
        guard capacity > 0 else { throw PoolError.invalidCapacity(capacity) }
        self._capacity = capacity
        self.factory = factory
        self.recycler = recycler
    }

    /// C1: take an object and receive a lease that MUST be closed, usually with
    /// `defer { try? lease.close() }`.
    public func borrow() throws -> Lease<T> {
        var reused: T?
        var isClosed = false
        lock.lock()
        isClosed = _closed
        if !isClosed && !idle.isEmpty {
            reused = idle.removeLast()
        }
        lock.unlock()

        if isClosed { throw PoolError.poolClosed }

        let value: T
        var createdNew = false
        if let reused = reused {
            value = reused
        } else {
            guard let produced = factory() else { throw PoolError.factoryFailed }
            value = produced
            createdNew = true
        }

        lock.lock()
        _borrowCount += 1
        _active += 1
        if createdNew { _created += 1 }
        lock.unlock()

        return Lease<T>(pool: self, value: value)
    }

    /// C2: reject further borrows and drop idle objects.
    public func close() {
        lock.lock()
        _closed = true
        idle.removeAll()
        lock.unlock()
    }

    public var capacity: Int { _capacity }

    public func stats() -> PoolStats {
        lock.lock()
        defer { lock.unlock() }
        return PoolStats(
            capacity: _capacity,
            idle: idle.count,
            active: _active,
            borrowCount: _borrowCount,
            returnCount: _returnCount,
            created: _created,
            closed: _closed
        )
    }

    /// Test-time leak detector.
    public func assertNoActiveLeases() throws {
        lock.lock()
        let n = _active
        lock.unlock()
        if n != 0 { throw PoolError.activeLeases(n) }
    }

    /// Internal return path. Counters settle BEFORE the reset hook so a failing
    /// recycler still leaves exact diagnostics (C4).
    internal func _return(_ value: T) throws {
        lock.lock()
        _returnCount += 1
        _active -= 1
        lock.unlock()

        // A throwing recycler means the object is dirty: drop it, propagate the
        // error, and never cache it.
        try recycler(value)

        lock.lock()
        if !_closed && idle.count < _capacity {
            idle.append(value)
        }
        lock.unlock()
    }

    /// Deinit fallback for a forgotten close(): settle counters, drop the
    /// object. It is NEVER cached because its reset cannot be verified.
    internal func _settleAbandoned() {
        lock.lock()
        _returnCount += 1
        _active -= 1
        lock.unlock()
    }
}

// MARK: - Lease

/// A borrow handle. Close it exactly once, typically with `defer`.
///
/// Swift classes have `deinit` but it cannot throw, so a forgotten close is
/// handled as a best-effort fallback: counters settle and the object is
/// dropped (never reused). Explicit `close()` is the recommended path.
public final class Lease<T: AnyObject> {
    private let pool: Pool<T>
    private var valueStorage: T?
    private var _returned = false

    internal init(pool: Pool<T>, value: T) {
        self.pool = pool
        self.valueStorage = value
    }

    deinit {
        if !_returned {
            pool._settleAbandoned()
        }
    }

    /// C5: reading the value after close throws; never returns stale data.
    public var value: T {
        get throws {
            if _returned { throw PoolError.leaseClosed }
            guard let v = valueStorage else { throw PoolError.leaseClosed }
            return v
        }
    }

    public var returned: Bool { _returned }

    /// C1 + C5: double close throws; a failing reset propagates and drops the object.
    public func close() throws {
        if _returned { throw PoolError.doubleReturn }
        _returned = true
        guard let v = valueStorage else { throw PoolError.leaseClosed }
        valueStorage = nil
        try pool._return(v)
    }
}
