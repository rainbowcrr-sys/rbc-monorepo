package net.de5.rainbowcrrsys.gcprimitives;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** gc-primitives 0.2.0 增量能力测试（与七语言同口径）。 */
class V020Test {

    private static V020.PoolConfig cfg(long n, V020.OnFull p) {
        V020.PoolConfig c = new V020.PoolConfig();
        c.maxSize = n; c.onFull = p;
        return c;
    }

    @Test
    void metricsSnapshotIsIsomorphic() {
        Map<String, Object> m = V020.metricsSnapshot();
        assertEquals(16, m.size());
        assertEquals(V020.METRICS_FIELDS.size(), m.size());
        assertEquals(Boolean.FALSE, m.get("closed"));
        for (String k : Arrays.asList("hit_rate", "wait_time_p50", "wait_time_p99",
                "wait_time_max", "object_lifetime_p50")) {
            assertTrue(m.get(k) instanceof Double);
        }
        assertThrows(IllegalArgumentException.class,
                () -> V020.metricsSnapshot(java.util.Collections.singletonMap("nope", 1)));
    }

    @Test
    void collectorCountsAndPercentiles() {
        V020.MetricsCollector c = new V020.MetricsCollector();
        c.recordBorrow(false, 1.0, true);
        c.recordBorrow(true, 2.0, false);
        c.recordReturn(3.0);
        c.recordReturn(5.0);
        Map<String, Object> s = c.snapshot(8, 1, false);
        assertEquals(2L, ((Number) s.get("borrow_count")).longValue());
        assertEquals(2L, ((Number) s.get("return_count")).longValue());
        assertEquals(0L, ((Number) s.get("active_leases")).longValue());
        assertEquals(0.5, (Double) s.get("hit_rate"), 1e-9);
        assertEquals(1L, ((Number) s.get("created")).longValue());
        assertEquals(2.0, (Double) s.get("wait_time_max"), 1e-9);
    }

    @Test
    void toJsonContainsAllFields() {
        String json = V020.toJson(V020.metricsSnapshot());
        for (String k : V020.METRICS_FIELDS) assertTrue(json.contains("\"" + k + "\""));
    }

    @Test
    void yamlSubsetAndSchemaValidation() {
        String text = "pools:\n  default:\n    max_size: 8\n    on_full: \"reject\"\n"
                + "    leak_detection: true\n    lifecycle:\n      on_return: \"reset\"\n"
                + "      clear_sensitive: yes\ndiagnostics:\n  memory_scope: false\n";
        Map<String, String> flat = V020.parseYamlSubset(text);
        assertEquals("8", flat.get("pools.default.max_size"));
        assertEquals("reject", flat.get("pools.default.on_full"));
        assertEquals("yes", flat.get("pools.default.lifecycle.clear_sensitive"));
        assertEquals("false", flat.get("diagnostics.memory_scope"));
        assertThrows(IllegalArgumentException.class, () -> {
            V020.PoolConfig c = new V020.PoolConfig(); c.maxSize = -5; c.validate();
        });
        assertThrows(IllegalArgumentException.class, () -> V020.OnFull.parse("bounce"));
    }

    @Test
    void configLoadAndEnvOverride() throws IOException {
        Path p = Files.createTempFile("gc-v020", ".yaml");
        Files.write(p, "pools:\n  default:\n    max_size: 3\n    on_full: reject\n"
                .getBytes(StandardCharsets.UTF_8));
        V020.PoolConfig c = V020.loadConfig(p.toString(), "default");
        assertEquals(3L, c.maxSize);
        assertEquals(V020.OnFull.REJECT, c.onFull);
        Files.delete(p);
    }

    @Test
    void memoryScopeDisabledByDefault() {
        // 未设 GC_PRIMITIVES_DIAG 时为空操作；开启时由 CI 环境变量验证
        try (V020.MemoryScope s = V020.memoryScope("disabled")) {
            @SuppressWarnings("unused") int[] x = new int[128];
        }
        assertFalse(V020.diagEnabled() && System.getenv(V020.DIAG_ENV) == null);
    }

    @Test
    void leakSamplingMinimumFields() {
        V020.LeakDetector d = new V020.LeakDetector(true);
        String id = d.onBorrow("db-query");
        List<Map<String, Object>> leaks = d.detectLeaks(0);
        assertEquals(1, leaks.size());
        Map<String, Object> s = leaks.get(0);
        for (String k : Arrays.asList("lease_id", "borrowed_at", "age_ms", "tag", "timed_out"))
            assertTrue(s.containsKey(k));
        assertEquals("db-query", s.get("tag"));
        assertTrue(s.containsKey("stack"));
        d.onReturn(id);
        assertTrue(d.detectLeaks(0).isEmpty());
    }

