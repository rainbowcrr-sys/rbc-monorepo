package gcprimitives_test

import (
	"fmt"

	gcprimitives "github.com/rainbowcrr-sys/rbc-monorepo/go/gc-primitives"
)

func Example() {
	p, err := gcprimitives.New(8,
		func() ([]byte, bool) { return make([]byte, 0, 32), true },
		func(b *[]byte) error {
			*b = (*b)[:0]
			return nil
		})
	if err != nil {
		panic(err)
	}

	l, err := p.Borrow()
	if err != nil {
		panic(err)
	}
	*l.Get() = append(*l.Get(), "hello from Go"...)
	fmt.Println(string(*l.Get()))

	if err := l.Close(); err != nil {
		panic(err)
	}
	if err := p.AssertNoActiveLeases(); err != nil {
		panic(err)
	}
	// Output: hello from Go
}
