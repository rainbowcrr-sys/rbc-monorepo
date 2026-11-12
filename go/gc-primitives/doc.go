// Package gcprimitives provides allocation-reducing object pooling primitives for Go.
//
// It is a Go port of the same conceptual contract as the Java, C++, Python and
// Rust implementations in this repository (see SPEC.md at the repository root).
// The pool is bounded, hands out leases that must be closed explicitly, and
// resets objects on return through a caller-supplied Recycler hook.
//
// Go has no thread-local storage: goroutines migrate between OS threads, so the
// pool uses sharded bounded stacks (one shard per GOMAXPROCS) instead of
// per-thread state, and global atomic counters for diagnostics. This is an
// explicitly documented concurrency variant, not a strict port of the C2/C3
// thread-ownership rules.
//
// A minimal example:
//
//	p, err := gcprimitives.New(8,
//		func() ([]byte, bool) { return make([]byte, 0, 32), true },
//		func(b *[]byte) error { *b = (*b)[:0]; return nil })
//	if err != nil { return err }
//
//	l, err := p.Borrow()
//	if err != nil { return err }
//	defer l.Close()
//	*l.Get() = append(*l.Get(), "hello"...)
//
// Every borrowed lease must be closed (typically with defer). Misuse such as a
// double Close or Get after Close panics immediately; there is no switch to
// relax validation. Factory failures, reset failures and invalid capacities are
// reported as errors.
package gcprimitives
