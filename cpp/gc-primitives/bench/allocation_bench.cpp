// 对照基准：每次 new/delete 一个 std::string，对比从线程池借用并归还。
// 用 --benchmark_counters_tabular=true 或自定义 counter 观察分配次数差异。
#include <rbc/gc.hpp>

#include <benchmark/benchmark.h>

#include <string>

namespace {

std::string* new_string() { return new std::string(); }
void clear_string(std::string& s) noexcept { s.clear(); }

using Pool = rbc::gc::Pool<std::string,
                           std::string* (*)(),
                           void (*)(std::string&)>;

Pool& pool() {
    static Pool p(16, &new_string, &clear_string);
    return p;
}

std::size_t counter = 0;

void BM_AllocateFresh(benchmark::State& state) {
    std::size_t bytes = 0;
    for ([[maybe_unused]] auto _ : state) {
        std::string* s = new std::string();
        s->append("item-");
        s->append(std::to_string(counter++));
        benchmark::DoNotOptimize(*s);
        bytes += s->size();
        delete s;
    }
    state.counters["ops"] = benchmark::Counter(state.iterations());
    benchmark::DoNotOptimize(bytes);
}
BENCHMARK(BM_AllocateFresh);

void BM_BorrowPooled(benchmark::State& state) {
    std::size_t bytes = 0;
    for ([[maybe_unused]] auto _ : state) {
        auto lease = pool().borrow();
        std::string& s = lease.get();
        s.append("item-");
        s.append(std::to_string(counter++));
        benchmark::DoNotOptimize(s);
        bytes += s.size();
    }
    state.counters["ops"] = benchmark::Counter(state.iterations());
    benchmark::DoNotOptimize(bytes);
}
BENCHMARK(BM_BorrowPooled);

}  // namespace

BENCHMARK_MAIN();
