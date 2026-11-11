package net.de5.rainbowcrrsys.gcprimitives;

import java.util.Objects;
import java.util.concurrent.atomic.LongAdder;
import java.util.function.Supplier;

/**
 * 线程本地 + 有界的 {@link Pool} 实现。
 *
 * <p>借还路径无锁、无跨线程同步；命中空闲槽时不分配对象，连 {@link Lease} 句柄本身也从
 * 线程本地栈复用，因此正常使用下热路径接近零分配。每个线程最多保留 {@code capacity} 个
 * 空闲对象，超出的归还对象直接丢弃，保证内存占用有界。
 *
 * <p>误用始终强制校验：双重归还、跨线程归还、跨线程取用、关闭后取用、工厂返回 null
 * 都会立即抛 {@link PoolStateException}。未归还的租约可通过 {@link #activeLeases()} 精确发现，
 * 并由 {@link #assertNoActiveLeases()} 在测试期转成失败。
 */
public final class ThreadLocalPool<T> implements Pool<T> {

    static final int DEFAULT_CAPACITY = 64;

    private final Supplier<? extends T> factory;
    private final Recycler<? super T> recycler;
    private final int capacity;
    private final ThreadLocal<ThreadState<T>> states;

    private final LongAdder borrows = new LongAdder();
    private final LongAdder returns = new LongAdder();
    private final LongAdder live = new LongAdder();

    ThreadLocalPool(Supplier<? extends T> factory, Recycler<? super T> recycler, int capacity) {
        if (capacity <= 0) {
            throw new IllegalArgumentException("capacity must be > 0, got " + capacity);
        }
        this.factory = Objects.requireNonNull(factory, "factory");
        this.recycler = Objects.requireNonNull(recycler, "recycler");
        this.capacity = capacity;
        this.states = ThreadLocal.withInitial(() -> new ThreadState<>(capacity));
    }

    @Override
    public Lease<T> borrow() {
        ThreadState<T> state = states.get();
        LeaseImpl<T> lease = state.takeLease(this);
        T value = state.takeValue();
        if (value == null) {
            try {
                value = factory.get();
            } catch (RuntimeException e) {
                state.offerLease(lease);
                throw e;
            }
            if (value == null) {
                state.offerLease(lease);
                throw new PoolStateException("factory returned null");
            }
        }
        borrows.increment();
        live.increment();
        lease.activate(value, state);
        return lease;
    }

    private void returnValue(T value, ThreadState<T> state) {
        try {
            recycler.recycle(value);
        } finally {
            returns.increment();
            live.decrement();
        }
        if (state.size < capacity) {
            state.values[state.size++] = value;
        }
        // 超过上限直接丢弃，保证有界
    }

    @Override
    public int capacity() {
        return capacity;
    }

    @Override
    public int idleCount() {
        return states.get().size;
    }

    @Override
    public long activeLeases() {
        return live.sum();
    }

    @Override
    public long borrowCount() {
        return borrows.sum();
    }

    @Override
    public long returnCount() {
        return returns.sum();
    }

    static final class LeaseImpl<T> implements Lease<T> {

        private final ThreadLocalPool<T> owner;
        private T value;
        private ThreadState<T> state;
        private Thread borrower;
        private boolean active;

        LeaseImpl(ThreadLocalPool<T> owner) {
            this.owner = owner;
        }

        void activate(T value, ThreadState<T> state) {
            this.value = value;
            this.state = state;
            this.borrower = Thread.currentThread();
            this.active = true;
        }

        @Override
        public T get() {
            checkUsable();
            return value;
        }

        @Override
        public void close() {
            if (!active) {
                throw new PoolStateException("lease already returned (double close)");
            }
            Thread current = Thread.currentThread();
            if (current != borrower) {
                throw new PoolStateException("cross-thread return: borrowed on "
                        + borrower.getName() + ", closed on " + current.getName());
            }
            active = false;
            T v = value;
            ThreadState<T> s = state;
            value = null;
            state = null;
            borrower = null;
            try {
                owner.returnValue(v, s);
            } finally {
                s.offerLease(this);
            }
        }

        private void checkUsable() {
            if (!active) {
                throw new PoolStateException("lease is closed; get() after close()");
            }
            if (Thread.currentThread() != borrower) {
                throw new PoolStateException("lease used off its borrowing thread");
            }
        }
    }

    /** 每线程的空闲对象栈与空闲租约栈；两个栈都以 Object[] 承载，避免泛型数组分配。 */
    static final class ThreadState<T> {

        final Object[] values;
        private final Object[] leases;
        int size;
        private int leaseSize;

        ThreadState(int capacity) {
            values = new Object[capacity];
            leases = new Object[capacity];
        }

        @SuppressWarnings("unchecked")
        T takeValue() {
            if (size == 0) {
                return null;
            }
            int i = --size;
            T v = (T) values[i];
            values[i] = null;
            return v;
        }

        @SuppressWarnings("unchecked")
        LeaseImpl<T> takeLease(ThreadLocalPool<T> owner) {
            if (leaseSize == 0) {
                return new LeaseImpl<>(owner);
            }
            int i = --leaseSize;
            LeaseImpl<T> l = (LeaseImpl<T>) leases[i];
            leases[i] = null;
            return l;
        }

        void offerLease(LeaseImpl<T> lease) {
            if (leaseSize < leases.length) {
                leases[leaseSize++] = lease;
            }
        }
    }
}
