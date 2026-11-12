# gc-primitives · Node / TypeScript Port

> [中文](README.md) · English

A Node port of the same conceptual contract as the Java / C++ / Python / Rust / Go implementations. See section 11.1 of the repository-root [SPEC.en.md](../../SPEC.en.md) ([中文](../../SPEC.md)).

**This first iteration implements the safety contract only**: strict misuse detection for C1–C5, bounded reuse, reset-on-return, and diagnostic counters. Async factories, `withLease` callbacks, and dedicated Worker Threads tests are deferred — see "Not implemented yet" below.

## Import

```bash
npm install @rainbowcrr-sys/gc-primitives
```

Pure ESM with bundled `.d.ts`; `@types/node` and `typescript` are dev-only, so the package has **zero runtime dependencies**. Baseline Node ≥ 18 (CI actually runs 18 / 20 / 22).

```ts
import { Pool } from '@rainbowcrr-sys/gc-primitives';

const pool = new Pool<{ buf: string[] }>({
  capacity: 32,
  factory: () => ({ buf: [] }),
  recycler: (obj) => { obj.buf.length = 0; },   // reset on return
});

const lease = pool.borrow();
try {
  lease.value.buf.push('hello');
  console.log(lease.value.buf);
} finally {
  lease.return();                                  // C1: every borrow must be returned
}

pool.assertNoActiveLeases();                        // turns a leak into a test failure
```

On Node 20+ / TypeScript 5.2+, `using` also works:

```ts
{
  using lease = pool.borrow();
  lease.value.buf.push('world');
} // the DISPOSE hook returns it automatically
```

## The Safety Contract (focus of this iteration)

| Contract | Implementation | On violation |
| --- | --- | --- |
| C1 Explicit return | `lease.return()` / `close()` / `dispose()` / `using` | No destructor fallback; detected by `assertNoActiveLeases()` |
| C2 Borrow after close | `pool.close()` rejects `borrow()` and clears idle objects | Throws `PoolStateError` |
| C3 Bounded | Idle list capped at `capacity` (default 16); excess is dropped | — |
| C4 Reset on return | `recycler` runs once per successful return | On throw: **object discarded, error propagated, counters still settle**, never returned to the pool |
| C5 Strict misuse detection | Double return, `value` after return, empty factory result, `capacity <= 0`, non-function hooks | Always throws `PoolStateError`; **no switch, no debug/release split, no `process.exit`** |

**Counter semantics**: `borrowCount / returnCount / active` settle at the very start of `return()`, so even a throwing `recycler` cannot leave a phantom active lease. `created` counts only objects actually produced by the factory.

**"Still referenced externally after return"**: JavaScript cannot intercept this at runtime; the caller must not retain `lease.value` after `return()`. This matches all five existing language docs.

## Diagnostics API (SPEC section 4 mapping)

| Java | Go | Node |
| --- | --- | --- |
| `borrow()` | `Borrow()` | `borrow()` |
| `capacity()` | `Capacity()` | `capacity` / `stats().capacity` |
| `idleCount()` | `IdleCount()` | `stats().idle` |
| `activeLeases()` | `ActiveLeases()` | `stats().active` |
| `borrowCount()` / `returnCount()` | `BorrowCount()` / `ReturnCount()` | `stats().borrowCount` / `.returnCount` |
| `assertNoActiveLeases()` | `AssertNoActiveLeases() error` | `assertNoActiveLeases()` (throws `PoolStateError`) |

Also `stats().created`, `stats().closed`, `lease.returned`, and `pool.closed`.

## Concurrency Model: Single-Threaded Variant

Node's event loop is single-threaded, so **the pool needs no internal lock**. However, each `worker_threads` worker owns a separate V8 heap:

- **Create one `new Pool(...)` per worker**; never share a Pool across workers
- No runtime cross-worker misuse check (a realm cannot be identified reliably); this is a documented contract, see SPEC 11.1
- `FinalizationRegistry` is deliberately not used for leak fallback: GC timing is nondeterministic and would introduce flaky behavior. `assertNoActiveLeases()` is deterministic instead.

## Verification

```bash
cd node/gc-primitives
npm install
npm run build     # tsc -> dist/*.js + *.d.ts
npm test          # node:test imports dist/ directly, i.e. the real published artifact
```

CI runs `build + test` on **Node 18 / 20 / 22**, plus a separate `tsc --noEmit` type check. There are 13 contract tests, covering every row in the table above.

## Distribution (not published in this iteration)

- Package name `@rainbowcrr-sys/gc-primitives` (scope matches the GitHub owner)
- `publish-npm.yml` is ready, using **npm Trusted Publishing / OIDC** with no long-lived token
- **First release has a chicken-and-egg problem**: OIDC can only be configured for a package that already exists on npm, so the first publish needs a one-time Granular Token (stored only as a GitHub Secret, never in a repository file). Trusted Publisher registration makes every later release fully automatic
- Tag prefix `node-gc-primitives-v0.1.0`

> As requested, this iteration **only creates the directory and code** — no publish, no credentials written anywhere. Say "publish Node 0.1.0" to start the first release.

## Not implemented yet (later versions)

- Async factory `borrowAsync()` / `Promise`-returning reset hook
- `withLease(pool, fn)` callback-style auto-return
- Dedicated Worker Threads integration test
- Dual ESM + CJS output (currently pure ESM)
- Benchmarks (no hard-coded performance numbers)

Every Markdown file has a Chinese and an English version; English filenames end in `.en.md`.
