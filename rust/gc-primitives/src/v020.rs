//! gc-primitives 0.2.0 · 增量能力层（纯新增，不改动 `lib.rs` 的 `Pool`）。
//!
//! 实现 SPEC.md 第 12 章：统一 metrics JSON 同构快照、差值型 `memory_scope`
//! （**不挂 `#[global_allocator]`**、保持 `#![forbid(unsafe_code)]`）、泄漏采样、
//! 统一 YAML 子集配置 + schema + env + 级联 + 自动热重载（Rust 档）、
//! 满池策略 / 生命周期钩子 / 预热 / 快照、`SharedPool`(`Send + Sync`) /
//! `LocalPool` / `ShardedPool` / `TwoLevelPool` 组合矩阵。
//!
//! 零依赖：只用 `std`。`GC_PRIMITIVES_DIAG` 未设时 `memory_scope` 为空操作。

use std::collections::BTreeMap;
use std::env;
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

pub const DIAG_ENV: &str = "GC_PRIMITIVES_DIAG";
pub const CONFIG_ENV: &str = "GC_PRIMITIVES_CONFIG";
/// 借出采样最小集七语言都可用；调用栈快照是 Python / Go / Java 的可选增强。
pub const DETECT_LEAKS_AVAILABLE: bool = true;

// ---------------------------------------------------------------------------
// 12.3 统一 metrics JSON 同构快照（16 字段，七语言同名）
// ---------------------------------------------------------------------------

pub const METRICS_FIELDS: [&str; 16] = [
    "borrow_count", "return_count", "active_leases", "pool_hits", "pool_misses",
    "hit_rate", "wait_time_p50", "wait_time_p99", "wait_time_max",
    "object_lifetime_p50", "eviction_count", "leak_count", "created", "idle",
    "capacity", "closed",
];

#[derive(Debug, Clone, Default)]
pub struct Metrics {
    pub borrow_count: u64,
    pub return_count: u64,
    pub active_leases: u64,
    pub pool_hits: u64,
    pub pool_misses: u64,
    pub hit_rate: f64,
    pub wait_time_p50: f64,
    pub wait_time_p99: f64,
    pub wait_time_max: f64,
    pub object_lifetime_p50: f64,
    pub eviction_count: u64,
    pub leak_count: u64,
    pub created: u64,
    pub idle: u64,
    pub capacity: u64,
    pub closed: bool,
}

impl Metrics {
    pub fn to_json(&self) -> String {
        format!(
            concat!(
                "{{",
                "\"borrow_count\":{},\"return_count\":{},\"active_leases\":{},",
                "\"pool_hits\":{},\"pool_misses\":{},\"hit_rate\":{},",
                "\"wait_time_p50\":{},\"wait_time_p99\":{},\"wait_time_max\":{},",
                "\"object_lifetime_p50\":{},\"eviction_count\":{},\"leak_count\":{},",
                "\"created\":{},\"idle\":{},\"capacity\":{},\"closed\":{}",
                "}}"
            ),
            self.borrow_count, self.return_count, self.active_leases,
            self.pool_hits, self.pool_misses, self.hit_rate,
            self.wait_time_p50, self.wait_time_p99, self.wait_time_max,
            self.object_lifetime_p50, self.eviction_count, self.leak_count,
            self.created, self.idle, self.capacity, self.closed
        )
    }
}

pub fn metrics_snapshot() -> Metrics { Metrics::default() }

#[derive(Debug)]
pub struct MetricsCollector {
    inner: Mutex<CollectorInner>,
}

#[derive(Debug, Default)]
struct CollectorInner {
    m: Metrics,
    waits: Vec<f64>,
    lifetimes: Vec<f64>,
}

impl MetricsCollector {
    pub fn new() -> Self { Self { inner: Mutex::new(CollectorInner::default()) } }

    pub fn record_borrow(&self, hit: bool, wait_ms: f64, created: bool) {
        let mut g = self.inner.lock().unwrap();
        g.m.borrow_count += 1;
        g.m.active_leases += 1;
        if hit { g.m.pool_hits += 1 } else { g.m.pool_misses += 1 }
        if created { g.m.created += 1 }
        g.waits.push(wait_ms);
    }
    pub fn record_return(&self, lifetime_ms: f64) {
        let mut g = self.inner.lock().unwrap();
        g.m.return_count += 1;
        g.m.active_leases = g.m.active_leases.saturating_sub(1);
        g.lifetimes.push(lifetime_ms);
    }
    pub fn record_eviction(&self) { self.inner.lock().unwrap().m.eviction_count += 1; }
    pub fn record_leak(&self, n: u64) { self.inner.lock().unwrap().m.leak_count += n; }

