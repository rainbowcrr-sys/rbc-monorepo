// gc-primitives 0.2.0 · C++ 增量能力契约测试（与七语言同口径）
// 编译: g++ -std=c++17 -Wall -Wextra -Wpedantic -pthread -I include tests/v020_test.cpp
#include <rbc/gc/v020.hpp>

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>
#include <thread>
#include <vector>

using namespace rbc::gc::v020;

static int passed = 0;
#define CHECK(cond) do { \
    if (!(cond)) { std::cerr << "FAIL " << __LINE__ << ": " #cond "\n"; std::exit(1); } \
    ++passed; \
} while (0)

static std::string* make_str() { return new std::string(); }
static void reset_str(std::string& s) { s.clear(); }
static PoolConfig cfg(long long n, OnFull p) { PoolConfig c; c.max_size = n; c.on_full = p; return c; }

static void test_metrics() {
    Metrics m;
    CHECK(m.to_json().find("\"wait_time_p99\":0") != std::string::npos);
    CHECK(m.to_json().find("\"closed\":false") != std::string::npos);
    MetricsCollector c;
    c.record_borrow(false, 1.0, true);
    c.record_borrow(true, 2.0, false);
    c.record_return(3.0);
    c.record_return(5.0);
    Metrics s = c.snapshot(8, 1, false);
    CHECK(s.borrow_count == 2);
    CHECK(s.return_count == 2);
    CHECK(s.active_leases == 0);
    CHECK(s.pool_hits == 1 && s.pool_misses == 1);
    CHECK(s.hit_rate == 0.5);
    CHECK(s.created == 1);
    CHECK(s.capacity == 8 && s.idle == 1);
    CHECK(s.wait_time_max == 2.0);
}

static void test_memory_scope() {
    unsetenv("GC_PRIMITIVES_DIAG");
    { RBC_GC_MEMORY_SCOPE(s, "disabled"); (void)s; }  // 零采集
    setenv("GC_PRIMITIVES_DIAG", "1", 1);
    int calls = 0;
    {
        MemoryScope outer("outer", [&](const ScopeReport& r) {
            CHECK(r.name == "outer"); ++calls;
        }, "", nullptr);
        MemoryScope inner("inner", [&](const ScopeReport& r) {
            CHECK(r.name == "inner"); ++calls;
        }, "", nullptr);
        std::vector<int> v(1000, 7);
        CHECK(v.size() == 1000);
    }
    CHECK(calls == 2);   // inner 先于 outer
    unsetenv("GC_PRIMITIVES_DIAG");
}

static void test_leak_detection() {
    LeakDetector d;
    std::string id = d.on_borrow("db-query");
    auto leaks = d.detect_leaks(0);
    CHECK(leaks.size() == 1);
    CHECK(leaks[0].tag == "db-query");
    CHECK(leaks[0].timed_out);
    CHECK(!leaks[0].lease_id.empty());
    CHECK(leaks[0].to_json().find("\"tag\":\"db-query\"") != std::string::npos);
    d.on_return(id);
    CHECK(d.detect_leaks(0).empty());
}

static void test_config() {
    const char* text =
        "pools:\n"
        "  default:\n"
        "    max_size: 8\n"
        "    on_full: \"reject\"\n"
        "    leak_detection: true\n"
        "    lifecycle:\n"
        "      on_return: \"reset\"\n"
        "      clear_sensitive: yes\n"
        "diagnostics:\n"
        "  memory_scope: false\n";
    auto flat = detail::parse_yaml_subset(text);
    CHECK(flat["pools.default.max_size"] == "8");
    CHECK(flat["pools.default.on_full"] == "reject");
    CHECK(flat["pools.default.lifecycle.clear_sensitive"] == "yes");
    CHECK(flat["diagnostics.memory_scope"] == "false");

    bool threw = false;
    try { PoolConfig bad; bad.max_size = -5; bad.validate(); }
    catch (const std::invalid_argument&) { threw = true; }
    CHECK(threw);
    threw = false;
    try { (void)PoolConfig::parse_on_full("bounce"); }
    catch (const std::invalid_argument&) { threw = true; }
    CHECK(threw);

    // env 覆盖 + 文件加载
    const std::string path = "/tmp/gc_v020_cfg.yaml";
    { std::ofstream f(path); f << "pools:\n  default:\n    max_size: 3\n    on_full: reject\n"; }
    setenv("GC_PRIMITIVES__DEFAULT__MAX_SIZE", "17", 1);
    PoolConfig c = load_config(path, "default");
    CHECK(c.max_size == 17);
    CHECK(c.on_full == OnFull::Reject);
    unsetenv("GC_PRIMITIVES__DEFAULT__MAX_SIZE");
    std::remove(path.c_str());
}

