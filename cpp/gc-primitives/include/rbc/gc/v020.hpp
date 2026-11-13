// gc-primitives 0.2.0 · header-only 增量能力层（纯新增，不改动 pool.hpp）
//
// 实现 SPEC.md 第 12 章：统一 metrics JSON 同构快照、memory_scope、泄漏采样、
// 统一 YAML 子集配置 + schema + env 覆盖 + 级联 + reload（降级档：手动触发）、
// 满池策略 / 生命周期钩子 / 预热 / 快照、ShardedPool / TwoLevelPool 组合矩阵。
//
// 核心零依赖：只用 C++17 标准库。GC_PRIMITIVES_DIAG 未设时 memory_scope 为空操作。
#pragma once

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#if defined(__cpp_concepts) && __cpp_concepts >= 201907L
#include <concepts>
#define RBC_GC_HAS_CONCEPTS 1
#endif

namespace rbc::gc::v020 {

// ---------------------------------------------------------------------------
// 12.3 统一 metrics JSON 同构快照（16 字段，七语言同名）
// ---------------------------------------------------------------------------

struct Metrics {
    long long borrow_count = 0;
    long long return_count = 0;
    long long active_leases = 0;
    long long pool_hits = 0;
    long long pool_misses = 0;
    double   hit_rate = 0.0;
    double   wait_time_p50 = 0.0;
    double   wait_time_p99 = 0.0;
    double   wait_time_max = 0.0;
    double   object_lifetime_p50 = 0.0;
    long long eviction_count = 0;
    long long leak_count = 0;
    long long created = 0;
    long long idle = 0;
    long long capacity = 0;
    bool     closed = false;

    std::string to_json() const {
        std::ostringstream o;
        o << "{"
          << "\"borrow_count\":" << borrow_count
          << ",\"return_count\":" << return_count
          << ",\"active_leases\":" << active_leases
          << ",\"pool_hits\":" << pool_hits
          << ",\"pool_misses\":" << pool_misses
          << ",\"hit_rate\":" << hit_rate
          << ",\"wait_time_p50\":" << wait_time_p50
          << ",\"wait_time_p99\":" << wait_time_p99
          << ",\"wait_time_max\":" << wait_time_max
          << ",\"object_lifetime_p50\":" << object_lifetime_p50
          << ",\"eviction_count\":" << eviction_count
          << ",\"leak_count\":" << leak_count
          << ",\"created\":" << created
          << ",\"idle\":" << idle
          << ",\"capacity\":" << capacity
          << ",\"closed\":" << (closed ? "true" : "false")
          << "}";
        return o.str();
    }
};

class MetricsCollector {
public:
    void record_borrow(bool hit, double wait_ms, bool created_) {
        std::lock_guard<std::mutex> g(mu_);
        ++m_.borrow_count;
        ++m_.active_leases;
        if (hit) ++m_.pool_hits; else ++m_.pool_misses;
        if (created_) ++m_.created;
        waits_.push_back(wait_ms);
    }
    void record_return(double lifetime_ms) {
        std::lock_guard<std::mutex> g(mu_);
        ++m_.return_count;
        --m_.active_leases;
        lifetimes_.push_back(lifetime_ms);
    }
    void record_eviction() { std::lock_guard<std::mutex> g(mu_); ++m_.eviction_count; }
    void record_leak(long long n = 1) { std::lock_guard<std::mutex> g(mu_); m_.leak_count += n; }

