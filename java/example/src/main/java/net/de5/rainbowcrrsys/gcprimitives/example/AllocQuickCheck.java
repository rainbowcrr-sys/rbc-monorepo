package net.de5.rainbowcrrsys.gcprimitives.example;

import net.de5.rainbowcrrsys.gcprimitives.Lease;
import net.de5.rainbowcrrsys.gcprimitives.Pool;
import net.de5.rainbowcrrsys.gcprimitives.Pools;

import com.sun.management.ThreadMXBean;

import java.lang.management.ManagementFactory;

/**
 * 不依赖 JMH 的分配量快检：用 ThreadMXBean 对照「每次 new」与「池化借用」的已分配字节数。
 * 正式基准请用 :benchmarks:jmh 的 -prof gc。
 */
public final class AllocQuickCheck {

    private static volatile String sink;
    private static final int N = 1_000_000;

    private AllocQuickCheck() {
    }

    public static void main(String[] args) {
        ThreadMXBean bean = (ThreadMXBean) ManagementFactory.getThreadMXBean();
        bean.setThreadAllocatedMemoryEnabled(true);
        long tid = Thread.currentThread().getId();

        Pool<StringBuilder> pool = Pools.threadLocal(StringBuilder::new, sb -> sb.setLength(0), 16);

        // 预热，让 JIT 稳定
        for (int r = 0; r < 3; r++) {
            runFresh(100_000);
            runPooled(pool, 100_000);
        }

        long beforeFresh = bean.getThreadAllocatedBytes(tid);
        runFresh(N);
        long freshBytes = bean.getThreadAllocatedBytes(tid) - beforeFresh;

        long beforePooled = bean.getThreadAllocatedBytes(tid);
        runPooled(pool, N);
        long pooledBytes = bean.getThreadAllocatedBytes(tid) - beforePooled;

        System.out.printf("N=%d%n", N);
        System.out.printf("fresh : %10d bytes (%6.2f MB)%n", freshBytes, freshBytes / 1048576.0);
        System.out.printf("pooled: %10d bytes (%6.2f MB)%n", pooledBytes, pooledBytes / 1048576.0);
        System.out.printf("ratio : %.3f%n", (double) pooledBytes / freshBytes);
        System.out.printf("active=%d borrows=%d returns=%d%n",
                pool.activeLeases(), pool.borrowCount(), pool.returnCount());
    }

    private static void runFresh(int n) {
        for (int i = 0; i < n; i++) {
            StringBuilder sb = new StringBuilder();
            sb.append("item-").append(i);
            sink = sb.toString();
        }
    }

    private static void runPooled(Pool<StringBuilder> pool, int n) {
        for (int i = 0; i < n; i++) {
            try (Lease<StringBuilder> lease = pool.borrow()) {
                StringBuilder sb = lease.get();
                sb.append("item-").append(i);
                sink = sb.toString();
            }
        }
    }
}
