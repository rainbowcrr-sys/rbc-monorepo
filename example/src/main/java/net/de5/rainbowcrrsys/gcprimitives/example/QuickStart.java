package net.de5.rainbowcrrsys.gcprimitives.example;

import net.de5.rainbowcrrsys.gcprimitives.Lease;
import net.de5.rainbowcrrsys.gcprimitives.Pool;
import net.de5.rainbowcrrsys.gcprimitives.PoolStateException;
import net.de5.rainbowcrrsys.gcprimitives.Pools;

import java.util.concurrent.atomic.AtomicReference;

/** 可运行示例，同时覆盖复用、复位、有界与四类强制校验。 */
public final class QuickStart {

    private QuickStart() {
    }

    public static void main(String[] args) throws InterruptedException {
        Pool<StringBuilder> pool = Pools.threadLocal(StringBuilder::new, sb -> sb.setLength(0), 8);

        // 1. 正常用法：try-with-resources 自动归还
        for (int i = 0; i < 10_000; i++) {
            try (Lease<StringBuilder> lease = pool.borrow()) {
                StringBuilder sb = lease.get();
                sb.append("item-").append(i);
                consume(sb);
            }
        }
        System.out.printf("borrows=%d returns=%d active=%d idle=%d%n",
                pool.borrowCount(), pool.returnCount(), pool.activeLeases(), pool.idleCount());

        // 2. 同一线程连续借用命中同一实例
        StringBuilder first;
        StringBuilder second;
        try (Lease<StringBuilder> lease = pool.borrow()) {
            first = lease.get();
        }
        try (Lease<StringBuilder> lease = pool.borrow()) {
            second = lease.get();
        }
        check(first == second, "连续借用应命中同一实例");

        // 3. 归还时 Recycler 复位
        try (Lease<StringBuilder> lease = pool.borrow()) {
            lease.get().append("dirty");
        }
        try (Lease<StringBuilder> lease = pool.borrow()) {
            check(lease.get().length() == 0, "归还时 Recycler 应清空 StringBuilder");
        }

        // 4. 强制校验：双重归还
        Lease<StringBuilder> twice = pool.borrow();
        twice.close();
        checkThrows(twice::close, PoolStateException.class, "双重归还");

        // 5. 强制校验：关闭后取用
        Lease<StringBuilder> closed = pool.borrow();
        closed.close();
        checkThrows(closed::get, PoolStateException.class, "关闭后 get()");

        // 6. 强制校验：跨线程归还
        Lease<StringBuilder> pending = pool.borrow();
        AtomicReference<Throwable> captured = new AtomicReference<>();
        Thread other = new Thread(() -> {
            try {
                pending.close();
            } catch (Throwable t) {
                captured.set(t);
            }
        }, "wrong-thread");
        other.start();
        other.join();
        check(captured.get() instanceof PoolStateException, "跨线程归还应抛 PoolStateException");
        pending.close(); // 由借用线程归还

        // 7. 有界：capacity=2 时嵌套归还 4 个对象，空闲数不超过上限
        Pool<StringBuilder> small = Pools.threadLocal(StringBuilder::new, sb -> sb.setLength(0), 2);
        Lease<StringBuilder> l1 = small.borrow();
        Lease<StringBuilder> l2 = small.borrow();
        Lease<StringBuilder> l3 = small.borrow();
        Lease<StringBuilder> l4 = small.borrow();
        l1.close();
        l2.close();
        l3.close();
        l4.close();
        check(small.idleCount() <= 2, "空闲对象数不得超过 capacity");

        // 8. 工厂返回 null
        checkThrows(() -> Pools.<StringBuilder>threadLocal(() -> null).borrow(),
                PoolStateException.class, "factory 返回 null");

        // 9. 未归还租约可被精确发现
        Pool<StringBuilder> leaky = Pools.threadLocal(StringBuilder::new, sb -> sb.setLength(0));
        Lease<StringBuilder> open = leaky.borrow();
        checkThrows(leaky::assertNoActiveLeases, PoolStateException.class, "未归还租约");
        open.close();
        leaky.assertNoActiveLeases();
        pool.assertNoActiveLeases();

        System.out.println("QuickStart OK");
    }

    private static void consume(StringBuilder sb) {
        // 真实场景里在这里使用对象；示例只保留一个不可消除的读取
        if (sb.length() < 0) {
            throw new AssertionError();
        }
    }

    private static void check(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }

    private static void checkThrows(Runnable action, Class<? extends Throwable> expected, String message) {
        try {
            action.run();
        } catch (Throwable t) {
            if (expected.isInstance(t)) {
                return;
            }
            throw new AssertionError(message + "：期望 " + expected.getSimpleName() + "，实际 " + t, t);
        }
        throw new AssertionError(message + "：未抛出异常");
    }
}
