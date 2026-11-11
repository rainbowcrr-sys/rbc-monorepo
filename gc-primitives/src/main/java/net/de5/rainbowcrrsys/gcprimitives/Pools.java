package net.de5.rainbowcrrsys.gcprimitives;

import java.util.function.Supplier;

/** {@link Pool} 的入口工厂。 */
public final class Pools {

    private Pools() {
    }

    /** 线程本地 + 有界池，指定容量。 */
    public static <T> Pool<T> threadLocal(Supplier<? extends T> factory,
                                          Recycler<? super T> recycler,
                                          int capacity) {
        return new ThreadLocalPool<>(factory, recycler, capacity);
    }

    /** 线程本地 + 有界池，使用默认容量 64。 */
    public static <T> Pool<T> threadLocal(Supplier<? extends T> factory,
                                          Recycler<? super T> recycler) {
        return threadLocal(factory, recycler, ThreadLocalPool.DEFAULT_CAPACITY);
    }

    /** 线程本地 + 有界池，归还时不复位（适用于无状态对象）。 */
    public static <T> Pool<T> threadLocal(Supplier<? extends T> factory) {
        return threadLocal(factory, Recycler.<T>noOp());
    }
}