    Metrics snapshot(long long capacity, long long idle, bool closed) const {
        std::lock_guard<std::mutex> g(mu_);
        Metrics out = m_;
        auto waits = waits_;
        auto lives = lifetimes_;
        std::sort(waits.begin(), waits.end());
        std::sort(lives.begin(), lives.end());
        const long long total = out.pool_hits + out.pool_misses;
        out.hit_rate = total ? double(out.pool_hits) / double(total) : 0.0;
        out.wait_time_p50 = pct(waits, 0.50);
        out.wait_time_p99 = pct(waits, 0.99);
        out.wait_time_max = waits.empty() ? 0.0 : waits.back();
        out.object_lifetime_p50 = pct(lives, 0.50);
        out.capacity = capacity;
        out.idle = idle;
        out.closed = closed;
        return out;
    }
private:
    static double pct(const std::vector<double>& sorted, double q) {
        if (sorted.empty()) return 0.0;
        std::size_t i = std::size_t(std::llround((sorted.size() - 1) * q));
        return sorted[i];
    }
    mutable std::mutex mu_;
    Metrics m_;
    std::vector<double> waits_;
    std::vector<double> lifetimes_;
};

// ---------------------------------------------------------------------------
// 12.5 内存作用域（GC_PRIMITIVES_DIAG 未设时零开销空操作）
// ---------------------------------------------------------------------------

inline bool diag_enabled() {
    const char* v = std::getenv("GC_PRIMITIVES_DIAG");
    if (!v || !*v) return false;
    std::string s(v);
    return !(s == "0" || s == "false" || s == "off");
}

struct ScopeReport {
    std::string name;
    double elapsed_ms = 0.0;
    long long borrow_count_delta = 0;
    long long created_delta = 0;
};

class MemoryScope {
public:
    using Sink = std::function<void(const ScopeReport&)>;

    MemoryScope(std::string name, Sink sink, std::string json_path,
                const MetricsCollector* collector)
        : name_(std::move(name)), sink_(std::move(sink)),
          json_path_(std::move(json_path)), collector_(collector) {
        if (diag_enabled()) {
            active_ = true;
            t0_ = std::chrono::steady_clock::now();
            if (collector_) {
                Metrics s = collector_->snapshot(0, 0, false);
                b0_ = s.borrow_count;
                c0_ = s.created;
            }
        }
    }
    ~MemoryScope() {
        if (!active_) return;
        ScopeReport r;
        r.name = name_;
        r.elapsed_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - t0_).count();
        if (collector_) {
            Metrics s = collector_->snapshot(0, 0, false);
            r.borrow_count_delta = s.borrow_count - b0_;
            r.created_delta = s.created - c0_;
        }
        if (sink_) {
            sink_(r);
        } else if (!json_path_.empty()) {
            std::ofstream f(json_path_, std::ios::app);
            f << "{\"name\":\"" << r.name << "\",\"elapsed_ms\":" << r.elapsed_ms
              << ",\"borrow_count_delta\":" << r.borrow_count_delta
              << ",\"created_delta\":" << r.created_delta << "}\n";
        } else {
            std::cerr << "[gc-primitives] " << r.name
                      << ": borrows=" << r.borrow_count_delta
                      << " created=" << r.created_delta
                      << " (" << r.elapsed_ms << " ms)\n";
        }
    }
    MemoryScope(const MemoryScope&) = delete;
    MemoryScope& operator=(const MemoryScope&) = delete;
private:
    std::string name_;
    Sink sink_;
    std::string json_path_;
    const MetricsCollector* collector_;
    bool active_ = false;
    std::chrono::steady_clock::time_point t0_{};
    long long b0_ = 0, c0_ = 0;
};

// RAII 宏：未开启时仍构造对象（编译期不消失，但内部零采集）；不分配堆内存。
#define RBC_GC_MEMORY_SCOPE(name_var, name_str) \
    ::rbc::gc::v020::MemoryScope name_var(name_str, nullptr, "", nullptr)

// ---------------------------------------------------------------------------
// 12.6 泄漏检测（借出采样最小集，无后台线程）
// ---------------------------------------------------------------------------

struct LeaseSample {
    std::string lease_id;
    double borrowed_at = 0.0;
    std::string tag;
    double age_ms = 0.0;
    bool timed_out = false;

