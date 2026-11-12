package gcprimitives

import (
	"errors"
	"sync"
	"sync/atomic"
	"testing"
)

func resetBytes(b *[]byte) error {
	*b = (*b)[:0]
	return nil
}

func newBytePool(t *testing.T, capacity int, recycler Recycler[[]byte]) (*Pool[[]byte], *atomic.Int64) {
	t.Helper()
	created := &atomic.Int64{}
	p, err := New[[]byte](capacity, func() ([]byte, bool) {
		created.Add(1)
		return make([]byte, 0, 16), true
	}, recycler)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return p, created
}

func mustPanic(t *testing.T, f func()) {
	t.Helper()
	defer func() {
		if recover() == nil {
			t.Fatal("expected a panic, but none occurred")
		}
	}()
	f()
}

func TestReuseAfterReset(t *testing.T) {
	p, created := newBytePool(t, 2, resetBytes)
	rounds := p.ShardCount() * 3
	for i := 0; i < rounds; i++ {
		l, err := p.Borrow()
		if err != nil {
			t.Fatalf("Borrow: %v", err)
		}
		if len(*l.Get()) != 0 {
			t.Fatalf("round %d: Recycler did not reset the object", i)
		}
		*l.Get() = append(*l.Get(), 'x')
		if err := l.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	}
	if got := created.Load(); got > int64(p.ShardCount()) {
		t.Fatalf("factory called %d times for %d shards; idle objects were not reused", got, p.ShardCount())
	}
	if err := p.AssertNoActiveLeases(); err != nil {
		t.Fatal(err)
	}
}

func TestDiagnostics(t *testing.T) {
	p, _ := newBytePool(t, 4, resetBytes)
	if got := p.Capacity(); got != 4 {
		t.Fatalf("Capacity = %d, want 4", got)
	}
	l, err := p.Borrow()
	if err != nil {
		t.Fatal(err)
	}
	if got := p.ActiveLeases(); got != 1 {
		t.Fatalf("ActiveLeases = %d, want 1", got)
	}
	if err := p.AssertNoActiveLeases(); err == nil {
		t.Fatal("AssertNoActiveLeases should fail while a lease is open")
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	if p.ActiveLeases() != 0 || p.BorrowCount() != 1 || p.ReturnCount() != 1 {
		t.Fatalf("counters: active=%d borrows=%d returns=%d", p.ActiveLeases(), p.BorrowCount(), p.ReturnCount())
	}
	if got := p.IdleCount(); got != 1 {
		t.Fatalf("IdleCount = %d, want 1", got)
	}
	if err := p.AssertNoActiveLeases(); err != nil {
		t.Fatal(err)
	}
}

func TestInvalidCapacityAndNilHooks(t *testing.T) {
	_, err := New[[]byte](0, func() ([]byte, bool) { return nil, true }, resetBytes)
	if !errors.Is(err, ErrInvalidCapacity) {
		t.Fatalf("capacity 0: got %v, want ErrInvalidCapacity", err)
	}
	_, err = New[[]byte](-1, func() ([]byte, bool) { return nil, true }, resetBytes)
	if !errors.Is(err, ErrInvalidCapacity) {
		t.Fatalf("capacity -1: got %v, want ErrInvalidCapacity", err)
	}
	_, err = New[[]byte](2, nil, resetBytes)
	if !errors.Is(err, ErrNilHook) {
		t.Fatalf("nil factory: got %v, want ErrNilHook", err)
	}
	_, err = New[[]byte](2, func() ([]byte, bool) { return nil, true }, nil)
	if !errors.Is(err, ErrNilHook) {
		t.Fatalf("nil recycler: got %v, want ErrNilHook", err)
	}
}

func TestFactoryFailure(t *testing.T) {
	p, err := New[[]byte](2, func() ([]byte, bool) { return nil, false }, resetBytes)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := p.Borrow(); !errors.Is(err, ErrFactoryFailed) {
		t.Fatalf("got %v, want ErrFactoryFailed", err)
	}
	if p.ActiveLeases() != 0 || p.BorrowCount() != 0 {
		t.Fatalf("failed borrow polluted counters: active=%d borrows=%d", p.ActiveLeases(), p.BorrowCount())
	}
	if err := p.AssertNoActiveLeases(); err != nil {
		t.Fatal(err)
	}
}

func TestDoubleClosePanics(t *testing.T) {
	p, _ := newBytePool(t, 2, resetBytes)
	l, err := p.Borrow()
	if err != nil {
		t.Fatal(err)
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	mustPanic(t, func() { _ = l.Close() })
	if err := p.AssertNoActiveLeases(); err != nil {
		t.Fatal(err)
	}
}

func TestGetAfterClosePanics(t *testing.T) {
	p, _ := newBytePool(t, 2, resetBytes)
	l, err := p.Borrow()
	if err != nil {
		t.Fatal(err)
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	mustPanic(t, func() { _ = l.Get() })
}

func TestResetFailureDiscardsObject(t *testing.T) {
	boom := errors.New("reset failed")
	created := &atomic.Int64{}
	p, err := New[[]byte](2, func() ([]byte, bool) {
		created.Add(1)
		return make([]byte, 0, 8), true
	}, func(*[]byte) error { return boom })
	if err != nil {
		t.Fatal(err)
	}
	rounds := p.ShardCount() * 2
	for i := 0; i < rounds; i++ {
		l, err := p.Borrow()
		if err != nil {
			t.Fatal(err)
		}
		if err := l.Close(); !errors.Is(err, boom) {
			t.Fatalf("round %d: Close error = %v, want the reset error", i, err)
		}
		if got := p.IdleCount(); got != 0 {
			t.Fatalf("round %d: IdleCount = %d, dirty object was cached", i, got)
		}
	}
	if got := created.Load(); got != int64(rounds) {
		t.Fatalf("factory called %d times for %d borrows; a discarded object was reused", got, rounds)
	}
	if p.ReturnCount() != int64(rounds) || p.ActiveLeases() != 0 {
		t.Fatalf("counters: returns=%d active=%d", p.ReturnCount(), p.ActiveLeases())
	}
}

func TestIdleIsBounded(t *testing.T) {
	p, _ := newBytePool(t, 1, resetBytes)
	for i := 0; i < 64; i++ {
		l, err := p.Borrow()
		if err != nil {
			t.Fatal(err)
		}
		if err := l.Close(); err != nil {
			t.Fatal(err)
		}
	}
	if got, max := p.IdleCount(), p.ShardCount(); got > max {
		t.Fatalf("IdleCount = %d, exceeds bound %d (capacity 1 per shard)", got, max)
	}
	if err := p.AssertNoActiveLeases(); err != nil {
		t.Fatal(err)
	}
}

func TestConcurrentBorrowReturn(t *testing.T) {
	p, _ := newBytePool(t, 8, resetBytes)
	const goroutines, iterations = 8, 200
	var wg sync.WaitGroup
	for g := 0; g < goroutines; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < iterations; i++ {
				l, err := p.Borrow()
				if err != nil {
					t.Errorf("Borrow: %v", err)
					return
				}
				*l.Get() = append(*l.Get(), byte(i))
				if err := l.Close(); err != nil {
					t.Errorf("Close: %v", err)
					return
				}
			}
		}()
	}
	wg.Wait()
	if err := p.AssertNoActiveLeases(); err != nil {
		t.Fatal(err)
	}
	want := int64(goroutines * iterations)
	if p.BorrowCount() != want || p.ReturnCount() != want {
		t.Fatalf("counters: borrows=%d returns=%d, want %d", p.BorrowCount(), p.ReturnCount(), want)
	}
}
