// Counterpart of worker_pool on standalone Asio + C++20 coroutines:
// --num-producers coroutines push --num-items values (split evenly) into one
// bounded concurrent_channel (capacity 256), --num-consumers coroutines race to
// drain it, each doing --work iterations of a data-dependent hash recurrence per
// item. An order-independent xor checksum verifies all runtimes agree.
// Multi-threaded thread_pool by default, --st for a single thread. Presets:
//
//   defaults                                          fan-out (1 -> 1000)
//   --num-producers=1000 --num-consumers=1 --work=0   fan-in shape
#include <asio.hpp>
#include <asio/experimental/concurrent_channel.hpp>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>

using channel_t = asio::experimental::concurrent_channel<void(asio::error_code, uint64_t)>;
static const size_t CAP = 256;

// Identical recurrence to the other runtimes so the checksum matches.
static uint64_t work(uint64_t seed, uint64_t iters) {
    uint64_t x = seed, acc = 0;
    for (uint64_t i = 0; i < iters; i++) {
        x = x * 6364136223846793005ULL + 1442695040888963407ULL;
        acc ^= x >> 29;
    }
    return acc;
}

asio::awaitable<void> producer(channel_t& ch, uint64_t start, uint64_t end,
                               std::atomic<uint64_t>& remaining, uint64_t consumers) {
    for (uint64_t i = start; i < end; i++) {
        auto [ec] = co_await ch.async_send(asio::error_code{}, i + 1, asio::as_tuple(asio::use_awaitable));
        if (ec) co_return;
    }
    // Last producer to finish pushes one stop sentinel (0) per consumer. Real
    // items are i+1, so 0 never collides; sentinels follow all real items in FIFO
    // order, so every item is drained before any consumer stops.
    if (remaining.fetch_sub(1, std::memory_order_acq_rel) == 1) {
        for (uint64_t c = 0; c < consumers; c++) {
            auto [ec] = co_await ch.async_send(asio::error_code{}, 0, asio::as_tuple(asio::use_awaitable));
            if (ec) co_return;
        }
    }
}

asio::awaitable<void> consumer(channel_t& ch, uint64_t work_iters, std::atomic<uint64_t>& checksum) {
    uint64_t acc = 0;
    for (;;) {
        auto [ec, item] = co_await ch.async_receive(asio::as_tuple(asio::use_awaitable));
        if (ec || item == 0) break; // channel error or stop sentinel
        acc ^= work(item, work_iters);
    }
    checksum.fetch_xor(acc, std::memory_order_relaxed);
}

int main(int argc, char** argv) {
    bool st = false;
    uint64_t items = 100000, producers = 1, consumers = 1000, work_iters = 64;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--st")) { st = true; continue; }
        uint64_t* target = nullptr;
        const char* value = nullptr;
        if (!strncmp(argv[i], "--num-items=", 12)) { target = &items; value = argv[i] + 12; }
        else if (!strncmp(argv[i], "--num-producers=", 16)) { target = &producers; value = argv[i] + 16; }
        else if (!strncmp(argv[i], "--num-consumers=", 16)) { target = &consumers; value = argv[i] + 16; }
        else if (!strncmp(argv[i], "--work=", 7)) { target = &work_iters; value = argv[i] + 7; }
        else {
            fprintf(stderr, "usage: worker_pool_asio [--st] [--num-items=N] [--num-producers=N] [--num-consumers=N] [--work=N]\n");
            return 1;
        }
        *target = strtoull(value, nullptr, 10);
    }

    auto start = std::chrono::steady_clock::now();
    asio::thread_pool pool(st ? 1 : std::thread::hardware_concurrency());
    channel_t ch(pool, CAP);
    std::atomic<uint64_t> checksum{0};
    std::atomic<uint64_t> remaining{producers};

    for (uint64_t c = 0; c < consumers; c++) {
        asio::co_spawn(pool, consumer(ch, work_iters, checksum), asio::detached);
    }
    for (uint64_t p = 0; p < producers; p++) {
        uint64_t s = p * items / producers;
        uint64_t e = (p + 1) * items / producers;
        asio::co_spawn(pool, producer(ch, s, e, remaining, consumers), asio::detached);
    }
    pool.join();

    auto d = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    printf("Duration: %.3fms (%lu items, %lu producers, %lu consumers, work=%lu, %.0f msgs/s, checksum=%lx)\n",
           d, (unsigned long)items, (unsigned long)producers, (unsigned long)consumers,
           (unsigned long)work_iters, items / (d / 1000.0), (unsigned long)checksum.load());
}