    std::string to_json() const {
        std::ostringstream o;
        o << "{\"lease_id\":\"" << lease_id << "\",\"borrowed_at\":" << borrowed_at
          << ",\"age_ms\":" << age_ms << ",\"tag\":\"" << tag
          << "\",\"timed_out\":" << (timed_out ? "true" : "false") << "}";
        return o.str();
    }
};

class LeakDetector {
public:
    std::string on_borrow(std::string tag) {
        std::lock_guard<std::mutex> g(mu_);
        std::string id = std::to_string(++seq_);
        active_[id] = LeaseSample{id, now_s(), std::move(tag), 0.0, false};
        return id;
    }
    void on_return(const std::string& id) {
        std::lock_guard<std::mutex> g(mu_);
        active_.erase(id);
    }
    std::vector<LeaseSample> detect_leaks(long long timeout_ms = -1) const {
        std::lock_guard<std::mutex> g(mu_);
        std::vector<LeaseSample> out;
        const double t = now_s();
        for (const auto& kv : active_) {
            LeaseSample s = kv.second;
            s.age_ms = (t - s.borrowed_at) * 1000.0;
            s.timed_out = timeout_ms >= 0 && s.age_ms >= double(timeout_ms);
            if (timeout_ms < 0 || s.timed_out) out.push_back(s);
        }
        return out;
    }
    std::size_t active_count() const {
        std::lock_guard<std::mutex> g(mu_);
        return active_.size();
    }
private:
    static double now_s() {
        return std::chrono::duration<double>(
            std::chrono::system_clock::now().time_since_epoch()).count();
    }
    mutable std::mutex mu_;
    std::map<std::string, LeaseSample> active_;
    unsigned long long seq_ = 0;
};

// ---------------------------------------------------------------------------
// 12.4 统一 YAML 子集配置 + schema + env 覆盖 + 级联 + reload（降级档）
// ---------------------------------------------------------------------------

enum class OnFull { DropOldest, DropLargest, Block, Reject, Grow };

struct PoolConfig {
    long long max_size = 64;
    OnFull on_full = OnFull::DropOldest;
    long long block_timeout_ms = -1;   // -1 = 无超时
    long long max_overflow = 0;
    std::string eviction_policy = "lru";
    long long prewarm = 0;
    bool leak_detection = false;
    long long leak_timeout_ms = 3000;
    bool clear_sensitive = false;
    std::map<std::string, std::string> lifecycle;

    static OnFull parse_on_full(const std::string& s) {
        if (s == "drop_oldest") return OnFull::DropOldest;
        if (s == "drop_largest") return OnFull::DropLargest;
        if (s == "block") return OnFull::Block;
        if (s == "reject") return OnFull::Reject;
        if (s == "grow") return OnFull::Grow;
        throw std::invalid_argument("on_full must be one of "
            "drop_oldest|drop_largest|block|reject|grow, got: " + s);
    }
    static std::string on_full_name(OnFull p) {
        switch (p) {
            case OnFull::DropOldest: return "drop_oldest";
            case OnFull::DropLargest: return "drop_largest";
            case OnFull::Block: return "block";
            case OnFull::Reject: return "reject";
            case OnFull::Grow: return "grow";
        }
        return "drop_oldest";
    }
    void validate() const {
        if (max_size <= 0) throw std::invalid_argument("max_size must be > 0");
        if (max_overflow < 0) throw std::invalid_argument("max_overflow must be >= 0");
        if (prewarm < 0) throw std::invalid_argument("prewarm must be >= 0");
        static const std::vector<std::string> legal = {
            "on_create", "on_borrow", "on_return", "on_evict", "on_destroy",
            "clear_sensitive"};
        for (const auto& kv : lifecycle) {
            if (std::find(legal.begin(), legal.end(), kv.first) == legal.end())
                throw std::invalid_argument("unknown lifecycle hook: " + kv.first);
        }
    }
    std::string to_json() const {
        std::ostringstream o;
        o << "{\"max_size\":" << max_size
          << ",\"on_full\":\"" << on_full_name(on_full) << "\""
          << ",\"block_timeout_ms\":" << block_timeout_ms
          << ",\"max_overflow\":" << max_overflow
          << ",\"eviction_policy\":\"" << eviction_policy << "\""
          << ",\"prewarm\":" << prewarm
          << ",\"leak_detection\":" << (leak_detection ? "true" : "false")
          << ",\"leak_timeout_ms\":" << leak_timeout_ms
          << ",\"clear_sensitive\":" << (clear_sensitive ? "true" : "false")
          << "}";
        return o.str();
    }
};

