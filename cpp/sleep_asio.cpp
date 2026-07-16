// Counterpart of sleep on standalone Asio + C++20 coroutines: spawn --tasks
// coroutines that each co_await a steady_timer for --sleep-ms, wait for all of
// them, on a multi-threaded thread_pool (--st for a single thread).
//
// Each coroutine bumps a shared atomic counter as its last act, and main
// verifies the count equals --tasks — proof that every task actually ran.
#include <asio.hpp>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>

asio::awaitable<void> sleep_task(uint64_t sleep_ms, std::atomic<uint64_t>& counter) {
    if (sleep_ms > 0) {
        asio::steady_timer timer(co_await asio::this_coro::executor);
        timer.expires_after(std::chrono::milliseconds(sleep_ms));
        co_await timer.async_wait(asio::use_awaitable);
    }
    counter.fetch_add(1, std::memory_order_relaxed);
}

int main(int argc, char** argv) {
    bool st = false;
    uint64_t num_tasks = 10000;
    uint64_t sleep_ms = 1;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--st")) st = true;
        else if (!strncmp(argv[i], "--tasks=", 8)) num_tasks = strtoull(argv[i] + 8, nullptr, 10);
        else if (!strncmp(argv[i], "--sleep-ms=", 11)) sleep_ms = strtoull(argv[i] + 11, nullptr, 10);
        else { fprintf(stderr, "usage: sleep_asio [--st] [--tasks=N] [--sleep-ms=N]\n"); return 1; }
    }

    std::atomic<uint64_t> counter{0};
    auto start = std::chrono::steady_clock::now();

    asio::thread_pool pool(st ? 1 : std::thread::hardware_concurrency());
    for (uint64_t i = 0; i < num_tasks; i++) {
        asio::co_spawn(pool, sleep_task(sleep_ms, counter), asio::detached);
    }
    pool.join();

    auto d = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();

    uint64_t ran = counter.load(std::memory_order_relaxed);
    if (ran != num_tasks) {
        fprintf(stderr, "only %lu/%lu tasks completed\n", (unsigned long)ran, (unsigned long)num_tasks);
        return 3;
    }

    printf("Duration: %.3fms (asio%s, %lu tasks, sleep %lu ms)\n",
           d, st ? "-st" : "", (unsigned long)num_tasks, (unsigned long)sleep_ms);
}