    pub fn snapshot(&self, capacity: u64, idle: u64, closed: bool) -> Metrics {
        let mut g = self.inner.lock().unwrap();
        let mut out = g.m.clone();
        let mut w = g.waits.clone();
        let mut l = g.lifetimes.clone();
        w.sort_by(|a, b| a.partial_cmp(b).unwrap());
        l.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let total = out.pool_hits + out.pool_misses;
        out.hit_rate = if total == 0 { 0.0 } else { out.pool_hits as f64 / total as f64 };
        out.wait_time_p50 = pct(&w, 0.50);
        out.wait_time_p99 = pct(&w, 0.99);
        out.wait_time_max = w.last().copied().unwrap_or(0.0);
        out.object_lifetime_p50 = pct(&l, 0.50);
        out.capacity = capacity;
        out.idle = idle;
        out.closed = closed;
        out
    }
}
impl Default for MetricsCollector { fn default() -> Self { Self::new() } }

fn pct(sorted: &[f64], q: f64) -> f64 {
    if sorted.is_empty() { return 0.0 }
    let i = ((sorted.len() - 1) as f64 * q).round() as usize;
    sorted[i]
}

// ---------------------------------------------------------------------------
// 12.5 差值型 memory_scope（不挂全局分配器）
// ---------------------------------------------------------------------------

pub fn diag_enabled() -> bool {
    match env::var(DIAG_ENV) {
        Ok(v) => {
            let s = v.trim().to_ascii_lowercase();
            !s.is_empty() && s != "0" && s != "false" && s != "off"
        }
        Err(_) => false,
    }
}

#[derive(Debug, Clone)]
pub struct ScopeReport {
    pub name: String,
    pub elapsed_ms: f64,
    pub borrow_count_delta: i64,
    pub created_delta: i64,
}

/// 差值型作用域：只统计池内借还/新建计数，**不采集字节级分配**。
/// `GC_PRIMITIVES_DIAG` 未设时返回 `None`（空操作，零分配）。
pub struct MemoryScope<'a> {
    name: String,
    sink: Option<Box<dyn Fn(&ScopeReport) + 'a>>,
    json_path: Option<String>,
    collector: Option<&'a MetricsCollector>,
    t0: Instant,
    b0: i64,
    c0: i64,
}

impl<'a> MemoryScope<'a> {
    pub fn new(name: impl Into<String>, sink: Option<Box<dyn Fn(&ScopeReport) + 'a>>,
               json_path: Option<String>, collector: Option<&'a MetricsCollector>) -> Option<Self> {
        if !diag_enabled() { return None }
        let (b0, c0) = match collector {
            Some(c) => {
                let s = c.snapshot(0, 0, false);
                (s.borrow_count as i64, s.created as i64)
            }
            None => (0, 0),
        };
        Some(Self {
            name: name.into(), sink, json_path, collector,
            t0: Instant::now(), b0, c0,
        })
    }
    fn report(&self) -> ScopeReport {
        let (b, c) = match self.collector {
            Some(col) => {
                let s = col.snapshot(0, 0, false);
                (s.borrow_count as i64, s.created as i64)
            }
            None => (self.b0, self.c0),
        };
        ScopeReport {
            name: self.name.clone(),
            elapsed_ms: self.t0.elapsed().as_secs_f64() * 1000.0,
            borrow_count_delta: b - self.b0,
            created_delta: c - self.c0,
        }
    }
}

impl Drop for MemoryScope<'_> {
    fn drop(&mut self) {
        let r = self.report();
        if let Some(sink) = &self.sink {
            sink(&r);
        } else if let Some(path) = &self.json_path {
            let line = format!(
                "{{\"name\":\"{}\",\"elapsed_ms\":{},\"borrow_count_delta\":{},\"created_delta\":{}}}\n",
                r.name, r.elapsed_ms, r.borrow_count_delta, r.created_delta);
            use std::io::Write;
            if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(path) {
                let _ = f.write_all(line.as_bytes());
            }
        } else {
            eprintln!("[gc-primitives] {}: borrows={:+} created={:+} ({:.2} ms)",
                      r.name, r.borrow_count_delta, r.created_delta, r.elapsed_ms);
        }
    }
}

// ---------------------------------------------------------------------------
// 12.6 泄漏检测（借出采样最小集，无后台线程）
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct LeaseSample {
    pub lease_id: String,
    pub borrowed_at: f64,
    pub tag: String,
    pub age_ms: f64,
    pub timed_out: bool,
}

