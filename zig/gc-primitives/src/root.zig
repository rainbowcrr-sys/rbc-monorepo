const std = @import("std");

/// 0.2.0 增量能力层（SPEC 第 12 章）。纯新增，不改动下方 Pool 的任何行为。
/// 显式 @import 让 v020.zig 的测试块进入 zig build test 的引用图。
pub const v020 = @import("v020.zig");

/// Contract violations. Nothing calls @panic, nothing silently ignores misuse,
/// and there is no "strict mode" switch. This is the Zig port of C5 in SPEC.md.
pub const PoolError = error{
    InvalidCapacity,
    FactoryFailed,
    LeaseClosed,
    DoubleClose,
    PoolClosed,
    ActiveLeases,
    OutOfMemory,
};

/// A snapshot of the pool counters. Maps to SPEC section 4.
pub const Stats = struct {
    capacity: usize,
    idle: usize,
    active: usize,
    borrow_count: usize,
    return_count: usize,
    created: usize,
    closed: bool,
};

/// A bounded object pool with comptime generics and an explicit allocator.
///
/// Zig has NO GC and NO implicit allocation: all memory comes from the caller's
/// Allocator, and every object the pool drops is released through `destroy`.
/// That makes this the port where "reduce allocations" is most literal — see
/// SPEC section 11.3.
///
/// `T` is the pooled object type (typically a pointer such as `*Buffer`).
/// A factory returning `null` is "factory returned an empty value" (C5).
pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Factory = *const fn (std.mem.Allocator) anyerror!?T;
        pub const Recycler = *const fn (T) anyerror!void;
        /// Zig-specific: called whenever an object is discarded, so the caller's
        /// allocator never leaks. Other languages lean on a GC/ARC/drop instead.
        pub const Destroy = *const fn (std.mem.Allocator, T) void;

        pub const Options = struct {
            capacity: usize = 16,
            factory: Factory,
            recycler: Recycler,
            destroy: Destroy,
        };

        allocator: std.mem.Allocator,
        capacity: usize,
        factory: Factory,
        recycler: Recycler,
        destroy_fn: Destroy,
        idle: std.ArrayListUnmanaged(T) = .{},
        closed: bool = false,
        created: usize = 0,
        borrow_count: usize = 0,
        return_count: usize = 0,
        active: usize = 0,

        pub fn init(allocator: std.mem.Allocator, options: Options) PoolError!Self {
            if (options.capacity == 0) return error.InvalidCapacity;
            return .{
                .allocator = allocator,
                .capacity = options.capacity,
                .factory = options.factory,
                .recycler = options.recycler,
                .destroy_fn = options.destroy,
            };
        }

        /// Frees every idle object. Any object still borrowed must have been
        /// closed first, otherwise the testing allocator reports a leak.
        pub fn deinit(self: *Self) void {
            for (self.idle.items) |item| self.destroy_fn(self.allocator, item);
            self.idle.deinit(self.allocator);
        }

        /// C1: take an object and receive a Lease that MUST be closed.
        pub fn borrow(self: *Self) anyerror!Lease(T) {
            if (self.closed) return error.PoolClosed;

            var value: T = undefined;
            const n = self.idle.items.len;
            if (n > 0) {
                value = self.idle.items[n - 1];
                self.idle.items.len = n - 1;
            } else {
                const produced = (try self.factory(self.allocator)) orelse
                    return error.FactoryFailed;
                self.created += 1;
                value = produced;
            }

            self.borrow_count += 1;
            self.active += 1;
            return .{ .pool = self, .value_ = value };
        }

        /// C2: reject further borrows and destroy all idle objects.
        pub fn close(self: *Self) void {
            self.closed = true;
            for (self.idle.items) |item| self.destroy_fn(self.allocator, item);
            self.idle.items.len = 0;
        }

        pub fn stats(self: *const Self) Stats {
            return .{
                .capacity = self.capacity,
                .idle = self.idle.items.len,
                .active = self.active,
                .borrow_count = self.borrow_count,
                .return_count = self.return_count,
                .created = self.created,
                .closed = self.closed,
            };
        }

        /// Test-time leak detector.
        pub fn assertNoActiveLeases(self: *const Self) PoolError!void {
            if (self.active != 0) return error.ActiveLeases;
        }

        /// Internal return path. Counters settle BEFORE the recycler so a
        /// failing reset still leaves exact diagnostics (C4).
        pub fn _return(self: *Self, value: T) anyerror!void {
            self.return_count += 1;
            self.active -= 1;

            // A failing recycler means the object is dirty: destroy it and
            // propagate the error. It is NEVER cached.
            self.recycler(value) catch |err| {
                self.destroy_fn(self.allocator, value);
                return err;
            };

            if (!self.closed and self.idle.items.len < self.capacity) {
                try self.idle.append(self.allocator, value);
            } else {
                // Beyond capacity (or pool closed): free it explicitly.
                self.destroy_fn(self.allocator, value);
            }
        }
    };
}