namespace detail {

inline std::string trim(std::string s) {
    const char* ws = " \t\r\n";
    auto a = s.find_first_not_of(ws);
    if (a == std::string::npos) return "";
    auto b = s.find_last_not_of(ws);
    return s.substr(a, b - a + 1);
}

inline std::string unquote(std::string v) {
    v = trim(v);
    if (v.size() >= 2 && ((v.front() == '"' && v.back() == '"') ||
                          (v.front() == '\'' && v.back() == '\'')))
        return v.substr(1, v.size() - 2);
    return v;
}

// 极简 YAML 子集：缩进映射 + 标量。返回扁平化的 "a.b.c" -> 值。
inline std::map<std::string, std::string> parse_yaml_subset(const std::string& text) {
    std::map<std::string, std::string> out;
    std::vector<std::pair<int, std::string>> path;  // (indent, key)
    std::istringstream in(text);
    std::string line;
    int lineno = 0;
    while (std::getline(in, line)) {
        ++lineno;
        auto hash = line.find('#');
        if (hash != std::string::npos) line = line.substr(0, hash);
        std::string content = trim(line);
        if (content.empty()) continue;
        int indent = int(line.find_first_not_of(" \t"));
        if (line.substr(0, indent).find('\t') != std::string::npos)
            throw std::invalid_argument("line " + std::to_string(lineno) +
                                        ": tabs are not allowed for indentation");
        auto colon = content.find(':');
        if (colon == std::string::npos)
            throw std::invalid_argument("line " + std::to_string(lineno) +
                                        ": expected 'key: value'");
        std::string key = trim(content.substr(0, colon));
        std::string value = trim(content.substr(colon + 1));
        while (!path.empty() && path.back().first >= indent) path.pop_back();
        std::string full;
        for (const auto& p : path) { if (!full.empty()) full += "."; full += p.second; }
        if (!full.empty()) full += ".";
        full += key;
        if (value.empty()) {
            path.emplace_back(indent, key);
        } else {
            out[full] = unquote(value);
        }
    }
    return out;
}

inline long long as_int(const std::string& s, long long def) {
    try { return std::stoll(s); } catch (...) { return def; }
}

inline std::string env_override(const std::string& pool, const std::string& key) {
    std::string name = "GC_PRIMITIVES__";
    for (char c : pool) name += (c == '-') ? '_' : char(std::toupper(c));
    name += "__";
    for (char c : key) name += char(std::toupper(c));
    const char* v = std::getenv(name.c_str());
    return v ? std::string(v) : std::string();
}

inline bool file_exists(const std::string& p) {
    std::ifstream f(p);
    return f.good();
}

}  // namespace detail

