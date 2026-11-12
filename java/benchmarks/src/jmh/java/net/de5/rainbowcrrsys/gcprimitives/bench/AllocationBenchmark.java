package net.de5.rainbowcrrsys.gcprimitives.bench;

import net.de5.rainbowcrrsys.gcprimitives.Lease;
import net.de5.rainbowcrrsys.gcprimitives.Pool;
import net.de5.rainbowcrrsys.gcprimitives.Pools;

import org.openjdk.jmh.annotations.Benchmark;
import org.openjdk.jmh.annotations.BenchmarkMode;
import org.openjdk.jmh.annotations.Fork;
import org.openjdk.jmh.annotations.Measurement;
import org.openjdk.jmh.annotations.Mode;
import org.openjdk.jmh.annotations.OutputTimeUnit;
import org.openjdk.jmh.annotations.Scope;
import org.openjdk.jmh.annotations.State;
import org.openjdk.jmh.annotations.Warmup;

import java.util.concurrent.TimeUnit;

/**
 * 对照基准：每操作都 new 一个 StringBuilder，对比从线程池借用并归还。
 * 用 -prof gc 观察分配速率与 GC 次数的差异。
 */
@State(Scope.Thread)
@BenchmarkMode(Mode.Throughput)
@OutputTimeUnit(TimeUnit.SECONDS)
@Warmup(iterations = 3)
@Measurement(iterations = 5)
@Fork(1)
public class AllocationBenchmark {

    private final Pool<StringBuilder> pool =
            Pools.threadLocal(StringBuilder::new, sb -> sb.setLength(0), 16);

    private int counter;

    @Benchmark
    public String allocateFresh() {
        StringBuilder sb = new StringBuilder();
        sb.append("item-").append(counter++);
        return sb.toString();
    }

    @Benchmark
    public String borrowPooled() {
        try (Lease<StringBuilder> lease = pool.borrow()) {
            StringBuilder sb = lease.get();
            sb.append("item-").append(counter++);
            return sb.toString();
        }
    }
}