impl LeaseSample {
    pub fn to_json(&self) -> String {
        format!(
            "{{\"lease_id\":\"{}\",\"borrowed_at\":{},\"age_ms\":{},\"tag\":\"{}\",\"timed_out\":{}}}",
            self.lease_id, self.borrowed_at, self.age_ms, self.tag, self.timed_out)
    }
}

#[derive(Debug)]
pub struct LeakDetector {
    inner: Mutex<BTreeMap<u64, (f64, String)>>,
    seq: AtomicU64,
}

impl LeakDetector {
    pub fn new() -> Self { Self { inner: Mutex::new(BTreeMap::new()), seq: AtomicU64::new(0) } }
    pub fn on_borrow(&self, tag: impl Into<String>) -> String {
        let id = self.seq.fetch_add(1, Ordering::SeqCst) + 1;
        let mut g = self.inner.lock().unwrap();
        g.insert(id, (now_s(), tag.into()));
        format!("{:x}", id)
    }
    pub fn on_return(&self, id: &str) {
        if let Ok(n) = u64::from_str_radix(id, 16) {
            self.inner.lock().unwrap().remove(&n);
        }
    }
    pub fn detect_leaks(&self, timeout_ms: i64) -> Vec<LeaseSample> {
        let g = self.inner.lock().unwrap();
        let t = now_s();
        let mut out = Vec::new();
        for (id, (at, tag)) in g.iter() {
            let age = (t - *at) * 1000.0;
            let timed_out = timeout_ms >= 0 && age >= timeout_ms as f64;
            if timeout_ms < 0 || timed_out {
                out.push(LeaseSample {
                    lease_id: format!("{:x}", id), borrowed_at: *at,
                    tag: tag.clone(), age_ms: age, timed_out,
                });
            }
        }
        out
    }
    pub fn active_count(&self) -> usize { self.inner.lock().unwrap().len() }
}
impl Default for LeakDetector { fn default() -> Self { Self::new() } }

fn now_s() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs_f64()
}

// ---------------------------------------------------------------------------
// 12.4 统一 YAML 子集配置
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OnFull { DropOldest, DropLargest, Block, Reject, Grow }

impl OnFull {
    pub fn config_name(self) -> &'static str {
        match self {
            OnFull::DropOldest => "drop_oldest", OnFull::DropLargest => "drop_largest",
            OnFull::Block => "block", OnFull::Reject => "reject", OnFull::Grow => "grow",
        }
    }
    pub fn parse(s: &str) -> Result<Self, ConfigError> {
        match s {
            "drop_oldest" => Ok(OnFull::DropOldest), "drop_largest" => Ok(OnFull::DropLargest),
            "block" => Ok(OnFull::Block), "reject" => Ok(OnFull::Reject), "grow" => Ok(OnFull::Grow),
            _ => Err(ConfigError(format!(
                "on_full must be one of drop_oldest|drop_largest|block|reject|grow, got: {}", s))),
        }
    }
}

pub const LIFECYCLE_HOOKS: [&str; 5] =
    ["on_create", "on_borrow", "on_return", "on_evict", "on_destroy"];

#[derive(Debug, Clone)]
pub struct ConfigError(pub String);
impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result { write!(f, "{}", self.0) }
}
impl std::error::Error for ConfigError {}

#[derive(Debug, Clone)]
pub struct PoolConfig {
    pub max_size: u64,
    pub on_full: OnFull,
    pub block_timeout_ms: i64,   // -1 = 无超时
    pub max_overflow: u64,
    pub eviction_policy: String,
    pub prewarm: u64,
    pub leak_detection: bool,
    pub leak_timeout_ms: i64,
    pub clear_sensitive: bool,
    pub lifecycle: BTreeMap<String, String>,
}

impl Default for PoolConfig {
    fn default() -> Self {
        Self {
            max_size: 64, on_full: OnFull::DropOldest, block_timeout_ms: -1,
            max_overflow: 0, eviction_policy: "lru".into(), prewarm: 0,
            leak_detection: false, leak_timeout_ms: 3000, clear_sensitive: false,
            lifecycle: BTreeMap::new(),
        }
    }
}

