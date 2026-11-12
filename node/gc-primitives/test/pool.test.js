// 契约测试直接 import 编译后的 dist/，验证的是真正会发布出去的产物。
// 运行： npm run build && npm test   （零测试框架依赖，只用 node:test）
import test from 'node:test';
import assert from 'node:assert/strict';

import {
  Pool,
  Lease,
  PoolStateError,
  DISPOSE,
} from '../dist/index.js';

function makePool(overrides = {}) {
  const created = { n: 0 };
  const resets = { n: 0 };
  const pool = new Pool({
    capacity: 4,
    factory: () => {
      created.n += 1;
      return { data: [] };
    },
    recycler: (obj) => {
      resets.n += 1;
      obj.data.length = 0;
    },
    ...overrides,
  });
  return { pool, created, resets };
}

function reuse(lease) {
  lease.value.data.push('x');
  lease.return();
}

test('C1 借出-使用-归还，计数精确', () => {
  const { pool, created, resets } = makePool();
  const lease = pool.borrow();
  assert.ok(lease instanceof Lease);
  assert.deepEqual(lease.value.data, []);
  reuse(lease);

  const s = pool.stats();
  assert.equal(s.active, 0);
  assert.equal(s.borrowCount, 1);
  assert.equal(s.returnCount, 1);
  assert.equal(s.idle, 1);
  assert.equal(s.created, 1);
  assert.equal(s.capacity, 4);
  assert.equal(s.closed, false);
  assert.equal(created.n, 1);
  assert.equal(resets.n, 1);
  assert.doesNotThrow(() => pool.assertNoActiveLeases());
});

test('C3 命中空闲槽时不再调用工厂，且复位生效', () => {
  const { pool, created } = makePool();
  for (let i = 0; i < 10; i++) {
    const lease = pool.borrow();
    assert.deepEqual(lease.value.data, [], `round ${i}: recycler did not reset`);
    reuse(lease);
  }
  assert.equal(created.n, 1, '工厂只应被调用一次');
  assert.equal(pool.stats().borrowCount, 10);
  assert.equal(pool.stats().returnCount, 10);
});

test('C3 空闲对象有界，超出 capacity 直接丢弃', () => {
  const { pool, created } = makePool({ capacity: 2 });
  // 先同时持有 32 个租约（否则顺序借还时池里永远只有 1 个空闲对象）
  const leases = Array.from({ length: 32 }, () => pool.borrow());
  for (const lease of leases) lease.return();
  assert.equal(pool.stats().idle, 2, '超出 capacity 的对象必须丢弃');
  assert.equal(pool.stats().active, 0);
  assert.equal(pool.stats().returnCount, 32);
  assert.equal(created.n, 32);
});

test('C4 复位失败：对象丢弃、错误透传、计数照常结算', () => {
  const boom = new Error('reset failed');
  const { pool, created } = makePool({
    capacity: 4,
    recycler: () => { throw boom; },
  });
  for (let i = 0; i < 6; i++) {
    const lease = pool.borrow();
    assert.throws(() => lease.return(), (e) => e === boom);
    assert.equal(pool.stats().idle, 0, '脏对象绝不能回池');
  }
  assert.equal(created.n, 6, '被丢弃的对象不应被复用');
  assert.equal(pool.stats().returnCount, 6);
  assert.equal(pool.stats().active, 0);
  assert.doesNotThrow(() => pool.assertNoActiveLeases());
});

test('C5 双重归还抛 PoolStateError', () => {
  const { pool } = makePool();
  const lease = pool.borrow();
  lease.return();
  assert.throws(() => lease.return(), PoolStateError);
  assert.throws(() => lease.close(), PoolStateError);
  assert.throws(() => lease.dispose(), PoolStateError);
  assert.equal(pool.stats().returnCount, 1, '第二次归还不能重复结算');
  assert.doesNotThrow(() => pool.assertNoActiveLeases());
});

test('C5 归还后读取 value 抛 PoolStateError', () => {
  const { pool } = makePool();
  const lease = pool.borrow();
  lease.value.data.push('x');
  lease.return();
  assert.throws(() => lease.value, PoolStateError);
  assert.equal(lease.returned, true);
});

