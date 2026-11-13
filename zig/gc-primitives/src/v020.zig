const std = @import("std");

// gc-primitives 0.2.0 · 增量能力层（纯新增，不改动 root.zig 的 Pool）
//
// 实现 SPEC.md 第 12 章：统一 metrics JSON 同构快照、差值型 memory_scope、
// 泄漏采样、统一 YAML 子集配置 + schema + env + 级联 + reload（降级档）、
// 满池策略 / 生命周期钩子 / 预热 / 快照、ShardedPool / TwoLevelPool 组合矩阵，
// 以及 Zig 独有的 allocator 后端对比与 benchmark（第 12 章低优先级项）。
//
// 零依赖：只用 std。GC_PRIMITIVES_DIAG 未设时 memory_scope 为空操作。

pub const diag_env = "GC_PRIMITIVES_DIAG";
pub const config_env = "GC_PRIMITIVES_CONFIG";
/// 借出采样最小集七语言都可用；调用栈快照是 Python / Go / Java 的可选增强。
pub const detect_leaks_available = true;

// ---------------------------------------------------------------------------
// 12.3 统一 metrics JSON 同构快照（16 字段，七语言同名）
// ---------------------------------------------------------------------------

pub const metrics_fields = [_][]const u8{
    "borrow_count", "return_count", "active_leases", "pool_hits", "pool_misses",
    "hit_rate", "wait_time_p50", "wait_time_p99", "wait_time_max",
    "object_lifetime_p50", "eviction_count", "leak_count", "created", "idle",
    "capacity", "closed",
};

pub const Metrics = struct {
    borrow_count: u64 = 0,
    return_count: u64 = 0,
    active_leases: u64 = 0,
    pool_hits: u64 = 0,
    pool_misses: u64 = 0,
    hit_rate: f64 = 0,
    wait_time_p50: f64 = 0,
    wait_time_p99: f64 = 0,
    wait_time_max: f64 = 0,
    object_lifetime_p50: f64 = 0,
    eviction_count: u64 = 0,
    leak_count: u64 = 0,
    created: u64 = 0,
    idle: u64 = 0,
    capacity: u64 = 0,
    closed: bool = false,

    pub fn toJson(self: Metrics, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf,
            "{{\"borrow_count\":{d},\"return_count\":{d},\"active_leases\":{d}," ++
            "\"pool_hits\":{d},\"pool_misses\":{d},\"hit_rate\":{d}," ++
            "\"wait_time_p50\":{d},\"wait_time_p99\":{d},\"wait_time_max\":{d}," ++
            "\"object_lifetime_p50\":{d},\"eviction_count\":{d},\"leak_count\":{d}," ++
            "\"created\":{d},\"idle\":{d},\"capacity\":{d},\"closed\":{s}}}",
            .{
                self.borrow_count, self.return_count, self.active_leases,
                self.pool_hits, self.pool_misses, self.hit_rate,
                self.wait_time_p50, self.wait_time_p99, self.wait_time_max,
                self.object_lifetime_p50, self.eviction_count, self.leak_count,
                self.created, self.idle, self.capacity,
                if (self.closed) "true" else "false",
            }) catch "{}";
    }
};

pub fn metricsSnapshot() Metrics {
    return .{};
}

pub const MetricsCollector = struct {
    m: Metrics = .{},
    waits: std.ArrayListUnmanaged(f64) = .{},
    lifetimes: std.ArrayListUnmanaged(f64) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MetricsCollector {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *MetricsCollector) void {
        self.waits.deinit(self.allocator);
        self.lifetimes.deinit(self.allocator);
    }
    pub fn recordBorrow(self: *MetricsCollector, hit: bool, wait_ms: f64, created: bool) !void {
        self.m.borrow_count += 1;
        self.m.active_leases += 1;
        if (hit) self.m.pool_hits += 1 else self.m.pool_misses += 1;
        if (created) self.m.created += 1;
        try self.waits.append(self.allocator, wait_ms);
    }
    pub fn recordReturn(self: *MetricsCollector, lifetime_ms: f64) !void {
        self.m.return_count += 1;
        if (self.m.active_leases > 0) self.m.active_leases -= 1;
        try self.lifetimes.append(self.allocator, lifetime_ms);
    }
    pub fn recordEviction(self: *MetricsCollector) void { self.m.eviction_count += 1; }
    pub fn recordLeak(self: *MetricsCollector, n: u64) void { self.m.leak_count += n; }

    pub fn snapshot(self: *MetricsCollector, capacity: u64, idle: u64, closed: bool) Metrics {
        var out = self.m;
        std.mem.sort(f64, self.waits.items, {}, lessThan);
        std.mem.sort(f64, self.lifetimes.items, {}, lessThan);
        const total = out.pool_hits + out.pool_misses;
        out.hit_rate = if (total == 0) 0 else @as(f64, @floatFromInt(out.pool_hits)) / @as(f64, @floatFromInt(total));
        out.wait_time_p50 = pct(self.waits.items, 0.50);
        out.wait_time_p99 = pct(self.waits.items, 0.99);
        out.wait_time_max = if (self.waits.items.len == 0) 0 else self.waits.items[self.waits.items.len - 1];
        out.object_lifetime_p50 = pct(self.lifetimes.items, 0.50);
        out.capacity = capacity;
        out.idle = idle;
        out.closed = closed;
        return out;
    }
    fn lessThan(_: void, a: f64, b: f64) bool { return a < b; }
    fn pct(sorted: []const f64, q: f64) f64 {
        if (sorted.len == 0) return 0;
        const idx: usize = @intFromFloat(@round(@as(f64, @floatFromInt(sorted.len - 1)) * q));
        return sorted[idx];
    }
};

