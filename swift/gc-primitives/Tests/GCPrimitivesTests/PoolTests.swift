import XCTest
import Foundation
@testable import GCPrimitives

private final class Box {
    var data: [String] = []
}

private enum ResetBoom: Error, Equatable {
    case failed
}

private final class Counter {
    var created = 0
    var resets = 0
}

final class PoolTests: XCTestCase {

    private func makePool(
        capacity: Int = 4,
        factory: (() -> Box?)? = nil,
        recycler: ((Box) throws -> Void)? = nil
    ) throws -> (Pool<Box>, Counter) {
        let counter = Counter()
        let f: () -> Box? = factory ?? {
            counter.created += 1
            return Box()
        }
        let r: (Box) throws -> Void = recycler ?? { box in
            counter.resets += 1
            box.data.removeAll()
        }
        return (try Pool<Box>(capacity: capacity, factory: f, recycler: r), counter)
    }

    // MARK: C1 / diagnostics

    func testBorrowUseCloseAndCounters() throws {
        let (pool, counter) = try makePool()
        let lease = try pool.borrow()
        let box = try lease.value
        XCTAssertTrue(box.data.isEmpty)
        box.data.append("x")
        try lease.close()

        let s = pool.stats()
        XCTAssertEqual(s.active, 0)
        XCTAssertEqual(s.borrowCount, 1)
        XCTAssertEqual(s.returnCount, 1)
        XCTAssertEqual(s.idle, 1)
        XCTAssertEqual(s.created, 1)
        XCTAssertEqual(s.capacity, 4)
        XCTAssertFalse(s.closed)
        XCTAssertEqual(counter.created, 1)
        XCTAssertEqual(counter.resets, 1)
        XCTAssertNoThrow(try pool.assertNoActiveLeases())
    }

    // MARK: C3 reuse is bounded and reset works

    func testReuseCallsFactoryOnlyOnce() throws {
        let (pool, counter) = try makePool()
        for i in 0..<10 {
            let lease = try pool.borrow()
            let box = try lease.value
            XCTAssertTrue(box.data.isEmpty, "round \(i): recycler did not reset")
            box.data.append("x")
            try lease.close()
        }
        XCTAssertEqual(counter.created, 1)
        XCTAssertEqual(pool.stats().borrowCount, 10)
        XCTAssertEqual(pool.stats().returnCount, 10)
    }

    func testIdleIsBoundedByCapacity() throws {
        let (pool, _) = try makePool(capacity: 2)
        // 先同时持有 32 个租约；顺序借还时池里永远只有 1 个空闲对象，
        // 根本测不到 capacity 上限。
        var leases: [Lease<Box>] = []
        for _ in 0..<32 {
            leases.append(try pool.borrow())
        }
        for lease in leases {
            try lease.close()
        }
        XCTAssertEqual(pool.stats().idle, 2)
        XCTAssertEqual(pool.stats().active, 0)
    }

    // MARK: C4 reset failure

    func testResetFailureDiscardsObjectAndPropagates() throws {
        let (pool, counter) = try makePool(recycler: { _ in throw ResetBoom.failed })
        for _ in 0..<6 {
            let lease = try pool.borrow()
            XCTAssertThrowsError(try lease.close()) { error in
                XCTAssertEqual(error as? ResetBoom, .failed)
            }
            XCTAssertEqual(pool.stats().idle, 0, "dirty object must never be cached")
        }
        XCTAssertEqual(counter.created, 6, "discarded objects must not be reused")
        XCTAssertEqual(pool.stats().returnCount, 6)
        XCTAssertEqual(pool.stats().active, 0)
        XCTAssertNoThrow(try pool.assertNoActiveLeases())
    }

    // MARK: C5 strict misuse detection

    func testDoubleCloseThrows() throws {
        let (pool, _) = try makePool()
        let lease = try pool.borrow()
        try lease.close()
        XCTAssertThrowsError(try lease.close()) { error in
            XCTAssertEqual(error as? PoolError, .doubleReturn)
        }
        XCTAssertEqual(pool.stats().returnCount, 1)
        XCTAssertNoThrow(try pool.assertNoActiveLeases())
    }

