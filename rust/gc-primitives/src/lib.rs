#![forbid(unsafe_code)]

//! # gc-primitives · Rust 版
//!
//! 与 Java / C++ / Python 同一套概念契约的 Rust 移植，行为规范见仓库根
//! [`SPEC.md`](https://github.com/rainbowcrr-sys/rbc-monorepo/blob/main/SPEC.md)。
//!
//! Rust 版把能编译期拦住的误用直接消掉：对象引用**逃不出** `with_borrow` 的闭包，
//! 因此「双重归还」「跨线程归还」「关闭后取用」在类型系统层面不存在，
//! 不需要像其他三语言那样运行时抛异常。整个 crate `#![forbid(unsafe_code)]`，零依赖。
//!
//! ```
//! use gc_primitives::Pool;
//!
//! let pool = Pool::new(8, || Some(String::new()), |s| {
//!     s.clear();
//!     Ok(())
//! })?;
//!
//! let len = pool.with_borrow(|s| {
//!     s.push_str("hello");
//!     s.len()
//! })?;
//! assert_eq!(len, 5);
//! pool.assert_no_active_leases()?;
//! # Ok::<(), gc_primitives::PoolError>(())
//! ```

use std::any::Any;
use std::cell::RefCell;
use std::collections::HashMap;
use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

/// 池契约被破坏时返回的错误；Rust 版全程 `Result`，不使用 `panic!` 表达业务错误。
#[derive(Debug)]
pub enum PoolError {
    /// `capacity` 为 0。
    InvalidCapacity,
    /// 工厂返回 `None`，对齐其他三语言的「factory 返回空值」。
    FactoryReturnedNone,
    /// 同一线程在 `with_borrow` 闭包内再次借用。
    ReentrantBorrow,
    /// 复位钩子失败；对象已被丢弃，**不会**回到池里。
    ResetFailed(String),
    /// 仍有未归还的借出，由 `assert_no_active_leases()` 返回。
    ActiveLeases(u64),
}

impl fmt::Display for PoolError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PoolError::InvalidCapacity => write!(f, "capacity must be > 0"),
            PoolError::FactoryReturnedNone => write!(f, "factory returned None"),
            PoolError::ReentrantBorrow => write!(f, "reentrant borrow is not allowed"),
            PoolError::ResetFailed(msg) => write!(f, "recycler failed, object discarded: {msg}"),
            PoolError::ActiveLeases(n) => {
                write!(f, "{n} borrow(s) not returned; every with_borrow must settle")
            }
        }
    }
}

impl std::error::Error for PoolError {}

type Factory<T> = Box<dyn FnMut() -> Option<T> + Send + 'static>;
type Recycler<T> = Box<dyn FnMut(&mut T) -> Result<(), PoolError> + Send + 'static>;

struct ThreadState<T> {
    values: Vec<T>,
    in_borrow: bool,
}

// 一份按 pool id 索引的线程本地状态。用 `Box<dyn Any>` 做类型擦除，
// 让不同 `T` 的 Pool 共用同一个 thread_local 静态量；pool id 全局唯一，downcast 必定成功。
thread_local! {
    static TLS: RefCell<HashMap<u64, Box<dyn Any>>> = RefCell::new(HashMap::new());
}

static NEXT_POOL_ID: AtomicU64 = AtomicU64::new(1);

/// 全局对象内含线程本地状态：一个 `Pool` 实例可用 `Arc` 跨线程共享，每线程各自有界空闲栈。
///
/// 借出采用**作用域回调**：`with_borrow` 把 `&mut T` 交给闭包，返回时自动归还、复位。
/// 对象引用无法逃出闭包，因此不需要 RAII guard 暴露给调用方。
pub struct Pool<T: 'static> {
    id: u64,
    capacity: usize,
    factory: Mutex<Factory<T>>,
    recycler: Mutex<Recycler<T>>,
    borrows: AtomicU64,
    returns: AtomicU64,
    live: AtomicU64,
}

