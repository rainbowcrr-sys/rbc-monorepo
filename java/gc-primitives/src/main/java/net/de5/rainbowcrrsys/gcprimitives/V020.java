package net.de5.rainbowcrrsys.gcprimitives;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.locks.Condition;
import java.util.concurrent.locks.ReentrantLock;
import java.util.function.Consumer;
import java.util.function.Supplier;
import java.util.stream.Collectors;

/**
 * gc-primitives 0.2.0 · 纯增量能力层（不改动 {@link Pool} / {@link ThreadLocalPool}）。
 *
 * <p>实现 SPEC.md 第 12 章：统一 metrics JSON 同构快照、memory_scope、泄漏采样、
 * 统一 YAML 子集配置 + schema + env 覆盖 + 级联 + 自动热重载（Java 档）、
 * 满池策略 / 生命周期钩子 / 预热 / 快照、ShardedPool / TwoLevelPool 组合矩阵、
 * 虚拟线程说明（见类尾 {@link #virtualThreadNote()}）。
 *
 * <p>核心零依赖：只用 JDK 标准库。{@code GC_PRIMITIVES_DIAG} 未设时 memory_scope 为空操作。
 */
public final class V020 {

    public static final String DIAG_ENV = "GC_PRIMITIVES_DIAG";
    public static final String CONFIG_ENV = "GC_PRIMITIVES_CONFIG";
    /** 借出采样最小集在七语言都可用；调用栈快照是 Python / Go / Java 的可选增强。 */
    public static final boolean DETECT_LEAKS_AVAILABLE = true;

    private V020() {}

    // ------------------------------------------------------------------
    // 12.3 统一 metrics JSON 同构快照（16 字段，七语言同名）
    // ------------------------------------------------------------------

    public static final List<String> METRICS_FIELDS = Collections.unmodifiableList(Arrays.asList(
            "borrow_count", "return_count", "active_leases",
            "pool_hits", "pool_misses", "hit_rate",
            "wait_time_p50", "wait_time_p99", "wait_time_max",
            "object_lifetime_p50", "eviction_count", "leak_count",
            "created", "idle", "capacity", "closed"));

    /** 统一快照：未知键报错，字段不许省略。 */
    public static Map<String, Object> metricsSnapshot(Map<String, Object> overrides) {
        Map<String, Object> m = new LinkedHashMap<>();
        for (String k : METRICS_FIELDS) {
            if (k.equals("closed")) m.put(k, Boolean.FALSE);
            else if (k.equals("hit_rate") || k.startsWith("wait_time")
                    || k.startsWith("object_lifetime")) m.put(k, 0.0);
            else m.put(k, 0L);
        }
        if (overrides != null) {
            for (String k : overrides.keySet()) {
                if (!METRICS_FIELDS.contains(k))
                    throw new IllegalArgumentException("unknown metrics field: " + k);
            }
            m.putAll(overrides);
        }
        return m;
    }

    public static Map<String, Object> metricsSnapshot() { return metricsSnapshot(null); }

    public static final class MetricsCollector {
        private final Object lock = new Object();
        private final Map<String, Object> m = metricsSnapshot();
        private final List<Double> waits = new ArrayList<>();
        private final List<Double> lifetimes = new ArrayList<>();

        private void inc(String k, long n) {
            synchronized (lock) { m.put(k, ((Number) m.get(k)).longValue() + n); }
        }

        public void recordBorrow(boolean hit, double waitMs, boolean created) {
            synchronized (lock) {
                inc("borrow_count", 1); inc("active_leases", 1);
                inc(hit ? "pool_hits" : "pool_misses", 1);
                if (created) inc("created", 1);
                waits.add(waitMs);
            }
        }
        public void recordReturn(double lifetimeMs) {
            synchronized (lock) {
                inc("return_count", 1); inc("active_leases", -1);
                lifetimes.add(lifetimeMs);
            }
        }
        public void recordEviction() { inc("eviction_count", 1); }
        public void recordLeak(long n) { inc("leak_count", n); }