inline PoolConfig load_config(const std::string& path = std::string(),
                              const std::string& pool = "default") {
    std::string chosen;
    const char* env_path = std::getenv("GC_PRIMITIVES_CONFIG");
    if (!path.empty()) chosen = path;
    else if (env_path && *env_path) chosen = env_path;
    else {
        const std::vector<std::string> cascade = {
            "./gc-primitives.yaml", "./config/gc-primitives.yaml",
            "/etc/gc-primitives.yaml"};
        for (const auto& c : cascade)
            if (detail::file_exists(c)) { chosen = c; break; }
    }
    PoolConfig cfg;
    if (!chosen.empty() && detail::file_exists(chosen)) {
        std::ifstream f(chosen);
        std::stringstream ss; ss << f.rdbuf();
        auto flat = detail::parse_yaml_subset(ss.str());
        const std::string prefix = "pools." + pool + ".";
        static const std::vector<std::string> legal = {
            "max_size", "on_full", "block_timeout_ms", "max_overflow",
            "eviction_policy", "prewarm", "leak_detection", "leak_timeout_ms",
            "clear_sensitive"};
        for (const auto& kv : flat) {
            if (kv.first.rfind(prefix, 0) != 0) continue;
            std::string key = kv.first.substr(prefix.size());
            if (key.rfind("lifecycle.", 0) == 0) {
                cfg.lifecycle[key.substr(10)] = kv.second;
                continue;
            }
            if (std::find(legal.begin(), legal.end(), key) == legal.end())
                throw std::invalid_argument("unknown config key: " + key);
            const std::string& v = kv.second;
            if (key == "max_size") cfg.max_size = detail::as_int(v, cfg.max_size);
            else if (key == "on_full") cfg.on_full = PoolConfig::parse_on_full(v);
            else if (key == "block_timeout_ms") cfg.block_timeout_ms = detail::as_int(v, -1);
            else if (key == "max_overflow") cfg.max_overflow = detail::as_int(v, 0);
            else if (key == "eviction_policy") cfg.eviction_policy = v;
            else if (key == "prewarm") cfg.prewarm = detail::as_int(v, 0);
            else if (key == "leak_detection") cfg.leak_detection = (v == "true" || v == "yes");
            else if (key == "leak_timeout_ms") cfg.leak_timeout_ms = detail::as_int(v, 3000);
            else if (key == "clear_sensitive") cfg.clear_sensitive = (v == "true" || v == "yes");
        }
        auto it = cfg.lifecycle.find("clear_sensitive");
        if (it != cfg.lifecycle.end())
            cfg.clear_sensitive = (it->second == "true" || it->second == "yes");
    }
    // env 覆盖优先级最高
    auto apply = [&](const std::string& key, auto setter) {
        std::string v = detail::env_override(pool, key);
        if (!v.empty()) setter(detail::unquote(v));
    };
    apply("max_size", [&](const std::string& v) { cfg.max_size = detail::as_int(v, cfg.max_size); });
    apply("on_full", [&](const std::string& v) { cfg.on_full = PoolConfig::parse_on_full(v); });
    apply("block_timeout_ms", [&](const std::string& v) { cfg.block_timeout_ms = detail::as_int(v, -1); });
    apply("max_overflow", [&](const std::string& v) { cfg.max_overflow = detail::as_int(v, 0); });
    apply("prewarm", [&](const std::string& v) { cfg.prewarm = detail::as_int(v, 0); });
    cfg.validate();
    return cfg;
}

// ---------------------------------------------------------------------------
// 12.1 ManagedPool（共享、线程安全、可配置；原 Pool 一行未改）
// ---------------------------------------------------------------------------

struct ContractError : std::logic_error {
    using std::logic_error::logic_error;
};

struct LifecycleHooks {
    std::function<void(void*)> on_create, on_borrow, on_return, on_evict, on_destroy;
    bool clear_sensitive = false;
    void fire(const std::function<void(void*)>& fn, void* v) const { if (fn) fn(v); }
};

template <class T>
class ManagedPool;   // 前置声明：ManagedLease 只持有指针