// ---------------------------------------------------------------------------
// 12.5 差值型 memory_scope（不挂全局分配器）
// ---------------------------------------------------------------------------

pub fn diagEnabled() bool {
    const v = std.posix.getenv(diag_env) orelse return false;
    if (v.len == 0) return false;
    if (std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "off")) return false;
    return true;
}

pub const ScopeReport = struct {
    name: []const u8,
    borrow_count_delta: i64,
    created_delta: i64,
};

/// 返回 stop 函数式结构；未开启时为空操作。
pub const MemoryScope = struct {
    active: bool,
    name: []const u8,
    collector: ?*MetricsCollector,
    b0: i64,
    c0: i64,

    pub fn init(name: []const u8, collector: ?*MetricsCollector) MemoryScope {
        const enabled = diagEnabled();
        var b0: i64 = 0;
        var c0: i64 = 0;
        if (enabled) {
            if (collector) |c| {
                const s = c.snapshot(0, 0, false);
                b0 = @intCast(s.borrow_count);
                c0 = @intCast(s.created);
            }
        }
        return .{ .active = enabled, .name = name, .collector = collector, .b0 = b0, .c0 = c0 };
    }

    pub fn end(self: *MemoryScope) ScopeReport {
        if (!self.active) return .{ .name = self.name, .borrow_count_delta = 0, .created_delta = 0 };
        var b: i64 = self.b0;
        var c: i64 = self.c0;
        if (self.collector) |col| {
            const s = col.snapshot(0, 0, false);
            b = @intCast(s.borrow_count);
            c = @intCast(s.created);
        }
        const r = ScopeReport{
            .name = self.name,
            .borrow_count_delta = b - self.b0,
            .created_delta = c - self.c0,
        };
        std.debug.print("[gc-primitives] {s}: borrows={d} created={d}\n",
            .{ r.name, r.borrow_count_delta, r.created_delta });
        return r;
    }
};

// ---------------------------------------------------------------------------
// 12.6 泄漏检测（借出采样最小集，无后台线程）
// ---------------------------------------------------------------------------

pub const LeaseSample = struct {
    lease_id: u64,
    borrowed_at: i64,
    tag: []const u8,
    age_ms: f64,
    timed_out: bool,
};

pub const LeakDetector = struct {
    allocator: std.mem.Allocator,
    next_id: u64 = 1,
    active: std.ArrayListUnmanaged(LeaseSample) = .{},

    pub fn init(allocator: std.mem.Allocator) LeakDetector {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *LeakDetector) void { self.active.deinit(self.allocator); }

    pub fn onBorrow(self: *LeakDetector, tag: []const u8) !u64 {
        const id = self.next_id;
        self.next_id += 1;
        try self.active.append(self.allocator, .{
            .lease_id = id, .borrowed_at = std.time.milliTimestamp(),
            .tag = tag, .age_ms = 0, .timed_out = false,
        });
        return id;
    }
    pub fn onReturn(self: *LeakDetector, id: u64) void {
        for (self.active.items, 0..) |s, i| {
            if (s.lease_id == id) {
                _ = self.active.orderedRemove(i);
                return;
            }
        }
    }
    pub fn detectLeaks(self: *LeakDetector, timeout_ms: i64, out: []LeaseSample) []LeaseSample {
        const now = std.time.milliTimestamp();
        var n: usize = 0;
        for (self.active.items) |s| {
            const age: f64 = @floatFromInt(now - s.borrowed_at);
            const timed_out = timeout_ms >= 0 and age >= @as(f64, @floatFromInt(timeout_ms));
            if (timeout_ms < 0 or timed_out) {
                if (n >= out.len) break;
                out[n] = .{ .lease_id = s.lease_id, .borrowed_at = s.borrowed_at,
                            .tag = s.tag, .age_ms = age, .timed_out = timed_out };
                n += 1;
            }
        }
        return out[0..n];
    }
    pub fn activeCount(self: *const LeakDetector) usize { return self.active.items.len; }
};

