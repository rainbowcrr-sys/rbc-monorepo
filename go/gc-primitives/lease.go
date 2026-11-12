package gcprimitives

import "sync/atomic"

const (
	leaseOpen   int32 = 0
	leaseClosed int32 = 1
)

// Lease is a borrow handle. It must be closed exactly once, usually with
// defer l.Close() immediately after Borrow. A Lease must not be copied and
// must not be passed to another goroutine for use; see SPEC.md section 8.2.
type Lease[T any] struct {
	pool  *Pool[T]
	shard int
	value *T
	state atomic.Int32
}

// Get returns the borrowed object. It panics if the lease has already been
// closed; misuse is always strictly validated, with no debug-only switch.
func (l *Lease[T]) Get() *T {
	if l.state.Load() != leaseOpen {
		panic("gcprimitives: lease is closed; Get() after Close()")
	}
	return l.value
}

// Close returns the object to the pool after invoking the Recycler hook.
//
// It panics on a double Close. A reset failure is returned as an error and the
// object is discarded instead of being cached, so a dirty object can never
// reach the next borrower. Callers that care about reset failures should not
// simply defer Close() and ignore its error.
func (l *Lease[T]) Close() error {
	if !l.state.CompareAndSwap(leaseOpen, leaseClosed) {
		panic("gcprimitives: lease closed twice")
	}
	return l.pool.release(l.shard, l.value)
}