        public Map<String, Object> snapshot(long capacity, long idle, boolean closed) {
            synchronized (lock) {
                Map<String, Object> out = new LinkedHashMap<>(m);
                List<Double> w = new ArrayList<>(waits), l = new ArrayList<>(lifetimes);
                Collections.sort(w); Collections.sort(l);
                long total = ((Number) out.get("pool_hits")).longValue()
                        + ((Number) out.get("pool_misses")).longValue();
                out.put("hit_rate", total == 0 ? 0.0
                        : ((Number) out.get("pool_hits")).doubleValue() / total);
                out.put("wait_time_p50", pct(w, .50));
                out.put("wait_time_p99", pct(w, .99));
                out.put("wait_time_max", w.isEmpty() ? 0.0 : w.get(w.size() - 1));
                out.put("object_lifetime_p50", pct(l, .50));
                out.put("capacity", capacity);
                out.put("idle", idle);
                out.put("closed", closed);
                return out;
            }
        }
        private static double pct(List<Double> sorted, double q) {
            if (sorted.isEmpty()) return 0.0;
            return sorted.get((int) Math.round((sorted.size() - 1) * q));
        }
    }

    /** 统一 JSON 序列化（零依赖）。 */
    @SuppressWarnings("unchecked")
    public static String toJson(Map<String, ?> map) {
        StringBuilder b = new StringBuilder("{");
        boolean first = true;
        for (Map.Entry<String, ?> e : map.entrySet()) {
            if (!first) b.append(',');
            first = false;
            b.append('"').append(e.getKey()).append("\":");
            Object v = e.getValue();
            if (v instanceof Map) b.append(toJson((Map<String, ?>) v));
            else if (v instanceof List) {
                b.append('[');
                boolean f2 = true;
                for (Object x : (List<?>) v) {
                    if (!f2) b.append(',');
                    f2 = false;
                    if (x instanceof Map) b.append(toJson((Map<String, ?>) x));
                    else b.append(jsonValue(x));
                }
                b.append(']');
            } else b.append(jsonValue(v));
        }
        return b.append('}').toString();
    }

    private static String jsonValue(Object v) {
        if (v == null) return "null";
        if (v instanceof Boolean || v instanceof Number) return String.valueOf(v);
        return "\"" + String.valueOf(v).replace("\\", "\\\\").replace("\"", "\\\"") + "\"";
    }

    // ------------------------------------------------------------------
    // 12.5 memory_scope
    // ------------------------------------------------------------------

    public static boolean diagEnabled() {
        String v = System.getenv(DIAG_ENV);
        if (v == null || v.isEmpty()) return false;
        String s = v.toLowerCase(Locale.ROOT);
        return !(s.equals("0") || s.equals("false") || s.equals("off"));
    }

    public static final class ScopeReport {
        public final String name;
        public final double elapsedMs;
        public final long borrowCountDelta;
        public final long createdDelta;
        ScopeReport(String n, double e, long b, long c) {
            name = n; elapsedMs = e; borrowCountDelta = b; createdDelta = c;
        }
        public Map<String, Object> toMap() {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("name", name); m.put("elapsed_ms", elapsedMs);
            m.put("borrow_count_delta", borrowCountDelta);
            m.put("created_delta", createdDelta);
            return m;
        }
    }

    /** try-with-resources；未开启时为空操作、零分配。 */
    public static final class MemoryScope implements AutoCloseable {
        private final String name;
        private final Consumer<ScopeReport> sink;
        private final String jsonPath;
        private final MetricsCollector collector;
        private final boolean active;
        private final long t0, b0, c0;

        public MemoryScope(String name, Consumer<ScopeReport> sink, String jsonPath,
                           MetricsCollector collector) {
            this.name = name; this.sink = sink; this.jsonPath = jsonPath;
            this.collector = collector;
            this.active = diagEnabled();
            this.t0 = System.nanoTime();
            if (active && collector != null) {
                Map<String, Object> s = collector.snapshot(0, 0, false);
                b0 = ((Number) s.get("borrow_count")).longValue();
                c0 = ((Number) s.get("created")).longValue();
            } else { b0 = 0; c0 = 0; }
        }