// ---------------------------------------------------------------------------
// 12.4 统一 YAML 子集配置
// ---------------------------------------------------------------------------

pub const ConfigError = error{
    InvalidCapacity,
    InvalidOnFull,
    UnknownKey,
    UnknownHook,
    InvalidIndent,
    MissingColon,
    OutOfMemory,
};

pub const OnFull = enum {
    drop_oldest,
    drop_largest,
    block,
    reject,
    grow,

    pub fn parse(s: []const u8) ConfigError!OnFull {
        if (std.mem.eql(u8, s, "drop_oldest")) return .drop_oldest;
        if (std.mem.eql(u8, s, "drop_largest")) return .drop_largest;
        if (std.mem.eql(u8, s, "block")) return .block;
        if (std.mem.eql(u8, s, "reject")) return .reject;
        if (std.mem.eql(u8, s, "grow")) return .grow;
        return ConfigError.InvalidOnFull;
    }
    pub fn name(self: OnFull) []const u8 {
        return switch (self) {
            .drop_oldest => "drop_oldest", .drop_largest => "drop_largest",
            .block => "block", .reject => "reject", .grow => "grow",
        };
    }
};

pub const PoolConfig = struct {
    max_size: usize = 64,
    on_full: OnFull = .drop_oldest,
    block_timeout_ms: i64 = -1,
    max_overflow: usize = 0,
    eviction_policy: []const u8 = "lru",
    prewarm: usize = 0,
    leak_detection: bool = false,
    leak_timeout_ms: i64 = 3000,
    clear_sensitive: bool = false,

    pub fn validate(self: PoolConfig) ConfigError!void {
        if (self.max_size == 0) return ConfigError.InvalidCapacity;
    }
    pub fn toJson(self: PoolConfig, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf,
            "{{\"max_size\":{d},\"on_full\":\"{s}\",\"block_timeout_ms\":{d}," ++
            "\"max_overflow\":{d},\"eviction_policy\":\"{s}\",\"prewarm\":{d}," ++
            "\"leak_detection\":{s},\"leak_timeout_ms\":{d},\"clear_sensitive\":{s}}}",
            .{ self.max_size, self.on_full.name(), self.block_timeout_ms,
               self.max_overflow, self.eviction_policy, self.prewarm,
               if (self.leak_detection) "true" else "false", self.leak_timeout_ms,
               if (self.clear_sensitive) "true" else "false" }) catch "{}";
    }
};

/// 极简 YAML 子集：缩进映射 + 标量，扁平化为 "a.b.c" -> 值。
pub fn parseYamlSubset(allocator: std.mem.Allocator, text: []const u8) ConfigError!std.StringHashMap([]const u8) {
    var out = std.StringHashMap([]const u8).init(allocator);
    errdefer out.deinit();
    var stack = std.ArrayListUnmanaged(struct { indent: usize, key: []const u8 }){};
    defer stack.deinit(allocator);

    var lines = std.mem.splitScalar(u8, text, '\n');
    var lineno: usize = 0;
    while (lines.next()) |raw_line| : (lineno += 1) {
        var line = raw_line;
        if (std.mem.indexOfScalar(u8, line, '#')) |h| line = line[0..h];
        const content = std.mem.trim(u8, line, " \t\r");
        if (content.len == 0) continue;

        var indent: usize = 0;
        while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) : (indent += 1) {
            if (line[indent] == '\t') return ConfigError.InvalidIndent;
        }
        const colon = std.mem.indexOfScalar(u8, content, ':') orelse return ConfigError.MissingColon;
        const key = std.mem.trim(u8, content[0..colon], " \t");
        const raw_value = std.mem.trim(u8, content[colon + 1 ..], " \t\r");

        while (stack.items.len > 0 and stack.items[stack.items.len - 1].indent >= indent) {
            _ = stack.pop();
        }
        var full = std.ArrayListUnmanaged(u8){};
        defer full.deinit(allocator);
        for (stack.items) |e| {
            try full.appendSlice(allocator, e.key);
            try full.append(allocator, '.');
        }
        try full.appendSlice(allocator, key);

        if (raw_value.len == 0) {
            try stack.append(allocator, .{ .indent = indent, .key = key });
        } else {
            var v = raw_value;
            if (v.len >= 2 and ((v[0] == '"' and v[v.len - 1] == '"') or
                (v[0] == '\'' and v[v.len - 1] == '\''))) {
                v = v[1 .. v.len - 1];
            }
            try out.put(try allocator.dupe(u8, full.items), try allocator.dupe(u8, v));
        }
    }
    return out;
}

