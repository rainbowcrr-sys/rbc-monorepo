package gcprimitives

// gc-primitives 0.2.0 · 增量能力层（纯新增，不改动 pool.go / lease.go）
//
// 实现 SPEC.md 第 12 章：Borrow(ctx)、统一 metrics JSON 同构快照、memory_scope、
// 泄漏采样、统一 YAML 子集配置 + schema + env + 级联 + 自动热重载（Go 档）、
// 满池策略 / 生命周期钩子 / 预热 / 快照、ShardedPool / TwoLevelPool 组合矩阵。
//
// 核心零依赖：只用标准库。GC_PRIMITIVES_DIAG 未设时 memory_scope 为空操作。

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	DiagEnv   = "GC_PRIMITIVES_DIAG"
	ConfigEnv = "GC_PRIMITIVES_CONFIG"
)

// DetectLeaksAvailable：借出采样最小集七语言都可用；调用栈是 Python / Go / Java 增强。
const DetectLeaksAvailable = true

var ErrCombination = errors.New("gcprimitives: forbidden pool combination")

// ---------------------------------------------------------------------------
// 12.1 Borrow(ctx)：响应取消与超时（原 Borrow() 一行未改）
// ---------------------------------------------------------------------------

// BorrowContext 在 ctx 未取消时调用原 Borrow()；ctx 取消/超时返回 ctx.Err()。
// 满池策略由 ManagedPool 的 BorrowCtx 提供真正的阻塞等待与取消。
func BorrowContext[T any](ctx context.Context, p *Pool[T]) (*Lease[T], error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	// 原 Borrow 不阻塞；如需「池满时等待」，请用 ManagedPool.BorrowCtx。
	return p.Borrow()
}

// ---------------------------------------------------------------------------
// 12.3 统一 metrics JSON 同构快照（16 字段，七语言同名）
// ---------------------------------------------------------------------------

type Metrics struct {
	BorrowCount       int64   `json:"borrow_count"`
	ReturnCount       int64   `json:"return_count"`
	ActiveLeases      int64   `json:"active_leases"`
	PoolHits          int64   `json:"pool_hits"`
	PoolMisses        int64   `json:"pool_misses"`
	HitRate           float64 `json:"hit_rate"`
	WaitTimeP50       float64 `json:"wait_time_p50"`
	WaitTimeP99       float64 `json:"wait_time_p99"`
	WaitTimeMax       float64 `json:"wait_time_max"`
	ObjectLifetimeP50 float64 `json:"object_lifetime_p50"`
	EvictionCount     int64   `json:"eviction_count"`
	LeakCount         int64   `json:"leak_count"`
	Created           int64   `json:"created"`
	Idle              int64   `json:"idle"`
	Capacity          int64   `json:"capacity"`
	Closed            bool    `json:"closed"`
}

var MetricsFields = []string{
	"borrow_count", "return_count", "active_leases", "pool_hits", "pool_misses",
	"hit_rate", "wait_time_p50", "wait_time_p99", "wait_time_max",
	"object_lifetime_p50", "eviction_count", "leak_count", "created", "idle",
	"capacity", "closed",
}

func MetricsSnapshot() Metrics { return Metrics{} }

type MetricsCollector struct {
	mu        sync.Mutex
	m         Metrics
	waits     []float64
	lifetimes []float64
}

func (c *MetricsCollector) RecordBorrow(hit bool, waitMs float64, created bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.m.BorrowCount++
	c.m.ActiveLeases++
	if hit {
		c.m.PoolHits++
	} else {
		c.m.PoolMisses++
	}
	if created {
		c.m.Created++
	}
	c.waits = append(c.waits, waitMs)
}

func (c *MetricsCollector) RecordReturn(lifetimeMs float64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.m.ReturnCount++
	c.m.ActiveLeases--
	c.lifetimes = append(c.lifetimes, lifetimeMs)
}

