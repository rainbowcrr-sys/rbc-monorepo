"""gc-primitives 0.2.0 · 增量能力层（纯新增，不改动 ``_pool.Pool``）。

实现 SPEC.md 第 12 章：

* 统一 metrics JSON 同构快照（七语言同名字段）
* ``memory_scope`` 内存作用域诊断，``GC_PRIMITIVES_DIAG`` 未设时零开销空操作
* 泄漏检测：手动 ``detect_leaks()`` + 借出采样最小集（不起后台线程）
* 统一 YAML 子集配置 + schema 校验 + 环境变量覆盖 + 级联查找 + 热重载
* 满池策略 / 生命周期钩子 / 预热 / 池快照
* ``ShardedPool`` / ``TwoLevelPool``，组合矩阵写死
* ``AsyncPool``：``borrow_async()`` 与 ``async with``

核心零依赖：只用标准库。加载器随主包同发，不新增版本号。
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
import threading
import time
import traceback
import uuid
from contextlib import AbstractAsyncContextManager, AbstractContextManager
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, Generic, List, Optional, TypeVar

from ._pool import Lease, Pool, PoolStateError, noop_recycler

T = TypeVar("T")

DIAG_ENV = "GC_PRIMITIVES_DIAG"
CONFIG_ENV = "GC_PRIMITIVES_CONFIG"

# 借出采样最小集在七语言都可用；调用栈快照是 Python / Go / Java 的可选增强。
detect_leaks_available = True

__all__ = [
    "METRICS_FIELDS", "metrics_snapshot", "MetricsCollector",
    "memory_scope", "MemoryScopeReport",
    "LeaseSample", "LeakDetector",
    "ON_FULL_POLICIES", "LIFECYCLE_HOOKS", "PoolConfig",
    "load_config", "parse_yaml_subset", "PoolManager",
    "LifecycleHooks", "ManagedPool", "ManagedLease",
    "LocalPool", "SharedPool", "ShardedPool", "TwoLevelPool",
    "COMBINATION_MATRIX", "assert_combination", "CombinationError",
    "AsyncPool", "AsyncLease", "detect_leaks_available",
]

# ---------------------------------------------------------------------------
# 12.3 统一 metrics JSON 同构快照
# ---------------------------------------------------------------------------

METRICS_FIELDS = (
    "borrow_count", "return_count", "active_leases",
    "pool_hits", "pool_misses", "hit_rate",
    "wait_time_p50", "wait_time_p99", "wait_time_max",
    "object_lifetime_p50", "eviction_count", "leak_count",
    "created", "idle", "capacity", "closed",
)
_FLOAT_FIELDS = frozenset({
    "hit_rate", "wait_time_p50", "wait_time_p99", "wait_time_max",
    "object_lifetime_p50",
})


def metrics_snapshot(**overrides: Any) -> Dict[str, Any]:
    """返回字段完全一致的 metrics 快照；未知键直接报错，不许省略字段。"""
    unknown = set(overrides) - set(METRICS_FIELDS)
    if unknown:
        raise ValueError("unknown metrics field(s): %s" % sorted(unknown))
    snap: Dict[str, Any] = {}
    for key in METRICS_FIELDS:
        if key == "closed":
            snap[key] = False
        elif key in _FLOAT_FIELDS:
            snap[key] = 0.0
        else:
            snap[key] = 0
    snap.update(overrides)
    return snap


def _percentile(sorted_values: List[float], q: float) -> float:
    if not sorted_values:
        return 0.0
    idx = int(round((len(sorted_values) - 1) * q))
    return float(sorted_values[idx])


class MetricsCollector:
    """线程安全地累积 0.2.0 指标；未采集的维度保持 0。"""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._counters: Dict[str, Any] = metrics_snapshot()
        self._waits: List[float] = []
        self._lifetimes: List[float] = []

    def _inc(self, key: str, n: int = 1) -> None:
        with self._lock:
            self._counters[key] += n

    def record_borrow(self, hit: bool, wait_ms: float = 0.0,
                      created: bool = False) -> None:
        with self._lock:
            self._counters["borrow_count"] += 1
            self._counters["active_leases"] += 1
            if hit:
                self._counters["pool_hits"] += 1
            else:
                self._counters["pool_misses"] += 1
            if created:
                self._counters["created"] += 1
            self._waits.append(float(wait_ms))

    def record_return(self, lifetime_ms: float = 0.0) -> None:
        with self._lock:
            self._counters["return_count"] += 1
            self._counters["active_leases"] -= 1
            self._lifetimes.append(float(lifetime_ms))

    def record_eviction(self) -> None:
        self._inc("eviction_count")

    def record_leak(self, n: int = 1) -> None:
        self._inc("leak_count", n)

    def snapshot(self, *, capacity: int, idle: int,
                 closed: bool = False) -> Dict[str, Any]:
        with self._lock:
            out = dict(self._counters)
            waits = sorted(self._waits)
            lifetimes = sorted(self._lifetimes)
        total = out["pool_hits"] + out["pool_misses"]
        out["hit_rate"] = (out["pool_hits"] / total) if total else 0.0
        out["wait_time_p50"] = _percentile(waits, 0.50)
        out["wait_time_p99"] = _percentile(waits, 0.99)
        out["wait_time_max"] = waits[-1] if waits else 0.0
        out["object_lifetime_p50"] = _percentile(lifetimes, 0.50)
        out["capacity"] = int(capacity)
        out["idle"] = int(idle)
        out["closed"] = bool(closed)
        return out


# ---------------------------------------------------------------------------
# 12.5 内存作用域诊断
# ---------------------------------------------------------------------------


@dataclass
class MemoryScopeReport:
    name: str
    elapsed_ms: float
    current_bytes_delta: int
    peak_bytes_delta: int
    borrow_count_delta: int = 0
    created_delta: int = 0


class _NullScope(AbstractContextManager):
    __slots__ = ()

    def __enter__(self) -> "_NullScope":
        return self

    def __exit__(self, *exc: Any) -> bool:
        return False


def _diag_enabled() -> bool:
    return os.environ.get(DIAG_ENV, "").strip().lower() not in ("", "0", "false", "off")


class _ActiveScope(AbstractContextManager):
    def __init__(self, name: str, sink: Optional[Callable[[MemoryScopeReport], Any]],
                 json_path: Optional[str], collector: Optional[MetricsCollector]) -> None:
        self.name = name
        self.sink = sink
        self.json_path = json_path
        self.collector = collector
        self.report: Optional[MemoryScopeReport] = None

    def __enter__(self) -> "_ActiveScope":
        import tracemalloc
        self._tracemalloc = tracemalloc
        self._started_here = not tracemalloc.is_tracing()
        if self._started_here:
            tracemalloc.start()
        self._cur, self._peak = tracemalloc.get_traced_memory()
        self._t0 = time.perf_counter()
        self._b0 = self.collector.snapshot(capacity=0, idle=0)["borrow_count"] if self.collector else 0
        self._c0 = self.collector.snapshot(capacity=0, idle=0)["created"] if self.collector else 0
        return self

    def __exit__(self, *exc: Any) -> bool:
        cur, peak = self._tracemalloc.get_traced_memory()
        snap = self.collector.snapshot(capacity=0, idle=0) if self.collector else {}
        self.report = MemoryScopeReport(
            name=self.name,
            elapsed_ms=(time.perf_counter() - self._t0) * 1000.0,
            current_bytes_delta=cur - self._cur,
            peak_bytes_delta=peak - self._peak,
            borrow_count_delta=snap.get("borrow_count", 0) - self._b0,
            created_delta=snap.get("created", 0) - self._c0,
        )
        if self.sink is not None:
            self.sink(self.report)
        elif self.json_path:
            with open(self.json_path, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(asdict(self.report), ensure_ascii=False) + "\n")
        else:
            print("[gc-primitives] %s: current=%+d B peak=%+d B borrows=%+d created=%+d (%.2f ms)"
                  % (self.name, self.report.current_bytes_delta,
                     self.report.peak_bytes_delta, self.report.borrow_count_delta,
                     self.report.created_delta, self.report.elapsed_ms),
                  file=sys.stderr)
        if self._started_here:
            self._tracemalloc.stop()
        return False


def memory_scope(
    name: str,
    *,
    sink: Optional[Callable[[MemoryScopeReport], Any]] = None,
    json_path: Optional[str] = None,
    collector: Optional[MetricsCollector] = None,
) -> AbstractContextManager:
    """标记一段可疑代码的内存压力。``GC_PRIMITIVES_DIAG`` 未设时为空操作。

    输出：默认 stderr；也可传 ``sink`` 回调或 ``json_path`` 写 JSON Lines。
    嵌套时差值归属最内层作用域。
    """
    if not _diag_enabled():
        return _NullScope()
    return _ActiveScope(name, sink, json_path, collector)


# ---------------------------------------------------------------------------
# 12.6 泄漏检测（借出采样最小集，无后台线程）
# ---------------------------------------------------------------------------


@dataclass
class LeaseSample:
    lease_id: str
    borrowed_at: float
    tag: str
    stack: Optional[str] = None


class LeakDetector:
    """只记录借出样本，由调用方手动 ``detect_leaks()``；零常驻开销。"""

    def __init__(self, capture_stack: bool = False) -> None:
        self._lock = threading.Lock()
        self._active: Dict[str, LeaseSample] = {}
        self._capture_stack = capture_stack

    def on_borrow(self, tag: str = "") -> str:
        lease_id = uuid.uuid4().hex
        stack = "".join(traceback.format_stack(limit=8)) if self._capture_stack else None
        with self._lock:
            self._active[lease_id] = LeaseSample(lease_id, time.time(), tag, stack)
        return lease_id

    def on_return(self, lease_id: str) -> None:
        with self._lock:
            self._active.pop(lease_id, None)

    def detect_leaks(self, timeout_ms: Optional[int] = None) -> List[Dict[str, Any]]:
        now = time.time()
        out: List[Dict[str, Any]] = []
        with self._lock:
            samples = list(self._active.values())
        for s in samples:
            age_ms = (now - s.borrowed_at) * 1000.0
            if timeout_ms is None or age_ms >= timeout_ms:
                out.append({
                    "lease_id": s.lease_id,
                    "borrowed_at": s.borrowed_at,
                    "age_ms": round(age_ms, 2),
                    "tag": s.tag,
                    "timed_out": timeout_ms is not None and age_ms >= timeout_ms,
                    **({"stack": s.stack} if s.stack else {}),
                })
        return out

    def active_count(self) -> int:
        with self._lock:
            return len(self._active)


# ---------------------------------------------------------------------------
# 12.4 统一 YAML 子集配置
# ---------------------------------------------------------------------------

ON_FULL_POLICIES = ("drop_oldest", "drop_largest", "block", "reject", "grow")
LIFECYCLE_HOOKS = ("on_create", "on_borrow", "on_return", "on_evict", "on_destroy")


def _scalar(raw: str) -> Any:
    v = raw.strip()
    if not v:
        return ""
    if (v[0] == v[-1] == '"') or (v[0] == v[-1] == "'"):
        return v[1:-1]
    low = v.lower()
    if low in ("true", "yes"):
        return True
    if low in ("false", "no"):
        return False
    if low in ("null", "none", "~"):
        return None
    try:
        return int(v)
    except ValueError:
        pass
    try:
        return float(v)
    except ValueError:
        pass
    return v


def parse_yaml_subset(text: str) -> Dict[str, Any]:
    """极简 YAML 子集：缩进映射 + 标量，不支持列表/锚点/多行。零依赖。"""
    root: Dict[str, Any] = {}
    stack: List[tuple] = [(-1, root)]
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        if "\t" in line[:indent]:
            raise ValueError("line %d: tabs are not allowed for indentation" % lineno)
        key, sep, value = line.strip().partition(":")
        if not sep or not key.strip():
            raise ValueError("line %d: expected 'key: value'" % lineno)
        key = key.strip()
        while stack and stack[-1][0] >= indent:
            stack.pop()
        if not stack:
            raise ValueError("line %d: inconsistent indentation" % lineno)
        parent = stack[-1][1]
        if not isinstance(parent, dict):
            raise ValueError("line %d: parent is not a mapping" % lineno)
        if value.strip() == "":
            child: Dict[str, Any] = {}
            parent[key] = child
            stack.append((indent, child))
        else:
            parent[key] = _scalar(value)
    return root


def _flatten_lifecycle(section: Any) -> Dict[str, Any]:
    out: Dict[str, Any] = {}
    if isinstance(section, dict):
        for k, v in section.items():
            if k in LIFECYCLE_HOOKS or k == "clear_sensitive":
                out[k] = v
    return out


@dataclass
class PoolConfig:
    """snake_case 字段名，七语言统一，配置复制即可跨语言迁移。"""

    max_size: int = 64
    on_full: str = "drop_oldest"
    block_timeout_ms: Optional[int] = None
    max_overflow: int = 0
    eviction_policy: str = "lru"
    prewarm: int = 0
    leak_detection: bool = False
    leak_timeout_ms: int = 3000
    clear_sensitive: bool = False
    lifecycle: Dict[str, Any] = field(default_factory=dict)

    _FIELDS = frozenset({
        "max_size", "on_full", "block_timeout_ms", "max_overflow",
        "eviction_policy", "prewarm", "leak_detection", "leak_timeout_ms",
        "clear_sensitive", "lifecycle",
    })

    @classmethod
    def from_mapping(cls, data: Dict[str, Any]) -> "PoolConfig":
        unknown = sorted(set(data) - cls._FIELDS - {"lifecycle"})
        if unknown:
            raise ValueError("unknown config key(s): %s; legal keys: %s"
                             % (unknown, sorted(cls._FIELDS)))
        cfg = cls()
        for k, v in data.items():
            if k == "lifecycle":
                cfg.lifecycle = _flatten_lifecycle(v)
                cfg.clear_sensitive = bool(cfg.lifecycle.get("clear_sensitive", False))
            elif hasattr(cfg, k):
                setattr(cfg, k, v)
        cfg.validate()
        return cfg

    def validate(self) -> None:
        if not isinstance(self.max_size, int) or isinstance(self.max_size, bool) or self.max_size <= 0:
            raise ValueError("max_size must be an integer > 0, got %r" % (self.max_size,))
        if self.on_full not in ON_FULL_POLICIES:
            raise ValueError("on_full must be one of %s, got %r"
                             % (list(ON_FULL_POLICIES), self.on_full))
        if self.max_overflow < 0:
            raise ValueError("max_overflow must be >= 0")
        if self.block_timeout_ms is not None and self.block_timeout_ms < 0:
            raise ValueError("block_timeout_ms must be >= 0 or null")
        if self.prewarm < 0:
            raise ValueError("prewarm must be >= 0")
        for hook in self.lifecycle:
            if hook not in LIFECYCLE_HOOKS and hook != "clear_sensitive":
                raise ValueError("unknown lifecycle hook: %s" % hook)

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


_CASCADE = (
    "./gc-primitives.yaml",
    "./config/gc-primitives.yaml",
    "~/.config/gc-primitives.yaml",
    "/etc/gc-primitives.yaml",
)


def _apply_env(cfg: PoolConfig, pool_name: str) -> None:
    prefix = "GC_PRIMITIVES__%s__" % pool_name.upper().replace("-", "_")
    for key, raw in os.environ.items():
        if not key.startswith(prefix):
            continue
        field_name = key[len(prefix):].lower()
        if field_name not in PoolConfig._FIELDS or field_name == "lifecycle":
            continue
        setattr(cfg, field_name, _scalar(raw))


def load_config(path: Optional[str] = None, pool: str = "default") -> PoolConfig:
    """加载配置；找不到文件时返回默认值（配置文件可选，不影响核心池）。"""
    chosen: Optional[Path] = None
    explicit = path or os.environ.get(CONFIG_ENV)
    if explicit:
        p = Path(explicit).expanduser()
        if p.is_file():
            chosen = p
    else:
        for cand in _CASCADE:
            p = Path(cand).expanduser()
            if p.is_file():
                chosen = p
                break
    if chosen is None:
        cfg = PoolConfig()
    else:
        doc = parse_yaml_subset(chosen.read_text(encoding="utf-8"))
        section = (doc.get("pools") or {}).get(pool) or {}
        cfg = PoolConfig.from_mapping(dict(section))
    _apply_env(cfg, pool)
    cfg.validate()
    return cfg


class PoolManager:
    """多池统一管理；热重载由调用方触发或显式开启后台轮询。"""

    def __init__(self, path: Optional[str] = None) -> None:
        self.path = path
        self._pools: Dict[str, ManagedPool] = {}
        self._factories: Dict[str, Any] = {}
        self._lock = threading.Lock()
        self._mtime: Optional[float] = self._stat_mtime()
        self._watch_thread: Optional[threading.Thread] = None
        self._stop = threading.Event()

    def _stat_mtime(self) -> Optional[float]:
        p = self.path or os.environ.get(CONFIG_ENV)
        if not p:
            return None
        f = Path(p).expanduser()
        return f.stat().st_mtime if f.is_file() else None

    def register(self, name: str, pool: "ManagedPool") -> None:
        with self._lock:
            self._pools[name] = pool

    def get(self, name: str) -> "ManagedPool":
        with self._lock:
            return self._pools[name]

    def reload(self) -> bool:
        """重新读取配置文件并把可变参数应用到已注册池；无变更返回 False。"""
        mtime = self._stat_mtime()
        if mtime is not None and mtime == self._mtime:
            return False
        with self._lock:
            for name, pool in self._pools.items():
                pool.apply_config(load_config(self.path, name))
        self._mtime = mtime
        return True

    def enable_hot_reload(self, interval_s: float = 1.0) -> None:
        """Python 档：可选后台轮询。默认不开，零常驻开销。"""
        if self._watch_thread is not None:
            return
        self._stop.clear()

        def _loop() -> None:
            while not self._stop.wait(interval_s):
                try:
                    self.reload()
                except Exception:  # 配置写错时保留旧配置，不打断服务
                    print("[gc-primitives] hot reload failed, keeping previous config",
                          file=sys.stderr)

        self._watch_thread = threading.Thread(target=_loop, daemon=True,
                                              name="gc-primitives-hot-reload")
        self._watch_thread.start()

    def shutdown(self) -> None:
        self._stop.set()
        with self._lock:
            pools = list(self._pools.values())
        for p in pools:
            p.close()


# ---------------------------------------------------------------------------
# 12.1 满池策略 / 生命周期钩子 / 预热 / 快照
# ---------------------------------------------------------------------------


@dataclass
class LifecycleHooks:
    on_create: Optional[Callable[[Any], Any]] = None
    on_borrow: Optional[Callable[[Any], Any]] = None
    on_return: Optional[Callable[[Any], Any]] = None
    on_evict: Optional[Callable[[Any], Any]] = None
    on_destroy: Optional[Callable[[Any], Any]] = None
    clear_sensitive: bool = False

    def fire(self, name: str, value: Any) -> None:
        fn = getattr(self, name, None)
        if fn is not None:
            fn(value)


class ManagedLease(Generic[T], AbstractContextManager):
    """共享池的租约；C1 显式归还、C5 双重归还 / 关闭后取用强制校验。"""

    __slots__ = ("_pool", "_value", "_active", "_id", "_borrowed_at", "_tag")

    def __init__(self, pool: "ManagedPool[T]", value: T,
                 lease_id: str, tag: str) -> None:
        self._pool = pool
        self._value: Optional[T] = value
        self._active = True
        self._id = lease_id
        self._borrowed_at = time.time()
        self._tag = tag

    def get(self) -> T:
        if not self._active:
            raise PoolStateError("lease is closed; get() after close()")
        return self._value  # type: ignore[return-value]

    def close(self) -> None:
        if not self._active:
            raise PoolStateError("lease already returned (double close)")
        self._active = False
        value = self._value
        self._value = None
        self._pool._return(value, self._id, self._borrowed_at)

    def __enter__(self) -> T:
        return self.get()

    def __exit__(self, *exc: Any) -> bool:
        self.close()
        return False

    @property
    def lease_id(self) -> str:
        return self._id

    @property
    def active(self) -> bool:
        return self._active


class ManagedPool(Generic[T]):
    """0.2.0 新增类型：共享、线程安全、可配置。原 ``Pool`` 一行未改。"""

    def __init__(
        self,
        factory: Callable[[], T],
        recycler: Optional[Callable[[T], Any]] = None,
        config: Optional[PoolConfig] = None,
        hooks: Optional[LifecycleHooks] = None,
        name: str = "default",
    ) -> None:
        self.name = name
        self._factory = factory
        self._recycler: Callable[[T], Any] = recycler or noop_recycler
        self.config = config or PoolConfig()
        self.config.validate()
        self.hooks = hooks or LifecycleHooks()
        self._lock = threading.Lock()
        self._cond = threading.Condition(self._lock)
        self._free: List[T] = []
        self._active: List[str] = []
        self._closed = False
        self._metrics = MetricsCollector()
        self._leaks = LeakDetector(capture_stack=True)
        if self.config.prewarm:
            self.prewarm(self.config.prewarm)

    # -- 借用 --
    def borrow(self, tag: str = "") -> ManagedLease[T]:
        t0 = time.perf_counter()
        with self._cond:
            if self._closed:
                raise PoolStateError("pool is closed; borrow() is no longer allowed")
            limit = self.config.max_size + (
                self.config.max_overflow if self.config.on_full == "grow" else 0)
            while len(self._active) >= limit:
                if self.config.on_full == "reject":
                    raise PoolStateError("pool exhausted (on_full=reject)")
                if self.config.on_full == "block":
                    timeout = (self.config.block_timeout_ms / 1000.0
                               if self.config.block_timeout_ms is not None else None)
                    if not self._cond.wait(timeout=timeout):
                        raise PoolStateError("borrow timed out (on_full=block)")
                    continue
                break  # drop_* / grow 在归还侧处理，借用侧不阻塞
            if self._free:
                value = self._free.pop()
                hit, created = True, False
            else:
                value = self._factory()
                if value is None:
                    raise PoolStateError("factory returned None")
                hit, created = False, True
                self.hooks.fire("on_create", value)
            lease_id = self._leaks.on_borrow(tag) if self.config.leak_detection else uuid.uuid4().hex
            self._active.append(lease_id)
            self._metrics.record_borrow(hit, (time.perf_counter() - t0) * 1000.0, created)
            self.hooks.fire("on_borrow", value)
        return ManagedLease(self, value, lease_id, tag)

    # -- 归还 --
    def _return(self, value: Optional[T], lease_id: str, borrowed_at: float) -> None:
        if value is None:
            return
        try:
            if self.hooks.clear_sensitive:
                self.hooks.fire("on_return", value)
            self._recycler(value)
            self.hooks.fire("on_return", value)
        except BaseException:
            self.hooks.fire("on_destroy", value)
            self._settle(lease_id, borrowed_at, evicted=True)
            raise
        with self._cond:
            self._leaks.on_return(lease_id)
            over = len(self._free) >= self.config.max_size
            if over:
                policy = self.config.on_full
                if policy in ("reject", "block", "grow", "drop_oldest"):
                    victim = self._free.pop(0) if self._free else value
                    self.hooks.fire("on_evict", victim)
                    self._metrics.record_eviction()
                    self._settle_in_lock(lease_id, borrowed_at)
                    self._cond.notify()
                    return
            self._free.append(value)
            self._settle_in_lock(lease_id, borrowed_at)
            self._cond.notify()

    def _settle_in_lock(self, lease_id: str, borrowed_at: float) -> None:
        self._metrics.record_return((time.time() - borrowed_at) * 1000.0)
        if lease_id in self._active:
            self._active.remove(lease_id)

    def _settle(self, lease_id: str, borrowed_at: float, evicted: bool = False) -> None:
        with self._cond:
            self._settle_in_lock(lease_id, borrowed_at)
            self._cond.notify()

    # -- 新增 API --
    def prewarm(self, n: int) -> int:
        made = 0
        for _ in range(n):
            lease = self.borrow(tag="prewarm")
            lease.close()
            made += 1
        return made

    def detect_leaks(self, timeout_ms: Optional[int] = None) -> List[Dict[str, Any]]:
        out = self._leaks.detect_leaks(timeout_ms if timeout_ms is not None
                                       else self.config.leak_timeout_ms)
        self._metrics.record_leak(len(out))
        return out

    def metrics(self) -> Dict[str, Any]:
        with self._cond:
            return self._metrics.snapshot(capacity=self.config.max_size,
                                          idle=len(self._free), closed=self._closed)

    # 兼容七语言统一命名
    stats = metrics

    def snapshot(self) -> Dict[str, Any]:
        with self._cond:
            return {
                "config": self.config.to_dict(),
                "stats": self._metrics.snapshot(capacity=self.config.max_size,
                                                idle=len(self._free), closed=self._closed),
                "active_leases": self._leaks.detect_leaks(timeout_ms=None),
                "idle_objects": len(self._free),
            }

    def apply_config(self, cfg: PoolConfig) -> None:
        cfg.validate()
        with self._cond:
            self.config = cfg
            self._cond.notify_all()

    def set_max_size(self, n: int) -> None:
        cfg = PoolConfig.from_mapping({**self.config.to_dict(), "max_size": n})
        self.apply_config(cfg)

    def close(self) -> None:
        with self._cond:
            if self._closed:
                return
            self._closed = True
            victims = self._free
            self._free = []
            self._cond.notify_all()
        for v in victims:
            self.hooks.fire("on_destroy", v)

    def assert_no_active_leases(self) -> None:
        with self._cond:
            n = len(self._active)
        if n:
            raise PoolStateError("%d lease(s) not returned" % n)


# ---------------------------------------------------------------------------
# 12.2 组合矩阵（写死）
# ---------------------------------------------------------------------------

COMBINATION_MATRIX: Dict[str, Dict[str, bool]] = {
    "local":  {"standalone": True,  "shardable": False, "two_level_l2": False},
    "shared": {"standalone": True,  "shardable": True,  "two_level_l2": True},
    "base":   {"standalone": True,  "shardable": True,  "two_level_l2": True},
}


class CombinationError(ValueError):
    pass


def assert_combination(kind: str, operation: str) -> None:
    """构造期校验，禁止组合直接报错。"""
    if kind not in COMBINATION_MATRIX:
        raise CombinationError("unknown pool kind: %s" % kind)
    if operation not in ("standalone", "shardable", "two_level_l2"):
        raise CombinationError("unknown operation: %s" % operation)
    if not COMBINATION_MATRIX[kind][operation]:
        raise CombinationError("pool kind %r cannot be used for %r" % (kind, operation))


LocalPool = Pool          # thread-local，不可分片 / 不可作 L2
SharedPool = ManagedPool  # 可共享、可分片、可作 L2


class ShardedPool(Generic[T]):
    """按借出线程路由到独立子池；只接受可分片类型。"""

    def __init__(self, shards: List[ManagedPool[T]], kind: str = "shared") -> None:
        assert_combination(kind, "shardable")
        if not shards:
            raise ValueError("shard list must not be empty")
        self.shards = shards
        self._metrics = MetricsCollector()

    def borrow(self, tag: str = "") -> ManagedLease[T]:
        idx = threading.get_ident() % len(self.shards)
        lease = self.shards[idx].borrow(tag)
        self._metrics.record_borrow(False)
        return lease

    def metrics(self) -> Dict[str, Any]:
        merged = metrics_snapshot()
        for s in self.shards:
            snap = s.metrics()
            for k in ("borrow_count", "return_count", "active_leases", "pool_hits",
                      "pool_misses", "eviction_count", "leak_count", "created", "idle"):
                merged[k] += snap[k]
            merged["capacity"] += snap["capacity"]
        total = merged["pool_hits"] + merged["pool_misses"]
        merged["hit_rate"] = merged["pool_hits"] / total if total else 0.0
        return merged

    stats = metrics

    def close(self) -> None:
        for s in self.shards:
            s.close()


class TwoLevelPool(Generic[T]):
    """L1 线程本地快路径 + L2 共享兜底；只建在 SharedPool 之上。"""

    def __init__(self, l2: ManagedPool[T], l1_size: int = 8,
                 kind: str = "shared") -> None:
        assert_combination(kind, "two_level_l2")
        self.l2 = l2
        self.l1_size = l1_size
        self._local = threading.local()

    def _l1(self) -> List[Any]:
        v = getattr(self._local, "values", None)
        if v is None:
            v = []
            self._local.values = v
        return v

    def borrow(self, tag: str = "") -> ManagedLease[T]:
        l1 = self._l1()
        if l1:
            value = l1.pop()
            lease_id = uuid.uuid4().hex
            self.l2._metrics.record_borrow(True)
            return ManagedLease(self, value, lease_id, tag)
        return self.l2.borrow(tag)

    def _return(self, value: Optional[T], lease_id: str, borrowed_at: float) -> None:
        l1 = self._l1()
        if len(l1) < self.l1_size:
            try:
                self.l2._recycler(value)
            except BaseException:
                raise
            l1.append(value)
            self.l2._settle(lease_id, borrowed_at)
        else:
            self.l2._return(value, lease_id, borrowed_at)

    def metrics(self) -> Dict[str, Any]:
        return self.l2.metrics()

    stats = metrics

    def close(self) -> None:
        self.l2.close()


# ---------------------------------------------------------------------------
# 12.1 AsyncPool（Python 并发三件套）
# ---------------------------------------------------------------------------


class AsyncLease(Generic[T], AbstractAsyncContextManager):
    __slots__ = ("_pool", "_value", "_active")

    def __init__(self, pool: "AsyncPool[T]", value: T) -> None:
        self._pool = pool
        self._value: Optional[T] = value
        self._active = True

    def get(self) -> T:
        if not self._active:
            raise PoolStateError("lease is closed; get() after close()")
        return self._value  # type: ignore[return-value]

    async def __aenter__(self) -> T:
        return self.get()

    async def __aexit__(self, *exc: Any) -> bool:
        self.release()
        return False

    def release(self) -> None:
        if not self._active:
            raise PoolStateError("lease already returned (double close)")
        self._active = False
        value = self._value
        self._value = None
        self._pool._release(value)


class _AsyncBorrow(Generic[T]):
    """既支持 ``await pool.borrow()``，也支持 ``async with pool.borrow()``。"""

    __slots__ = ("_pool", "_lease")

    def __init__(self, pool: "AsyncPool[T]") -> None:
        self._pool = pool
        self._lease: Optional[AsyncLease[T]] = None

    def __await__(self):
        return self._pool.borrow_async().__await__()

    async def __aenter__(self) -> T:
        self._lease = await self._pool.borrow_async()
        return self._lease.get()

    async def __aexit__(self, *exc: Any) -> bool:
        if self._lease is not None:
            self._lease.release()  # C1：即使 with 体内抛异常也归还
            self._lease = None
        return False


class AsyncPool(Generic[T]):
    """asyncio 友好池：满池时 ``await`` 而不是阻塞事件循环。"""

    def __init__(self, factory: Callable[[], T],
                 recycler: Optional[Callable[[T], Any]] = None,
                 max_size: int = 64) -> None:
        if max_size <= 0:
            raise ValueError("max_size must be > 0")
        self._factory = factory
        self._recycler: Callable[[T], Any] = recycler or noop_recycler
        self._free: List[T] = []
        self._cond: Optional[asyncio.Condition] = None
        self._sem: Optional[asyncio.Semaphore] = None
        self._max_size = max_size
        self._metrics = MetricsCollector()

    def _ensure(self) -> None:
        if self._cond is None:
            self._cond = asyncio.Condition()
            self._sem = asyncio.Semaphore(self._max_size)

    def borrow(self) -> _AsyncBorrow[T]:
        return _AsyncBorrow(self)

    async def borrow_async(self, tag: str = "") -> AsyncLease[T]:
        self._ensure()
        assert self._cond is not None and self._sem is not None
        t0 = time.perf_counter()
        await self._sem.acquire()
        async with self._cond:
            if self._free:
                value = self._free.pop()
                hit, created = True, False
            else:
                value = self._factory()
                if value is None:
                    self._sem.release()
                    raise PoolStateError("factory returned None")
                hit, created = False, True
            self._metrics.record_borrow(hit, (time.perf_counter() - t0) * 1000.0, created)
        return AsyncLease(self, value)

    def _release(self, value: Optional[T]) -> None:
        if value is None:
            return
        try:
            self._recycler(value)
        except BaseException:
            self._metrics.record_return()
            if self._sem is not None:
                self._sem.release()
            raise
        self._metrics.record_return()
        self._free.append(value)
        if self._sem is not None:
            self._sem.release()

    def metrics(self) -> Dict[str, Any]:
        return self._metrics.snapshot(capacity=self._max_size, idle=len(self._free))

    stats = metrics