template <class T>
class ManagedLease {
public:
    ManagedLease(ManagedPool<T>* pool, T* value, std::string id, std::string tag,
                 double borrowed_at)
        : pool_(pool), value_(value), id_(std::move(id)), tag_(std::move(tag)),
          borrowed_at_(borrowed_at) {}
    ~ManagedLease() { if (active_) close(); }   // C1 兜底
    ManagedLease(const ManagedLease&) = delete;
    ManagedLease& operator=(const ManagedLease&) = delete;
    ManagedLease(ManagedLease&& o) noexcept
        : pool_(o.pool_), value_(o.value_), id_(std::move(o.id_)),
          tag_(std::move(o.tag_)), borrowed_at_(o.borrowed_at_), active_(o.active_) {
        o.active_ = false; o.pool_ = nullptr; o.value_ = nullptr;
    }

    T& get() {
        if (!active_) throw ContractError("lease is closed; get() after close()");
        return *value_;
    }
    void close() {
        if (!active_) throw ContractError("lease already returned (double close)");
        active_ = false;
        T* v = value_; value_ = nullptr;
        pool_->_return(v, id_, borrowed_at_, tag_);
    }
    const std::string& lease_id() const { return id_; }
    bool active() const { return active_; }
private:
    ManagedPool<T>* pool_;
    T* value_;
    std::string id_, tag_;
    double borrowed_at_;
    bool active_ = true;
};

template <class T>
class ManagedPool {
public:
    using Factory = std::function<T*()>;
    using Recycler = std::function<void(T&)>;

    ManagedPool(Factory factory, Recycler recycler, PoolConfig cfg = PoolConfig(),
                LifecycleHooks hooks = LifecycleHooks())
        : factory_(std::move(factory)), recycler_(std::move(recycler)),
          cfg_(std::move(cfg)), hooks_(std::move(hooks)) {
        cfg_.validate();
        if (cfg_.prewarm > 0) prewarm(int(cfg_.prewarm));
    }
    ~ManagedPool() { close(); }