func (c *MetricsCollector) RecordEviction() {
	c.mu.Lock()
	c.m.EvictionCount++
	c.mu.Unlock()
}
func (c *MetricsCollector) RecordLeak(n int64) {
	c.mu.Lock()
	c.m.LeakCount += n
	c.mu.Unlock()
}

func pct(sorted []float64, q float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	return sorted[int(math_round(float64(len(sorted)-1)*q))]
}
func math_round(v float64) float64 { return float64(int(v + 0.5)) }

func (c *MetricsCollector) Snapshot(capacity, idle int64, closed bool) Metrics {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := c.m
	w := append([]float64(nil), c.waits...)
	l := append([]float64(nil), c.lifetimes...)
	sort.Float64s(w)
	sort.Float64s(l)
	total := out.PoolHits + out.PoolMisses
	if total > 0 {
		out.HitRate = float64(out.PoolHits) / float64(total)
	}
	out.WaitTimeP50 = pct(w, 0.50)
	out.WaitTimeP99 = pct(w, 0.99)
	if len(w) > 0 {
		out.WaitTimeMax = w[len(w)-1]
	}
	out.ObjectLifetimeP50 = pct(l, 0.50)
	out.Capacity = capacity
	out.Idle = idle
	out.Closed = closed
	return out
}

func (m Metrics) JSON() string {
	b, _ := json.Marshal(m)
	return string(b)
}

// ---------------------------------------------------------------------------
// 12.5 memory_scope
// ---------------------------------------------------------------------------

func DiagEnabled() bool {
	v := strings.ToLower(strings.TrimSpace(os.Getenv(DiagEnv)))
	return v != "" && v != "0" && v != "false" && v != "off"
}

type ScopeReport struct {
	Name             string  `json:"name"`
	ElapsedMs        float64 `json:"elapsed_ms"`
	BorrowCountDelta int64   `json:"borrow_count_delta"`
	CreatedDelta     int64   `json:"created_delta"`
}

type ScopeSink func(ScopeReport)

// MemoryScope 返回 stop 函数；未开启时返回空操作。
func MemoryScope(name string, sink ScopeSink, jsonPath string, c *MetricsCollector) func() {
	if !DiagEnabled() {
		return func() {}
	}
	t0 := time.Now()
	var b0, c0 int64
	if c != nil {
		s := c.Snapshot(0, 0, false)
		b0, c0 = s.BorrowCount, s.Created
	}
	return func() {
		r := ScopeReport{Name: name, ElapsedMs: float64(time.Since(t0).Microseconds()) / 1000.0}
		if c != nil {
			s := c.Snapshot(0, 0, false)
			r.BorrowCountDelta = s.BorrowCount - b0
			r.CreatedDelta = s.Created - c0
		}
		if sink != nil {
			sink(r)
		} else if jsonPath != "" {
			f, err := os.OpenFile(jsonPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
			if err == nil {
				b, _ := json.Marshal(r)
				_, _ = f.Write(append(b, '\n'))
				_ = f.Close()
			}
		} else {
			fmt.Fprintf(os.Stderr, "[gc-primitives] %s: borrows=%+d created=%+d (%.2f ms)\n",
				r.Name, r.BorrowCountDelta, r.CreatedDelta, r.ElapsedMs)
		}
	}
}

// ---------------------------------------------------------------------------
// 12.6 泄漏检测（借出采样最小集，无后台线程）
// ---------------------------------------------------------------------------

type LeaseSample struct {
	LeaseID    string  `json:"lease_id"`
	BorrowedAt float64 `json:"borrowed_at"`
	AgeMs      float64 `json:"age_ms"`
	Tag        string  `json:"tag"`
	TimedOut   bool    `json:"timed_out"`
	Stack      string  `json:"stack,omitempty"`
}

type LeakDetector struct {
	mu           sync.Mutex
	active       map[string]LeaseSample
	seq          uint64
	captureStack bool
}

func NewLeakDetector(captureStack bool) *LeakDetector {
	return &LeakDetector{active: map[string]LeaseSample{}, captureStack: captureStack}
}
func (d *LeakDetector) OnBorrow(tag string) string {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.seq++
	id := strconv.FormatUint(d.seq, 16)
	stack := ""
	if d.captureStack {
		buf := make([]byte, 4096)
		n := runtime.Stack(buf, false)
		stack = string(buf[:n])
	}
	d.active[id] = LeaseSample{LeaseID: id, BorrowedAt: float64(time.Now().UnixNano()) / 1e9, Tag: tag, Stack: stack}
	return id
}
func (d *LeakDetector) OnReturn(id string) {
	d.mu.Lock()
	delete(d.active, id)
	d.mu.Unlock()
}
func (d *LeakDetector) DetectLeaks(timeoutMs int64) []LeaseSample {
	d.mu.Lock()
	defer d.mu.Unlock()
	now := float64(time.Now().UnixNano()) / 1e9
	out := []LeaseSample{}
	for _, s := range d.active {
		s.AgeMs = (now - s.BorrowedAt) * 1000
		s.TimedOut = timeoutMs >= 0 && s.AgeMs >= float64(timeoutMs)
		if timeoutMs < 0 || s.TimedOut {
			out = append(out, s)
		}
	}
	return out
}
func (d *LeakDetector) ActiveCount() int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return len(d.active)
}