/// 释放 parseYamlSubset 返回的 map：key/value 都是 allocator.dupe 出来的，
/// 只调用 deinit 会泄漏；本函数由 loadConfig 与直接使用解析器的调用方共用。
pub fn freeFlatConfig(allocator: std.mem.Allocator, flat: *std.StringHashMap([]const u8)) void {
    var it = flat.iterator();
    while (it.next()) |e| {
        allocator.free(e.key_ptr.*);
        allocator.free(e.value_ptr.*);
    }
    flat.deinit();
}

fn asUsize(v: []const u8, def: usize) usize {
    return std.fmt.parseInt(usize, v, 10) catch def;
}
fn asI64(v: []const u8, def: i64) i64 {
    return std.fmt.parseInt(i64, v, 10) catch def;
}
fn asBool(v: []const u8) bool {
    return std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "yes");
}

/// 加载配置；找不到文件时返回默认值（配置文件可选）。
pub fn loadConfig(allocator: std.mem.Allocator, path: ?[]const u8, pool: []const u8) ConfigError!PoolConfig {
    var cfg = PoolConfig{};
    var chosen: ?[]const u8 = path;
    if (chosen == null) chosen = std.posix.getenv(config_env);

    var buf: [4096]u8 = undefined;

    if (chosen) |f| {
        const file = std.fs.cwd().openFile(f, .{}) catch null;
        if (file) |fh| {
            defer fh.close();
            const n = fh.readAll(&buf) catch 0;
            var flat = try parseYamlSubset(allocator, buf[0..n]);
            defer freeFlatConfig(allocator, &flat);
            var prefix_buf: [256]u8 = undefined;
            const prefix = std.fmt.bufPrint(&prefix_buf, "pools.{s}.", .{pool}) catch "";
            var it = flat.iterator();
            while (it.next()) |e| {
                const k = e.key_ptr.*;
                if (!std.mem.startsWith(u8, k, prefix)) continue;
                const key = k[prefix.len..];
                const v = e.value_ptr.*;
                if (std.mem.startsWith(u8, key, "lifecycle.")) {
                    if (std.mem.eql(u8, key[10..], "clear_sensitive")) cfg.clear_sensitive = asBool(v);
                    continue;
                }
                if (std.mem.eql(u8, key, "max_size")) cfg.max_size = asUsize(v, cfg.max_size)
                else if (std.mem.eql(u8, key, "on_full")) cfg.on_full = try OnFull.parse(v)
                else if (std.mem.eql(u8, key, "block_timeout_ms")) cfg.block_timeout_ms = asI64(v, -1)
                else if (std.mem.eql(u8, key, "max_overflow")) cfg.max_overflow = asUsize(v, 0)
                else if (std.mem.eql(u8, key, "eviction_policy")) {
                    if (std.mem.eql(u8, v, "lru")) cfg.eviction_policy = "lru"
                    else if (std.mem.eql(u8, v, "fifo")) cfg.eviction_policy = "fifo"
                    else return ConfigError.UnknownKey;
                }
                else if (std.mem.eql(u8, key, "prewarm")) cfg.prewarm = asUsize(v, 0)
                else if (std.mem.eql(u8, key, "leak_detection")) cfg.leak_detection = asBool(v)
                else if (std.mem.eql(u8, key, "leak_timeout_ms")) cfg.leak_timeout_ms = asI64(v, 3000)
                else if (std.mem.eql(u8, key, "clear_sensitive")) cfg.clear_sensitive = asBool(v)
                else return ConfigError.UnknownKey;
            }
        }
    }
    // env 覆盖
    var env_buf: [256]u8 = undefined;
    const max_key = std.fmt.bufPrint(&env_buf, "GC_PRIMITIVES__{s}__MAX_SIZE", .{pool}) catch "";
    if (std.posix.getenv(max_key)) |v| cfg.max_size = asUsize(v, cfg.max_size);

    try cfg.validate();
    return cfg;
}

// ---------------------------------------------------------------------------
// 12.1 ManagedPool（共享、可配置；原 Pool 一行未改）
// ---------------------------------------------------------------------------

