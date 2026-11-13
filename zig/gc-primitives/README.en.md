# gc-primitives · Zig Port

> [中文](README.md) · English

A Zig port of the same conceptual contract as the Java / C++ / Python / Rust / Go / Swift implementations. See section 11.2 of the repository-root [SPEC.en.md](../../SPEC.en.md) ([中文](../../SPEC.md)).
> ⚠️ **0.1.x is deprecated — use 0.2.0** (older releases lack the concurrency, diagnostics, configuration and observability capabilities and receive no further fixes).


## Why Zig needs a pool most: no GC, no implicit allocation

Zig has **no garbage collector and no hidden allocator**: every byte comes from an explicit `std.mem.Allocator` supplied by the caller. So "reduce allocations" is literal here:

- A free-slot hit performs no `allocator.create` at all
- Every discarded object is released via the `destroy` hook, never leaked
- `Pool(comptime T)` is a compile-time generic: zero runtime overhead, no vtable, no type erasure
- The pool itself uses `std.ArrayListUnmanaged` and holds no implicit state

**The Zig-specific `destroy` hook**: other languages rely on a GC / ARC / Drop to reclaim discarded objects; Zig must do it itself. Objects dropped on reset failure, beyond capacity, or at pool close all go through `destroy`, and `std.testing.allocator` catches every object that was missed.

## Import

Zig has no central registry, no account, and no token. A public Git repository + tag is enough:

```bash
# Run directly
zig test src/root.zig
```

As a dependency (tag tarball at release time, see below):

```zig
const gc = @import("gc_primitives");
var pool = try gc.Pool(*Buffer).init(allocator, .{
    .capacity = 32,
    .factory = createBuffer,
    .recycler = resetBuffer,
    .destroy = destroyBuffer,
});
defer pool.deinit();
```

## Usage

```zig
const std = @import("std");
const gc = @import("gc_primitives");

const Buffer = struct {
    data: [32]u8 = undefined,
    len: usize = 0,
};

fn createBuffer(a: std.mem.Allocator) anyerror!?*Buffer {
    const b = try a.create(Buffer);
    b.* = .{};
    return b;
}
fn resetBuffer(b: *Buffer) anyerror!void { b.len = 0; }
fn destroyBuffer(a: std.mem.Allocator, b: *Buffer) void { a.destroy(b); }

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pool = try gc.Pool(*Buffer).init(allocator, .{
        .capacity = 8,
        .factory = createBuffer,
        .recycler = resetBuffer,
        .destroy = destroyBuffer,
    });
    defer pool.deinit();                 // frees every idle object

    var lease = try pool.borrow();
    defer lease.close() catch {};        // C1: every borrow must be returned
    const b = try lease.value();
    b.len = 3;

    try pool.assertNoActiveLeases();     // turns a leak into a test error
}
```

> Zig has no destructor, so **forgetting `close()` leaves both an active count and an unfreed object**. `assertNoActiveLeases()` plus the testing allocator's leak detection catch it together.

## The Safety Contract (C1–C5)

| Contract | Implementation | On violation |
| --- | --- | --- |
| C1 Explicit return | `lease.close()`, recommended `defer lease.close() catch {};` | No destructor fallback; `assertNoActiveLeases()` + allocator leak detection |
| C2 Borrow after close | `pool.close()` rejects `borrow()` and `destroy`s all idle objects | `error.PoolClosed` |
| C3 Bounded | `ArrayListUnmanaged` capped at `capacity` (default 16); excess is `destroy`ed | — |
| C4 Reset on return | `recycler` runs once per successful return | Returning an error → **object `destroy`ed, error propagated, counters still settle**, never returned to the pool |
| C5 Strict misuse detection | Double close, `value()` after close, factory returning `null`, `capacity == 0` | Always returns an error; **no `@panic`, no switch** |

**Counter semantics**: `return_count / active` settle at the very start of `close()`, so a failing `recycler` cannot leave a phantom active lease.

**Error set**: `PoolError` (`InvalidCapacity` / `FactoryFailed` / `LeaseClosed` / `DoubleClose` / `PoolClosed` / `ActiveLeases` / `OutOfMemory`). Custom errors from `recycler` and `factory` propagate unchanged through `anyerror`.

## Diagnostics API

| Java | Zig |
| --- | --- |
| `borrow()` | `borrow() anyerror!Lease(T)` |
| `capacity()` | `stats().capacity` |
| `idleCount()` | `stats().idle` |
| `activeLeases()` | `stats().active` |
| `borrowCount()` / `returnCount()` | `stats().borrow_count` / `.return_count` |
| `assertNoActiveLeases()` | `assertNoActiveLeases() PoolError!void` |

Also `stats().created`, `stats().closed`, and `lease.isReturned()`.

## Concurrency Model

A single `Pool` instance is not shared across threads (Zig has no built-in lock or thread-local abstraction; threading is the caller's responsibility). Counters are plain `usize`, with the same "instance ownership" convention as the other ports. Every test uses **local state only**, no mutable globals, so `zig test` running test blocks concurrently cannot corrupt data.

## Verification

```bash
cd zig/gc-primitives
zig test src/root.zig                # compile + run 11 contract tests + leak detection
zig test -O ReleaseSafe src/root.zig # repeat in ReleaseSafe
zig build test
```

CI actually runs all three on **Zig 0.14.0**. `std.testing.allocator` verifies that every allocation is freed at the end of each test — the hardest guarantee behind "no bugs at all" in this port.

## Distribution (`0.1.0` published)

- Repository tag: `zig/gc-primitives/v0.1.0`
- Release asset: `gc-primitives-zig-0.1.0.tar.gz`; the package root contains `build.zig.zon` and a `build.zig` that exposes the `gc_primitives` module via `addModule`
- To consume: add the asset `.url` + `.hash` to your own `build.zig.zon`. Get the hash from `zig fetch <asset-URL>`, or let `zig fetch --save <asset-URL>` write both for you
- CI already fetched that exact asset with `zig fetch`, computed the hash, then built and ran a separate consumer package that does `@import("gc_primitives")`
- The repository carries the `zig-package` topic; find it at https://zigpkg.dev by searching `gc-primitives`
- Release page: https://github.com/rainbowcrr-sys/rbc-monorepo/releases/tag/zig/gc-primitives/v0.1.0

No registration, no token, no credentials.

Every Markdown file has a Chinese and an English version; English filenames end in `.en.md`.