static void test_full_policy_and_hooks() {
    {   // reject
        ManagedPool<std::string> p(make_str, reset_str,
                                  cfg(1, OnFull::Reject));
        auto a = p.borrow();
        bool threw = false;
        try { auto b = p.borrow(); (void)b; }
        catch (const ContractError&) { threw = true; }
        CHECK(threw);
        a.close();
    }
    {   // block timeout
        PoolConfig c; c.max_size = 1; c.on_full = OnFull::Block; c.block_timeout_ms = 30;
        ManagedPool<std::string> p(make_str, reset_str, c);
        auto a = p.borrow();
        bool threw = false;
        try { auto b = p.borrow(); (void)b; }
        catch (const ContractError&) { threw = true; }
        CHECK(threw);
        a.close();
    }
    {   // grow
        PoolConfig c; c.max_size = 1; c.on_full = OnFull::Grow; c.max_overflow = 2;
        ManagedPool<std::string> p(make_str, reset_str, c);
        std::vector<ManagedLease<std::string>> leases;
        for (int i = 0; i < 3; ++i) leases.push_back(p.borrow());
        for (auto& l : leases) l.close();
        p.assert_no_active_leases();
    }
    {   // hooks + prewarm + snapshot
        std::vector<std::string> events;
        LifecycleHooks h;
        h.on_create = [&](void*) { events.push_back("create"); };
        h.on_borrow = [&](void*) { events.push_back("borrow"); };
        h.on_return = [&](void*) { events.push_back("return"); };
        h.on_evict = [&](void*) { events.push_back("evict"); };
        h.on_destroy = [&](void*) { events.push_back("destroy"); };
        ManagedPool<std::string> p(make_str, reset_str, PoolConfig{}, h);
        CHECK(p.prewarm(2) == 2);
        std::string snap = p.snapshot();
        CHECK(snap.find("\"config\"") != std::string::npos);
        CHECK(snap.find("\"stats\"") != std::string::npos);
        CHECK(snap.find("\"active_leases\"") != std::string::npos);
        CHECK(snap.find("\"idle_objects\"") != std::string::npos);
        CHECK(std::count(events.begin(), events.end(), "create") >= 1);
        CHECK(std::count(events.begin(), events.end(), "borrow") >= 2);
        p.close();
        CHECK(std::count(events.begin(), events.end(), "destroy") >= 1);
    }
}

static void test_combinations() {
    assert_combination(PoolKind::Shared, "shardable");
    assert_combination(PoolKind::Shared, "two_level_l2");
    bool threw = false;
    try { assert_combination(PoolKind::Local, "shardable"); }
    catch (const ContractError&) { threw = true; }
    CHECK(threw);
    threw = false;
    try { assert_combination(PoolKind::Local, "two_level_l2"); }
    catch (const ContractError&) { threw = true; }
    CHECK(threw);

    std::vector<std::shared_ptr<ManagedPool<std::string>>> shards;
    for (int i = 0; i < 4; ++i)
        shards.push_back(std::make_shared<ManagedPool<std::string>>(
            make_str, reset_str, cfg(2, OnFull::DropOldest)));
    {
        ShardedPool<std::string> sp(shards);
        auto l = sp.borrow();
        l.get().append("x");
        l.close();
        CHECK(sp.metrics().borrow_count == 1);
    }
    {
        auto l2 = std::make_shared<ManagedPool<std::string>>(
            make_str, reset_str, cfg(8, OnFull::DropOldest));
        TwoLevelPool<std::string> tp(l2, 2);
        auto l = tp.borrow();
        l.get().append("a");
        l.close();
        l2->assert_no_active_leases();
    }
}

static void test_threaded() {
    ManagedPool<std::string> p(make_str, reset_str, cfg(4, OnFull::Grow));
    std::vector<std::thread> ts;
    for (int i = 0; i < 8; ++i) {
        ts.emplace_back([&] {
            for (int j = 0; j < 50; ++j) {
                auto l = p.borrow("t");
                l.get().append("x");
                l.close();
            }
        });
    }
    for (auto& t : ts) t.join();
    p.assert_no_active_leases();
    CHECK(p.metrics().borrow_count == 400);
    CHECK(p.metrics().return_count == 400);
}

int main() {
    test_metrics();
    test_memory_scope();
    test_leak_detection();
    test_config();
    test_full_policy_and_hooks();
    test_combinations();
    test_threaded();
    std::cout << "C++ 0.2.0 OK · " << passed << " assertions passed\n";
    return 0;
}