test('C5 工厂返回空值抛 PoolStateError', () => {
  const { pool } = makePool({ factory: () => null });
  assert.throws(() => pool.borrow(), PoolStateError);
  assert.equal(pool.stats().borrowCount, 0);
  assert.equal(pool.stats().active, 0);
  assert.doesNotThrow(() => pool.assertNoActiveLeases());

  const p2 = new Pool({ factory: () => undefined });
  assert.throws(() => p2.borrow(), PoolStateError);
});

test('C5 capacity <= 0 / 非整数 / 钩子非函数 抛 PoolStateError', () => {
  assert.throws(() => new Pool({ capacity: 0, factory: () => ({}) }), PoolStateError);
  assert.throws(() => new Pool({ capacity: -1, factory: () => ({}) }), PoolStateError);
  assert.throws(() => new Pool({ capacity: 1.5, factory: () => ({}) }), PoolStateError);
  assert.throws(() => new Pool({ factory: null }), PoolStateError);
  assert.throws(() => new Pool({ factory: () => ({}), recycler: 42 }), PoolStateError);
});

test('C2 关闭池后拒绝新借出，且清空空闲对象', () => {
  const { pool } = makePool();
  const lease = pool.borrow();
  lease.return();
  assert.equal(pool.stats().idle, 1);

  pool.close();
  assert.equal(pool.closed, true);
  assert.equal(pool.stats().idle, 0);
  assert.throws(() => pool.borrow(), PoolStateError);

  // 关闭前已借出的租约仍可归还，但对象不再入池
  const outstanding = makePool();
  const l2 = outstanding.pool.borrow();
  outstanding.pool.close();
  assert.doesNotThrow(() => l2.return());
  assert.equal(outstanding.pool.stats().idle, 0);
  assert.equal(outstanding.pool.stats().active, 0);
  assert.doesNotThrow(() => outstanding.pool.assertNoActiveLeases());
});

test('未归还租约被 assertNoActiveLeases 精确发现', () => {
  const { pool } = makePool();
  const lease = pool.borrow();
  assert.throws(() => pool.assertNoActiveLeases(), PoolStateError);
  assert.equal(pool.stats().active, 1);
  lease.return();
  assert.doesNotThrow(() => pool.assertNoActiveLeases());
});

test('DISPOSE 钩子存在、不可枚举，且调用等于 return', () => {
  const { pool } = makePool();
  const lease = pool.borrow();
  assert.equal(typeof lease[DISPOSE], 'function');
  const desc = Object.getOwnPropertyDescriptor(lease, DISPOSE);
  assert.ok(desc, 'DISPOSE 应是实例自有属性');
  assert.equal(desc.enumerable, false);
  lease[DISPOSE]();
  assert.equal(lease.returned, true);
  assert.equal(pool.stats().returnCount, 1);
  assert.doesNotThrow(() => pool.assertNoActiveLeases());
});

test('默认 capacity 为 16，默认 recycler 是空操作', () => {
  const pool = new Pool({ factory: () => ({ n: 0 }) });
  assert.equal(pool.capacity, 16);
  const lease = pool.borrow();
  lease.value.n = 7;
  assert.doesNotThrow(() => lease.return());
  const second = pool.borrow();
  assert.equal(second.value.n, 7, '无 recycler 时不复位，由调用方负责');
  second.return();
  pool.assertNoActiveLeases();
});

test('并发借用（事件循环内交错）计数仍精确', async () => {
  const { pool } = makePool({ capacity: 8 });
  const jobs = Array.from({ length: 50 }, async (_, i) => {
    await Promise.resolve();
    const lease = pool.borrow();
    lease.value.data.push(i);
    await Promise.resolve();
    lease.return();
  });
  await Promise.all(jobs);
  const s = pool.stats();
  assert.equal(s.borrowCount, 50);
  assert.equal(s.returnCount, 50);
  assert.equal(s.active, 0);
  assert.doesNotThrow(() => pool.assertNoActiveLeases());
});
