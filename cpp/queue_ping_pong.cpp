// Counterpart of queue_ping_pong on standalone Asio + C++20 coroutines:
// ping-pong between two coroutines over two capacity-1 channels. --pairs=N runs
// N independent pairs concurrently, splitting a fixed total of TOTAL messages
// evenly (each pair bounces TOTAL/N). Multi-threaded thread_pool, --st for one.
#include <asio.hpp>
#include <asio/experimental/concurrent_channel.hpp>
#include <asio/experimental/awaitable_operators.hpp>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>

using namespace asio::experimental::awaitable_operators;
using channel_t = asio::experimental::concurrent_channel<void(asio::error_code, uint64_t)>;
static constexpr uint64_t TOTAL = 100000;

asio::awaitable<void> task_a(channel_t& ab, channel_t& ba, uint64_t limit) {
    co_await ab.async_send(asio::error_code{}, 0, asio::use_awaitable);
    for (;;) {
        auto [ec, v] = co_await ba.async_receive(asio::as_tuple(asio::use_awaitable));
        if (ec) co_return;
        uint64_t next = v + 1;
        if (next >= limit) { ab.close(); co_return; }
        auto [ec2] = co_await ab.async_send(asio::error_code{}, next, asio::as_tuple(asio::use_awaitable));
        if (ec2) co_return;
    }
}

asio::awaitable<void> task_b(channel_t& ab, channel_t& ba, uint64_t limit) {
    for (;;) {
        auto [ec, v] = co_await ab.async_receive(asio::as_tuple(asio::use_awaitable));
        if (ec) co_return;
        uint64_t next = v + 1;
        if (next >= limit) { ba.close(); co_return; }
        auto [ec2] = co_await ba.async_send(asio::error_code{}, next, asio::as_tuple(asio::use_awaitable));
        if (ec2) co_return;
    }
}

// One pair: owns its two channels and runs both ping-pong tasks concurrently.
asio::awaitable<void> pair(uint64_t limit) {
    auto ex = co_await asio::this_coro::executor;
    channel_t ab(ex, 1), ba(ex, 1);
    co_await (task_a(ab, ba, limit) && task_b(ab, ba, limit));
}

int main(int argc, char** argv) {
    bool st = false;
    uint64_t pairs = 1;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--st")) st = true;
        else if (!strncmp(argv[i], "--pairs=", 8)) pairs = strtoull(argv[i] + 8, nullptr, 10);
    }
    if (pairs == 0) pairs = 1;
    uint64_t per_pair = TOTAL / pairs;
    if (per_pair < 1) per_pair = 1;

    auto start = std::chrono::steady_clock::now();
    asio::thread_pool pool(st ? 1 : std::thread::hardware_concurrency());
    for (uint64_t i = 0; i < pairs; i++) {
        asio::co_spawn(pool, pair(per_pair), asio::detached);
    }
    pool.join();
    auto d = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    printf("Duration: %.3fms (asio%s, %lu pairs, %lu msgs each)\n",
           d, st ? "-st" : "", (unsigned long)pairs, (unsigned long)per_pair);
}
