// 与 Java 版 ThreadLocalPoolTest / QuickStart 一一对应的契约测试。
// 不依赖任何第三方框架，g++ -std=c++17 -pthread 直接编译运行。
#include <rbc/gc.hpp>

#include <iostream>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

int failures = 0;
int checks = 0;

void check(bool ok, const char* what) {
    ++checks;
    if (!ok) {
        ++failures;
        std::cerr << "  FAIL: " << what << '\n';
    }
}

template <class F>
void check_throws(F&& fn, const char* what) {
    ++checks;
    try {
        fn();
    } catch (const rbc::gc::pool_error&) {
        return;
    } catch (...) {
        ++failures;
        std::cerr << "  FAIL: " << what << " (抛出的不是 pool_error)\n";
        return;
    }
    ++failures;
    std::cerr << "  FAIL: " << what << " (未抛异常)\n";
}

using StringPool = rbc::gc::Pool<std::string,
                                 std::string* (*)(),
                                 void (*)(std::string&)>;

std::string* new_string() { return new std::string(); }
void clear_string(std::string& s) noexcept { s.clear(); }

StringPool make_string_pool(std::size_t capacity = 8) {
    return StringPool(capacity, &new_string, &clear_string);
}

void test_reuse() {
    StringPool pool = make_string_pool();
    std::string* a = nullptr;
    std::string* b = nullptr;
    {
        auto lease = pool.borrow();
        a = &lease.get();
    }
    {
        auto lease = pool.borrow();
        b = &lease.get();
    }
    check(a == b, "同线程连续借用应命中同一实例");
    check(pool.borrow_count() == 2, "borrow_count == 2");
    check(pool.return_count() == 2, "return_count == 2");
    check(pool.active_leases() == 0, "归还后 active_leases == 0");
}

void test_recycler() {
    StringPool pool = make_string_pool();
    {
        auto lease = pool.borrow();
        lease.get().append("dirty");
    }
    {
        auto lease = pool.borrow();
        check(lease.get().empty(), "归还时 Recycler 应清空字符串");
    }
    pool.assert_no_active_leases();
}

void test_double_close() {
    StringPool pool = make_string_pool();
    auto lease = pool.borrow();
    lease.close();
    check_throws([&] { lease.close(); }, "双重归还");
    pool.assert_no_active_leases();
}

void test_get_after_close() {
    StringPool pool = make_string_pool();
    auto lease = pool.borrow();
    lease.close();
    check_throws([&] { (void)lease.get(); }, "关闭后 get()");
}

void test_cross_thread_close() {
    StringPool pool = make_string_pool();
    auto lease = pool.borrow();
    bool caught = false;
    std::thread t([&] {
        try {
            lease.close();
        } catch (const rbc::gc::pool_error&) {
            caught = true;
        }
    });
    t.join();
    check(caught, "跨线程归还应抛 pool_error");
    lease.close();  // 由借用线程归还
    pool.assert_no_active_leases();
}

void test_cross_thread_get() {
    StringPool pool = make_string_pool();
    auto lease = pool.borrow();
    bool caught = false;
    std::thread t([&] {
        try {
            (void)lease.get();
        } catch (const rbc::gc::pool_error&) {
            caught = true;
        }
    });
    t.join();
    check(caught, "跨线程取用应抛 pool_error");
    lease.close();
    pool.assert_no_active_leases();
}

void test_capacity_bounded() {
    StringPool pool = make_string_pool(2);
    std::vector<StringPool::Lease> leases;
    leases.reserve(4);
    for (int i = 0; i < 4; ++i) {
        leases.push_back(pool.borrow());
    }
    for (auto& l : leases) {
        l.close();
    }
    check(pool.capacity() == 2, "capacity() == 2");
    check(pool.idle_count() <= 2, "空闲对象数不得超过 capacity");
    pool.assert_no_active_leases();
}

void test_factory_null() {
    rbc::gc::Pool<std::string, std::string* (*)()> pool(
        4, []() -> std::string* { return nullptr; });
    check_throws([&] { (void)pool.borrow(); }, "factory 返回 null");
    pool.assert_no_active_leases();
}

void test_invalid_capacity() {
    ++checks;
    try {
        StringPool bad(0, &new_string, &clear_string);
        (void)bad;
        ++failures;
        std::cerr << "  FAIL: capacity <= 0 应抛 invalid_argument\n";
    } catch (const std::invalid_argument&) {
    } catch (...) {
        ++failures;
        std::cerr << "  FAIL: capacity <= 0 抛出的不是 invalid_argument\n";
    }
}

void test_unreturned_detectable() {
    StringPool pool = make_string_pool();
    {
        auto open = pool.borrow();
        check(pool.active_leases() == 1, "未归还租约被精确计数");
        check_throws([&] { pool.assert_no_active_leases(); }, "未归还租约应使断言失败");
    }  // 析构自动归还
    pool.assert_no_active_leases();
}

void test_move_semantics() {
    StringPool pool = make_string_pool();
    {
        auto first = pool.borrow();
        auto moved = std::move(first);
        check(!first.active(), "move 后原句柄失效");
        check(moved.active(), "move 后新句柄有效");
        moved.get().append("ok");
    }
    pool.assert_no_active_leases();

    // move 赋值时，若目标仍持有有效租约，应先归还再接管
    {
        auto a = pool.borrow();
        auto b = pool.borrow();
        a = std::move(b);
        check(pool.active_leases() == 1, "move 赋值先归还原租约，不留泄漏");
    }
    pool.assert_no_active_leases();
}

void test_noop_recycler() {
    rbc::gc::Pool<int> pool(4);
    {
        auto lease = pool.borrow();
        check(lease.get() == 0, "默认工厂构造出可借用对象");
    }
    pool.assert_no_active_leases();
}

void test_thread_isolation() {
    StringPool pool = make_string_pool();
    std::string* main_ptr = nullptr;
    {
        auto lease = pool.borrow();
        main_ptr = &lease.get();
    }
    std::string* other_ptr = nullptr;
    std::thread t([&] {
        auto lease = pool.borrow();
        other_ptr = &lease.get();
    });
    t.join();
    check(main_ptr != other_ptr, "不同线程使用各自的空闲栈");
    // 子线程归还的对象留在子线程状态里，主线程不受影响
    check(pool.active_leases() == 0, "跨线程借还后计数归零");
    pool.assert_no_active_leases();
}

}  // namespace

int main() {
    test_reuse();
    test_recycler();
    test_double_close();
    test_get_after_close();
    test_cross_thread_close();
    test_cross_thread_get();
    test_capacity_bounded();
    test_factory_null();
    test_invalid_capacity();
    test_unreturned_detectable();
    test_move_semantics();
    test_noop_recycler();
    test_thread_isolation();

    std::cout << "C++ 契约测试: " << checks << " 项，失败 " << failures << " 项\n";
    if (failures == 0) {
        std::cout << "contract_test OK\n";
    }
    return failures == 0 ? 0 : 1;
}