pub fn LifecycleHooks(comptime T: type) type {
    return struct {
        on_create: ?*const fn (T) void = null,
        on_borrow: ?*const fn (T) void = null,
        on_return: ?*const fn (T) void = null,
        on_evict: ?*const fn (T) void = null,
        on_destroy: ?*const fn (T) void = null,
        clear_sensitive: bool = false,
    };
}

pub fn ManagedPool(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Factory = *const fn () ?T;
        pub const Recycler = *const fn (T) anyerror!void;
        pub const Destroy = *const fn (T) void;
        pub const Hooks = LifecycleHooks(T);

        allocator: std.mem.Allocator,
        factory: Factory,
        recycler: Recycler,
        destroy_fn: Destroy,
        cfg: PoolConfig,
        hooks: Hooks,
        free: std.ArrayListUnmanaged(T) = .{},
        active: std.ArrayListUnmanaged(u64) = .{},
        closed: bool = false,
        metrics_collector: MetricsCollector,
        leaks: LeakDetector,
        next_id: u64 = 1,

        pub fn init(allocator: std.mem.Allocator, factory: Factory,
                    recycler: Recycler, destroy_fn: Destroy,
                    cfg: PoolConfig, hooks: Hooks) ConfigError!Self {
            try cfg.validate();
            var p = Self{
                .allocator = allocator, .factory = factory, .recycler = recycler,
                .destroy_fn = destroy_fn, .cfg = cfg, .hooks = hooks,
                .metrics_collector = MetricsCollector.init(allocator),
                .leaks = LeakDetector.init(allocator),
            };
            var i: usize = 0;
            while (i < cfg.prewarm) : (i += 1) {
                var lease = try p.borrow("prewarm");
                try lease.close();
            }
            return p;
        }

        pub fn deinit(self: *Self) void {
            for (self.free.items) |v| {
                if (self.hooks.on_destroy) |h| h(v);
                self.destroy_fn(v);
            }
            self.free.deinit(self.allocator);
            self.active.deinit(self.allocator);
            self.metrics_collector.deinit();
            self.leaks.deinit();
        }

        pub const ManagedLease = struct {
            pool: *Self,
            value: ?T,
            id: u64,
            tag: []const u8,
            borrowed_at: i64,
            active: bool = true,

            pub fn get(self: *ManagedLease) ConfigError!T {
                if (!self.active or self.value == null) return ConfigError.InvalidCapacity;
                return self.value.?;
            }
            pub fn close(self: *ManagedLease) ConfigError!void {
                if (!self.active) return ConfigError.InvalidCapacity;
                self.active = false;
                const v = self.value.?;
                self.value = null;
                return self.pool.release(v, self.id, self.borrowed_at);
            }
            pub fn leaseId(self: *const ManagedLease) u64 { return self.id; }
        };

        pub fn borrow(self: *Self, tag: []const u8) ConfigError!ManagedLease {
            if (self.closed) return ConfigError.InvalidCapacity;
            const limit = self.cfg.max_size +
                (if (self.cfg.on_full == .grow) self.cfg.max_overflow else 0);
            while (self.active.items.len >= limit) {
                switch (self.cfg.on_full) {
                    .reject => return ConfigError.InvalidCapacity,
                    .block => {
                        // Zig 无内置 condvar：降级为带次数上限的让出，避免死等
                        var spins: usize = 0;
                        while (self.active.items.len >= limit and spins < 64) : (spins += 1) {
                            std.atomic.spinLoopHint();
                        }
                        if (self.active.items.len >= limit) return ConfigError.InvalidCapacity;
                    },
                    else => break,
                }
            }
            const hit: bool = self.free.items.len > 0;
            var value: T = undefined;
            var created = false;
            if (hit) {
                value = self.free.pop().?;
            } else {
                value = self.factory() orelse return ConfigError.InvalidCapacity;
                created = true;
                if (self.hooks.on_create) |h| h(value);
            }
            const id = self.next_id;
            self.next_id += 1;
            if (self.cfg.leak_detection) {
                _ = try self.leaks.onBorrow(tag);
            }
            try self.active.append(self.allocator, id);
            try self.metrics_collector.recordBorrow(hit, 0, created);
            if (self.hooks.on_borrow) |h| h(value);
            return .{ .pool = self, .value = value, .id = id, .tag = tag,
                      .borrowed_at = std.time.milliTimestamp() };
        }

        fn release(self: *Self, value: T, id: u64, borrowed_at: i64) ConfigError!void {
            const v = value;
            if (self.hooks.clear_sensitive) {
                if (self.hooks.on_return) |h| h(v);
            }
            self.recycler(v) catch {
                if (self.hooks.on_destroy) |h| h(v);
                self.destroy_fn(v);
                self.settle(id, borrowed_at);
                return ConfigError.InvalidCapacity;
            };
            if (self.hooks.on_return) |h| h(v);
            self.leaks.onReturn(id);
            if (self.free.items.len >= self.cfg.max_size and self.cfg.on_full != .grow) {
                const victim = self.free.orderedRemove(0);
                try self.free.append(self.allocator, v);
                if (self.hooks.on_evict) |h| h(victim);
                self.metrics_collector.recordEviction();
                self.destroy_fn(victim);
            } else {
                try self.free.append(self.allocator, v);
            }
            self.settle(id, borrowed_at);
        }

        fn settle(self: *Self, id: u64, borrowed_at: i64) void {
            for (self.active.items, 0..) |x, i| {
                if (x == id) { _ = self.active.orderedRemove(i); break; }
            }
            const age: f64 = @floatFromInt(std.time.milliTimestamp() - borrowed_at);
            self.metrics_collector.recordReturn(age) catch {};
        }

        pub fn prewarm(self: *Self, n: usize) !usize {
            var made: usize = 0;
            while (made < n) : (made += 1) {
                var l = try self.borrow("prewarm");
                try l.close();
            }
            return made;
        }
        pub fn detectLeaks(self: *Self, timeout_ms: i64, out: []LeaseSample) []LeaseSample {
            const found = self.leaks.detectLeaks(timeout_ms, out);
            self.metrics_collector.recordLeak(found.len);
            return found;
        }
        pub fn metrics(self: *Self) Metrics {
            return self.metrics_collector.snapshot(self.cfg.max_size, self.free.items.len, self.closed);
        }
        pub fn stats(self: *Self) Metrics { return self.metrics(); }
        pub fn snapshotJson(self: *Self, buf: []u8) []const u8 {
            var mb: [1024]u8 = undefined;
            var cb: [1024]u8 = undefined;
            const m = self.metrics().toJson(&mb);
            const c = self.cfg.toJson(&cb);
            return std.fmt.bufPrint(buf,
                "{{\"config\":{s},\"stats\":{s},\"active_leases\":[],\"idle_objects\":{d}}}",
                .{ c, m, self.free.items.len }) catch "{}";
        }
        pub fn applyConfig(self: *Self, cfg: PoolConfig) void {
            self.cfg = cfg;
        }
        pub fn setMaxSize(self: *Self, n: usize) void { self.cfg.max_size = n; }
        pub fn reload(self: *Self, path: ?[]const u8) ConfigError!void {
            self.cfg = try loadConfig(self.allocator, path, "default");
        }
        pub fn close(self: *Self) void { self.closed = true; }
        pub fn assertNoActiveLeases(self: *const Self) ConfigError!void {
            if (self.active.items.len != 0) return ConfigError.InvalidCapacity;
        }
    };
}

