import {
  DISPOSE,
  doubleReturn,
  leaseClosed,
} from './errors.js';
import type { Pool } from './pool.js';

/**
 * A borrow handle. It must be returned exactly once.
 *
 * Recommended usage:
 *
 * ```ts
 * const lease = pool.borrow();
 * try {
 *   use(lease.value);
 * } finally {
 *   lease.return();
 * }
 * ```
 *
 * On Node 20+ / TypeScript 5.2+, `using lease = pool.borrow()` also works via
 * the DISPOSE hook. There is no destructor fallback in JavaScript: an
 * unreturned lease is only detectable through Pool#assertNoActiveLeases().
 */
export class Lease<T> {
  readonly #pool: Pool<T>;
  readonly #value: T;
  #returned = false;

  constructor(pool: Pool<T>, value: T) {
    this.#pool = pool;
    this.#value = value;

    // A computed class method requires a `unique symbol` type, which cannot be
    // produced by the `??` fallback in errors.ts. Installing the hook on the
    // instance keeps it non-enumerable and gives `using` a callable dispose.
    Object.defineProperty(this, DISPOSE, {
      value: (): void => this.return(),
      enumerable: false,
      configurable: true,
      writable: false,
    });
  }

  /** C5: reading the value after return throws; never returns stale data. */
  get value(): T {
    if (this.#returned) throw leaseClosed();
    return this.#value;
  }

  get returned(): boolean {
    return this.#returned;
  }

  /** C1 + C5: double return throws; a failing reset propagates and drops the object. */
  return(): void {
    if (this.#returned) throw doubleReturn();
    this.#returned = true;
    this.#pool._return(this.#value);
  }

  /** Alias for return(), so `using` and manual code share one path. */
  close(): void {
    this.return();
  }

  /** Explicit Resource Management hook (`using`). */
  dispose(): void {
    this.return();
  }
}