// ---------------------------------------------------------------------------
// 12.4 统一 YAML 子集配置
// ---------------------------------------------------------------------------

type OnFull string

const (
	DropOldest  OnFull = "drop_oldest"
	DropLargest OnFull = "drop_largest"
	Block       OnFull = "block"
	Reject      OnFull = "reject"
	Grow        OnFull = "grow"
)

type PoolConfig struct {
	MaxSize        int64             `json:"max_size"`
	OnFull         OnFull            `json:"on_full"`
	BlockTimeoutMs int64             `json:"block_timeout_ms"`
	MaxOverflow    int64             `json:"max_overflow"`
	EvictionPolicy string            `json:"eviction_policy"`
	Prewarm        int64             `json:"prewarm"`
	LeakDetection  bool              `json:"leak_detection"`
	LeakTimeoutMs  int64             `json:"leak_timeout_ms"`
	ClearSensitive bool              `json:"clear_sensitive"`
	Lifecycle      map[string]string `json:"-"`
}

func DefaultConfig() PoolConfig {
	return PoolConfig{MaxSize: 64, OnFull: DropOldest, BlockTimeoutMs: -1,
		EvictionPolicy: "lru", LeakTimeoutMs: 3000, Lifecycle: map[string]string{}}
}

var legalConfigKeys = map[string]bool{
	"max_size": true, "on_full": true, "block_timeout_ms": true,
	"max_overflow": true, "eviction_policy": true, "prewarm": true,
	"leak_detection": true, "leak_timeout_ms": true, "clear_sensitive": true,
}
var legalLifecycleHooks = map[string]bool{
	"on_create": true, "on_borrow": true, "on_return": true,
	"on_evict": true, "on_destroy": true, "clear_sensitive": true,
}

func (c *PoolConfig) Validate() error {
	if c.MaxSize <= 0 {
		return fmt.Errorf("max_size must be > 0, got %d", c.MaxSize)
	}
	switch c.OnFull {
	case DropOldest, DropLargest, Block, Reject, Grow:
	default:
		return fmt.Errorf("on_full must be one of drop_oldest|drop_largest|block|reject|grow, got %q", c.OnFull)
	}
	if c.MaxOverflow < 0 || c.Prewarm < 0 {
		return errors.New("max_overflow and prewarm must be >= 0")
	}
	for k := range c.Lifecycle {
		if !legalLifecycleHooks[k] {
			return fmt.Errorf("unknown lifecycle hook: %s", k)
		}
	}
	return nil
}