        @Override public void close() {
            if (!active) return;
            ScopeReport r = new ScopeReport(name, (System.nanoTime() - t0) / 1_000_000.0,
                    delta("borrow_count", b0), delta("created", c0));
            if (sink != null) sink.accept(r);
            else if (jsonPath != null && !jsonPath.isEmpty()) {
                try {
                    Files.write(Paths.get(jsonPath),
                            (toJson(r.toMap()) + "\n").getBytes(StandardCharsets.UTF_8),
                            java.nio.file.StandardOpenOption.CREATE,
                            java.nio.file.StandardOpenOption.APPEND);
                } catch (IOException e) { System.err.println("[gc-primitives] scope json: " + e); }
            } else {
                System.err.printf("[gc-primitives] %s: borrows=%+d created=%+d (%.2f ms)%n",
                        r.name, r.borrowCountDelta, r.createdDelta, r.elapsedMs);
            }
        }
        private long delta(String k, long base) {
            if (collector == null) return 0;
            Map<String, Object> s = collector.snapshot(0, 0, false);
            return ((Number) s.get(k)).longValue() - base;
        }
    }

    public static MemoryScope memoryScope(String name) {
        return new MemoryScope(name, null, null, null);
    }
    public static MemoryScope memoryScope(String name, Consumer<ScopeReport> sink,
                                          String jsonPath, MetricsCollector collector) {
        return new MemoryScope(name, sink, jsonPath, collector);
    }

    // ------------------------------------------------------------------
    // 12.6 泄漏检测（借出采样最小集，无后台线程）
    // ------------------------------------------------------------------

    public static final class LeaseSample {
        public final String leaseId;
        public final double borrowedAt;
        public final String tag;
        public final String stack;
        final double ageMs;
        final boolean timedOut;
        LeaseSample(String id, double at, String tag, String stack, double age, boolean out) {
            leaseId = id; borrowedAt = at; this.tag = tag; this.stack = stack;
            ageMs = age; timedOut = out;
        }
        public Map<String, Object> toMap() {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("lease_id", leaseId); m.put("borrowed_at", borrowedAt);
            m.put("age_ms", ageMs); m.put("tag", tag); m.put("timed_out", timedOut);
            if (stack != null) m.put("stack", stack);
            return m;
        }
    }

    public static final class LeakDetector {
        private final Object lock = new Object();
        private final Map<String, LeaseSample> active = new LinkedHashMap<>();
        private final AtomicLong seq = new AtomicLong();
        private final boolean captureStack;

        public LeakDetector(boolean captureStack) { this.captureStack = captureStack; }

        public String onBorrow(String tag) {
            String id = Long.toHexString(seq.incrementAndGet());
            String stack = captureStack ? stackTrace() : null;
            synchronized (lock) {
                active.put(id, new LeaseSample(id, now(), tag, stack, 0, false));
            }
            return id;
        }
        public void onReturn(String id) { synchronized (lock) { active.remove(id); } }
        public List<Map<String, Object>> detectLeaks(long timeoutMs) {
            double t = now();
            List<Map<String, Object>> out = new ArrayList<>();
            synchronized (lock) {
                for (LeaseSample s : new ArrayList<>(active.values())) {
                    double age = (t - s.borrowedAt) * 1000.0;
                    boolean out_ = timeoutMs >= 0 && age >= timeoutMs;
                    if (timeoutMs < 0 || out_) {
                        out.add(new LeaseSample(s.leaseId, s.borrowedAt, s.tag, s.stack,
                                age, out_).toMap());
                    }
                }
            }
            return out;
        }
        public int activeCount() { synchronized (lock) { return active.size(); } }
        private static double now() { return System.currentTimeMillis() / 1000.0; }
        private static String stackTrace() {
            StringBuilder b = new StringBuilder();
            for (StackTraceElement e : Thread.currentThread().getStackTrace())
                b.append("\tat ").append(e).append('\n');
            return b.toString();
        }
    }

    // ------------------------------------------------------------------
    // 12.4 统一 YAML 子集配置
    // ------------------------------------------------------------------

    public enum OnFull { DROP_OLDEST, DROP_LARGEST, BLOCK, REJECT, GROW;
        public String configName() { return name().toLowerCase(Locale.ROOT); }
        public static OnFull parse(String s) {
            for (OnFull p : values()) if (p.configName().equals(s)) return p;
            throw new IllegalArgumentException("on_full must be one of "
                    + Arrays.toString(Arrays.stream(values()).map(OnFull::configName)
                        .collect(Collectors.toList()).toArray()) + ", got: " + s);
        }
    }

    public static final List<String> LIFECYCLE_HOOKS = Collections.unmodifiableList(Arrays.asList(
            "on_create", "on_borrow", "on_return", "on_evict", "on_destroy"));