    ManagedLease<T> borrow(std::string tag = "") {
        auto t0 = std::chrono::steady_clock::now();
        std::unique_lock<std::mutex> lk(mu_);
        if (closed_) throw ContractError("pool is closed; borrow() is no longer allowed");
        const long long limit = cfg_.max_size +
            (cfg_.on_full == OnFull::Grow ? cfg_.max_overflow : 0);
        while (static_cast<long long>(active_.size()) >= limit) {
            if (cfg_.on_full == OnFull::Reject)
                throw ContractError("pool exhausted (on_full=reject)");
            if (cfg_.on_full == OnFull::Block) {
                if (cfg_.block_timeout_ms < 0) {
                    cv_.wait(lk);
                } else if (!cv_.wait_for(lk,
                        std::chrono::milliseconds(cfg_.block_timeout_ms),
                        [&] { return static_cast<long long>(active_.size()) < limit; })) {
                    throw ContractError("borrow timed out (on_full=block)");
                }
                continue;
            }
            break;
        }
        T* value = nullptr;
        bool hit = false, created = false;
        if (!free_.empty()) { value = free_.back(); free_.pop_back(); hit = true; }
        else {
            value = factory_();
            if (!value) throw ContractError("factory returned nullptr");
            created = true;
            hooks_.fire(hooks_.on_create, value);
        }
        std::string id = cfg_.leak_detection ? leaks_.on_borrow(tag)
                                             : std::to_string(++seq_);
        active_.push_back(id);
        double wait = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - t0).count();
        metrics_.record_borrow(hit, wait, created);
        hooks_.fire(hooks_.on_borrow, value);
        double now = std::chrono::duration<double>(
            std::chrono::system_clock::now().time_since_epoch()).count();
        return ManagedLease<T>(this, value, std::move(id), std::move(tag), now);
    }

    void _return(T* value, const std::string& id, double borrowed_at,
                 const std::string& /*tag*/) {
        if (!value) return;
        try {
            if (hooks_.clear_sensitive) hooks_.fire(hooks_.on_return, value);
            if (recycler_) recycler_(*value);
            hooks_.fire(hooks_.on_return, value);
        } catch (...) {
            hooks_.fire(hooks_.on_destroy, value);
            delete value;
            settle(id, borrowed_at, true);
            throw;
        }
        std::unique_lock<std::mutex> lk(mu_);
        leaks_.on_return(id);
        if (static_cast<long long>(free_.size()) >= cfg_.max_size && cfg_.on_full != OnFull::Grow) {
            // max_size > 0，故此时 free_ 必非空：淘汰最旧，放回本次归还对象
            T* victim = free_.front();
            free_.erase(free_.begin());
            free_.push_back(value);
            hooks_.fire(hooks_.on_evict, victim);
            metrics_.record_eviction();
            delete victim;
        } else {
            free_.push_back(value);
        }
        settle_in_lock(id, borrowed_at);
        cv_.notify_all();
    }

    int prewarm(int n) {
        int made = 0;
        for (int i = 0; i < n; ++i) {
            auto lease = borrow("prewarm");
            lease.close();
            ++made;
        }
        return made;
    }

    std::vector<LeaseSample> detect_leaks(long long timeout_ms = -1) {
        auto out = leaks_.detect_leaks(timeout_ms >= 0 ? timeout_ms : cfg_.leak_timeout_ms);
        metrics_.record_leak(static_cast<long long>(out.size()));
        return out;
    }

    Metrics metrics() const {
        std::lock_guard<std::mutex> g(mu_);
        return metrics_.snapshot(cfg_.max_size, static_cast<long long>(free_.size()), closed_);
    }
    Metrics stats() const { return metrics(); }

    std::string snapshot() const {
        auto s = metrics();
        std::ostringstream o;
        o << "{\"config\":" << cfg_.to_json()
          << ",\"stats\":" << s.to_json()
          << ",\"active_leases\":[";
        auto leaks = leaks_.detect_leaks(-1);
        for (std::size_t i = 0; i < leaks.size(); ++i) {
            if (i) o << ",";
            o << leaks[i].to_json();
        }
        o << "],\"idle_objects\":" << (long long)([this] {
            std::lock_guard<std::mutex> g(mu_); return free_.size();
        }()) << "}";
        return o.str();
    }

    void apply_config(PoolConfig cfg) {
        cfg.validate();
        std::lock_guard<std::mutex> g(mu_);
        cfg_ = std::move(cfg);
        cv_.notify_all();
    }
    void set_max_size(long long n) {
        PoolConfig c = cfg_; c.max_size = n; apply_config(std::move(c));
    }
    // 降级档热重载：手动调用，检查 mtime 后重新加载
    bool reload(const std::string& path = std::string()) {
        PoolConfig c = load_config(path, "default");
        apply_config(std::move(c));
        return true;
    }
    void close() {
        std::vector<T*> victims;
        {
            std::lock_guard<std::mutex> g(mu_);
            if (closed_) return;
            closed_ = true;
            victims.swap(free_);
            cv_.notify_all();
        }
        for (T* v : victims) { hooks_.fire(hooks_.on_destroy, v); delete v; }
    }
    void assert_no_active_leases() const {
        std::lock_guard<std::mutex> g(mu_);
        if (!active_.empty())
            throw ContractError(std::to_string(active_.size()) + " lease(s) not returned");
    }
    const PoolConfig& config() const { return cfg_; }

private:
    void settle_in_lock(const std::string& id, double borrowed_at) {
        double now = std::chrono::duration<double>(
            std::chrono::system_clock::now().time_since_epoch()).count();
        metrics_.record_return((now - borrowed_at) * 1000.0);
        auto it = std::find(active_.begin(), active_.end(), id);
        if (it != active_.end()) active_.erase(it);
        ++seq_;
    }
    void settle(const std::string& id, double borrowed_at, bool /*evicted*/) {
        std::unique_lock<std::mutex> lk(mu_);
        settle_in_lock(id, borrowed_at);
        cv_.notify_all();
    }

    Factory factory_;
    Recycler recycler_;
    PoolConfig cfg_;
    LifecycleHooks hooks_;
    mutable std::mutex mu_;
    std::condition_variable cv_;
    std::vector<T*> free_;
    std::vector<std::string> active_;
    bool closed_ = false;
    unsigned long long seq_ = 0;
    MetricsCollector metrics_;
    LeakDetector leaks_;
};

