//! 与 Java / C++ / Python 版逐条对应的契约测试。
//! 回调租约让「双重归还 / 跨线程归还 / 关闭后取用」在编译期就不存在，
//! 因此这里重点验证 Rust 版仍保留的运行时契约与跨线程行为。

use gc_primitives::{Pool, PoolError};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Arc;

fn make_pool(capacity: usize) -> Pool<String> {
    Pool::new(
        capacity,
        || Some(String::new()),
        |value| {
            value.clear();
            Ok(())
        },
    )
    .unwrap()
}

#[test]
fn reuse_returns_same_buffer_after_reset() {
    let pool = make_pool(8);
    let first = pool
        .with_borrow(|s| {
            s.push_str("dirty");
            s.as_ptr() as usize
        })
        .unwrap();
    let second = pool
        .with_borrow(|s| {
            assert!(s.is_empty(), "归还时 Recycler 应清空对象");
            s.as_ptr() as usize
        })
        .unwrap();
    assert_eq!(first, second, "同线程连续借用应命中同一实例");
    assert_eq!(pool.borrow_count(), 2);
    assert_eq!(pool.return_count(), 2);
    assert_eq!(pool.active_leases(), 0);
    pool.assert_no_active_leases().unwrap();
}

#[test]
fn diagnostics_are_precise() {
    let pool = make_pool(4);
    assert_eq!(pool.capacity(), 4);
    pool.with_borrow(|_| {
        assert_eq!(pool.active_leases(), 1);
        assert!(matches!(
            pool.assert_no_active_leases(),
            Err(PoolError::ActiveLeases(1))
        ));
    })
    .unwrap();
    assert_eq!(pool.active_leases(), 0);
    assert_eq!(pool.borrow_count(), 1);
    assert_eq!(pool.return_count(), 1);
    assert_eq!(pool.idle_count(), 1);
}

#[test]
fn invalid_capacity_is_rejected() {
    let result: Result<Pool<String>, PoolError> = Pool::new(0, || Some(String::new()), |_| Ok(()));
    assert!(matches!(result, Err(PoolError::InvalidCapacity)));
    assert!(matches!(Pool::<String>::with_defaults(0), Err(PoolError::InvalidCapacity)));
}

#[test]
fn factory_returning_none_is_rejected() {
    let pool: Pool<String> = Pool::new(4, || None, |_| Ok(())).unwrap();
    let result = pool.with_borrow(|_| ());
    assert!(matches!(result, Err(PoolError::FactoryReturnedNone)));
    assert_eq!(pool.active_leases(), 0, "失败的借用不能计入活跃租约");
    assert_eq!(pool.borrow_count(), 0);
    pool.assert_no_active_leases().unwrap();
}

#[test]
fn reentrant_borrow_is_rejected_and_flag_is_cleared() {
    let pool = make_pool(4);
    let seen = pool
        .with_borrow(|_| -> Result<(), PoolError> { pool.with_borrow(|_| ()) })
        .unwrap();
    assert!(matches!(seen, Err(PoolError::ReentrantBorrow)));
    assert_eq!(pool.active_leases(), 0);
    // 重入失败后标志必须复位，否则后续借用会一直被拒
    pool.with_borrow(|_| ()).unwrap();
}

#[test]
fn reset_failure_discards_object_and_propagates_error() {
    let pool: Pool<String> = Pool::new(
        4,
        || Some(String::from("fresh")),
        |_| Err(PoolError::ResetFailed("reset failed".to_string())),
    )
    .unwrap();
    let result = pool.with_borrow(|s| s.push('x'));
    assert!(matches!(result, Err(PoolError::ResetFailed(_))));
    assert_eq!(pool.active_leases(), 0);
    assert_eq!(pool.return_count(), 1);
    assert_eq!(pool.idle_count(), 0, "脏对象不得回池");

    let _ = pool.with_borrow(|s| assert_eq!(s, "fresh"));
    assert_eq!(pool.borrow_count(), 2, "第二次必须重新走工厂");
}

#[test]
fn panic_in_closure_still_settles_counts() {
    let pool = make_pool(4);
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        let _ = pool.with_borrow(|_| panic!("closure blew up"));
    }));
    assert!(outcome.is_err());
    assert_eq!(pool.active_leases(), 0);
    assert_eq!(pool.borrow_count(), 1);
    assert_eq!(pool.return_count(), 1);
    // 标志已清除，池仍可用
    pool.with_borrow(|_| ()).unwrap();
    assert_eq!(pool.borrow_count(), 2);
}

#[test]
fn idle_objects_stay_bounded() {
    let pool = make_pool(2);
    for _ in 0..32 {
        pool.with_borrow(|_| ()).unwrap();
    }
    assert!(pool.idle_count() <= 2);
    assert_eq!(pool.borrow_count(), 32);
    assert_eq!(pool.return_count(), 32);
    pool.assert_no_active_leases().unwrap();
}

#[test]
fn pool_is_shareable_across_threads_with_isolated_idle_stacks() {
    let pool = Arc::new(make_pool(4));
    let mut handles = Vec::new();
    for _ in 0..4 {
        let shared = Arc::clone(&pool);
        handles.push(std::thread::spawn(move || {
            shared
                .with_borrow(|s| {
                    s.push('x');
                    s.len()
                })
                .unwrap()
        }));
    }
    for handle in handles {
        assert_eq!(handle.join().unwrap(), 1);
    }
    assert_eq!(pool.borrow_count(), 4);
    assert_eq!(pool.return_count(), 4);
    assert_eq!(pool.active_leases(), 0);
    // 子线程归还的对象留在子线程 TLS，不污染主线程
    assert_eq!(pool.idle_count(), 0);
    pool.assert_no_active_leases().unwrap();
}

#[test]
fn error_display_is_human_readable() {
    assert_eq!(PoolError::InvalidCapacity.to_string(), "capacity must be > 0");
    assert_eq!(
        PoolError::FactoryReturnedNone.to_string(),
        "factory returned None"
    );
    assert!(PoolError::ActiveLeases(3).to_string().contains('3'));
}