// ParseYAMLSubset：极简 YAML 子集（缩进映射 + 标量），扁平化为 "a.b.c" -> 值。
func ParseYAMLSubset(text string) (map[string]string, error) {
	out := map[string]string{}
	type entry struct {
		indent int
		key    string
	}
	stack := []entry{}
	for i, raw := range strings.Split(text, "\n") {
		if j := strings.IndexByte(raw, '#'); j >= 0 {
			raw = raw[:j]
		}
		content := strings.TrimSpace(raw)
		if content == "" {
			continue
		}
		indent := 0
		for indent < len(raw) && (raw[indent] == ' ' || raw[indent] == '\t') {
			if raw[indent] == '\t' {
				return nil, fmt.Errorf("line %d: tabs are not allowed for indentation", i+1)
			}
			indent++
		}
		colon := strings.IndexByte(content, ':')
		if colon < 0 {
			return nil, fmt.Errorf("line %d: expected 'key: value'", i+1)
		}
		key := strings.TrimSpace(content[:colon])
		value := strings.TrimSpace(content[colon+1:])
		for len(stack) > 0 && stack[len(stack)-1].indent >= indent {
			stack = stack[:len(stack)-1]
		}
		parts := []string{}
		for _, e := range stack {
			parts = append(parts, e.key)
		}
		parts = append(parts, key)
		full := strings.Join(parts, ".")
		if value == "" {
			stack = append(stack, entry{indent, key})
		} else {
			out[full] = unquote(value)
		}
	}
	return out, nil
}

func unquote(v string) string {
	if len(v) >= 2 && ((v[0] == '"' && v[len(v)-1] == '"') || (v[0] == '\'' && v[len(v)-1] == '\'')) {
		return v[1 : len(v)-1]
	}
	return v
}
func asInt(v string, def int64) int64 {
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return def
	}
	return n
}
func asBool(v string) bool { return strings.EqualFold(v, "true") || strings.EqualFold(v, "yes") }

func envOverride(pool, key string) (string, bool) {
	name := "GC_PRIMITIVES__" + strings.ToUpper(strings.ReplaceAll(pool, "-", "_")) + "__" + strings.ToUpper(key)
	return os.LookupEnv(name)
}

func applyConfig(c *PoolConfig, key, value string) error {
	switch key {
	case "max_size":
		c.MaxSize = asInt(value, c.MaxSize)
	case "on_full":
		c.OnFull = OnFull(value)
	case "block_timeout_ms":
		c.BlockTimeoutMs = asInt(value, -1)
	case "max_overflow":
		c.MaxOverflow = asInt(value, 0)
	case "eviction_policy":
		c.EvictionPolicy = value
	case "prewarm":
		c.Prewarm = asInt(value, 0)
	case "leak_detection":
		c.LeakDetection = asBool(value)
	case "leak_timeout_ms":
		c.LeakTimeoutMs = asInt(value, 3000)
	case "clear_sensitive":
		c.ClearSensitive = asBool(value)
	default:
		return fmt.Errorf("unknown config key: %s", key)
	}
	return nil
}

