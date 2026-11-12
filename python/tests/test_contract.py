"""与 Java / C++ 版一一对应的契约测试，只用标准库 unittest。

运行：python3 -m unittest discover -s python/tests -v
"""
import sys
import threading
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from gc_primitives import Pool, PoolStateError, noop_recycler  # noqa: E402


def make_pool(capacity=8):
    return Pool(list, list.clear, capacity=capacity)


class ContractTest(unittest.TestCase):
    def test_reuse_same_instance(self):
        pool = make_pool()
        with pool.borrow() as a:
            pass
        with pool.borrow() as b:
            pass
        self.assertIs(a, b)
        self.assertEqual(pool.borrow_count(), 2)
        self.assertEqual(pool.return_count(), 2)
        self.assertEqual(pool.active_leases(), 0)

    def test_recycler_resets_on_return(self):
        pool = make_pool()
        with pool.borrow() as xs:
            xs.append("dirty")
        with pool.borrow() as xs:
            self.assertEqual(xs, [])
        pool.assert_no_active_leases()

    def test_double_close(self):
        pool = make_pool()
        lease = pool.borrow()
        lease.close()
        with self.assertRaises(PoolStateError):
            lease.close()
        pool.assert_no_active_leases()

    def test_get_after_close(self):
        pool = make_pool()
        lease = pool.borrow()
        lease.close()
        with self.assertRaises(PoolStateError):
            lease.get()

    def test_cross_thread_close(self):
        pool = make_pool()
        lease = pool.borrow()
        captured = []

        def wrong_thread():
            try:
                lease.close()
            except BaseException as e:  # noqa: BLE001
                captured.append(e)

        t = threading.Thread(target=wrong_thread)
        t.start()
        t.join()
        self.assertEqual(len(captured), 1)
        self.assertIsInstance(captured[0], PoolStateError)
        lease.close()
        pool.assert_no_active_leases()

    def test_cross_thread_get(self):
        pool = make_pool()
        lease = pool.borrow()
        captured = []

        def wrong_thread():
            try:
                lease.get()
            except BaseException as e:  # noqa: BLE001
                captured.append(e)

        t = threading.Thread(target=wrong_thread)
        t.start()
        t.join()
        self.assertIsInstance(captured[0], PoolStateError)
        lease.close()
        pool.assert_no_active_leases()

    def test_capacity_bounded(self):
        pool = make_pool(capacity=2)
        leases = [pool.borrow() for _ in range(4)]
        for lease in leases:
            lease.close()
        self.assertEqual(pool.capacity(), 2)
        self.assertLessEqual(pool.idle_count(), 2)
        pool.assert_no_active_leases()

    def test_factory_returns_none(self):
        pool = Pool(lambda: None, noop_recycler, capacity=4)
        with self.assertRaises(PoolStateError):
            pool.borrow()
        pool.assert_no_active_leases()

    def test_invalid_capacity(self):
        with self.assertRaises(ValueError):
            Pool(list, list.clear, capacity=0)

    def test_unreturned_lease_detectable(self):
        pool = make_pool()
        open_lease = pool.borrow()
        self.assertEqual(pool.active_leases(), 1)
        with self.assertRaises(PoolStateError):
            pool.assert_no_active_leases()
        open_lease.close()
        pool.assert_no_active_leases()

    def test_with_body_exception_still_returns(self):
        pool = make_pool()
        with self.assertRaises(ZeroDivisionError):
            with pool.borrow() as xs:
                xs.append(1)
                1 / 0
        pool.assert_no_active_leases()
        self.assertEqual(pool.borrow_count(), pool.return_count())

    def test_recycler_failure_discards_object(self):
        def bad_reset(xs):
            raise RuntimeError("reset failed")

        pool = Pool(list, bad_reset, capacity=4)
        lease = pool.borrow()
        lease.get().append("dirty")
        with self.assertRaises(RuntimeError):
            lease.close()
        # 租约已失效，计数已结算，脏对象没有回池
        self.assertFalse(lease.active)
        pool.assert_no_active_leases()
        self.assertEqual(pool.idle_count(), 0)

        # 下一次借用必须是全新的空对象，证明脏对象没被放回
        fresh = pool.borrow()
        self.assertEqual(fresh.get(), [])
        with self.assertRaises(RuntimeError):
            fresh.close()
        pool.assert_no_active_leases()

    def test_noop_recycler(self):
        pool = Pool(object, noop_recycler, capacity=4)
        with pool.borrow() as obj:
            self.assertIsNotNone(obj)
        pool.assert_no_active_leases()

    def test_thread_isolation(self):
        pool = make_pool()
        with pool.borrow() as main_obj:
            pass
        other = []

        def worker():
            with pool.borrow() as obj:
                other.append(obj)

        t = threading.Thread(target=worker)
        t.start()
        t.join()
        self.assertIsNot(main_obj, other[0])
        self.assertEqual(pool.active_leases(), 0)
        pool.assert_no_active_leases()


if __name__ == "__main__":
    unittest.main(verbosity=2)
