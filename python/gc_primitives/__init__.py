"""gc-primitives · 减少分配与复用的 Python 语义移植。

规范见仓库根 SPEC.md。纯 Python 实现，**不承诺性能收益**，价值在跨语言契约一致。

    from gc_primitives import Pool

    pool = Pool(list, list.clear)
    with pool.borrow() as xs:
        xs.append(1)
"""
from ._pool import Lease, Pool, PoolStateError, noop_recycler

__all__ = ["Pool", "Lease", "PoolStateError", "noop_recycler"]
__version__ = "0.1.0"