    public static final class PoolConfig {
        public long maxSize = 64;
        public OnFull onFull = OnFull.DROP_OLDEST;
        public long blockTimeoutMs = -1;   // -1 = 无超时
        public long maxOverflow = 0;
        public String evictionPolicy = "lru";
        public long prewarm = 0;
        public boolean leakDetection = false;
        public long leakTimeoutMs = 3000;
        public boolean clearSensitive = false;
        public Map<String, String> lifecycle = new LinkedHashMap<>();

        public void validate() {
            if (maxSize <= 0) throw new IllegalArgumentException("max_size must be > 0");
            if (maxOverflow < 0) throw new IllegalArgumentException("max_overflow must be >= 0");
            if (prewarm < 0) throw new IllegalArgumentException("prewarm must be >= 0");
            for (String k : lifecycle.keySet()) {
                if (!LIFECYCLE_HOOKS.contains(k) && !k.equals("clear_sensitive"))
                    throw new IllegalArgumentException("unknown lifecycle hook: " + k);
            }
        }
        public Map<String, Object> toMap() {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("max_size", maxSize); m.put("on_full", onFull.configName());
            m.put("block_timeout_ms", blockTimeoutMs); m.put("max_overflow", maxOverflow);
            m.put("eviction_policy", evictionPolicy); m.put("prewarm", prewarm);
            m.put("leak_detection", leakDetection); m.put("leak_timeout_ms", leakTimeoutMs);
            m.put("clear_sensitive", clearSensitive);
            return m;
        }
    }

    /** 极简 YAML 子集：缩进映射 + 标量，扁平化为 {@code "a.b.c"} 形式的键，映射到字符串值。零依赖。 */
    public static Map<String, String> parseYamlSubset(String text) {
        Map<String, String> out = new LinkedHashMap<>();
        List<String> pathKeys = new ArrayList<>();
        List<Integer> pathIndent = new ArrayList<>();
        String[] lines = text.split("\\R", -1);
        for (int i = 0; i < lines.length; i++) {
            String line = lines[i];
            int hash = line.indexOf('#');
            if (hash >= 0) line = line.substring(0, hash);
            String content = line.trim();
            if (content.isEmpty()) continue;
            int indent = 0;
            while (indent < line.length() && (line.charAt(indent) == ' '
                    || line.charAt(indent) == '\t')) {
                if (line.charAt(indent) == '\t')
                    throw new IllegalArgumentException("line " + (i + 1)
                            + ": tabs are not allowed for indentation");
                indent++;
            }
            int colon = content.indexOf(':');
            if (colon < 0)
                throw new IllegalArgumentException("line " + (i + 1)
                        + ": expected 'key: value'");
            String key = content.substring(0, colon).trim();
            String value = content.substring(colon + 1).trim();
            while (!pathIndent.isEmpty() && pathIndent.get(pathIndent.size() - 1) >= indent) {
                pathIndent.remove(pathIndent.size() - 1);
                pathKeys.remove(pathKeys.size() - 1);
            }
            String full = String.join(".", pathKeys);
            if (!full.isEmpty()) full += ".";
            full += key;
            if (value.isEmpty()) { pathIndent.add(indent); pathKeys.add(key); }
            else out.put(full, unquote(value));
        }
        return out;
    }

    private static String unquote(String v) {
        if (v.length() >= 2 && ((v.startsWith("\"") && v.endsWith("\""))
                || (v.startsWith("'") && v.endsWith("'"))))
            return v.substring(1, v.length() - 1);
        return v;
    }

    private static long asLong(String s, long def) {
        try { return Long.parseLong(s); } catch (NumberFormatException e) { return def; }
    }
    private static boolean asBool(String s) {
        return s.equalsIgnoreCase("true") || s.equalsIgnoreCase("yes");
    }
    private static String envOverride(String pool, String key) {
        String name = "GC_PRIMITIVES__" + pool.toUpperCase(Locale.ROOT).replace('-', '_')
                + "__" + key.toUpperCase(Locale.ROOT);
        return System.getenv(name);
    }

    private static final List<String> LEGAL_CONFIG_KEYS = Arrays.asList(
            "max_size", "on_full", "block_timeout_ms", "max_overflow",
            "eviction_policy", "prewarm", "leak_detection", "leak_timeout_ms",
            "clear_sensitive");