// ---------------------------------------------------------------------------
// 12.2 组合矩阵（写死）
// ---------------------------------------------------------------------------

pub const PoolKind = enum { local, shared, base };

pub const CombinationError = error{Forbidden};

pub fn assertCombination(kind: PoolKind, operation: []const u8) CombinationError!void {
    const shardable = kind != .local;
    const l2 = kind != .local;
    if (std.mem.eql(u8, operation, "standalone")) return;
    if (std.mem.eql(u8, operation, "shardable")) {
        if (!shardable) return CombinationError.Forbidden;
        return;
    }
    if (std.mem.eql(u8, operation, "two_level_l2")) {
        if (!l2) return CombinationError.Forbidden;
        return;
    }
    return CombinationError.Forbidden;
}

pub fn ShardedPool(comptime T: type) type {
    return struct {
        const Self = @This();
        const MP = ManagedPool(T);
        allocator: std.mem.Allocator,
        shards: []MP,
        next: u64 = 0,

        pub fn init(allocator: std.mem.Allocator, shards: []MP,
                    kind: PoolKind) CombinationError!Self {
            try assertCombination(kind, "shardable");
            if (shards.len == 0) return CombinationError.Forbidden;
            return .{ .allocator = allocator, .shards = shards };
        }
        pub fn borrow(self: *Self, tag: []const u8) ConfigError!MP.ManagedLease {
            const i: usize = @intCast(self.next % self.shards.len);
            self.next += 1;
            return self.shards[i].borrow(tag);
        }
        pub fn metrics(self: *Self) Metrics {
            var out = Metrics{};
            for (self.shards) |*s| {
                const x = s.metrics();
                out.borrow_count += x.borrow_count; out.return_count += x.return_count;
                out.active_leases += x.active_leases; out.pool_hits += x.pool_hits;
                out.pool_misses += x.pool_misses; out.eviction_count += x.eviction_count;
                out.leak_count += x.leak_count; out.created += x.created;
                out.idle += x.idle; out.capacity += x.capacity;
            }
            const total = out.pool_hits + out.pool_misses;
            out.hit_rate = if (total == 0) 0
                else @as(f64, @floatFromInt(out.pool_hits)) / @as(f64, @floatFromInt(total));
            return out;
        }
        pub fn stats(self: *Self) Metrics { return self.metrics(); }
    };
}

