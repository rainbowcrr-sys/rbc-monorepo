package gcprimitives

// gc-primitives 0.2.0 增量能力测试（与七语言同口径）。
// 旧 pool_test.go 必须同时全绿。

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func strFactory() (string, bool) { return "", true }
func strRecycler(s *string) error { *s = ""; return nil }

func TestV020MetricsFields(t *testing.T) {
	m := MetricsSnapshot()
	b, _ := json.Marshal(m)
	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	if len(got) != 16 || len(MetricsFields) != 16 {
		t.Fatalf("metrics fields = %d, want 16", len(got))
	}
	for _, k := range MetricsFields {
		if _, ok := got[k]; !ok {
			t.Errorf("missing field %s", k)
		}
	}
}

func TestV020Collector(t *testing.T) {
	c := &MetricsCollector{}
	c.RecordBorrow(false, 1, true)
	c.RecordBorrow(true, 2, false)
	c.RecordReturn(3)
	c.RecordReturn(5)
	s := c.Snapshot(8, 1, false)
	if s.BorrowCount != 2 || s.ReturnCount != 2 || s.ActiveLeases != 0 {
		t.Fatalf("bad counters: %+v", s)
	}
	if s.HitRate != 0.5 || s.Created != 1 || s.WaitTimeMax != 2 {
		t.Fatalf("bad derived: %+v", s)
	}
}

func TestV020YAMLAndSchema(t *testing.T) {
	text := "pools:\n  default:\n    max_size: 8\n    on_full: \"reject\"\n" +
		"    leak_detection: true\n    lifecycle:\n      on_return: \"reset\"\n" +
		"      clear_sensitive: yes\ndiagnostics:\n  memory_scope: false\n"
	flat, err := ParseYAMLSubset(text)
	if err != nil {
		t.Fatal(err)
	}
	if flat["pools.default.max_size"] != "8" || flat["pools.default.on_full"] != "reject" {
		t.Fatalf("bad flat: %+v", flat)
	}
	if flat["pools.default.lifecycle.clear_sensitive"] != "yes" ||
		flat["diagnostics.memory_scope"] != "false" {
		t.Fatalf("bad nested: %+v", flat)
	}
	bad := DefaultConfig()
	bad.MaxSize = -5
	if err := bad.Validate(); err == nil {
		t.Fatal("expected max_size validation error")
	}
	bad = DefaultConfig()
	bad.OnFull = "bounce"
	if err := bad.Validate(); err == nil {
		t.Fatal("expected on_full validation error")
	}
}

func TestV020ConfigEnvOverride(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "gc-primitives.yaml")
	if err := os.WriteFile(p, []byte("pools:\n  default:\n    max_size: 3\n    on_full: reject\n"), 0644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GC_PRIMITIVES__DEFAULT__MAX_SIZE", "17")
	cfg, err := LoadConfig(p, "default")
	if err != nil {
		t.Fatal(err)
	}
	if cfg.MaxSize != 17 || cfg.OnFull != Reject {
		t.Fatalf("env override failed: %+v", cfg)
	}
}

func TestV020MemoryScopeDisabled(t *testing.T) {
	t.Setenv(DiagEnv, "")
	calls := 0
	stop := MemoryScope("disabled", func(ScopeReport) { calls++ }, "", nil)
	stop()
	if calls != 0 {
		t.Fatal("scope should be no-op when diag disabled")
	}
}

func TestV020MemoryScopeEnabled(t *testing.T) {
	t.Setenv(DiagEnv, "1")
	var names []string
	inner := MemoryScope("inner", func(r ScopeReport) { names = append(names, r.Name) }, "", nil)
	outer := MemoryScope("outer", func(r ScopeReport) { names = append(names, r.Name) }, "", nil)
	_ = make([]byte, 4096)
	inner()
	outer()
	if len(names) != 2 || names[0] != "inner" || names[1] != "outer" {
		t.Fatalf("nesting order wrong: %v", names)
	}
}

func TestV020LeakSampling(t *testing.T) {
	d := NewLeakDetector(true)
	id := d.OnBorrow("db-query")
	leaks := d.DetectLeaks(0)
	if len(leaks) != 1 {
		t.Fatalf("want 1 leak, got %d", len(leaks))
	}
	if leaks[0].Tag != "db-query" || leaks[0].LeaseID == "" || !leaks[0].TimedOut {
		t.Fatalf("bad sample: %+v", leaks[0])
	}
	if leaks[0].Stack == "" {
		t.Fatal("Go 应自带调用栈快照")
	}
	d.OnReturn(id)
	if len(d.DetectLeaks(0)) != 0 {
		t.Fatal("leak not cleared")
	}
}

func newCfg(n int64, p OnFull) PoolConfig {
	c := DefaultConfig()
	c.MaxSize = n
	c.OnFull = p
	return c
}

