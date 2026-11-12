import {
  PoolStateError,
  activeLeases,
  closedPool,
  factoryFailed,
  invalidCapacity,
} from './errors.js';
import { Lease } from './lease.js';

/** A factory that returns null/undefined is treated as "could not create". */
export type Factory<T> = () => T | null | undefined;

/**
 * A reset hook invoked on return. If it throws, the object is discarded and
 * never placed back into the idle list (C4), and the error is propagated to
 * the caller of Lease.return().
 */
export type Recycler<T> = (value: T) => void;

export interface PoolOptions<T> {
  factory: Factory<T>;
  /** Defaults to a no-op. Called exactly once per successful return. */
  recycler?: Recycler<T>;
  /** Maximum number of idle objects retained. Defaults to 16. */
  capacity?: number;
}

export interface PoolStats {
  capacity: number;
  idle: number;
  active: number;
  borrowCount: number;
  returnCount: number;
  created: number;
  closed: boolean;
}

const NOOP = (): void => {};

/**
 * A bounded object pool for a single-threaded Node event loop.
 *
 * Node has no thread-local storage: the event loop runs on one thread, and each
 * worker thread owns a separate V8 heap. A Pool must therefore be created per
 * worker; it is intentionally NOT shared across workers. Cross-realm misuse
 * cannot be detected reliably at runtime and is covered by the documented
 * contract instead (see SPEC.md section 11.1).
 */
export class Pool<T> {
  readonly #capacity: number;
  readonly #factory: Factory<T>;
  readonly #recycler: Recycler<T>;
  readonly #idle: T[] = [];

  #closed = false;
  #created = 0;
  #borrowCount = 0;
  #returnCount = 0;
  #active = 0;

  constructor(options: PoolOptions<T>) {
    const capacity = options.capacity ?? 16;
    if (!Number.isInteger(capacity) || capacity <= 0) {
      throw invalidCapacity(capacity);
    }
    if (typeof options.factory !== 'function') {
      throw new PoolStateError('factory must be a function');
    }
    if (options.recycler !== undefined && typeof options.recycler !== 'function') {
      throw new PoolStateError('recycler must be a function');
    }
    this.#capacity = capacity;
    this.#factory = options.factory;
    this.#recycler = options.recycler ?? (NOOP as Recycler<T>);
  }

  /** C1: take an object and receive a lease that MUST be returned. */
  borrow(): Lease<T> {
    if (this.#closed) throw closedPool();

    let value: T | null | undefined = this.#idle.pop();
    if (value === undefined) {
      value = this.#factory();
      if (value === null || value === undefined) throw factoryFailed();
      this.#created += 1;
    }

    this.#borrowCount += 1;
    this.#active += 1;
    return new Lease<T>(this, value);
  }

  /** C3: rejects new borrows. Idle objects are dropped, never resurrected. */
  close(): void {
    this.#closed = true;
    this.#idle.length = 0;
  }

  get closed(): boolean {
    return this.#closed;
  }

  get capacity(): number {
    return this.#capacity;
  }

  /** A snapshot of the diagnostics counters (SPEC section 4 mapping). */
  stats(): PoolStats {
    return {
      capacity: this.#capacity,
      idle: this.#idle.length,
      active: this.#active,
      borrowCount: this.#borrowCount,
      returnCount: this.#returnCount,
      created: this.#created,
      closed: this.#closed,
    };
  }

  /** Test-time leak detector; throws if any borrow is still outstanding. */
  assertNoActiveLeases(): void {
    if (this.#active !== 0) throw activeLeases(this.#active);
  }

  /**
   * Internal return path. Called exactly once by Lease.return().
   *
   * Counters settle BEFORE the reset hook so that a failing recycler still
   * leaves exact diagnostics and never reports a phantom active lease.
   */
  _return(value: T): void {
    this.#returnCount += 1;
    this.#active -= 1;

    // A throwing recycler means the object is dirty: drop it, propagate the
    // error, and never cache it. This aligns with C4 in every other port.
    this.#recycler(value);

    if (!this.#closed && this.#idle.length < this.#capacity) {
      this.#idle.push(value);
    }
  }
}