impl PoolConfig {
    pub fn validate(&self) -> Result<(), ConfigError> {
        if self.max_size == 0 { return Err(ConfigError("max_size must be > 0".into())) }
        if self.prewarm > 1_000_000 { return Err(ConfigError("prewarm too large".into())) }
        for k in self.lifecycle.keys() {
            if !LIFECYCLE_HOOKS.contains(&k.as_str()) && k != "clear_sensitive" {
                return Err(ConfigError(format!("unknown lifecycle hook: {}", k)))
            }
        }
        Ok(())
    }
    pub fn to_json(&self) -> String {
        format!(
            concat!("{{",
                "\"max_size\":{},\"on_full\":\"{}\",\"block_timeout_ms\":{},",
                "\"max_overflow\":{},\"eviction_policy\":\"{}\",\"prewarm\":{},",
                "\"leak_detection\":{},\"leak_timeout_ms\":{},\"clear_sensitive\":{}",
            "}}"),
            self.max_size, self.on_full.config_name(), self.block_timeout_ms,
            self.max_overflow, self.eviction_policy, self.prewarm,
            self.leak_detection, self.leak_timeout_ms, self.clear_sensitive)
    }
}

/// 极简 YAML 子集：缩进映射 + 标量，扁平化为 "a.b.c" -> 值。
pub fn parse_yaml_subset(text: &str) -> Result<BTreeMap<String, String>, ConfigError> {
    let mut out = BTreeMap::new();
    let mut stack: Vec<(usize, String)> = Vec::new();
    for (i, raw) in text.lines().enumerate() {
        let line = match raw.find('#') { Some(j) => &raw[..j], None => raw };
        let content = line.trim();
        if content.is_empty() { continue }
        let indent = line.len() - line.trim_start_matches(|c| c == ' ' || c == '\t').len();
        if line[..indent].contains('\t') {
            return Err(ConfigError(format!("line {}: tabs are not allowed for indentation", i + 1)))
        }
        let colon = content.find(':')
            .ok_or_else(|| ConfigError(format!("line {}: expected 'key: value'", i + 1)))?;
        let key = content[..colon].trim().to_string();
        let value = content[colon + 1..].trim().to_string();
        while stack.last().map(|(ind, _)| *ind >= indent).unwrap_or(false) { stack.pop(); }
        let mut parts: Vec<&str> = stack.iter().map(|(_, k)| k.as_str()).collect();
        parts.push(&key);
        let full = parts.join(".");
        if value.is_empty() { stack.push((indent, key)); }
        else { out.insert(full, unquote(&value)); }
    }
    Ok(out)
}

fn unquote(v: &str) -> String {
    if v.len() >= 2 && ((v.starts_with('"') && v.ends_with('"'))
        || (v.starts_with('\'') && v.ends_with('\''))) {
        v[1..v.len() - 1].to_string()
    } else { v.to_string() }
}
fn as_u64(v: &str, def: u64) -> u64 { v.parse().unwrap_or(def) }
fn as_i64(v: &str, def: i64) -> i64 { v.parse().unwrap_or(def) }
fn as_bool(v: &str) -> bool { v.eq_ignore_ascii_case("true") || v.eq_ignore_ascii_case("yes") }

fn env_override(pool: &str, key: &str) -> Option<String> {
    let name = format!("GC_PRIMITIVES__{}__{}",
        pool.to_ascii_uppercase().replace('-', "_"), key.to_ascii_uppercase());
    env::var(name).ok()
}

const LEGAL_KEYS: [&str; 9] = ["max_size", "on_full", "block_timeout_ms",
    "max_overflow", "eviction_policy", "prewarm", "leak_detection",
    "leak_timeout_ms", "clear_sensitive"];

fn apply(cfg: &mut PoolConfig, key: &str, value: &str) -> Result<(), ConfigError> {
    match key {
        "max_size" => cfg.max_size = as_u64(value, cfg.max_size),
        "on_full" => cfg.on_full = OnFull::parse(value)?,
        "block_timeout_ms" => cfg.block_timeout_ms = as_i64(value, -1),
        "max_overflow" => cfg.max_overflow = as_u64(value, 0),
        "eviction_policy" => cfg.eviction_policy = value.to_string(),
        "prewarm" => cfg.prewarm = as_u64(value, 0),
        "leak_detection" => cfg.leak_detection = as_bool(value),
        "leak_timeout_ms" => cfg.leak_timeout_ms = as_i64(value, 3000),
        "clear_sensitive" => cfg.clear_sensitive = as_bool(value),
        _ => return Err(ConfigError(format!("unknown config key: {}", key))),
    }
    Ok(())
}

