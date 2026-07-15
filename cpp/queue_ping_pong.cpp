// Counterpart of queue_ping_pong on standalone Asio + C++20 coroutines:
// 100k messages ping-ponged between two coroutines over two capacity-1
// channels, on a multi-threaded thread_pool (--st for single thread).
#include <asio.hpp>
#include <asio/experimental/concurrent_channel.hpp>
#include <chrono>
#include <cstdio>
#include <cstring>

using channel_t = asio::experimental::concurrent_channel<void(asio::error_code, uint64_t)>;
static constexpr uint64_t LIMIT = 100000;

asio::awaitable<void> task_a(channel_t& ab, channel_t& ba) {
    co_await ab.async_send(asio::error_code{}, 0, asio::use_awaitable);
    for (;;) {
        auto [ec, v] = co_await ba.async_receive(asio::as_tuple(asio::use_awaitable));
        if (ec) co_return;
        uint64_t next = v + 1;
        if (next >= LIMIT) { ab.close(); co_return; }
        auto [ec2] = co_await ab.async_send(asio::error_code{}, next, asio::as_tuple(asio::use_awaitable));
        if (ec2) co_return;
    }
}

asio::awaitable<void> task_b(channel_t& ab, channel_t& ba) {
    for (;;) {
        auto [ec, v] = co_await ab.async_receive(asio::as_tuple(asio::use_awaitable));
        if (ec) co_return;
        uint64_t next = v + 1;
        if (next >= LIMIT) { ba.close(); co_return; }
        auto [ec2] = co_await ba.async_send(asio::error_code{}, next, asio::as_tuple(asio::use_awaitable));
        if (ec2) co_return;
    }
}

int main(int argc, char** argv) {
    bool st = argc > 1 && !strcmp(argv[1], "--st");
    auto start = std::chrono::steady_clock::now();
    asio::thread_pool pool(st ? 1 : std::thread::hardware_concurrency());
    channel_t ab(pool, 1), ba(pool, 1);
    asio::co_spawn(pool, task_a(ab, ba), asio::detached);
    asio::co_spawn(pool, task_b(ab, ba), asio::detached);
    pool.join();
    auto d = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    printf("Duration: %.3fms (asio%s, %lu msgs)\n", d, st ? "-st" : "", (unsigned long)LIMIT);
}
