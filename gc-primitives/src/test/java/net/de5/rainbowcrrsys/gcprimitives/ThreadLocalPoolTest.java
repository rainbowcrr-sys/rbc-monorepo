package net.de5.rainbowcrrsys.gcprimitives;

import org.junit.jupiter.api.Test;

import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ThreadLocalPoolTest {

    private static Pool<StringBuilder> pool(int capacity) {
        return Pools.threadLocal(StringBuilder::new, sb -> sb.setLength(0), capacity);
    }

    @Test
    void reusesInstanceOnSameThread() {
        Pool<StringBuilder> pool = pool(4);
        StringBuilder a;
        StringBuilder b;
        try (Lease<StringBuilder> lease = pool.borrow()) {
            a = lease.get();
        }
        try (Lease<StringBuilder> lease = pool.borrow()) {
            b = lease.get();
        }
        assertSame(a, b);
        assertEquals(2, pool.borrowCount());
        assertEquals(2, pool.returnCount());
        assertEquals(0, pool.activeLeases());
    }

    @Test
    void recyclerResetsStateOnReturn() {
        Pool<StringBuilder> pool = pool(4);
        try (Lease<StringBuilder> lease = pool.borrow()) {
            lease.get().append("dirty");
        }
        try (Lease<StringBuilder> lease = pool.borrow()) {
            assertEquals(0, lease.get().length());
        }
    }

    @Test
    void doubleCloseIsRejected() {
        Pool<StringBuilder> pool = pool(4);
        Lease<StringBuilder> lease = pool.borrow();
        lease.close();
        assertThrows(PoolStateException.class, lease::close);
        pool.assertNoActiveLeases();
    }

    @Test
    void getAfterCloseIsRejected() {
        Pool<StringBuilder> pool = pool(4);
        Lease<StringBuilder> lease = pool.borrow();
        lease.close();
        assertThrows(PoolStateException.class, lease::get);
    }

    @Test
    void crossThreadReturnIsRejected() throws InterruptedException {
        Pool<StringBuilder> pool = pool(4);
        Lease<StringBuilder> lease = pool.borrow();
        AtomicReference<Throwable> captured = new AtomicReference<>();
        Thread t = new Thread(() -> {
            try {
                lease.close();
            } catch (Throwable e) {
                captured.set(e);
            }
        });
        t.start();
        t.join();
        assertTrue(captured.get() instanceof PoolStateException);
        lease.close();
        pool.assertNoActiveLeases();
    }

    @Test
    void capacityBoundsIdleObjects() {
        Pool<StringBuilder> pool = pool(2);
        Lease<StringBuilder> l1 = pool.borrow();
        Lease<StringBuilder> l2 = pool.borrow();
        Lease<StringBuilder> l3 = pool.borrow();
        Lease<StringBuilder> l4 = pool.borrow();
        l1.close();
        l2.close();
        l3.close();
        l4.close();
        assertEquals(2, pool.capacity());
        assertTrue(pool.idleCount() <= 2);
        pool.assertNoActiveLeases();
    }

    @Test
    void nullFactoryResultIsRejected() {
        Pool<StringBuilder> pool = Pools.<StringBuilder>threadLocal(() -> null);
        assertThrows(PoolStateException.class, pool::borrow);
        pool.assertNoActiveLeases();
    }

    @Test
    void invalidCapacityIsRejected() {
        assertThrows(IllegalArgumentException.class,
                () -> Pools.threadLocal(StringBuilder::new, sb -> sb.setLength(0), 0));
    }

    @Test
    void noOpRecyclerIsUsable() {
        Pool<Object> pool = Pools.threadLocal(Object::new);
        try (Lease<Object> lease = pool.borrow()) {
            assertNotNull(lease.get());
        }
        pool.assertNoActiveLeases();
    }

    @Test
    void unreturnedLeaseIsDetectable() {
        Pool<StringBuilder> pool = pool(4);
        Lease<StringBuilder> open = pool.borrow();
        assertEquals(1, pool.activeLeases());
        assertThrows(PoolStateException.class, pool::assertNoActiveLeases);
        open.close();
        pool.assertNoActiveLeases();
    }
}