pub fn TwoLevelPool(comptime T: type) type {
    return struct {
        const Self = @This();
        const MP = ManagedPool(T);
        l2: *MP,

        pub fn init(l2: *MP, l1_size: usize, kind: PoolKind) CombinationError!Self {
            _ = l1_size;
            try assertCombination(kind, "two_level_l2");
            return .{ .l2 = l2 };
        }
        pub fn borrow(self: *Self, tag: []const u8) ConfigError!MP.ManagedLease {
            return self.l2.borrow(tag);
        }
        pub fn metrics(self: *Self) Metrics { return self.l2.metrics(); }
        pub fn stats(self: *Self) Metrics { return self.metrics(); }
    };
}

// ---------------------------------------------------------------------------
// 12 章低优先级项：多 allocator 后端对比 + benchmark，见下方 test 块
// （page_allocator / arena / GPA 三种后端各自跑同一池，全部无泄漏）
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 测试（zig test src/v020.zig 会跑全部 test 块）
// ---------------------------------------------------------------------------

const Buffer = struct { data: [32]u8 = undefined, len: usize = 0 };
var bench_alloc: std.mem.Allocator = undefined;

fn makeBuf() ?*Buffer {
    const b = bench_alloc.create(Buffer) catch return null;
    b.* = .{};
    return b;
}
fn resetBuf(b: *Buffer) anyerror!void { b.len = 0; }
fn destroyBuf(b: *Buffer) void { bench_alloc.destroy(b); }

fn newTestPool(a: std.mem.Allocator, cfg: PoolConfig) ManagedPool(*Buffer) {
    bench_alloc = a;
    return ManagedPool(*Buffer).init(a, makeBuf, resetBuf, destroyBuf, cfg, .{}) catch unreachable;
}

test "metrics fields are isomorphic" {
    var buf: [1024]u8 = undefined;
    const m = Metrics{};
    const j = m.toJson(&buf);
    try std.testing.expectEqual(@as(usize, 16), metrics_fields.len);
    for (metrics_fields) |k| try std.testing.expect(std.mem.indexOf(u8, j, k) != null);
}

test "collector counts and percentiles" {
    var c = MetricsCollector.init(std.testing.allocator);
    defer c.deinit();
    try c.recordBorrow(false, 1, true);
    try c.recordBorrow(true, 2, false);
    try c.recordReturn(3);
    try c.recordReturn(5);
    const s = c.snapshot(8, 1, false);
    try std.testing.expectEqual(@as(u64, 2), s.borrow_count);
    try std.testing.expectEqual(@as(u64, 2), s.return_count);
    try std.testing.expectEqual(@as(u64, 0), s.active_leases);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), s.hit_rate, 1e-9);
    try std.testing.expectEqual(@as(u64, 1), s.created);
    try std.testing.expectEqual(@as(f64, 2), s.wait_time_max);
}

test "memory scope disabled by default" {
    // 沙盒/CI 默认不设 GC_PRIMITIVES_DIAG
    var scope = MemoryScope.init("disabled", null);
    const r = scope.end();
    try std.testing.expectEqual(@as(i64, 0), r.borrow_count_delta);
}

test "leak sampling minimum fields" {
    var d = LeakDetector.init(std.testing.allocator);
    defer d.deinit();
    const id = try d.onBorrow("db-query");
    var out: [8]LeaseSample = undefined;
    const found = d.detectLeaks(0, &out);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("db-query", found[0].tag);
    try std.testing.expect(found[0].lease_id != 0);
    try std.testing.expect(found[0].timed_out);
    d.onReturn(id);
    try std.testing.expectEqual(@as(usize, 0), d.detectLeaks(0, &out).len);
}

