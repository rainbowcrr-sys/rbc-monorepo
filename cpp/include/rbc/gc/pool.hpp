// gc-primitives · C++17 header-only
// 与 Java 版同一套概念契约：Pool / Lease / Recycler、线程本地有界、始终强制误用检测。
//
// 使用契约（与 SPEC.md 一致）：
//   - Lease 是 move-only 的 RAII 句柄，析构自动归还；
//   - 句柄与借出的对象只归借用线程使用，不跨线程传递；
//   - close() 之后不得再持有对象引用；
//   - Factory 返回 T*（池负责 delete），Recycler 约定 noexcept；
//   - 回收对象只能由同一 Pool 实例借还，Pool 对象须长于使用它的线程。
#pragma once

#include <atomic>
#include <cstddef>
#include <exception>
#include <stdexcept>
#include <string>
#include <thread>
#include <type_traits>
#include <unordered_map>
#include <utility>
#include <vector>

namespace rbc::gc {

/** 契约被破坏时抛出；对应 Java 的 PoolStateException。 */
class pool_error : public std::logic_error {
public:
    using std::logic_error::logic_error;
};

namespace detail {

template <class T>
struct default_factory {
    T* operator()() const { return new T(); }
};

struct noop_recycler {
    template <class T>
    void operator()(T&) const noexcept {}
};

}  // namespace detail

/**
 * 全局对象内含线程本地状态：一个 Pool 实例可跨线程使用，每线程各自一份有界空闲栈。
 * 命中空闲槽时不分配对象；Lease 本身按值返回、活在栈上，因此正常路径接近零堆分配。
 *
 * Factory  : T*()                 工厂，返回空指针视为契约违反
 * Recycler : void(T&) noexcept   归还时的复位钩子（约定，不强制 static_assert）
 */
template <class T,
          class Factory = detail::default_factory<T>,
          class Recycler = detail::noop_recycler>
class Pool {
public:
    using value_type = T;
    static constexpr std::size_t default_capacity = 64;

private:
    struct State {
        std::vector<T*> values;
        bool reserved = false;

        State() = default;
        State(const State&) = delete;
        State& operator=(const State&) = delete;
        State(State&&) = default;
        State& operator=(State&&) = default;

        ~State() {
            // 线程退出时释放它自己缓存的空闲对象，不留泄漏
            for (T* p : values) {
                delete p;
            }
        }
    };

    // 函数内 static thread_local：每个 Pool<T, F, R> 特化各自一份，按实例指针分状态
    static std::unordered_map<const Pool*, State>& states() {
        static thread_local std::unordered_map<const Pool*, State> m;
        return m;
    }

public:
    /** move-only 的租约句柄；析构自动归还。 */
    class Lease {
        friend class Pool;

        Pool* owner_ = nullptr;
        T* value_ = nullptr;
        std::thread::id borrower_{};
        bool active_ = false;

        Lease(Pool* owner, T* value, std::thread::id borrower) noexcept
            : owner_(owner), value_(value), borrower_(borrower), active_(true) {}

        void take_from(Lease& other) noexcept {
            owner_ = other.owner_;
            value_ = other.value_;
            borrower_ = other.borrower_;
            active_ = other.active_;
            other.owner_ = nullptr;
            other.value_ = nullptr;
            other.active_ = false;
        }

        void release() noexcept {
            active_ = false;
            T* v = value_;
            Pool* o = owner_;
            value_ = nullptr;
            owner_ = nullptr;
            o->return_value(v);
        }

    public:
        Lease() noexcept = default;
        Lease(const Lease&) = delete;
        Lease& operator=(const Lease&) = delete;

        Lease(Lease&& other) noexcept { take_from(other); }

        Lease& operator=(Lease&& other) noexcept {
            if (this != &other) {
                if (active_) {
                    release();
                }
                take_from(other);
            }
            return *this;
        }

        ~Lease() {
            if (active_) {
                // 析构不能抛异常。跨线程析构属于契约违反，不静默放过。
                if (std::this_thread::get_id() != borrower_) {
                    std::terminate();
                }
                release();
            }
        }

        T& get() {
            if (!active_) {
                throw pool_error("lease is closed; get() after close()");
            }
            if (std::this_thread::get_id() != borrower_) {
                throw pool_error("lease used off its borrowing thread");
            }
            return *value_;
        }