impl<T: 'static> Pool<T> {
    /// 创建一个池。`capacity == 0` 返回 [`PoolError::InvalidCapacity`]。
    ///
    /// 工厂返回 `None` 视为契约违反；复位钩子返回 `Err` 时对象被丢弃、错误透传。
    pub fn new<F, R>(capacity: usize, factory: F, recycler: R) -> Result<Self, PoolError>
    where
        F: FnMut() -> Option<T> + Send + 'static,
        R: FnMut(&mut T) -> Result<(), PoolError> + Send + 'static,
    {
        if capacity == 0 {
            return Err(PoolError::InvalidCapacity);
        }
        Ok(Self {
            id: NEXT_POOL_ID.fetch_add(1, Ordering::SeqCst),
            capacity,
            factory: Mutex::new(Box::new(factory)),
            recycler: Mutex::new(Box::new(recycler)),
            borrows: AtomicU64::new(0),
            returns: AtomicU64::new(0),
            live: AtomicU64::new(0),
        })
    }

    /// 借出对象交给闭包，返回闭包结果；作用域结束时归还并复位。
    ///
    /// 运行时校验：禁止重入、工厂返回空值、复位失败。
    /// 若闭包 `panic!`，`BorrowGuard` 仍会结算计数并尽力归还，且不会二次 panic。
    pub fn with_borrow<R, F>(&self, f: F) -> Result<R, PoolError>
    where
        F: FnOnce(&mut T) -> R,
    {
        self.mark_borrow_start()?;

        let value = match self.acquire() {
            Ok(value) => value,
            Err(err) => {
                self.clear_borrow_flag();
                return Err(err);
            }
        };

        let mut guard = BorrowGuard {
            pool: self,
            value: Some(value),
            armed: true,
        };
        let out = f(guard.value.as_mut().expect("guard 刚装入借出的对象"));

        // 正常路径：显式归还，这样复位失败的错误可以透传给调用方
        guard.armed = false;
        let value = guard.value.take().expect("guard 刚装入借出的对象");
        self.clear_borrow_flag();
        self.return_value(value)?;
        Ok(out)
    }

    /// 每线程空闲对象上限。
    pub fn capacity(&self) -> usize {
        self.capacity
    }

    /// **当前线程**的空闲对象数；其他线程的状态不在此统计。
    pub fn idle_count(&self) -> usize {
        self.with_state(|state| state.values.len())
    }

    /// 跨线程精确统计的未归还借出数。
    pub fn active_leases(&self) -> u64 {
        self.live.load(Ordering::SeqCst)
    }

    /// 累计借出次数。
    pub fn borrow_count(&self) -> u64 {
        self.borrows.load(Ordering::SeqCst)
    }

    /// 累计归还次数（含复位失败被丢弃的对象）。
    pub fn return_count(&self) -> u64 {
        self.returns.load(Ordering::SeqCst)
    }

    /// 测试期把未归还的借出转成 `Err`，对齐另外三语言的 `assertNoActiveLeases()`。
    pub fn assert_no_active_leases(&self) -> Result<(), PoolError> {
        let active = self.active_leases();
        if active == 0 {
            Ok(())
        } else {
            Err(PoolError::ActiveLeases(active))
        }
    }

    // ---- 内部实现 ----

    fn with_state<R>(&self, f: impl FnOnce(&mut ThreadState<T>) -> R) -> R {
        TLS.with(|tls| {
            let mut map = tls.borrow_mut();
            let entry = map.entry(self.id).or_insert_with(|| {
                Box::new(ThreadState::<T> {
                    values: Vec::new(),
                    in_borrow: false,
                }) as Box<dyn Any>
            });
            let any: &mut dyn Any = entry.as_mut();
            let state = any
                .downcast_mut::<ThreadState<T>>()
                .expect("pool id 全局唯一，TLS 状态类型与 Pool<T> 一致");
            f(state)
        })
    }

    fn mark_borrow_start(&self) -> Result<(), PoolError> {
        self.with_state(|state| {
            if state.in_borrow {
                Err(PoolError::ReentrantBorrow)
            } else {
                state.in_borrow = true;
                Ok(())
            }
        })
    }

    fn clear_borrow_flag(&self) {
        TLS.with(|tls| {
            // panic 展开时 TLS 可能已被借用，用 try_borrow_mut 避免二次 panic
            if let Ok(mut map) = tls.try_borrow_mut() {
                if let Some(entry) = map.get_mut(&self.id) {
                    let any: &mut dyn Any = entry.as_mut();
                    if let Some(state) = any.downcast_mut::<ThreadState<T>>() {
                        state.in_borrow = false;
                    }
                }
            }
        })
    }

    fn acquire(&self) -> Result<T, PoolError> {
        let cached = self.with_state(|state| state.values.pop());
        let value = match cached {
            Some(value) => value,
            None => {
                let mut factory = self
                    .factory
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                match (*factory)() {
                    Some(value) => value,
                    None => return Err(PoolError::FactoryReturnedNone),
                }
            }
        };
        self.borrows.fetch_add(1, Ordering::SeqCst);
        self.live.fetch_add(1, Ordering::SeqCst);
        Ok(value)
    }

    fn return_value(&self, mut value: T) -> Result<(), PoolError> {
        // 先结算计数：即便复位钩子 panic，全局诊断数也不会失真
        self.returns.fetch_add(1, Ordering::SeqCst);
        self.live.fetch_sub(1, Ordering::SeqCst);

        let reset = {
            let mut recycler = self
                .recycler
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            (*recycler)(&mut value)
        };
        if let Err(err) = reset {
            drop(value); // 复位失败：脏对象直接丢弃，绝不回池
            return Err(err);
        }
        self.try_cache(value);
        Ok(())
    }

    fn try_cache(&self, value: T) {
        let mut pending = Some(value);
        TLS.with(|tls| {
            if let Ok(mut map) = tls.try_borrow_mut() {
                if let Some(entry) = map.get_mut(&self.id) {
                    let any: &mut dyn Any = entry.as_mut();
                    if let Some(state) = any.downcast_mut::<ThreadState<T>>() {
                        if state.values.len() < self.capacity {
                            if let Some(value) = pending.take() {
                                state.values.push(value);
                            }
                        }
                    }
                }
            }
        });
        // 容量已满或 TLS 不可用：pending 里的对象在此 drop，保证有界
    }
}

