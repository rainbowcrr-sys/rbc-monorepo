"""gc-primitives · 纯 Python 语义移植。

行为规范见仓库根 SPEC.md。定位是**跨语言契约一致性**，不承诺比 CPython 解释器快：
CPython 主力是引用计数，另有分代 GC 清循环引用，再加 pymalloc 的 arena 与小对象
free-list，解释器底层已经在做复用，纯 Python 再手写一层对象池常与内置缓存重叠。

契约要点：
  - 用 ``with pool.borrow() as x`` 显式归还（对应 Java 的 try-with-resources）；
  - 句柄与对象只归借用线程使用，跨线程归还/取用抛 PoolStateError；
  - 每线程空闲对象数有上限，超出直接丢弃；
  - 归还时由库调用 recycler 复位；复位失败则**对象丢弃、绝不回池**；
  - 误用始终强制校验，不设开关。
"""
from __future__ import annotations

import threading
from typing import Any, Callable, Generic, List, Optional, TypeVar

T = TypeVar("T")

__all__ = ["Pool", "Lease", "PoolStateError", "noop_recycler"]


class PoolStateError(RuntimeError):
    """池契约被破坏时抛出；对应 Java 的 PoolStateException / C++ 的 pool_error。"""


def noop_recycler(value: Any) -> None:
    """不做任何复位的复位钩子，适用于无可变状态的对象。"""
    return None


class Lease(Generic[T]):
    """一次借用的句柄，配合 ``with`` 使用。"""

    __slots__ = ("_pool", "_value", "_borrower", "_active")

    def __init__(self, pool: "Pool[T]", value: T, borrower: int) -> None:
        self._pool: Pool[T] = pool
        self._value: Optional[T] = value
        self._borrower = borrower
        self._active = True

    def get(self) -> T:
        if not self._active:
            raise PoolStateError("lease is closed; get() after close()")
        if threading.get_ident() != self._borrower:
            raise PoolStateError("lease used off its borrowing thread")
        return self._value  # type: ignore[return-value]

    def close(self) -> None:
        """显式归还；重复关闭或跨线程关闭抛 PoolStateError。"""
        if not self._active:
            raise PoolStateError("lease already returned (double close)")
        if threading.get_ident() != self._borrower:
            raise PoolStateError("cross-thread return")

        self._active = False
        value = self._value
        self._value = None
        # 复位失败时 _return 会照常抛异常，但对象不回池；租约此时已失效
        self._pool._return(value)

    def __enter__(self) -> T:
        return self.get()

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> bool:
        # 即使 with 体内抛异常，也要归还（并让原异常继续冒泡）
        self.close()
        return False

    @property
    def active(self) -> bool:
        return self._active


class Pool(Generic[T]):
    """全局对象内含线程本地状态：一个 Pool 实例可跨线程使用，每线程各自一份有界空闲栈。"""

    DEFAULT_CAPACITY = 64

    def __init__(
        self,
        factory: Callable[[], T],
        recycler: Optional[Callable[[T], Any]] = None,
        capacity: int = DEFAULT_CAPACITY,
    ) -> None:
        if capacity <= 0:
            raise ValueError("capacity must be > 0")
        self._factory = factory
        self._recycler: Callable[[T], Any] = recycler or noop_recycler
        self._capacity = capacity
        self._local = threading.local()
        self._lock = threading.Lock()
        self._borrows = 0
        self._returns = 0
        self._live = 0

    def borrow(self) -> Lease[T]:
        state = self._state(create=True)
        if state:
            value = state.pop()
        else:
            value = self._factory()
            if value is None:
                raise PoolStateError("factory returned None")
        with self._lock:
            self._borrows += 1
            self._live += 1
        return Lease(self, value, threading.get_ident())

    def capacity(self) -> int:
        return self._capacity

    def idle_count(self) -> int:
        """当前线程的空闲对象数；仅用于诊断。"""
        return len(self._state(create=False))

    def active_leases(self) -> int:
        with self._lock:
            return self._live

    def borrow_count(self) -> int:
        with self._lock:
            return self._borrows

    def return_count(self) -> int:
        with self._lock:
            return self._returns

    def assert_no_active_leases(self) -> None:
        n = self.active_leases()
        if n != 0:
            raise PoolStateError(
                f"{n} lease(s) not returned; use 'with pool.borrow() as x'"
            )

    # ---- 内部 ----

    def _state(self, create: bool) -> List[T]:
        values: Optional[List[T]] = getattr(self._local, "values", None)
        if values is None:
            if not create:
                return []
            values = []
            self._local.values = values
        return values

    def _return(self, value: Optional[T]) -> None:
        try:
            self._recycler(value)  # type: ignore[arg-type]
        except BaseException:
            # 复位失败：对象直接丢弃，计数照常结算，租约已失效，污染不得入池
            with self._lock:
                self._returns += 1
                self._live -= 1
            raise

        with self._lock:
            self._returns += 1
            self._live -= 1

        state = self._state(create=False)
        if len(state) < self._capacity:
            state.append(value)  # type: ignore[arg-type]
        # 超出上限直接丢弃，由引用计数回收，保证有界