/// 加载配置；找不到文件时返回默认值（配置文件可选）。
pub fn load_config(path: Option<&str>, pool: &str) -> Result<PoolConfig, ConfigError> {
    let explicit = path.map(str::to_string).or_else(|| env::var(CONFIG_ENV).ok());
    let chosen: Option<PathBuf> = match explicit {
        Some(p) if !p.is_empty() => {
            let f = PathBuf::from(p);
            if f.is_file() { Some(f) } else { None }
        }
        _ => {
            let home = env::var("HOME").unwrap_or_default();
            ["./gc-primitives.yaml".to_string(),
             "./config/gc-primitives.yaml".to_string(),
             format!("{}/.config/gc-primitives.yaml", home),
             "/etc/gc-primitives.yaml".to_string()]
                .iter().map(|s| PathBuf::from(s.as_str())).find(|p| p.is_file())
        }
    };
    let mut cfg = PoolConfig::default();
    if let Some(f) = &chosen {
        let text = fs::read_to_string(f)
            .map_err(|e| ConfigError(format!("failed to read config: {}", e)))?;
        let flat = parse_yaml_subset(&text)?;
        let prefix = format!("pools.{}.", pool);
        for (k, v) in &flat {
            if !k.starts_with(&prefix) { continue }
            let key = &k[prefix.len()..];
            if let Some(h) = key.strip_prefix("lifecycle.") {
                cfg.lifecycle.insert(h.to_string(), v.clone());
                continue;
            }
            if !LEGAL_KEYS.contains(&key) {
                return Err(ConfigError(format!("unknown config key: {}", key)))
            }
            apply(&mut cfg, key, v)?;
        }
        if let Some(v) = cfg.lifecycle.get("clear_sensitive") {
            cfg.clear_sensitive = as_bool(v);
        }
    }
    for key in LEGAL_KEYS {
        if let Some(v) = env_override(pool, key) {
            if !v.is_empty() { apply(&mut cfg, key, &unquote(&v))?; }
        }
    }
    cfg.validate()?;
    Ok(cfg)
}

/// 多池统一管理；Rust 档支持自动文件监听（可选开启，默认零常驻开销）。
pub struct PoolManager {
    path: Option<String>,
    pools: Mutex<BTreeMap<String, Arc<SharedPool<String>>>>,
    last_mtime: Mutex<Option<SystemTime>>,
}

impl PoolManager {
    pub fn new(path: Option<&str>) -> Self {
        Self { path: path.map(str::to_string), pools: Mutex::new(BTreeMap::new()),
               last_mtime: Mutex::new(None) }
    }
    pub fn register(&self, name: &str, pool: Arc<SharedPool<String>>) {
        self.pools.lock().unwrap().insert(name.to_string(), pool);
    }
    fn mtime(&self) -> Option<SystemTime> {
        let p = self.path.clone().or_else(|| env::var(CONFIG_ENV).ok())?;
        fs::metadata(Path::new(&p)).ok()?.modified().ok()
    }
    /// 手动/自动共用：mtime 未变返回 false；变更则按池重载。
    pub fn reload(&self) -> bool {
        let mt = self.mtime();
        {
            let mut last = self.last_mtime.lock().unwrap();
            if mt.is_some() && *last == mt { return false }
            *last = mt;
        }
        let pools = self.pools.lock().unwrap();
        for (name, p) in pools.iter() {
            if let Ok(cfg) = load_config(self.path.as_deref(), name) { p.apply_config(cfg); }
        }
        true
    }
    /// Rust 档：可选后台轮询。默认不开，零常驻开销。
    pub fn enable_hot_reload(self: Arc<Self>, interval: std::time::Duration) {
        let _ = std::thread::Builder::new()
            .name("gc-primitives-hot-reload".into())
            .spawn(move || loop {
                std::thread::sleep(interval);
                let _ = self.reload();
            });
    }
}

// ---------------------------------------------------------------------------
// 12.1 SharedPool（Send + Sync）、满池策略、钩子、预热、快照
// ---------------------------------------------------------------------------

pub type Factory<T> = Arc<dyn Fn() -> Option<T> + Send + Sync + 'static>;
pub type Recycler<T> = Arc<dyn Fn(&mut T) -> Result<(), String> + Send + Sync + 'static>;

