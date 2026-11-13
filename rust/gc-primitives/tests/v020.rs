//! gc-primitives 0.2.0 增量能力测试（与七语言同口径）。
//! 旧 tests/contract.rs 必须同时全绿。零 unsafe、零依赖。

use std::env;
use std::fs;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use gc_primitives::v020::*;

fn cfg(n: u64, p: OnFull) -> PoolConfig {
    PoolConfig { max_size: n, on_full: p, ..PoolConfig::default() }
}
fn factory() -> Factory<String> { Arc::new(|| Some(String::new())) }
fn recycler() -> Recycler<String> {
    Arc::new(|s| { s.clear(); Ok(()) })
}

#[test]
fn metrics_fields_are_isomorphic() {
    let m = metrics_snapshot();
    assert_eq!(METRICS_FIELDS.len(), 16);
    let j = m.to_json();
    for k in METRICS_FIELDS {
        assert!(j.contains(&format!("\"{}\"", k)), "missing {}", k);
    }
    assert!(!m.closed);
}

#[test]
fn collector_counts() {
    let c = MetricsCollector::new();
    c.record_borrow(false, 1.0, true);
    c.record_borrow(true, 2.0, false);
    c.record_return(3.0);
    c.record_return(5.0);
    let s = c.snapshot(8, 1, false);
    assert_eq!(s.borrow_count, 2);
    assert_eq!(s.return_count, 2);
    assert_eq!(s.active_leases, 0);
    assert_eq!(s.pool_hits, 1);
    assert_eq!(s.created, 1);
    assert!((s.hit_rate - 0.5).abs() < 1e-9);
    assert_eq!(s.wait_time_max, 2.0);
}

#[test]
fn memory_scope_disabled_and_enabled() {
    env::remove_var(DIAG_ENV);
    assert!(MemoryScope::new("disabled", None, None, None).is_none());

    env::set_var(DIAG_ENV, "1");
    let calls = Arc::new(AtomicUsize::new(0));
    {
        let c1 = Arc::clone(&calls);
        let outer = MemoryScope::new("outer", Some(Box::new(move |_| { c1.fetch_add(1, Ordering::SeqCst); })), None, None);
        let c2 = Arc::clone(&calls);
        let inner = MemoryScope::new("inner", Some(Box::new(move |_| { c2.fetch_add(1, Ordering::SeqCst); })), None, None);
        assert!(outer.is_some() && inner.is_some());
        let _v: Vec<u8> = vec![0; 4096];
        drop(inner);   // inner 先
        drop(outer);   // outer 后
    }
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    env::remove_var(DIAG_ENV);
}

#[test]
fn leak_sampling_minimum_fields() {
    let d = LeakDetector::new();
    let id = d.on_borrow("db-query");
    let leaks = d.detect_leaks(0);
    assert_eq!(leaks.len(), 1);
    assert_eq!(leaks[0].tag, "db-query");
    assert!(!leaks[0].lease_id.is_empty());
    assert!(leaks[0].timed_out);
    let j = leaks[0].to_json();
    for k in ["lease_id", "borrowed_at", "age_ms", "tag", "timed_out"] {
        assert!(j.contains(k), "missing {}", k);
    }
    d.on_return(&id);
    assert!(d.detect_leaks(0).is_empty());
}

#[test]
fn yaml_subset_and_schema() {
    let text = concat!(
        "pools:\n",
        "  default:\n",
        "    max_size: 8\n",
        "    on_full: \"reject\"\n",
        "    leak_detection: true\n",
        "    lifecycle:\n",
        "      on_return: \"reset\"\n",
        "      clear_sensitive: yes\n",
        "diagnostics:\n",
        "  memory_scope: false\n",
    );
    let flat = parse_yaml_subset(text).unwrap();
    assert_eq!(flat.get("pools.default.max_size").unwrap(), "8");
    assert_eq!(flat.get("pools.default.on_full").unwrap(), "reject");
    assert_eq!(flat.get("pools.default.lifecycle.clear_sensitive").unwrap(), "yes");
    assert_eq!(flat.get("diagnostics.memory_scope").unwrap(), "false");

    let mut bad = PoolConfig::default(); bad.max_size = 0;
    assert!(bad.validate().is_err());
    assert!(OnFull::parse("bounce").is_err());
}

#[test]
fn config_env_override() {
    let dir = std::env::temp_dir().join(format!("gc_v020_{}", std::process::id()));
    let _ = fs::create_dir_all(&dir);
    let p = dir.join("cfg.yaml");
    fs::write(&p, "pools:\n  default:\n    max_size: 3\n    on_full: reject\n").unwrap();
    env::set_var("GC_PRIMITIVES__DEFAULT__MAX_SIZE", "17");
    let c = load_config(Some(p.to_str().unwrap()), "default").unwrap();
    assert_eq!(c.max_size, 17);
    assert_eq!(c.on_full, OnFull::Reject);
    env::remove_var("GC_PRIMITIVES__DEFAULT__MAX_SIZE");
    let _ = fs::remove_file(&p);
    let _ = fs::remove_dir(&dir);
}