        const T& get() const {
            return const_cast<Lease*>(this)->get();
        }

        /** 显式归还：完整校验，误用抛 pool_error。 */
        void close() {
            if (!active_) {
                throw pool_error("lease already returned (double close)");
            }
            if (std::this_thread::get_id() != borrower_) {
                throw pool_error("cross-thread return");
            }
            release();
        }

        bool active() const noexcept { return active_; }
    };

    explicit Pool(std::size_t capacity = default_capacity,
                  Factory factory = Factory{},
                  Recycler recycler = Recycler{})
        : capacity_(capacity),
          factory_(std::move(factory)),
          recycler_(std::move(recycler)) {
        if (capacity_ == 0) {
            throw std::invalid_argument("capacity must be > 0");
        }
    }

    Pool(const Pool&) = delete;
    Pool& operator=(const Pool&) = delete;
    Pool(Pool&&) = delete;
    Pool& operator=(Pool&&) = delete;

    ~Pool() = default;

    /** 借出一个对象；返回的 Lease 必须关闭或析构。 */
    Lease borrow() {
        State& s = state_for_this_thread();
        T* v = nullptr;
        if (!s.values.empty()) {
            v = s.values.back();
            s.values.pop_back();
        } else {
            try {
                v = factory_();
            } catch (...) {
                throw;
            }
            if (v == nullptr) {
                throw pool_error("factory returned null");
            }
        }
        borrows_.fetch_add(1, std::memory_order_relaxed);
        live_.fetch_add(1, std::memory_order_relaxed);
        return Lease(this, v, std::this_thread::get_id());
    }

    std::size_t capacity() const noexcept { return capacity_; }

    /** 当前线程的空闲对象数；仅用于诊断。 */
    std::size_t idle_count() const noexcept {
        auto& m = states();
        auto it = m.find(this);
        return it == m.end() ? 0 : it->second.values.size();
    }

    long long active_leases() const noexcept {
        return live_.load(std::memory_order_relaxed);
    }

    long long borrow_count() const noexcept {
        return borrows_.load(std::memory_order_relaxed);
    }

    long long return_count() const noexcept {
        return returns_.load(std::memory_order_relaxed);
    }

    /** 断言当前没有未归还的租约，测试期用来把泄漏直接变成失败。 */
    void assert_no_active_leases() const {
        long long n = active_leases();
        if (n != 0) {
            throw pool_error(std::to_string(n) +
                             " lease(s) not returned; every borrow() must be closed");
        }
    }

private:
    friend class Lease;

    State& state_for_this_thread() {
        auto& m = states();
        auto it = m.find(this);
        if (it == m.end()) {
            it = m.emplace(this, State{}).first;
        }
        State& s = it->second;
        if (!s.reserved) {
            s.values.reserve(capacity_);
            s.reserved = true;
        }
        return s;
    }

    void recycle(T& v) noexcept {
        // noexcept 边界：用户复位钩子若抛异常会 std::terminate，
        // 与 SPEC「复位约定 noexcept，违者 terminate」一致。
        recycler_(v);
    }

    void return_value(T* v) noexcept {
        recycle(*v);
        returns_.fetch_add(1, std::memory_order_relaxed);
        live_.fetch_sub(1, std::memory_order_relaxed);

        // borrow() 一定已为本线程建好 State，这里只查找、不插入，避免分配
        auto& m = states();
        auto it = m.find(this);
        if (it == m.end() || it->second.values.size() >= capacity_) {
            delete v;  // 超出上限直接丢弃，保证有界
            return;
        }
        it->second.values.push_back(v);
    }

    std::size_t capacity_;
    Factory factory_;
    Recycler recycler_;
    std::atomic<long long> borrows_{0};
    std::atomic<long long> returns_{0};
    std::atomic<long long> live_{0};
};

/** 便捷工厂，对应 Java 的 Pools.threadLocal(...)。 */
template <class T, class Factory, class Recycler>
Pool<T, Factory, Recycler> make_pool(Factory factory, Recycler recycler,
                                     std::size_t capacity = Pool<T, Factory, Recycler>::default_capacity) {
    return Pool<T, Factory, Recycler>(capacity, std::move(factory), std::move(recycler));
}

template <class T>
Pool<T> make_pool(std::size_t capacity = Pool<T>::default_capacity) {
    return Pool<T>(capacity);
}

}  // namespace rbc::gc