pub struct LifecycleHooks<T> {
    pub on_create: Option<Arc<dyn Fn(&T) + Send + Sync>>,
    pub on_borrow: Option<Arc<dyn Fn(&T) + Send + Sync>>,
    pub on_return: Option<Arc<dyn Fn(&T) + Send + Sync>>,
    pub on_evict: Option<Arc<dyn Fn(&T) + Send + Sync>>,
    pub on_destroy: Option<Arc<dyn Fn(&T) + Send + Sync>>,
    pub clear_sensitive: bool,
}
impl<T> Default for LifecycleHooks<T> {
    fn default() -> Self {
        Self { on_create: None, on_borrow: None, on_return: None,
               on_evict: None, on_destroy: None, clear_sensitive: false }
    }
}
impl<T> LifecycleHooks<T> {
    fn fire(h: &Option<Arc<dyn Fn(&T) + Send + Sync>>, v: &T) {
        if let Some(f) = h { f(v) }
    }
}

#[derive(Debug, Clone)]
pub enum SharedError {
    PoolClosed,
    PoolExhausted,
    BorrowTimeout,
    FactoryFailed,
    RecyclerFailed(String),
    DoubleClose,
    LeaseClosed,
    ActiveLeases(u64),
    Config(String),
}
impl fmt::Display for SharedError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SharedError::PoolClosed => write!(f, "pool is closed"),
            SharedError::PoolExhausted => write!(f, "pool exhausted (on_full=reject)"),
            SharedError::BorrowTimeout => write!(f, "borrow timed out (on_full=block)"),
            SharedError::FactoryFailed => write!(f, "factory returned None"),
            SharedError::RecyclerFailed(s) => write!(f, "recycler failed: {}", s),
            SharedError::DoubleClose => write!(f, "lease already returned (double close)"),
            SharedError::LeaseClosed => write!(f, "lease is closed"),
            SharedError::ActiveLeases(n) => write!(f, "{} lease(s) not returned", n),
            SharedError::Config(s) => write!(f, "config error: {}", s),
        }
    }
}
impl std::error::Error for SharedError {}

struct SharedInner<T> {
    cfg: PoolConfig,
    hooks: LifecycleHooks<T>,
    free: Vec<T>,
    active: Vec<String>,
    closed: bool,
}

/// 共享池：`Arc<SharedPool<T>>` 可跨线程使用，编译期即 `Send + Sync`。
pub struct SharedPool<T: Send + 'static> {
    factory: Factory<T>,
    recycler: Recycler<T>,
    inner: Mutex<SharedInner<T>>,
    cv: Condvar,
    metrics: MetricsCollector,
    leaks: LeakDetector,
    seq: AtomicU64,
}