    /** 加载配置；找不到文件时返回默认值（配置文件可选）。 */
    public static PoolConfig loadConfig(String path, String pool) {
        String explicit = path != null && !path.isEmpty() ? path : System.getenv(CONFIG_ENV);
        Path chosen = null;
        if (explicit != null && !explicit.isEmpty()) {
            Path p = Paths.get(explicit);
            if (Files.isRegularFile(p)) chosen = p;
        } else {
            String[] cascade = {"./gc-primitives.yaml", "./config/gc-primitives.yaml",
                    System.getProperty("user.home") + "/.config/gc-primitives.yaml",
                    "/etc/gc-primitives.yaml"};
            for (String c : cascade) {
                Path p = Paths.get(c);
                if (Files.isRegularFile(p)) { chosen = p; break; }
            }
        }
        PoolConfig cfg = new PoolConfig();
        if (chosen != null) {
            try {
                Map<String, String> flat = parseYamlSubset(
                        new String(Files.readAllBytes(chosen), StandardCharsets.UTF_8));
                String prefix = "pools." + pool + ".";
                for (Map.Entry<String, String> e : flat.entrySet()) {
                    if (!e.getKey().startsWith(prefix)) continue;
                    String key = e.getKey().substring(prefix.length());
                    if (key.startsWith("lifecycle.")) {
                        cfg.lifecycle.put(key.substring(10), e.getValue());
                        continue;
                    }
                    if (!LEGAL_CONFIG_KEYS.contains(key))
                        throw new IllegalArgumentException("unknown config key: " + key);
                    apply(cfg, key, e.getValue());
                }
                if (cfg.lifecycle.containsKey("clear_sensitive"))
                    cfg.clearSensitive = asBool(cfg.lifecycle.get("clear_sensitive"));
            } catch (IOException e) {
                throw new IllegalStateException("failed to read config: " + chosen, e);
            }
        }
        for (String key : LEGAL_CONFIG_KEYS) {
            String v = envOverride(pool, key);
            if (v != null && !v.isEmpty()) apply(cfg, key, unquote(v));
        }
        cfg.validate();
        return cfg;
    }

    private static void apply(PoolConfig c, String key, String v) {
        switch (key) {
            case "max_size": c.maxSize = asLong(v, c.maxSize); break;
            case "on_full": c.onFull = OnFull.parse(v); break;
            case "block_timeout_ms": c.blockTimeoutMs = asLong(v, -1); break;
            case "max_overflow": c.maxOverflow = asLong(v, 0); break;
            case "eviction_policy": c.evictionPolicy = v; break;
            case "prewarm": c.prewarm = asLong(v, 0); break;
            case "leak_detection": c.leakDetection = asBool(v); break;
            case "leak_timeout_ms": c.leakTimeoutMs = asLong(v, 3000); break;
            case "clear_sensitive": c.clearSensitive = asBool(v); break;
            default: throw new IllegalArgumentException("unknown config key: " + key);
        }
    }

    /** 多池统一管理；Java 档支持自动文件监听（可选开启，默认零常驻开销）。 */
    public static final class PoolManager implements AutoCloseable {
        private final String path;
        private final Map<String, ManagedPool<?>> pools = new LinkedHashMap<>();
        private final Object lock = new Object();
        private volatile long lastMtime = -1;
        private volatile Thread watcher;
        private volatile boolean stopped;

        public PoolManager(String path) { this.path = path; this.lastMtime = mtime(); }

        public <T> void register(String name, ManagedPool<T> pool) {
            synchronized (lock) { pools.put(name, pool); }
        }
        @SuppressWarnings("unchecked")
        public <T> ManagedPool<T> get(String name) {
            synchronized (lock) { return (ManagedPool<T>) pools.get(name); }
        }
        private long mtime() {
            String p = path != null && !path.isEmpty() ? path : System.getenv(CONFIG_ENV);
            if (p == null || p.isEmpty()) return -1;
            try { return Files.getLastModifiedTime(Paths.get(p)).toMillis(); }
            catch (IOException e) { return -1; }
        }
        /** 手动/自动共用：mtime 未变返回 false；变更则按池重载。 */
        public boolean reload() {
            long m = mtime();
            if (m < 0) return false; // 没有配置文件可监听，保持现有配置
            if (m == lastMtime) return false;
            synchronized (lock) {
                for (Map.Entry<String, ManagedPool<?>> e : pools.entrySet())
                    e.getValue().applyConfig(loadConfig(path, e.getKey()));
            }
            lastMtime = m;
            return true;
        }
        /** Java 档：文件变更自动监听。默认不开。 */
        public void enableHotReload(long intervalMs) {
            if (watcher != null) return;
            stopped = false;
            watcher = new Thread(() -> {
                while (!stopped) {
                    try {
                        Thread.sleep(intervalMs);
                        reload();
                    } catch (InterruptedException e) { return; }
                    catch (RuntimeException e) {
                        System.err.println("[gc-primitives] hot reload failed, keeping previous config");
                    }
                }
            }, "gc-primitives-hot-reload");
            watcher.setDaemon(true);
            watcher.start();
        }
        @Override public void close() {
            stopped = true;
            synchronized (lock) { for (ManagedPool<?> p : pools.values()) p.close(); }
        }
    }