func TestV020FullPolicies(t *testing.T) {
	// reject
	p1, err := NewManagedPool(strFactory, strRecycler,
		newCfg(1, Reject), LifecycleHooks[string]{})
	if err != nil {
		t.Fatal(err)
	}
	a, err := p1.Borrow("")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := p1.Borrow(""); !errors.Is(err, ErrPoolExhausted) {
		t.Fatalf("want ErrPoolExhausted, got %v", err)
	}
	if err := a.Close(); err != nil {
		t.Fatal(err)
	}

	// block + ctx timeout
	c := newCfg(1, Block)
	p2, err := NewManagedPool(strFactory, strRecycler, c, LifecycleHooks[string]{})
	if err != nil {
		t.Fatal(err)
	}
	b, err := p2.Borrow("")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	if _, err := p2.BorrowCtx(ctx, ""); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("want DeadlineExceeded, got %v", err)
	}
	if err := b.Close(); err != nil {
		t.Fatal(err)
	}

	// grow
	g := newCfg(1, Grow)
	g.MaxOverflow = 2
	p3, err := NewManagedPool(strFactory, strRecycler, g, LifecycleHooks[string]{})
	if err != nil {
		t.Fatal(err)
	}
	leases := make([]*ManagedLease[string], 3)
	for i := range leases {
		leases[i], err = p3.Borrow("")
		if err != nil {
			t.Fatal(err)
		}
	}
	for _, l := range leases {
		if err := l.Close(); err != nil {
			t.Fatal(err)
		}
	}
	if err := p3.AssertNoActiveLeases(); err != nil {
		t.Fatal(err)
	}
}

func TestV020BorrowContextCancelled(t *testing.T) {
	p, err := New(2, strFactory, strRecycler)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := BorrowContext(ctx, p); !errors.Is(err, context.Canceled) {
		t.Fatalf("want Canceled, got %v", err)
	}
	l, err := BorrowContext(context.Background(), p)
	if err != nil {
		t.Fatal(err)
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	if err := p.AssertNoActiveLeases(); err != nil {
		t.Fatal(err)
	}
}

func TestV020HooksPrewarmSnapshot(t *testing.T) {
	events := []string{}
	h := LifecycleHooks[string]{
		OnCreate:  func(*string) { events = append(events, "create") },
		OnBorrow:  func(*string) { events = append(events, "borrow") },
		OnReturn:  func(*string) { events = append(events, "return") },
		OnEvict:   func(*string) { events = append(events, "evict") },
		OnDestroy: func(*string) { events = append(events, "destroy") },
	}
	p, err := NewManagedPool(strFactory, strRecycler, DefaultConfig(), h)
	if err != nil {
		t.Fatal(err)
	}
	n, err := p.Prewarm(2)
	if err != nil || n != 2 {
		t.Fatalf("prewarm = %d, %v", n, err)
	}
	snap := p.Snapshot()
	for _, k := range []string{"config", "stats", "active_leases", "idle_objects"} {
		if _, ok := snap[k]; !ok {
			t.Errorf("snapshot missing %s", k)
		}
	}
	s := p.Metrics()
	if s.BorrowCount != 2 {
		t.Fatalf("borrow_count = %d, want 2", s.BorrowCount)
	}
	joined := strings.Join(events, ",")
	for _, want := range []string{"create", "borrow", "return"} {
		if !strings.Contains(joined, want) {
			t.Errorf("missing hook %s", want)
		}
	}
	p.Close()
	if !strings.Contains(strings.Join(events, ","), "destroy") {
		t.Error("missing destroy hook")
	}
}

func TestV020CombinationMatrix(t *testing.T) {
	if err := AssertCombination(KindShared, "shardable"); err != nil {
		t.Fatal(err)
	}
	if err := AssertCombination(KindLocal, "shardable"); !errors.Is(err, ErrCombination) {
		t.Fatalf("want ErrCombination, got %v", err)
	}
	if err := AssertCombination(KindLocal, "two_level_l2"); !errors.Is(err, ErrCombination) {
		t.Fatalf("want ErrCombination, got %v", err)
	}
}

func TestV020ShardedAndTwoLevel(t *testing.T) {
	shards := []*ManagedPool[string]{}
	for i := 0; i < 4; i++ {
		p, err := NewManagedPool(strFactory, strRecycler,
			newCfg(2, DropOldest), LifecycleHooks[string]{})
		if err != nil {
			t.Fatal(err)
		}
		shards = append(shards, p)
	}
	sp, err := NewShardedPool(shards, KindShared)
	if err != nil {
		t.Fatal(err)
	}
	l, err := sp.Borrow("")
	if err != nil {
		t.Fatal(err)
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	if sp.Metrics().BorrowCount != 1 {
		t.Fatalf("sharded borrow_count = %d", sp.Metrics().BorrowCount)
	}
	sp.Close()

	l2, err := NewManagedPool(strFactory, strRecycler,
		newCfg(8, DropOldest), LifecycleHooks[string]{})
	if err != nil {
		t.Fatal(err)
	}
	tp, err := NewTwoLevelPool(l2, 2, KindShared)
	if err != nil {
		t.Fatal(err)
	}
	tl, err := tp.Borrow("")
	if err != nil {
		t.Fatal(err)
	}
	if err := tl.Close(); err != nil {
		t.Fatal(err)
	}
	if err := l2.AssertNoActiveLeases(); err != nil {
		t.Fatal(err)
	}
}

func TestV020OldContractStillGreen(t *testing.T) {
	p, err := New(4, strFactory, strRecycler)
	if err != nil {
		t.Fatal(err)
	}
	l, err := p.Borrow()
	if err != nil {
		t.Fatal(err)
	}
	*l.Get() = "x"
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	if err := p.AssertNoActiveLeases(); err != nil {
		t.Fatal(err)
	}
	if p.BorrowCount() != 1 || p.ReturnCount() != 1 {
		t.Fatal("old counters broken")
	}
}
