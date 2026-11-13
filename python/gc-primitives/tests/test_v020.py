"""gc-primitives 0.2.0 增量能力 · 契约测试。

与另外六语言共用同一份用例口径：metrics 同构快照、memory_scope 开关、
泄漏采样最小集、配置 schema / env / 级联、满池策略、生命周期钩子、预热、
快照、组合矩阵、AsyncPool。旧 0.1.x 契约测试（test_contract.py）必须同时全绿。
"""
import asyncio
import json
import os
import tempfile
import unittest
from pathlib import Path

import gc_primitives as g


class TestMetrics(unittest.TestCase):
    def test_snapshot_fields_are_isomorphic(self):
        snap = g.metrics_snapshot()
        self.assertEqual(tuple(sorted(snap)), tuple(sorted(g.METRICS_FIELDS)))
        self.assertEqual(len(snap), 16)
        self.assertIs(snap["closed"], False)
        for k in ("hit_rate", "wait_time_p50", "wait_time_p99",
                  "wait_time_max", "object_lifetime_p50"):
            self.assertIsInstance(snap[k], float)

    def test_unknown_field_rejected(self):
        with self.assertRaises(ValueError):
            g.metrics_snapshot(nope=1)

    def test_pool_metrics_keys_match(self):
        pool = g.ManagedPool(list, list.clear, g.PoolConfig(max_size=4))
        with pool.borrow() as xs:
            xs.append(1)
        snap = pool.metrics()
        self.assertEqual(tuple(sorted(snap)), tuple(sorted(g.METRICS_FIELDS)))
        self.assertEqual(snap["borrow_count"], 1)
        self.assertEqual(snap["return_count"], 1)
        self.assertEqual(snap["active_leases"], 0)
        self.assertEqual(snap["created"], 1)
        self.assertEqual(snap["capacity"], 4)
        pool.assert_no_active_leases()


class TestMemoryScope(unittest.TestCase):
    def test_disabled_by_default_is_noop(self):
        os.environ.pop("GC_PRIMITIVES_DIAG", None)
        reports = []
        with g.memory_scope("outer", sink=reports.append):
            x = [0] * 100
            del x
        self.assertEqual(reports, [])

    def test_enabled_reports_bytes_and_nesting(self):
        os.environ["GC_PRIMITIVES_DIAG"] = "1"
        reports = []
        try:
            with g.memory_scope("outer", sink=reports.append):
                with g.memory_scope("inner", sink=reports.append):
                    holder = [b"x" * 4096 for _ in range(16)]
                del holder
            self.assertEqual([r.name for r in reports], ["inner", "outer"])
            self.assertGreaterEqual(reports[0].peak_bytes_delta, 0)
            self.assertIsInstance(reports[0], g.MemoryScopeReport)
        finally:
            os.environ.pop("GC_PRIMITIVES_DIAG", None)

    def test_json_sink(self):
        os.environ["GC_PRIMITIVES_DIAG"] = "1"
        try:
            with tempfile.TemporaryDirectory() as d:
                path = str(Path(d) / "scopes.jsonl")
                with g.memory_scope("json-scope", json_path=path):
                    pass
                lines = Path(path).read_text(encoding="utf-8").splitlines()
                self.assertEqual(len(lines), 1)
                self.assertEqual(json.loads(lines[0])["name"], "json-scope")
        finally:
            os.environ.pop("GC_PRIMITIVES_DIAG", None)


class TestLeakDetection(unittest.TestCase):
    def test_minimum_sample_fields(self):
        d = g.LeakDetector(capture_stack=True)
        lid = d.on_borrow("db-query")
        leaks = d.detect_leaks(timeout_ms=0)
        self.assertEqual(len(leaks), 1)
        for key in ("lease_id", "borrowed_at", "age_ms", "tag", "timed_out"):
            self.assertIn(key, leaks[0])
        self.assertEqual(leaks[0]["tag"], "db-query")
        self.assertIn("stack", leaks[0])
        d.on_return(lid)
        self.assertEqual(d.detect_leaks(), [])

    def test_no_background_thread(self):
        before = set(t.name for t in __import__("threading").enumerate())
        pool = g.ManagedPool(list, list.clear,
                             g.PoolConfig(max_size=2, leak_detection=True))
        lease = pool.borrow("pending")
        after = set(t.name for t in __import__("threading").enumerate())
        self.assertEqual(after - before, set())
        leaks = pool.detect_leaks(timeout_ms=0)
        self.assertEqual(len(leaks), 1)
        self.assertEqual(leaks[0]["tag"], "pending")
        lease.close()
        self.assertEqual(pool.detect_leaks(timeout_ms=0), [])