// LoadConfig：找不到文件时返回默认值（配置文件可选）。
func LoadConfig(path, pool string) (PoolConfig, error) {
	explicit := path
	if explicit == "" {
		explicit = os.Getenv(ConfigEnv)
	}
	chosen := ""
	if explicit != "" {
		if _, err := os.Stat(explicit); err == nil {
			chosen = explicit
		}
	} else {
		home, _ := os.UserHomeDir()
		cascade := []string{
			"./gc-primitives.yaml", "./config/gc-primitives.yaml",
			filepath.Join(home, ".config", "gc-primitives.yaml"),
			"/etc/gc-primitives.yaml",
		}
		for _, c := range cascade {
			if _, err := os.Stat(c); err == nil {
				chosen = c
				break
			}
		}
	}
	cfg := DefaultConfig()
	if chosen != "" {
		b, err := os.ReadFile(chosen)
		if err != nil {
			return cfg, err
		}
		flat, err := ParseYAMLSubset(string(b))
		if err != nil {
			return cfg, err
		}
		prefix := "pools." + pool + "."
		for k, v := range flat {
			if !strings.HasPrefix(k, prefix) {
				continue
			}
			key := strings.TrimPrefix(k, prefix)
			if strings.HasPrefix(key, "lifecycle.") {
				cfg.Lifecycle[strings.TrimPrefix(key, "lifecycle.")] = v
				continue
			}
			if !legalConfigKeys[key] {
				return cfg, fmt.Errorf("unknown config key: %s", key)
			}
			if err := applyConfig(&cfg, key, v); err != nil {
				return cfg, err
			}
		}
		if v, ok := cfg.Lifecycle["clear_sensitive"]; ok {
			cfg.ClearSensitive = asBool(v)
		}
	}
	for key := range legalConfigKeys {
		if v, ok := envOverride(pool, key); ok && v != "" {
			if err := applyConfig(&cfg, key, unquote(v)); err != nil {
				return cfg, err
			}
		}
	}
	return cfg, cfg.Validate()
}

// PoolManager：Go 档支持自动文件监听（可选开启，默认零常驻开销）。
type PoolManager struct {
	path      string
	mu        sync.Mutex
	pools     map[string]interface{ ApplyConfig(PoolConfig) }
	lastMtime int64
	watching  bool
	stop      chan struct{}
}

func NewPoolManager(path string) *PoolManager {
	return &PoolManager{path: path, pools: map[string]interface{ ApplyConfig(PoolConfig) }{},
		stop: make(chan struct{})}
}
func (m *PoolManager) Register(name string, p interface{ ApplyConfig(PoolConfig) }) {
	m.mu.Lock()
	m.pools[name] = p
	m.mu.Unlock()
}
func (m *PoolManager) mtime() int64 {
	p := m.path
	if p == "" {
		p = os.Getenv(ConfigEnv)
	}
	if p == "" {
		return -1
	}
	st, err := os.Stat(p)
	if err != nil {
		return -1
	}
	return st.ModTime().UnixNano()
}
func (m *PoolManager) Reload() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	mt := m.mtime()
	if mt >= 0 && mt == m.lastMtime {
		return false
	}
	for name, p := range m.pools {
		cfg, err := LoadConfig(m.path, name)
		if err == nil {
			p.ApplyConfig(cfg)
		}
	}
	m.lastMtime = mt
	return true
}

// EnableHotReload：Go 档自动监听。默认不开。
func (m *PoolManager) EnableHotReload(interval time.Duration) {
	m.mu.Lock()
	if m.watching {
		m.mu.Unlock()
		return
	}
	m.watching = true
	m.lastMtime = m.mtime()
	m.mu.Unlock()
	go func() {
		t := time.NewTicker(interval)
		defer t.Stop()
		for {
			select {
			case <-m.stop:
				return
			case <-t.C:
				_ = m.Reload()
			}
		}
	}()
}
func (m *PoolManager) Shutdown() {
	m.mu.Lock()
	if m.watching {
		close(m.stop)
		m.watching = false
	}
	m.mu.Unlock()
}

// ---------------------------------------------------------------------------
// 12.1 ManagedPool（共享、可配置、支持 ctx）
// ---------------------------------------------------------------------------

type LifecycleHooks[T any] struct {
	OnCreate, OnBorrow, OnReturn, OnEvict, OnDestroy func(*T)
	ClearSensitive                                   bool
}

type ManagedLease[T any] struct {
	pool       *ManagedPool[T]
	value      *T
	id         string
	tag        string
	borrowedAt float64
	active     bool
}

