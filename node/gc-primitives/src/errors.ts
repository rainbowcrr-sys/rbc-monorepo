/**
 * Every contract violation in this package is reported as a thrown
 * PoolStateError. Nothing calls process.exit(), nothing silently ignores
 * misuse, and there is no "strict mode" switch that can be turned off.
 *
 * This is the Node port of contract C5 in SPEC.md.
 */
export class PoolStateError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'PoolStateError';
  }
}

/**
 * Symbol.dispose is part of Explicit Resource Management. Node 20+ and
 * TypeScript 5.2+ expose it natively; older runtimes do not. We fall back to a
 * well-known symbol so that the Lease always carries a callable dispose hook,
 * and `using` works wherever the runtime provides Symbol.dispose.
 *
 * A well-known fallback is used instead of a private Symbol so that a Lease
 * crossing a realm boundary (e.g. a worker or a second copy of the package)
 * can still be disposed.
 */
export const DISPOSE: symbol =
  (Symbol as unknown as { dispose?: symbol }).dispose ??
  Symbol.for('nodejs.gc-primitives.dispose');

/** Thrown when the caller borrows from a closed pool. */
export function closedPool(): PoolStateError {
  return new PoolStateError('pool is closed; borrow() is no longer allowed');
}

/** Thrown when the factory produced nothing (C5: factory returned empty). */
export function factoryFailed(): PoolStateError {
  return new PoolStateError('factory returned an empty value (null/undefined)');
}

/** Thrown for capacity <= 0 (C5). */
export function invalidCapacity(capacity: number): PoolStateError {
  return new PoolStateError(`capacity must be > 0, got ${capacity}`);
}

/** Thrown when a lease is used after it was returned (C5). */
export function leaseClosed(): PoolStateError {
  return new PoolStateError('lease is closed; value/return() after close()');
}

/** Thrown when a lease is returned twice (C5). */
export function doubleReturn(): PoolStateError {
  return new PoolStateError('lease was returned twice');
}

/** Thrown by assertNoActiveLeases() when a borrow was not returned. */
export function activeLeases(count: number): PoolStateError {
  return new PoolStateError(
    `${count} borrow(s) not returned; every borrow() needs return()`,
  );
}