impl<T: Default + 'static> Pool<T> {
    /// 便捷构造：默认工厂 `T::default()`，复位时把对象还原成 `T::default()`。
    pub fn with_defaults(capacity: usize) -> Result<Self, PoolError> {
        Self::new(
            capacity,
            || Some(T::default()),
            |value| {
                *value = T::default();
                Ok(())
            },
        )
    }
}

/// 闭包 `panic!` 时的兜底：结算计数、尽力归还，且不制造二次 panic。
struct BorrowGuard<'a, T: 'static> {
    pool: &'a Pool<T>,
    value: Option<T>,
    armed: bool,
}

impl<T: 'static> Drop for BorrowGuard<'_, T> {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        self.pool.clear_borrow_flag();
        if let Some(value) = self.value.take() {
            let pool = self.pool;
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let _ = pool.return_value(value);
            }));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Pool, PoolError};

    #[test]
    fn crate_level_doctest_example_runs() {
        let pool = Pool::<String>::with_defaults(4).unwrap();
        let len = pool.with_borrow(|s| {
            s.push_str("hello");
            s.len()
        });
        assert_eq!(len.unwrap(), 5);
        assert!(matches!(pool.assert_no_active_leases(), Ok(())));
    }

    #[test]
    fn reset_failure_discards_object() {
        let pool: Pool<String> = Pool::new(
            4,
            || Some(String::from("fresh")),
            |_| Err(PoolError::ResetFailed("boom".to_string())),
        )
        .unwrap();
        let result = pool.with_borrow(|s| s.push('x'));
        assert!(matches!(result, Err(PoolError::ResetFailed(_))));
        assert_eq!(pool.active_leases(), 0);
        assert_eq!(pool.return_count(), 1);
        assert_eq!(pool.idle_count(), 0);

        // 下一次必须重新走工厂，证明脏对象没回池
        let _ = pool.with_borrow(|s| assert_eq!(s, "fresh"));
        assert_eq!(pool.borrow_count(), 2);
    }
}