    func testValueAfterCloseThrows() throws {
        let (pool, _) = try makePool()
        let lease = try pool.borrow()
        try lease.close()
        XCTAssertTrue(lease.returned)
        XCTAssertThrowsError(try lease.value) { error in
            XCTAssertEqual(error as? PoolError, .leaseClosed)
        }
    }

    func testFactoryReturningNilThrows() throws {
        let (pool, _) = try makePool(factory: { nil })
        XCTAssertThrowsError(try pool.borrow()) { error in
            XCTAssertEqual(error as? PoolError, .factoryFailed)
        }
        XCTAssertEqual(pool.stats().borrowCount, 0)
        XCTAssertEqual(pool.stats().active, 0)
        XCTAssertNoThrow(try pool.assertNoActiveLeases())
    }

    func testInvalidCapacityThrows() {
        XCTAssertThrowsError(try Pool<Box>(capacity: 0, factory: { Box() })) { error in
            XCTAssertEqual(error as? PoolError, .invalidCapacity(0))
        }
        XCTAssertThrowsError(try Pool<Box>(capacity: -3, factory: { Box() })) { error in
            XCTAssertEqual(error as? PoolError, .invalidCapacity(-3))
        }
    }

    func testClosedPoolRejectsBorrow() throws {
        let (pool, _) = try makePool()
        let lease = try pool.borrow()
        try lease.close()
        XCTAssertEqual(pool.stats().idle, 1)

        pool.close()
        XCTAssertEqual(pool.stats().idle, 0)
        XCTAssertThrowsError(try pool.borrow()) { error in
            XCTAssertEqual(error as? PoolError, .poolClosed)
        }

        // A lease borrowed before close() can still be closed, but the object
        // is not cached afterwards.
        let (p2, _) = try makePool()
        let l2 = try p2.borrow()
        p2.close()
        XCTAssertNoThrow(try l2.close())
        XCTAssertEqual(p2.stats().idle, 0)
        XCTAssertNoThrow(try p2.assertNoActiveLeases())
    }

    func testAssertNoActiveLeasesDetectsLeak() throws {
        let (pool, _) = try makePool()
        var kept: Lease<Box>? = try pool.borrow()
        try withExtendedLifetime(kept) {
            XCTAssertThrowsError(try pool.assertNoActiveLeases()) { error in
                guard let e = error as? PoolError,
                      case .activeLeases(let n) = e else {
                    return XCTFail("unexpected error: \(error)")
                }
                XCTAssertEqual(n, 1)
            }
            XCTAssertEqual(pool.stats().active, 1)
        }
        try kept?.close()
        kept = nil
        XCTAssertNoThrow(try pool.assertNoActiveLeases())
    }

    // MARK: deinit fallback

    func testForgottenCloseFallbackDropsObjectAndSettlesCounters() throws {
        let (pool, _) = try makePool()
        do {
            let abandoned = try pool.borrow()
            let box = try abandoned.value
            box.data.append("dirty")
            XCTAssertEqual(pool.stats().active, 1)
            // deliberately no close()
        }
        XCTAssertEqual(pool.stats().active, 0, "deinit fallback must settle counters")
        XCTAssertEqual(pool.stats().returnCount, 1)
        XCTAssertEqual(pool.stats().idle, 0, "abandoned object must be dropped, not cached")
        XCTAssertNoThrow(try pool.assertNoActiveLeases())
    }

    // MARK: concurrency

    func testConcurrentBorrowCloseKeepsCountersExact() throws {
        let (pool, _) = try makePool(capacity: 8)
        let iterations = 100
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            guard let lease = try? pool.borrow() else { return }
            if let box = try? lease.value {
                box.data.append("\(i)")
            }
            try? lease.close()
        }
        let s = pool.stats()
        XCTAssertEqual(s.borrowCount, iterations)
        XCTAssertEqual(s.returnCount, iterations)
        XCTAssertEqual(s.active, 0)
        XCTAssertNoThrow(try pool.assertNoActiveLeases())
    }
}