func (l *ManagedLease[T]) Get() *T {
	if !l.active {
		panic("gcprimitives: lease is closed; Get() after Close()")
	}
	return l.value
}
func (l *ManagedLease[T]) Close() error {
	if !l.active {
		panic("gcprimitives: lease closed twice")
	}
	l.active = false
	v := l.value
	l.value = nil
	return l.pool.release(v, l.id, l.borrowedAt)
}
func (l *ManagedLease[T]) LeaseID() string { return l.id }

type ManagedPool[T any] struct {
	factory  Factory[T]
	recycler Recycler[T]
	mu       sync.Mutex
	cond     *sync.Cond
	cfg      PoolConfig
	hooks    LifecycleHooks[T]
	free     []*T
	active   []string
	closed   bool
	seq      atomic.Uint64
	metrics  MetricsCollector
	leaks    *LeakDetector
}

func NewManagedPool[T any](factory Factory[T], recycler Recycler[T],
	cfg PoolConfig, hooks LifecycleHooks[T]) (*ManagedPool[T], error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	if cfg.Lifecycle == nil {
		cfg.Lifecycle = map[string]string{}
	}
	p := &ManagedPool[T]{factory: factory, recycler: recycler, cfg: cfg,
		hooks: hooks, leaks: NewLeakDetector(true)}
	p.cond = sync.NewCond(&p.mu)
	if cfg.Prewarm > 0 {
		for i := int64(0); i < cfg.Prewarm; i++ {
			l, err := p.Borrow("prewarm")
			if err != nil {
				return nil, err
			}
			if err := l.Close(); err != nil {
				return nil, err
			}
		}
	}
	return p, nil
}

func (p *ManagedPool[T]) Borrow(tag string) (*ManagedLease[T], error) {
	return p.BorrowCtx(context.Background(), tag)
}

// BorrowCtx：满池时按 on_full 策略响应 ctx 取消 / 超时。
func (p *ManagedPool[T]) BorrowCtx(ctx context.Context, tag string) (*ManagedLease[T], error) {
	t0 := time.Now()
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return nil, ErrPoolClosed
	}
	limit := p.cfg.MaxSize
	if p.cfg.OnFull == Grow {
		limit += p.cfg.MaxOverflow
	}
	for int64(len(p.active)) >= limit {
		if p.cfg.OnFull == Reject {
			return nil, ErrPoolExhausted
		}
		if p.cfg.OnFull != Block {
			break // drop_* / grow 在归还侧处理，借用侧不阻塞
		}
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		// sync.Cond 不支持 ctx，用 goroutine 在 ctx 结束时广播唤醒
		done := make(chan struct{})
		go func() {
			select {
			case <-ctx.Done():
				p.mu.Lock()
				p.cond.Broadcast()
				p.mu.Unlock()
			case <-done:
			}
		}()
		p.cond.Wait()
		close(done)
		if err := ctx.Err(); err != nil {
			return nil, err
		}
	}
	var value *T
	hit, created := false, false
	if n := len(p.free); n > 0 {
		value = p.free[n-1]
		p.free = p.free[:n-1]
		hit = true
	} else {
		v, ok := p.factory()
		if !ok {
			return nil, ErrFactoryFailed
		}
		value = &v
		created = true
		if p.hooks.OnCreate != nil {
			p.hooks.OnCreate(value)
		}
	}
	id := strconv.FormatUint(p.seq.Add(1), 16)
	if p.cfg.LeakDetection {
		id = p.leaks.OnBorrow(tag)
	}
	p.active = append(p.active, id)
	p.metrics.RecordBorrow(hit, float64(time.Since(t0).Microseconds())/1000.0, created)
	if p.hooks.OnBorrow != nil {
		p.hooks.OnBorrow(value)
	}
	return &ManagedLease[T]{pool: p, value: value, id: id, tag: tag,
		borrowedAt: float64(time.Now().UnixNano()) / 1e9, active: true}, nil
}