    // ------------------------------------------------------------------
    // 12.1 ManagedPool（共享、线程安全、可配置；原 Pool 一行未改）
    // ------------------------------------------------------------------

    public static final class LifecycleHooks<T> {
        public Consumer<T> onCreate, onBorrow, onReturn, onEvict, onDestroy;
        public boolean clearSensitive;
        void fire(Consumer<T> h, T v) { if (h != null) h.accept(v); }
    }

    public static final class ManagedPool<T> implements AutoCloseable {
        private final Supplier<T> factory;
        private final Consumer<T> recycler;
        private PoolConfig cfg;
        private final LifecycleHooks<T> hooks;
        private final ReentrantLock lock = new ReentrantLock();
        private final Condition cv = lock.newCondition();
        private final List<T> free = new ArrayList<>();
        private final List<String> active = new ArrayList<>();
        private boolean closed;
        private final MetricsCollector metrics = new MetricsCollector();
        private final LeakDetector leaks = new LeakDetector(true);
        private final AtomicLong seq = new AtomicLong();

        public ManagedPool(Supplier<T> factory, Consumer<T> recycler,
                           PoolConfig cfg, LifecycleHooks<T> hooks) {
            this.factory = factory; this.recycler = recycler;
            this.cfg = cfg != null ? cfg : new PoolConfig();
            this.hooks = hooks != null ? hooks : new LifecycleHooks<>();
            this.cfg.validate();
            if (this.cfg.prewarm > 0) prewarm((int) this.cfg.prewarm);
        }

        public ManagedLease<T> borrow() { return borrow(""); }

        public ManagedLease<T> borrow(String tag) {
            long t0 = System.nanoTime();
            lock.lock();
            try {
                if (closed) throw new PoolStateException("pool is closed; borrow() is no longer allowed");
                long limit = cfg.maxSize + (cfg.onFull == OnFull.GROW ? cfg.maxOverflow : 0);
                while (active.size() >= limit) {
                    if (cfg.onFull == OnFull.REJECT)
                        throw new PoolStateException("pool exhausted (on_full=reject)");
                    if (cfg.onFull == OnFull.BLOCK) {
                        if (cfg.blockTimeoutMs < 0) cv.await();
                        else if (!cv.await(cfg.blockTimeoutMs, TimeUnit.MILLISECONDS))
                            throw new PoolStateException("borrow timed out (on_full=block)");
                        continue;
                    }
                    break;
                }
                T value;
                boolean hit, created;
                if (!free.isEmpty()) {
                    value = free.remove(free.size() - 1); hit = true; created = false;
                } else {
                    value = factory.get();
                    if (value == null) throw new PoolStateException("factory returned null");
                    hit = false; created = true;
                    hooks.fire(hooks.onCreate, value);
                }
                String id = cfg.leakDetection ? leaks.onBorrow(tag)
                        : Long.toHexString(seq.incrementAndGet());
                active.add(id);
                metrics.recordBorrow(hit, (System.nanoTime() - t0) / 1_000_000.0, created);
                hooks.fire(hooks.onBorrow, value);
                return new ManagedLease<>(this, value, id, tag,
                        System.currentTimeMillis() / 1000.0);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new PoolStateException("borrow interrupted", e);
            } finally { lock.unlock(); }
        }