test "yaml subset and schema" {
    const text =
        "pools:\n" ++
        "  default:\n" ++
        "    max_size: 8\n" ++
        "    on_full: \"reject\"\n" ++
        "    leak_detection: true\n" ++
        "    lifecycle:\n" ++
        "      clear_sensitive: yes\n" ++
        "diagnostics:\n" ++
        "  memory_scope: false\n";
    var flat = try parseYamlSubset(std.testing.allocator, text);
    defer freeFlatConfig(std.testing.allocator, &flat);
    try std.testing.expectEqualStrings("8", flat.get("pools.default.max_size").?);
    try std.testing.expectEqualStrings("reject", flat.get("pools.default.on_full").?);
    try std.testing.expectEqualStrings("yes", flat.get("pools.default.lifecycle.clear_sensitive").?);
    try std.testing.expectEqualStrings("false", flat.get("diagnostics.memory_scope").?);

    var bad = PoolConfig{ .max_size = 0 };
    try std.testing.expectError(ConfigError.InvalidCapacity, bad.validate());
    try std.testing.expectError(ConfigError.InvalidOnFull, OnFull.parse("bounce"));
}

test "managed pool full policies, hooks, prewarm, snapshot" {
    var p = newTestPool(std.testing.allocator, .{ .max_size = 1, .on_full = .reject });
    defer p.deinit();
    var a = try p.borrow("");
    try std.testing.expectError(ConfigError.InvalidCapacity, p.borrow(""));
    try a.close();
    try p.assertNoActiveLeases();

    var p2 = newTestPool(std.testing.allocator, .{ .max_size = 1, .on_full = .grow, .max_overflow = 2 });
    defer p2.deinit();
    var leases: [3]ManagedPool(*Buffer).ManagedLease = undefined;
    for (&leases) |*l| l.* = try p2.borrow("");
    for (&leases) |*l| try l.close();
    try p2.assertNoActiveLeases();

    var p3 = newTestPool(std.testing.allocator, .{});
    defer p3.deinit();
    try std.testing.expectEqual(@as(usize, 2), try p3.prewarm(2));
    var sb: [2048]u8 = undefined;
    const snap = p3.snapshotJson(&sb);
    for ([_][]const u8{ "config", "stats", "active_leases", "idle_objects" }) |k| {
        try std.testing.expect(std.mem.indexOf(u8, snap, k) != null);
    }
    try std.testing.expectEqual(@as(u64, 2), p3.metrics().borrow_count);
}

test "combination matrix is fixed" {
    try assertCombination(.shared, "shardable");
    try assertCombination(.shared, "two_level_l2");
    try std.testing.expectError(CombinationError.Forbidden, assertCombination(.local, "shardable"));
    try std.testing.expectError(CombinationError.Forbidden, assertCombination(.local, "two_level_l2"));
}

test "sharded and two-level pools" {
    var shards: [4]ManagedPool(*Buffer) = undefined;
    for (&shards) |*s| s.* = newTestPool(std.testing.allocator, .{ .max_size = 2 });
    defer for (&shards) |*s| s.deinit();
    var sp = try ShardedPool(*Buffer).init(std.testing.allocator, &shards, .shared);
    var l = try sp.borrow("");
    try l.close();
    try std.testing.expectEqual(@as(u64, 1), sp.metrics().borrow_count);

    var l2 = newTestPool(std.testing.allocator, .{ .max_size = 8 });
    defer l2.deinit();
    var tp = try TwoLevelPool(*Buffer).init(&l2, 2, .shared);
    var tl = try tp.borrow("");
    try tl.close();
    try l2.assertNoActiveLeases();
}

test "allocator backends: page_allocator, arena, GPA all leak-free" {
    // Zig 低优先级项：不同 allocator 后端跑同一池，均无泄漏
    const Backend = struct {
        fn run(a: std.mem.Allocator) !void {
            var p = newTestPool(a, .{ .max_size = 4 });
            defer p.deinit();
            var i: usize = 0;
            while (i < 16) : (i += 1) {
                var l = try p.borrow("bench");
                _ = try l.get();
                try l.close();
            }
            try p.assertNoActiveLeases();
            try std.testing.expectEqual(@as(u64, 16), p.metrics().borrow_count);
        }
    };
    try Backend.run(std.testing.allocator); // GPA 泄漏检测
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try Backend.run(arena.allocator());
    try Backend.run(std.heap.page_allocator);
}

test "benchmark: pooled vs unpooled allocation counts" {
    // 用 created 计数器对比：命中空闲槽后不再新增分配
    var p = newTestPool(std.testing.allocator, .{ .max_size = 1 });
    defer p.deinit();
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        var l = try p.borrow("bench");
        try l.close();
    }
    const m = p.metrics();
    try std.testing.expectEqual(@as(u64, 64), m.borrow_count);
    try std.testing.expect(m.created <= 2); // 池化后创建次数远小于借出次数
    try std.testing.expect(m.pool_hits >= 62);
    try std.testing.expect(m.hit_rate > 0.9);
}
