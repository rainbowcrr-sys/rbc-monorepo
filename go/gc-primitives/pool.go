package gcprimitives

import (
	"errors"
	"fmt"
	"runtime"
	"sync"
	"sync/atomic"
)

// Sentinel errors returned by New and Borrow.
var (
	// ErrInvalidCapacity is returned when capacity <= 0.
	ErrInvalidCapacity = errors.New("gcprimitives: capacity must be > 0")
	// ErrNilHook is returned when factory or recycler is nil.
	ErrNilHook = errors.New("gcprimitives: factory and recycler must not be nil")
	// ErrFactoryFailed is returned when the factory reports that it could not
	// create an object (the equivalent of a null/None factory result in the
	// other language ports).
	ErrFactoryFailed = errors.New("gcprimitives: factory failed to create an object")
)

// Factory creates a fresh object. The bool result is false when creation
// failed; this aligns with the "factory returned an empty value" check of the
// other language ports.
type Factory[T any] func() (T, bool)

// Recycler restores an object to a clean state on return. A non-nil error means
// the reset failed: the object is discarded and never returned to the pool, and
// the error is propagated to the caller of Lease.Close.
type Recycler[T any] func(*T) error

type shard[T any] struct {
	mu   sync.Mutex
	free []*T
}

// Pool is a bounded, sharded object pool. A single Pool value is safe for
// concurrent use by multiple goroutines; each shard keeps at most capacity idle
// objects.
//
// Go has no thread-local storage, so shards replace the per-thread idle stacks
// used by the Java, C++ and Python ports. See the package documentation and
// SPEC.md section 8.2.
type Pool[T any] struct {
	capacity int
	factory  Factory[T]
	recycler Recycler[T]
	shards   []shard[T]
	next     atomic.Uint64
	borrows  atomic.Int64
	returns  atomic.Int64
	active   atomic.Int64
}

// New creates a pool with one shard per GOMAXPROCS. capacity is the per-shard
// bound on idle objects, so the process-wide idle bound is
// capacity * GOMAXPROCS(0).
func New[T any](capacity int, factory Factory[T], recycler Recycler[T]) (*Pool[T], error) {
	if capacity <= 0 {
		return nil, ErrInvalidCapacity
	}
	if factory == nil || recycler == nil {
		return nil, ErrNilHook
	}
	n := runtime.GOMAXPROCS(0)
	if n < 1 {
		n = 1
	}
	return &Pool[T]{
		capacity: capacity,
		factory:  factory,
		recycler: recycler,
		shards:   make([]shard[T], n),
	}, nil
}

// Borrow takes an object from the pool and returns a lease that must be closed.
// The returned error is non-nil only when the factory fails; in that case no
// lease is created and the counters stay unchanged.
func (p *Pool[T]) Borrow() (*Lease[T], error) {
	idx := int((p.next.Add(1) - 1) % uint64(len(p.shards)))
	value, err := p.acquire(idx)
	if err != nil {
		return nil, err
	}
	p.borrows.Add(1)
	p.active.Add(1)
	return &Lease[T]{pool: p, shard: idx, value: value}, nil
}

func (p *Pool[T]) acquire(idx int) (*T, error) {
	s := &p.shards[idx]
	s.mu.Lock()
	if n := len(s.free); n > 0 {
		value := s.free[n-1]
		s.free = s.free[:n-1]
		s.mu.Unlock()
		return value, nil
	}
	s.mu.Unlock()

	// Call the factory outside the shard lock so a slow factory does not block
	// other borrowers of the same shard.
	value, ok := p.factory()
	if !ok {
		return nil, ErrFactoryFailed
	}
	return &value, nil
}

func (p *Pool[T]) release(idx int, value *T) error {
	// Settle the counters first: even when the recycler fails, the diagnostics
	// stay exact and the pool never reports a phantom active lease.
	p.returns.Add(1)
	p.active.Add(-1)

	if err := p.recycler(value); err != nil {
		return err // dirty object is dropped, never cached
	}

	s := &p.shards[idx]
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.free) < p.capacity {
		s.free = append(s.free, value)
	}
	return nil
}

// Capacity returns the per-shard bound on idle objects.
func (p *Pool[T]) Capacity() int { return p.capacity }

// ShardCount returns the number of shards (normally GOMAXPROCS).
func (p *Pool[T]) ShardCount() int { return len(p.shards) }

// IdleCount returns a snapshot of the total number of idle objects across all
// shards. It is a snapshot, not a linearizable global value.
func (p *Pool[T]) IdleCount() int {
	total := 0
	for i := range p.shards {
		s := &p.shards[i]
		s.mu.Lock()
		total += len(s.free)
		s.mu.Unlock()
	}
	return total
}

// ActiveLeases returns the number of borrows that have not been closed.
func (p *Pool[T]) ActiveLeases() int64 { return p.active.Load() }

// BorrowCount returns the total number of successful borrows.
func (p *Pool[T]) BorrowCount() int64 { return p.borrows.Load() }

// ReturnCount returns the total number of closed leases, including those whose
// reset failed and whose object was discarded.
func (p *Pool[T]) ReturnCount() int64 { return p.returns.Load() }

// AssertNoActiveLeases turns an outstanding borrow into an error. Use it in
// tests to detect missing lease.Close calls.
func (p *Pool[T]) AssertNoActiveLeases() error {
	if n := p.active.Load(); n != 0 {
		return fmt.Errorf("gcprimitives: %d borrow(s) not returned; every Borrow needs Close", n)
	}
	return nil
}