        void _return(T value, String id, double borrowedAt, String tag) {
            if (value == null) return;
            try {
                if (hooks.clearSensitive) hooks.fire(hooks.onReturn, value);
                if (recycler != null) recycler.accept(value);
                hooks.fire(hooks.onReturn, value);
            } catch (RuntimeException e) {
                hooks.fire(hooks.onDestroy, value);
                settle(id, borrowedAt);
                throw e;
            }
            lock.lock();
            try {
                leaks.onReturn(id);
                if (free.size() >= cfg.maxSize && cfg.onFull != OnFull.GROW) {
                    T victim = free.remove(0);
                    free.add(value);
                    hooks.fire(hooks.onEvict, victim);
                    metrics.recordEviction();
                } else free.add(value);
                settleInLock(id, borrowedAt);
                cv.signalAll();
            } finally { lock.unlock(); }
        }

        private void settleInLock(String id, double borrowedAt) {
            metrics.recordReturn((System.currentTimeMillis() / 1000.0 - borrowedAt) * 1000.0);
            active.remove(id);
        }
        private void settle(String id, double borrowedAt) {
            lock.lock();
            try { settleInLock(id, borrowedAt); cv.signalAll(); }
            finally { lock.unlock(); }
        }

        public int prewarm(int n) {
            int made = 0;
            for (int i = 0; i < n; ++i) { ManagedLease<T> l = borrow("prewarm"); l.close(); ++made; }
            return made;
        }
        public List<Map<String, Object>> detectLeaks(long timeoutMs) {
            List<Map<String, Object>> out = leaks.detectLeaks(
                    timeoutMs >= 0 ? timeoutMs : cfg.leakTimeoutMs);
            metrics.recordLeak(out.size());
            return out;
        }
        public Map<String, Object> metrics() {
            lock.lock();
            try { return metrics.snapshot(cfg.maxSize, free.size(), closed); }
            finally { lock.unlock(); }
        }
        public Map<String, Object> stats() { return metrics(); }
        public Map<String, Object> snapshot() {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("config", cfg.toMap());
            m.put("stats", metrics());
            m.put("active_leases", leaks.detectLeaks(-1));
            lock.lock();
            try { m.put("idle_objects", free.size()); }
            finally { lock.unlock(); }
            return m;
        }
        public void applyConfig(PoolConfig c) {
            c.validate();
            lock.lock();
            try { cfg = c; cv.signalAll(); }
            finally { lock.unlock(); }
        }
        public void setMaxSize(long n) {
            PoolConfig c = copyConfig(); c.maxSize = n; applyConfig(c);
        }
        private PoolConfig copyConfig() {
            PoolConfig c = new PoolConfig();
            c.maxSize = cfg.maxSize; c.onFull = cfg.onFull;
            c.blockTimeoutMs = cfg.blockTimeoutMs; c.maxOverflow = cfg.maxOverflow;
            c.evictionPolicy = cfg.evictionPolicy; c.prewarm = cfg.prewarm;
            c.leakDetection = cfg.leakDetection; c.leakTimeoutMs = cfg.leakTimeoutMs;
            c.clearSensitive = cfg.clearSensitive; c.lifecycle = new LinkedHashMap<>(cfg.lifecycle);
            return c;
        }
        public void assertNoActiveLeases() {
            lock.lock();
            try { if (!active.isEmpty())
                throw new PoolStateException(active.size() + " lease(s) not returned"); }
            finally { lock.unlock(); }
        }
        @Override public void close() {
            List<T> victims;
            lock.lock();
            try {
                if (closed) return;
                closed = true;
                victims = new ArrayList<>(free);
                free.clear();
                cv.signalAll();
            } finally { lock.unlock(); }
            for (T v : victims) hooks.fire(hooks.onDestroy, v);
        }
        public long configMaxSize() { return cfg.maxSize; }
    }

    public static final class ManagedLease<T> implements AutoCloseable {
        private final ManagedPool<T> pool;
        private T value;
        private final String id, tag;
        private final double borrowedAt;
        private boolean active = true;

        ManagedLease(ManagedPool<T> pool, T value, String id, String tag, double borrowedAt) {
            this.pool = pool; this.value = value; this.id = id;
            this.tag = tag; this.borrowedAt = borrowedAt;
        }
        public T get() {
            if (!active) throw new PoolStateException("lease is closed; get() after close()");
            return value;
        }
        @Override public void close() {
            if (!active) throw new PoolStateException("lease already returned (double close)");
            active = false;
            T v = value; value = null;
            pool._return(v, id, borrowedAt, tag);
        }
        public String leaseId() { return id; }
        public boolean isActive() { return active; }
    }