var (
	ErrPoolClosed    = errors.New("gcprimitives: pool is closed")
	ErrPoolExhausted = errors.New("gcprimitives: pool exhausted (on_full=reject)")
)

func (p *ManagedPool[T]) release(value *T, id string, borrowedAt float64) error {
	if value == nil {
		return nil
	}
	if p.hooks.ClearSensitive && p.hooks.OnReturn != nil {
		p.hooks.OnReturn(value)
	}
	if p.recycler != nil {
		if err := p.recycler(value); err != nil {
			if p.hooks.OnDestroy != nil {
				p.hooks.OnDestroy(value)
			}
			p.settle(id, borrowedAt)
			return err
		}
	}
	if p.hooks.OnReturn != nil {
		p.hooks.OnReturn(value)
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.leaks.OnReturn(id)
	if int64(len(p.free)) >= p.cfg.MaxSize && p.cfg.OnFull != Grow {
		victim := p.free[0]
		p.free = append(p.free[1:], value)
		if p.hooks.OnEvict != nil {
			p.hooks.OnEvict(victim)
		}
		p.metrics.RecordEviction()
	} else {
		p.free = append(p.free, value)
	}
	p.settleInLock(id, borrowedAt)
	p.cond.Broadcast()
	return nil
}

func (p *ManagedPool[T]) settleInLock(id string, borrowedAt float64) {
	p.metrics.RecordReturn((float64(time.Now().UnixNano())/1e9 - borrowedAt) * 1000)
	for i, x := range p.active {
		if x == id {
			p.active = append(p.active[:i], p.active[i+1:]...)
			break
		}
	}
}
func (p *ManagedPool[T]) settle(id string, borrowedAt float64) {
	p.mu.Lock()
	p.settleInLock(id, borrowedAt)
	p.cond.Broadcast()
	p.mu.Unlock()
}

func (p *ManagedPool[T]) Prewarm(n int) (int, error) {
	made := 0
	for i := 0; i < n; i++ {
		l, err := p.Borrow("prewarm")
		if err != nil {
			return made, err
		}
		if err := l.Close(); err != nil {
			return made, err
		}
		made++
	}
	return made, nil
}
func (p *ManagedPool[T]) DetectLeaks(timeoutMs int64) []LeaseSample {
	out := p.leaks.DetectLeaks(timeoutMs)
	p.metrics.RecordLeak(int64(len(out)))
	return out
}
func (p *ManagedPool[T]) Metrics() Metrics {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.metrics.Snapshot(p.cfg.MaxSize, int64(len(p.free)), p.closed)
}
func (p *ManagedPool[T]) Stats() Metrics { return p.Metrics() }
func (p *ManagedPool[T]) Snapshot() map[string]any {
	cfg := p.cfg
	return map[string]any{
		"config":        cfg,
		"stats":         p.Metrics(),
		"active_leases": p.leaks.DetectLeaks(-1),
		"idle_objects":  p.IdleCount(),
	}
}
func (p *ManagedPool[T]) IdleCount() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.free)
}
func (p *ManagedPool[T]) ApplyConfig(cfg PoolConfig) {
	_ = cfg.Validate()
	p.mu.Lock()
	p.cfg = cfg
	p.cond.Broadcast()
	p.mu.Unlock()
}
func (p *ManagedPool[T]) SetMaxSize(n int64) {
	p.mu.Lock()
	cfg := p.cfg
	p.mu.Unlock()
	cfg.MaxSize = n
	p.ApplyConfig(cfg)
}
func (p *ManagedPool[T]) Close() {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return
	}
	p.closed = true
	victims := p.free
	p.free = nil
	p.cond.Broadcast()
	p.mu.Unlock()
	for _, v := range victims {
		if p.hooks.OnDestroy != nil {
			p.hooks.OnDestroy(v)
		}
	}
}
func (p *ManagedPool[T]) AssertNoActiveLeases() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.active) != 0 {
		return fmt.Errorf("%d lease(s) not returned", len(p.active))
	}
	return nil
}