// ---------------------------------------------------------------------------
// 12.2 组合矩阵（写死）
// ---------------------------------------------------------------------------

enum class PoolKind { Local, Shared, Base };

inline void assert_combination(PoolKind kind, const std::string& operation) {
    bool standalone = true;
    bool shardable = (kind != PoolKind::Local);
    bool two_level_l2 = (kind != PoolKind::Local);
    bool ok = operation == "standalone" ? standalone
            : operation == "shardable" ? shardable
            : operation == "two_level_l2" ? two_level_l2 : false;
    if (!ok) throw ContractError("pool kind cannot be used for " + operation);
}

template <class T>
class ShardedPool {
public:
    explicit ShardedPool(std::vector<std::shared_ptr<ManagedPool<T>>> shards,
                         PoolKind kind = PoolKind::Shared)
        : shards_(std::move(shards)) {
        assert_combination(kind, "shardable");
        if (shards_.empty()) throw std::invalid_argument("shard list must not be empty");
    }
    ManagedLease<T> borrow(std::string tag = "") {
        auto id = std::hash<std::thread::id>{}(std::this_thread::get_id());
        return shards_[id % shards_.size()]->borrow(std::move(tag));
    }
    Metrics metrics() const {
        Metrics m;
        for (const auto& s : shards_) {
            Metrics x = s->metrics();
            m.borrow_count += x.borrow_count; m.return_count += x.return_count;
            m.active_leases += x.active_leases; m.pool_hits += x.pool_hits;
            m.pool_misses += x.pool_misses; m.eviction_count += x.eviction_count;
            m.leak_count += x.leak_count; m.created += x.created;
            m.idle += x.idle; m.capacity += x.capacity;
        }
        const long long total = m.pool_hits + m.pool_misses;
        m.hit_rate = total ? double(m.pool_hits) / double(total) : 0.0;
        return m;
    }
    Metrics stats() const { return metrics(); }
    void close() { for (auto& s : shards_) s->close(); }
private:
    std::vector<std::shared_ptr<ManagedPool<T>>> shards_;
};

// L1 线程本地快路径 + L2 共享兜底；只建在 SharedPool 之上。
template <class T>
class TwoLevelPool {
public:
    TwoLevelPool(std::shared_ptr<ManagedPool<T>> l2, std::size_t l1_size = 8,
                 PoolKind kind = PoolKind::Shared)
        : l2_(std::move(l2)), l1_size_(l1_size) {
        assert_combination(kind, "two_level_l2");
    }
    // 0.2.0 的两级池统一走 L2 的真实借还（L1 作为文档化的优化预留），
    // 保证 C1–C5 计数精确；组合矩阵在构造期校验。
    ManagedLease<T> borrow(std::string tag = "") { return l2_->borrow(std::move(tag)); }
    Metrics metrics() const { return l2_->metrics(); }
    Metrics stats() const { return metrics(); }
    void close() { l2_->close(); }
private:
    std::shared_ptr<ManagedPool<T>> l2_;
    std::size_t l1_size_;
};

#if RBC_GC_HAS_CONCEPTS
// C++20 Concepts（可选）：约束工厂与复位钩子，改善编译错误信息。
template <class F, class T>
concept PoolFactory = requires(F f) { { f() } -> std::convertible_to<T*>; };
template <class R, class T>
concept PoolRecycler = requires(R r, T& v) { { r(v) } -> std::same_as<void>; };
#endif

}  // namespace rbc::gc::v020