    // ------------------------------------------------------------------
    // 12.2 组合矩阵（写死）
    // ------------------------------------------------------------------

    public enum PoolKind { LOCAL, SHARED, BASE }

    public static final Map<String, Map<String, Boolean>> COMBINATION_MATRIX;
    static {
        Map<String, Map<String, Boolean>> m = new LinkedHashMap<>();
        Map<String, Boolean> local = new LinkedHashMap<>();
        local.put("standalone", true); local.put("shardable", false); local.put("two_level_l2", false);
        Map<String, Boolean> shared = new LinkedHashMap<>();
        shared.put("standalone", true); shared.put("shardable", true); shared.put("two_level_l2", true);
        Map<String, Boolean> base = new LinkedHashMap<>(shared);
        m.put("local", Collections.unmodifiableMap(local));
        m.put("shared", Collections.unmodifiableMap(shared));
        m.put("base", Collections.unmodifiableMap(base));
        COMBINATION_MATRIX = Collections.unmodifiableMap(m);
    }

    public static final class CombinationError extends IllegalArgumentException {
        private static final long serialVersionUID = 1L;
        public CombinationError(String s) { super(s); }
    }

    public static void assertCombination(PoolKind kind, String operation) {
        String k = kind.name().toLowerCase(Locale.ROOT);
        Map<String, Boolean> row = COMBINATION_MATRIX.get(k);
        if (row == null) throw new CombinationError("unknown pool kind: " + k);
        Boolean ok = row.get(operation);
        if (ok == null) throw new CombinationError("unknown operation: " + operation);
        if (!ok) throw new CombinationError("pool kind " + k + " cannot be used for " + operation);
    }

    public static final class ShardedPool<T> implements AutoCloseable {
        private final List<ManagedPool<T>> shards;
        public ShardedPool(List<ManagedPool<T>> shards, PoolKind kind) {
            assertCombination(kind, "shardable");
            if (shards.isEmpty()) throw new IllegalArgumentException("shard list must not be empty");
            this.shards = shards;
        }
        public ManagedLease<T> borrow() {
            int idx = Math.floorMod(Thread.currentThread().hashCode(), shards.size());
            return shards.get(idx).borrow();
        }
        public Map<String, Object> metrics() {
            Map<String, Object> out = metricsSnapshot();
            for (ManagedPool<T> s : shards) {
                Map<String, Object> x = s.metrics();
                for (String k : Arrays.asList("borrow_count", "return_count", "active_leases",
                        "pool_hits", "pool_misses", "eviction_count", "leak_count",
                        "created", "idle", "capacity")) {
                    out.put(k, ((Number) out.get(k)).longValue()
                            + ((Number) x.get(k)).longValue());
                }
            }
            long total = ((Number) out.get("pool_hits")).longValue()
                    + ((Number) out.get("pool_misses")).longValue();
            out.put("hit_rate", total == 0 ? 0.0
                    : ((Number) out.get("pool_hits")).doubleValue() / total);
            return out;
        }
        public Map<String, Object> stats() { return metrics(); }
        @Override public void close() { for (ManagedPool<T> s : shards) s.close(); }
    }

    public static final class TwoLevelPool<T> implements AutoCloseable {
        private final ManagedPool<T> l2;
        private final int l1Size;
        public TwoLevelPool(ManagedPool<T> l2, int l1Size, PoolKind kind) {
            assertCombination(kind, "two_level_l2");
            this.l2 = l2; this.l1Size = l1Size;
        }
        /** 统一走 L2 的真实借还，保证 C1–C5 计数精确；L1 为文档化优化预留。 */
        public ManagedLease<T> borrow() { return l2.borrow(); }
        public Map<String, Object> metrics() { return l2.metrics(); }
        public Map<String, Object> stats() { return metrics(); }
        @Override public void close() { l2.close(); }
    }

    /** 虚拟线程（Java 21+）行为说明：见 SPEC 12.1，0.2.0 不改 ThreadLocalPool 语义。 */
    public static String virtualThreadNote() {
        return "ThreadLocalPool uses ThreadLocal; in Java 21+ virtual threads each get their own "
                + "ThreadLocal state, so the per-thread bounded idle stack still applies. "
                + "Virtual threads may be mounted/unmounted on different carrier threads, but "
                + "ThreadLocal values follow the virtual thread, not the carrier. "
                + "Leases must still be used by the borrowing (virtual) thread only.";
    }
}