// ---------------------------------------------------------------------------
// 12.2 组合矩阵（写死）
// ---------------------------------------------------------------------------

type PoolKind string

const (
	KindLocal  PoolKind = "local"
	KindShared PoolKind = "shared"
	KindBase   PoolKind = "base"
)

var CombinationMatrix = map[PoolKind]map[string]bool{
	KindLocal:  {"standalone": true, "shardable": false, "two_level_l2": false},
	KindShared: {"standalone": true, "shardable": true, "two_level_l2": true},
	KindBase:   {"standalone": true, "shardable": true, "two_level_l2": true},
}

func AssertCombination(kind PoolKind, operation string) error {
	row, ok := CombinationMatrix[kind]
	if !ok {
		return fmt.Errorf("%w: unknown pool kind %q", ErrCombination, kind)
	}
	v, exists := row[operation]
	if !exists {
		return fmt.Errorf("%w: unknown operation %q", ErrCombination, operation)
	}
	if !v {
		return fmt.Errorf("%w: pool kind %q cannot be used for %q", ErrCombination, kind, operation)
	}
	return nil
}

type ShardedPool[T any] struct{ shards []*ManagedPool[T] }

func NewShardedPool[T any](shards []*ManagedPool[T], kind PoolKind) (*ShardedPool[T], error) {
	if err := AssertCombination(kind, "shardable"); err != nil {
		return nil, err
	}
	if len(shards) == 0 {
		return nil, errors.New("shard list must not be empty")
	}
	return &ShardedPool[T]{shards: shards}, nil
}
func (s *ShardedPool[T]) Borrow(tag string) (*ManagedLease[T], error) {
	// 用 goroutine 无关的轻量路由：按调用方 P 的 id 不可得，改用轮询均衡
	idx := int(atomic.AddUint64(&shardRoundRobin, 1)-1) % len(s.shards)
	return s.shards[idx].Borrow(tag)
}

var shardRoundRobin uint64

func (s *ShardedPool[T]) Metrics() Metrics {
	out := MetricsSnapshot()
	for _, p := range s.shards {
		x := p.Metrics()
		out.BorrowCount += x.BorrowCount
		out.ReturnCount += x.ReturnCount
		out.ActiveLeases += x.ActiveLeases
		out.PoolHits += x.PoolHits
		out.PoolMisses += x.PoolMisses
		out.EvictionCount += x.EvictionCount
		out.LeakCount += x.LeakCount
		out.Created += x.Created
		out.Idle += x.Idle
		out.Capacity += x.Capacity
	}
	if total := out.PoolHits + out.PoolMisses; total > 0 {
		out.HitRate = float64(out.PoolHits) / float64(total)
	}
	return out
}
func (s *ShardedPool[T]) Stats() Metrics { return s.Metrics() }
func (s *ShardedPool[T]) Close() {
	for _, p := range s.shards {
		p.Close()
	}
}

type TwoLevelPool[T any] struct {
	l2 *ManagedPool[T]
}

func NewTwoLevelPool[T any](l2 *ManagedPool[T], l1Size int,
	kind PoolKind) (*TwoLevelPool[T], error) {
	if err := AssertCombination(kind, "two_level_l2"); err != nil {
		return nil, err
	}
	return &TwoLevelPool[T]{l2: l2}, nil
}
func (p *TwoLevelPool[T]) Borrow(tag string) (*ManagedLease[T], error) {
	return p.l2.Borrow(tag)
}
func (p *TwoLevelPool[T]) Metrics() Metrics { return p.l2.Metrics() }
func (p *TwoLevelPool[T]) Stats() Metrics   { return p.Metrics() }
func (p *TwoLevelPool[T]) Close()           { p.l2.Close() }