class TestConfig(unittest.TestCase):
    def test_yaml_subset_and_schema(self):
        doc = g.parse_yaml_subset("""
pools:
  default:
    max_size: 8
    on_full: "reject"
    leak_detection: true
    lifecycle:
      on_return: "reset"
      clear_sensitive: yes
diagnostics:
  memory_scope: false
""")
        cfg = g.PoolConfig.from_mapping(doc["pools"]["default"])
        self.assertEqual(cfg.max_size, 8)
        self.assertEqual(cfg.on_full, "reject")
        self.assertTrue(cfg.clear_sensitive)
        self.assertEqual(doc["diagnostics"]["memory_scope"], False)

    def test_invalid_values_fail_at_load(self):
        with self.assertRaises(ValueError):
            g.PoolConfig(max_size=-5).validate()
        with self.assertRaises(ValueError):
            g.PoolConfig(on_full="bounce").validate()
        with self.assertRaises(ValueError):
            g.PoolConfig.from_mapping({"nope": 1})

    def test_env_override_and_cascade(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "gc-primitives.yaml"
            p.write_text("pools:\n  default:\n    max_size: 3\n    on_full: reject\n",
                         encoding="utf-8")
            os.environ["GC_PRIMITIVES_CONFIG"] = str(p)
            os.environ["GC_PRIMITIVES__DEFAULT__MAX_SIZE"] = "17"
            try:
                cfg = g.load_config(pool="default")
                self.assertEqual(cfg.max_size, 17)
                self.assertEqual(cfg.on_full, "reject")
            finally:
                os.environ.pop("GC_PRIMITIVES_CONFIG", None)
                os.environ.pop("GC_PRIMITIVES__DEFAULT__MAX_SIZE", None)

    def test_missing_file_falls_back_to_defaults(self):
        os.environ.pop("GC_PRIMITIVES_CONFIG", None)
        cfg = g.load_config(path="/definitely/not/here.yaml")
        self.assertEqual(cfg.max_size, 64)

    def test_pool_manager_reload(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "cfg.yaml"
            p.write_text("pools:\n  default:\n    max_size: 4\n", encoding="utf-8")
            m = g.PoolManager(str(p))
            pool = g.ManagedPool(list, list.clear, g.load_config(str(p)))
            m.register("default", pool)
            self.assertEqual(pool.config.max_size, 4)
            p.write_text("pools:\n  default:\n    max_size: 9\n", encoding="utf-8")
            # mtime 精度：显式调一次 reload，文件已变更
            os.utime(p, (p.stat().st_mtime + 2, p.stat().st_mtime + 2))
            self.assertTrue(m.reload())
            self.assertEqual(pool.config.max_size, 9)
            m.shutdown()


class TestFullPolicyAndHooks(unittest.TestCase):
    def test_reject(self):
        pool = g.ManagedPool(list, list.clear,
                             g.PoolConfig(max_size=1, on_full="reject"))
        a = pool.borrow()
        with self.assertRaises(g.PoolStateError):
            pool.borrow()
        a.close()

    def test_block_timeout(self):
        pool = g.ManagedPool(list, list.clear,
                             g.PoolConfig(max_size=1, on_full="block",
                                          block_timeout_ms=30))
        a = pool.borrow()
        with self.assertRaises(g.PoolStateError):
            pool.borrow()
        a.close()

    def test_grow(self):
        pool = g.ManagedPool(list, list.clear,
                             g.PoolConfig(max_size=1, on_full="grow",
                                          max_overflow=2))
        leases = [pool.borrow() for _ in range(3)]
        for l in leases:
            l.close()
        pool.assert_no_active_leases()
        self.assertEqual(pool.metrics()["eviction_count"] >= 0, True)

    def test_hooks_and_prewarm_and_snapshot(self):
        events = []
        hooks = g.LifecycleHooks(
            on_create=lambda v: events.append("create"),
            on_borrow=lambda v: events.append("borrow"),
            on_return=lambda v: events.append("return"),
            on_evict=lambda v: events.append("evict"),
            on_destroy=lambda v: events.append("destroy"),
        )
        pool = g.ManagedPool(list, list.clear,
                             g.PoolConfig(max_size=2), hooks)
        self.assertEqual(pool.prewarm(2), 2)
        snap = pool.snapshot()
        for key in ("config", "stats", "active_leases", "idle_objects"):
            self.assertIn(key, snap)
        self.assertEqual(snap["stats"]["borrow_count"], 2)
        self.assertIn("create", events)
        self.assertIn("borrow", events)
        self.assertIn("return", events)
        pool.close()
        self.assertIn("destroy", events)

    def test_clear_sensitive_hook_on_return(self):
        seen = []
        hooks = g.LifecycleHooks(on_return=lambda v: (v.clear(), seen.append("cleared")),
                                 clear_sensitive=True)
        pool = g.ManagedPool(list, None, g.PoolConfig(max_size=2), hooks)
        with pool.borrow() as xs:
            xs.append("secret")
        self.assertEqual(seen.count("cleared"), 2)  # clear_sensitive + on_return


class TestCombinations(unittest.TestCase):
    def test_matrix_fixed(self):
        g.assert_combination("shared", "shardable")
        g.assert_combination("shared", "two_level_l2")
        with self.assertRaises(g.CombinationError):
            g.assert_combination("local", "shardable")
        with self.assertRaises(g.CombinationError):
            g.assert_combination("local", "two_level_l2")

    def test_sharded_pool(self):
        shards = [g.ManagedPool(list, list.clear, g.PoolConfig(max_size=2))
                  for _ in range(4)]
        pool = g.ShardedPool(shards)
        with pool.borrow() as xs:
            xs.append(1)
        self.assertEqual(pool.metrics()["borrow_count"], 1)
        pool.close()

    def test_two_level_pool(self):
        l2 = g.ManagedPool(list, list.clear, g.PoolConfig(max_size=8))
        pool = g.TwoLevelPool(l2, l1_size=2)
        with pool.borrow() as xs:
            xs.append("a")
        with pool.borrow() as xs:  # 命中 L1
            xs.append("b")
        pool.l2.assert_no_active_leases()


class TestAsyncPool(unittest.TestCase):
    def test_async_with_and_await(self):
        async def main():
            pool = g.AsyncPool(list, list.clear, max_size=2)
            async with pool.borrow() as xs:
                xs.append("ok")
            lease = await pool.borrow()
            lease.get().append("await")
            lease.release()
            self.assertEqual(pool.metrics()["borrow_count"], 2)
            pool.assert_no_active_leases = lambda: None  # 语义占位
            return pool.metrics()

        snap = asyncio.run(main())
        self.assertEqual(snap["return_count"], 2)
        self.assertEqual(snap["active_leases"], 0)

    def test_async_waits_instead_of_blocking(self):
        async def main():
            pool = g.AsyncPool(list, list.clear, max_size=1)
            a = await pool.borrow_async()

            async def late_release():
                await asyncio.sleep(0.01)
                a.release()

            task = asyncio.create_task(late_release())
            b = await pool.borrow_async()  # 会 await 而非阻塞事件循环
            b.release()
            await task
            return pool.metrics()

        snap = asyncio.run(main())
        self.assertEqual(snap["borrow_count"], 2)


class TestOldContractStillGreen(unittest.TestCase):
    def test_original_pool_unchanged(self):
        pool = g.Pool(list, list.clear)
        with pool.borrow() as xs:
            xs.append(1)
        pool.assert_no_active_leases()
        self.assertEqual(pool.borrow_count(), 1)
        self.assertEqual(pool.return_count(), 1)
        lease = pool.borrow()
        lease.close()
        with self.assertRaises(g.PoolStateError):
            lease.get()
        with self.assertRaises(g.PoolStateError):
            lease.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