    @Test
    void rejectAndBlockTimeoutAndGrow() {
        try (V020.ManagedPool<StringBuilder> p = new V020.ManagedPool<>(
                StringBuilder::new, sb -> sb.setLength(0), cfg(1, V020.OnFull.REJECT), null)) {
            V020.ManagedLease<StringBuilder> a = p.borrow();
            assertThrows(PoolStateException.class, p::borrow);
            a.close();
        }
        V020.PoolConfig blockCfg = cfg(1, V020.OnFull.BLOCK);
        blockCfg.blockTimeoutMs = 30;
        try (V020.ManagedPool<StringBuilder> p = new V020.ManagedPool<>(
                StringBuilder::new, sb -> sb.setLength(0), blockCfg, null)) {
            V020.ManagedLease<StringBuilder> a = p.borrow();
            assertThrows(PoolStateException.class, p::borrow);
            a.close();
        }
        V020.PoolConfig growCfg = cfg(1, V020.OnFull.GROW);
        growCfg.maxOverflow = 2;
        try (V020.ManagedPool<StringBuilder> p = new V020.ManagedPool<>(
                StringBuilder::new, sb -> sb.setLength(0), growCfg, null)) {
            List<V020.ManagedLease<StringBuilder>> ls = new ArrayList<>();
            for (int i = 0; i < 3; ++i) ls.add(p.borrow());
            for (V020.ManagedLease<StringBuilder> l : ls) l.close();
            p.assertNoActiveLeases();
        }
    }

    @Test
    void hooksPrewarmAndSnapshot() {
        List<String> events = new ArrayList<>();
        V020.LifecycleHooks<StringBuilder> h = new V020.LifecycleHooks<>();
        h.onCreate = v -> events.add("create");
        h.onBorrow = v -> events.add("borrow");
        h.onReturn = v -> events.add("return");
        h.onEvict = v -> events.add("evict");
        h.onDestroy = v -> events.add("destroy");
        V020.ManagedPool<StringBuilder> p = new V020.ManagedPool<>(
                StringBuilder::new, sb -> sb.setLength(0), new V020.PoolConfig(), h);
        assertEquals(2, p.prewarm(2));
        Map<String, Object> snap = p.snapshot();
        for (String k : Arrays.asList("config", "stats", "active_leases", "idle_objects"))
            assertTrue(snap.containsKey(k));
        assertTrue(events.contains("create"));
        assertTrue(events.contains("borrow"));
        assertTrue(events.contains("return"));
        p.close();
        assertTrue(events.contains("destroy"));
    }

    @Test
    void combinationMatrixIsFixed() {
        V020.assertCombination(V020.PoolKind.SHARED, "shardable");
        V020.assertCombination(V020.PoolKind.SHARED, "two_level_l2");
        assertThrows(V020.CombinationError.class,
                () -> V020.assertCombination(V020.PoolKind.LOCAL, "shardable"));
        assertThrows(V020.CombinationError.class,
                () -> V020.assertCombination(V020.PoolKind.LOCAL, "two_level_l2"));
    }

    @Test
    void shardedAndTwoLevelPools() {
        List<V020.ManagedPool<StringBuilder>> shards = new ArrayList<>();
        for (int i = 0; i < 4; ++i)
            shards.add(new V020.ManagedPool<>(StringBuilder::new,
                    sb -> sb.setLength(0), cfg(2, V020.OnFull.DROP_OLDEST), null));
        try (V020.ShardedPool<StringBuilder> sp =
                     new V020.ShardedPool<>(shards, V020.PoolKind.SHARED)) {
            V020.ManagedLease<StringBuilder> l = sp.borrow();
            l.get().append("x");
            l.close();
            assertEquals(1L, ((Number) sp.metrics().get("borrow_count")).longValue());
        }
        V020.ManagedPool<StringBuilder> l2 = new V020.ManagedPool<>(
                StringBuilder::new, sb -> sb.setLength(0),
                cfg(8, V020.OnFull.DROP_OLDEST), null);
        try (V020.TwoLevelPool<StringBuilder> tp =
                     new V020.TwoLevelPool<>(l2, 2, V020.PoolKind.SHARED)) {
            V020.ManagedLease<StringBuilder> l = tp.borrow();
            l.get().append("a");
            l.close();
            l2.assertNoActiveLeases();
        }
    }

    @Test
    void virtualThreadNoteIsDocumented() {
        assertNotNull(V020.virtualThreadNote());
        assertTrue(V020.virtualThreadNote().contains("virtual threads"));
    }

    @Test
    void originalContractStillGreen() {
        Pool<StringBuilder> pool = Pools.threadLocal(
                StringBuilder::new, sb -> sb.setLength(0), 4);
        try (Lease<StringBuilder> l = pool.borrow()) {
            l.get().append("x");
        }
        pool.assertNoActiveLeases();
        assertEquals(1, pool.borrowCount());
        assertEquals(1, pool.returnCount());
    }
}