impl<T: Send + 'static> SharedPool<T> {
    pub fn new(factory: Factory<T>, recycler: Recycler<T>,
               cfg: PoolConfig, hooks: LifecycleHooks<T>) -> Result<Arc<Self>, SharedError> {
        cfg.validate().map_err(|e| SharedError::Config(e.0))?;
        let p = Arc::new(Self {
            factory, recycler,
            inner: Mutex::new(SharedInner { cfg, hooks, free: Vec::new(),
                                            active: Vec::new(), closed: false }),
            cv: Condvar::new(), metrics: MetricsCollector::new(),
            leaks: LeakDetector::new(), seq: AtomicU64::new(0),
        });
        let n = { p.inner.lock().unwrap().cfg.prewarm };
        for _ in 0..n {
            let l = p.borrow("prewarm")?;
            l.close()?;
        }
        Ok(p)
    }

    pub fn borrow(self: &Arc<Self>, tag: &str) -> Result<SharedLease<T>, SharedError> {
        let t0 = Instant::now();
        let mut g = self.inner.lock().unwrap();
        if g.closed { return Err(SharedError::PoolClosed) }
        let limit = g.cfg.max_size +
            if g.cfg.on_full == OnFull::Grow { g.cfg.max_overflow } else { 0 };
        loop {
            if (g.active.len() as u64) < limit { break }
            match g.cfg.on_full {
                OnFull::Reject => return Err(SharedError::PoolExhausted),
                OnFull::Block => {
                    if g.cfg.block_timeout_ms < 0 { g = self.cv.wait(g).unwrap(); }
                    else {
                        let timeout = std::time::Duration::from_millis(
                            g.cfg.block_timeout_ms as u64);
                        let (guard, res) = self.cv.wait_timeout(g, timeout).unwrap();
                        g = guard;
                        if res.timed_out() { return Err(SharedError::BorrowTimeout) }
                    }
                    continue;
                }
                _ => break, // drop_* / grow 在归还侧处理
            }
        }
        let hit;
        let created;
        let value = if let Some(v) = g.free.pop() { hit = true; created = false; v }
        else {
            let v = (self.factory)().ok_or(SharedError::FactoryFailed)?;
            hit = false; created = true;
            LifecycleHooks::fire(&g.hooks.on_create, &v);
            v
        };
        let id = if g.cfg.leak_detection { self.leaks.on_borrow(tag) }
                 else { format!("{:x}", self.seq.fetch_add(1, Ordering::SeqCst) + 1) };
        g.active.push(id.clone());
        let wait = t0.elapsed().as_secs_f64() * 1000.0;
        self.metrics.record_borrow(hit, wait, created);
        LifecycleHooks::fire(&g.hooks.on_borrow, &value);
        drop(g);
        Ok(SharedLease { pool: Arc::clone(self), value: Some(value), id,
                         borrowed_at: now_s(), active: true })
    }

    fn release(&self, mut value: T, id: &str, borrowed_at: f64) -> Result<(), SharedError> {
        {
            let g = self.inner.lock().unwrap();
            if g.hooks.clear_sensitive {
                LifecycleHooks::fire(&g.hooks.on_return, &value);
            }
        }
        if let Err(e) = (self.recycler)(&mut value) {
            let g = self.inner.lock().unwrap();
            LifecycleHooks::fire(&g.hooks.on_destroy, &value);
            drop(g);
            self.settle(id, borrowed_at);
            return Err(SharedError::RecyclerFailed(e))
        }
        {
            let g = self.inner.lock().unwrap();
            LifecycleHooks::fire(&g.hooks.on_return, &value);
        }
        let mut g = self.inner.lock().unwrap();
        self.leaks.on_return(id);
        if (g.free.len() as u64) >= g.cfg.max_size && g.cfg.on_full != OnFull::Grow {
            let victim = g.free.remove(0);
            g.free.push(value);
            LifecycleHooks::fire(&g.hooks.on_evict, &victim);
            self.metrics.record_eviction();
        } else {
            g.free.push(value);
        }
        g.active.retain(|x| x != id);
        self.metrics.record_return((now_s() - borrowed_at) * 1000.0);
        self.cv.notify_all();
        Ok(())
    }

    fn settle(&self, id: &str, borrowed_at: f64) {
        let mut g = self.inner.lock().unwrap();
        g.active.retain(|x| x != id);
        self.metrics.record_return((now_s() - borrowed_at) * 1000.0);
        self.cv.notify_all();
    }

    pub fn prewarm(self: &Arc<Self>, n: usize) -> Result<usize, SharedError> {
        let mut made = 0;
        for _ in 0..n { let l = self.borrow("prewarm")?; l.close()?; made += 1 }
        Ok(made)
    }
    pub fn detect_leaks(&self, timeout_ms: i64) -> Vec<LeaseSample> {
        let out = self.leaks.detect_leaks(timeout_ms);
        self.metrics.record_leak(out.len() as u64);
        out
    }
    pub fn metrics(&self) -> Metrics {
        let g = self.inner.lock().unwrap();
        self.metrics.snapshot(g.cfg.max_size, g.free.len() as u64, g.closed)
    }
    pub fn stats(&self) -> Metrics { self.metrics() }
    pub fn snapshot(&self) -> String {
        let g = self.inner.lock().unwrap();
        let leaks = self.leaks.detect_leaks(-1);
        let arr: Vec<String> = leaks.iter().map(|s| s.to_json()).collect();
        format!("{{\"config\":{},\"stats\":{},\"active_leases\":[{}],\"idle_objects\":{}}}",
            g.cfg.to_json(), self.metrics.snapshot(g.cfg.max_size, g.free.len() as u64, g.closed).to_json(),
            arr.join(","), g.free.len())
    }
    pub fn apply_config(&self, cfg: PoolConfig) {
        let _ = cfg.validate();
        let mut g = self.inner.lock().unwrap();
        g.cfg = cfg;
        self.cv.notify_all();
    }
    pub fn set_max_size(&self, n: u64) {
        let mut g = self.inner.lock().unwrap();
        g.cfg.max_size = n;
        self.cv.notify_all();
    }
    pub fn close(&self) {
        let (victims, on_destroy) = {
            let mut g = self.inner.lock().unwrap();
            if g.closed { return }
            g.closed = true;
            let v: Vec<T> = g.free.drain(..).collect();
            (v, g.hooks.on_destroy.clone())
        };
        self.cv.notify_all();
        for v in &victims { LifecycleHooks::fire(&on_destroy, v) }
    }
    pub fn assert_no_active_leases(&self) -> Result<(), SharedError> {
        let n = self.inner.lock().unwrap().active.len() as u64;
        if n != 0 { Err(SharedError::ActiveLeases(n)) } else { Ok(()) }
    }
}

