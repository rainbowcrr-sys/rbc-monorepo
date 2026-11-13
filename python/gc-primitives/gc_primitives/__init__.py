"""gc-primitives · 减少分配与复用的 Python 语义移植。

规范见仓库根 SPEC.md。纯 Python 实现，**不承诺性能收益**，价值在跨语言契约一致。

    from gc_primitives import Pool

    pool = Pool(list, list.clear)
    with pool.borrow() as xs:
        xs.append(1)

0.2.0 起新增纯增量能力层（并发、诊断、配置、可观测），见 ``gc_primitives._v020``：

    from gc_primitives import ManagedPool, PoolConfig, memory_scope, AsyncPool

    pool = ManagedPool(list, list.clear,
                       config=PoolConfig(max_size=8, on_full="reject"))
    with memory_scope("hot_path"):
        with pool.borrow() as xs:
            xs.append(1)
    print(pool.metrics())
"""
from ._pool import Lease, Pool, PoolStateError, noop_recycler
from ._v020 import (
    METRICS_FIELDS,
    AsyncLease,
    AsyncPool,
    COMBINATION_MATRIX,
    CombinationError,
    LIFECYCLE_HOOKS,
    LeakDetector,
    LeaseSample,
    LifecycleHooks,
    LocalPool,
    ManagedLease,
    ManagedPool,
    MemoryScopeReport,
    MetricsCollector,
    ON_FULL_POLICIES,
    PoolConfig,
    PoolManager,
    SharedPool,
    ShardedPool,
    TwoLevelPool,
    assert_combination,
    detect_leaks_available,
    load_config,
    memory_scope,
    metrics_snapshot,
    parse_yaml_subset,
)

__all__ = [
    # 0.1.x 原有 API（一行未改）
    "Pool", "Lease", "PoolStateError", "noop_recycler",
    # 0.2.0 增量
    "METRICS_FIELDS", "metrics_snapshot", "MetricsCollector",
    "memory_scope", "MemoryScopeReport",
    "LeaseSample", "LeakDetector",
    "ON_FULL_POLICIES", "LIFECYCLE_HOOKS", "PoolConfig",
    "load_config", "parse_yaml_subset", "PoolManager", "detect_leaks_available",
    "LifecycleHooks", "ManagedPool", "ManagedLease",
    "LocalPool", "SharedPool", "ShardedPool", "TwoLevelPool",
    "COMBINATION_MATRIX", "assert_combination", "CombinationError",
    "AsyncPool", "AsyncLease",
]
__version__ = "0.2.0"