#[test]
fn full_policies() {
    // reject
    let p = SharedPool::new(factory(), recycler(), cfg(1, OnFull::Reject),
                            LifecycleHooks::default()).unwrap();
    let a = p.borrow("").unwrap();
    assert!(matches!(p.borrow(""), Err(SharedError::PoolExhausted)));
    a.close().unwrap();

    // block timeout
    let c = PoolConfig { block_timeout_ms: 30, ..cfg(1, OnFull::Block) };
    let p2 = SharedPool::new(factory(), recycler(), c, LifecycleHooks::default()).unwrap();
    let b = p2.borrow("").unwrap();
    assert!(matches!(p2.borrow(""), Err(SharedError::BorrowTimeout)));
    b.close().unwrap();

    // grow
    let g = PoolConfig { max_overflow: 2, ..cfg(1, OnFull::Grow) };
    let p3 = SharedPool::new(factory(), recycler(), g, LifecycleHooks::default()).unwrap();
    let mut leases = Vec::new();
    for _ in 0..3 { leases.push(p3.borrow("").unwrap()); }
    for l in leases { l.close().unwrap(); }
    p3.assert_no_active_leases().unwrap();
}

#[test]
fn hooks_prewarm_snapshot() {
    let created = Arc::new(AtomicUsize::new(0));
    let borrowed = Arc::new(AtomicUsize::new(0));
    let destroyed = Arc::new(AtomicUsize::new(0));
    let c1 = Arc::clone(&created); let c2 = Arc::clone(&borrowed); let c3 = Arc::clone(&destroyed);
    let hooks = LifecycleHooks {
        on_create: Some(Arc::new(move |_| { c1.fetch_add(1, Ordering::SeqCst); })),
        on_borrow: Some(Arc::new(move |_| { c2.fetch_add(1, Ordering::SeqCst); })),
        on_destroy: Some(Arc::new(move |_| { c3.fetch_add(1, Ordering::SeqCst); })),
        ..LifecycleHooks::default()
    };
    let p = SharedPool::new(factory(), recycler(), PoolConfig::default(), hooks).unwrap();
    assert_eq!(p.prewarm(2).unwrap(), 2);
    let snap = p.snapshot();
    for k in ["config", "stats", "active_leases", "idle_objects"] {
        assert!(snap.contains(k), "missing {}", k);
    }
    assert!(created.load(Ordering::SeqCst) >= 1);
    assert_eq!(borrowed.load(Ordering::SeqCst), 2);
    p.close();
    assert!(destroyed.load(Ordering::SeqCst) >= 1);
}

#[test]
fn combination_matrix_is_fixed() {
    assert!(assert_combination(PoolKind::Shared, "shardable").is_ok());
    assert!(assert_combination(PoolKind::Shared, "two_level_l2").is_ok());
    assert!(assert_combination(PoolKind::Local, "shardable").is_err());
    assert!(assert_combination(PoolKind::Local, "two_level_l2").is_err());
}

#[test]
fn sharded_and_two_level() {
    let mut shards = Vec::new();
    for _ in 0..4 {
        shards.push(SharedPool::new(factory(), recycler(),
            cfg(2, OnFull::DropOldest), LifecycleHooks::default()).unwrap());
    }
    let sp = ShardedPool::new(shards, PoolKind::Shared).unwrap();
    let l = sp.borrow("").unwrap();
    l.close().unwrap();
    assert_eq!(sp.metrics().borrow_count, 1);
    sp.close();

    let l2 = SharedPool::new(factory(), recycler(),
        cfg(8, OnFull::DropOldest), LifecycleHooks::default()).unwrap();
    let tp = TwoLevelPool::new(Arc::clone(&l2), 2, PoolKind::Shared).unwrap();
    let l = tp.borrow("").unwrap();
    l.close().unwrap();
    l2.assert_no_active_leases().unwrap();
}

#[test]
fn shared_pool_is_send_sync() {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<Arc<SharedPool<String>>>();

    // 真跨线程用一次
    let p = SharedPool::new(factory(), recycler(),
        cfg(8, OnFull::Grow), LifecycleHooks::default()).unwrap();
    let mut handles = Vec::new();
    for _ in 0..4 {
        let q = Arc::clone(&p);
        handles.push(std::thread::spawn(move || {
            for _ in 0..25 {
                let mut l = q.borrow("t").unwrap();
                l.get().unwrap().push('x');
                l.close().unwrap();
            }
        }));
    }
    for h in handles { h.join().unwrap(); }
    p.assert_no_active_leases().unwrap();
    assert_eq!(p.metrics().borrow_count, 100);
}

#[test]
fn original_contract_still_green() {
    let pool = gc_primitives::Pool::<String>::with_defaults(4).unwrap();
    let len = pool.with_borrow(|s| { s.push_str("hello"); s.len() }).unwrap();
    assert_eq!(len, 5);
    pool.assert_no_active_leases().unwrap();
}