/// A borrow handle. Zig has no destructor, so `defer { lease.close() catch {}; }`
/// (or an explicit `try lease.close()`) is mandatory. A forgotten close is
/// caught by `assertNoActiveLeases()` and by the allocator's leak detector.
pub fn Lease(comptime T: type) type {
    return struct {
        const Self = @This();

        pool: *Pool(T),
        value_: T,
        returned: bool = false,

        /// C5: reading the value after close throws; never returns stale data.
        pub fn value(self: *Self) PoolError!T {
            if (self.returned) return error.LeaseClosed;
            return self.value_;
        }

        pub fn isReturned(self: *const Self) bool {
            return self.returned;
        }

        /// C1 + C5: double close throws; a failing reset propagates and drops
        /// the object. Callers should inspect the error rather than ignore it.
        pub fn close(self: *Self) anyerror!void {
            if (self.returned) return error.DoubleClose;
            self.returned = true;
            try self.pool._return(self.value_);
        }
    };
}

// MARK: - Contract tests (run by `zig test src/root.zig`)
//
// No mutable global state: `zig test` may run test blocks concurrently, so
// every counter lives either on the Pool instance or on the testing allocator.

const testing = std.testing;

const Buffer = struct {
    data: [32]u8 = undefined,
    len: usize = 0,
};

fn makeBuffer(a: std.mem.Allocator) anyerror!?*Buffer {
    const b = try a.create(Buffer);
    b.* = .{};
    return b;
}

fn resetBuffer(b: *Buffer) anyerror!void {
    b.len = 0;
}

const ResetBoom = error{ResetFailed};

fn alwaysFailReset(_: *Buffer) anyerror!void {
    return ResetBoom.ResetFailed;
}

fn destroyBuffer(a: std.mem.Allocator, b: *Buffer) void {
    a.destroy(b);
}

fn testOptions() Pool(*Buffer).Options {
    return .{
        .factory = makeBuffer,
        .recycler = resetBuffer,
        .destroy = destroyBuffer,
    };
}

test "C1 borrow / use / close, counters exact" {
    var pool = try Pool(*Buffer).init(testing.allocator, testOptions());
    defer pool.deinit();

    var lease = try pool.borrow();
    const b = try lease.value();
    try testing.expectEqual(@as(usize, 0), b.len);
    b.len = 7;
    try lease.close();

    const s = pool.stats();
    try testing.expectEqual(@as(usize, 0), s.active);
    try testing.expectEqual(@as(usize, 1), s.borrow_count);
    try testing.expectEqual(@as(usize, 1), s.return_count);
    try testing.expectEqual(@as(usize, 1), s.idle);
    try testing.expectEqual(@as(usize, 1), s.created);
    try pool.assertNoActiveLeases();

    // The recycler must have restored a clean object for the next borrower.
    var again = try pool.borrow();
    try testing.expectEqual(@as(usize, 0), (try again.value()).len);
    try again.close();
}

test "C3 reuse calls the factory only once and resets on return" {
    var opts = testOptions();
    opts.capacity = 4;
    var pool = try Pool(*Buffer).init(testing.allocator, opts);
    defer pool.deinit();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var lease = try pool.borrow();
        const b = try lease.value();
        try testing.expectEqual(@as(usize, 0), b.len);
        b.len = i + 1;
        try lease.close();
    }
    try testing.expectEqual(@as(usize, 1), pool.stats().created);
    try testing.expectEqual(@as(usize, 10), pool.stats().borrow_count);
    try testing.expectEqual(@as(usize, 10), pool.stats().return_count);
    try pool.assertNoActiveLeases();
}

test "C3 idle objects are bounded by capacity" {
    var opts = testOptions();
    opts.capacity = 2;
    var pool = try Pool(*Buffer).init(testing.allocator, opts);
    defer pool.deinit();

    // Hold all 32 leases first; sequential borrow/close would leave at most
    // one idle object and never exercise the capacity bound.
    var leases: [32]Lease(*Buffer) = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        leases[i] = try pool.borrow();
    }
    i = 0;
    while (i < 32) : (i += 1) {
        try leases[i].close();
    }
    try testing.expectEqual(@as(usize, 2), pool.stats().idle);
    try testing.expectEqual(@as(usize, 0), pool.stats().active);
    // The testing allocator would report a leak if any discarded object had
    // not been released through destroy().
    try pool.assertNoActiveLeases();
}