/// RAII 租约：引用逃不出 `get()` 的 `&mut`，关闭后取用报错。
pub struct SharedLease<T: Send + 'static> {
    pool: Arc<SharedPool<T>>,
    value: Option<T>,
    id: String,
    borrowed_at: f64,
    active: bool,
}

impl<T: Send + 'static> SharedLease<T> {
    pub fn get(&mut self) -> Result<&mut T, SharedError> {
        if let Some(v) = self.value.as_mut() { Ok(v) }
        else { Err(SharedError::LeaseClosed) }
    }
    pub fn close(mut self) -> Result<(), SharedError> {
        if !self.active { return Err(SharedError::DoubleClose) }
        self.active = false;
        let v = self.value.take().unwrap();
        self.pool.release(v, &self.id, self.borrowed_at)
    }
    pub fn lease_id(&self) -> &str { &self.id }
}
impl<T: Send + 'static> Drop for SharedLease<T> {
    fn drop(&mut self) {
        if self.active {
            self.active = false;
            if let Some(v) = self.value.take() {
                let _ = self.pool.release(v, &self.id, self.borrowed_at);
            }
        }
    }
}

/// `LocalPool` 即 `crate::Pool<T>`（thread-local，不可分片 / 不可作 L2）。
/// 这里不定义 type alias，避免 `T: 'static` 在 alias 上的 WF 限制；
/// 组合矩阵用 [`PoolKind::Local`] 表达，见下方 `assert_combination`。

// ---------------------------------------------------------------------------
// 12.2 组合矩阵（写死）
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PoolKind { Local, Shared, Base }

pub fn assert_combination(kind: PoolKind, operation: &str) -> Result<(), String> {
    let (shardable, l2) = match kind {
        PoolKind::Local => (false, false),
        PoolKind::Shared | PoolKind::Base => (true, true),
    };
    let ok = match operation {
        "standalone" => true,
        "shardable" => shardable,
        "two_level_l2" => l2,
        _ => return Err(format!("unknown operation: {}", operation)),
    };
    if ok { Ok(()) }
    else { Err(format!("pool kind {:?} cannot be used for {}", kind, operation)) }
}

pub struct ShardedPool<T: Send + 'static> {
    shards: Vec<Arc<SharedPool<T>>>,
    next: AtomicU64,
}

impl<T: Send + 'static> ShardedPool<T> {
    pub fn new(shards: Vec<Arc<SharedPool<T>>>, kind: PoolKind) -> Result<Self, String> {
        assert_combination(kind, "shardable")?;
        if shards.is_empty() { return Err("shard list must not be empty".into()) }
        Ok(Self { shards, next: AtomicU64::new(0) })
    }
    pub fn borrow(&self, tag: &str) -> Result<SharedLease<T>, SharedError> {
        let i = (self.next.fetch_add(1, Ordering::SeqCst) as usize) % self.shards.len();
        self.shards[i].borrow(tag)
    }
    pub fn metrics(&self) -> Metrics {
        let mut out = Metrics::default();
        for s in &self.shards {
            let x = s.metrics();
            out.borrow_count += x.borrow_count; out.return_count += x.return_count;
            out.active_leases += x.active_leases; out.pool_hits += x.pool_hits;
            out.pool_misses += x.pool_misses; out.eviction_count += x.eviction_count;
            out.leak_count += x.leak_count; out.created += x.created;
            out.idle += x.idle; out.capacity += x.capacity;
        }
        let total = out.pool_hits + out.pool_misses;
        out.hit_rate = if total == 0 { 0.0 } else { out.pool_hits as f64 / total as f64 };
        out
    }
    pub fn stats(&self) -> Metrics { self.metrics() }
    pub fn close(&self) { for s in &self.shards { s.close() } }
}

pub struct TwoLevelPool<T: Send + 'static> { l2: Arc<SharedPool<T>>, _l1_size: usize }

impl<T: Send + 'static> TwoLevelPool<T> {
    pub fn new(l2: Arc<SharedPool<T>>, l1_size: usize,
               kind: PoolKind) -> Result<Self, String> {
        assert_combination(kind, "two_level_l2")?;
        Ok(Self { l2, _l1_size: l1_size })
    }
    pub fn borrow(&self, tag: &str) -> Result<SharedLease<T>, SharedError> { self.l2.borrow(tag) }
    pub fn metrics(&self) -> Metrics { self.l2.metrics() }
    pub fn stats(&self) -> Metrics { self.metrics() }
    pub fn close(&self) { self.l2.close() }
}