test "C4 reset failure destroys the object, propagates the error, settles counters" {
    var opts = testOptions();
    opts.recycler = alwaysFailReset;
    var pool = try Pool(*Buffer).init(testing.allocator, opts);
    defer pool.deinit();

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var lease = try pool.borrow();
        try testing.expectError(ResetBoom.ResetFailed, lease.close());
        try testing.expectEqual(@as(usize, 0), pool.stats().idle);
    }
    // Every object was discarded, so the factory had to create a new one each time.
    try testing.expectEqual(@as(usize, 5), pool.stats().created);
    try testing.expectEqual(@as(usize, 5), pool.stats().return_count);
    try testing.expectEqual(@as(usize, 0), pool.stats().active);
    try pool.assertNoActiveLeases();
}

test "C5 double close throws and does not double-settle" {
    var pool = try Pool(*Buffer).init(testing.allocator, testOptions());
    defer pool.deinit();

    var lease = try pool.borrow();
    try lease.close();
    try testing.expectError(error.DoubleClose, lease.close());
    try testing.expectEqual(@as(usize, 1), pool.stats().return_count);
    try pool.assertNoActiveLeases();
}

test "C5 value after close throws" {
    var pool = try Pool(*Buffer).init(testing.allocator, testOptions());
    defer pool.deinit();

    var lease = try pool.borrow();
    try lease.close();
    try testing.expect(lease.isReturned());
    try testing.expectError(error.LeaseClosed, lease.value());
}

test "C5 factory returning null throws FactoryFailed" {
    const NullFactory = struct {
        fn create(_: std.mem.Allocator) anyerror!?*Buffer {
            return null;
        }
    };
    var opts = testOptions();
    opts.factory = NullFactory.create;
    var pool = try Pool(*Buffer).init(testing.allocator, opts);
    defer pool.deinit();

    try testing.expectError(error.FactoryFailed, pool.borrow());
    try testing.expectEqual(@as(usize, 0), pool.stats().borrow_count);
    try testing.expectEqual(@as(usize, 0), pool.stats().active);
    try pool.assertNoActiveLeases();
}

test "C5 capacity 0 throws InvalidCapacity" {
    var opts = testOptions();
    opts.capacity = 0;
    try testing.expectError(
        error.InvalidCapacity,
        Pool(*Buffer).init(testing.allocator, opts),
    );
}

test "C2 closed pool rejects borrow and destroys idle objects" {
    var pool = try Pool(*Buffer).init(testing.allocator, testOptions());
    defer pool.deinit();

    {
        var lease = try pool.borrow();
        try lease.close();
    }
    try testing.expectEqual(@as(usize, 1), pool.stats().idle);

    pool.close();
    try testing.expectEqual(@as(usize, 0), pool.stats().idle);
    try testing.expectError(error.PoolClosed, pool.borrow());

    // A lease borrowed before close() can still be closed, but its object is
    // destroyed instead of being cached.
    var p2 = try Pool(*Buffer).init(testing.allocator, testOptions());
    defer p2.deinit();
    var l2 = try p2.borrow();
    p2.close();
    try l2.close();
    try testing.expectEqual(@as(usize, 0), p2.stats().idle);
    try testing.expectEqual(@as(usize, 0), p2.stats().active);
    try p2.assertNoActiveLeases();
}

test "unreturned lease is detected by assertNoActiveLeases" {
    var pool = try Pool(*Buffer).init(testing.allocator, testOptions());
    defer pool.deinit();

    var lease = try pool.borrow();
    try testing.expectError(error.ActiveLeases, pool.assertNoActiveLeases());
    try testing.expectEqual(@as(usize, 1), pool.stats().active);
    try lease.close();
    try pool.assertNoActiveLeases();
}

test "default capacity is 16" {
    var pool = try Pool(*Buffer).init(testing.allocator, testOptions());
    defer pool.deinit();
    try testing.expectEqual(@as(usize, 16), pool.stats().capacity);
    var lease = try pool.borrow();
    try lease.close();
    try pool.assertNoActiveLeases();
}

// Zig 默认只收集 root 文件的 test 声明；显式 test 引用把 0.2.0 能力层
// （v020.zig）的契约测试一并拉入 zig test / zig build test 的测试集。
test {
    _ = @import("v020.zig");
}
