// Golden TCP benchmark on standalone Asio + C++20 coroutines: --conns
// concurrent loopback connections, each doing --msgs request/response
// round-trips of --size bytes against a per-connection echo handler.
// io_context run by hardware_concurrency threads by default (--st for one).
// Presets:
//
//   defaults (1000 conns x 100 msgs x 64B)   many-connection throughput
//   --conns=1 --msgs=100000 --size=4096      single-connection latency chain
#include <asio.hpp>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>

using asio::ip::tcp;

static const uint16_t PORT = 18770;

static size_t g_conns = 1000, g_msgs = 100, g_size = 64;

asio::awaitable<void> echo_handler(tcp::socket sock) {
    sock.set_option(tcp::no_delay(true));
    std::vector<char> msg(g_size);
    try {
        for (;;) {
            co_await asio::async_read(sock, asio::buffer(msg), asio::use_awaitable);
            co_await asio::async_write(sock, asio::buffer(msg), asio::use_awaitable);
        }
    } catch (const std::exception&) {
        // connection closed
    }
}

asio::awaitable<void> server(tcp::acceptor& acceptor) {
    auto executor = co_await asio::this_coro::executor;
    for (size_t i = 0; i < g_conns; i++) {
        tcp::socket sock = co_await acceptor.async_accept(asio::use_awaitable);
        asio::co_spawn(executor, echo_handler(std::move(sock)), asio::detached);
    }
}

asio::awaitable<void> client() {
    auto executor = co_await asio::this_coro::executor;
    tcp::socket sock(executor);
    co_await sock.async_connect(tcp::endpoint(asio::ip::make_address_v4("127.0.0.1"), PORT), asio::use_awaitable);
    sock.set_option(tcp::no_delay(true));
    std::vector<char> msg(g_size, 0);
    try {
        for (size_t i = 0; i < g_msgs; i++) {
            co_await asio::async_write(sock, asio::buffer(msg), asio::use_awaitable);
            co_await asio::async_read(sock, asio::buffer(msg), asio::use_awaitable);
        }
    } catch (const std::exception& e) {
        fprintf(stderr, "client: %s\n", e.what());
    }
}

int main(int argc, char** argv) {
    unsigned num_threads = std::thread::hardware_concurrency();
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--st")) { num_threads = 1; continue; }
        size_t* target = nullptr;
        const char* value = nullptr;
        if (!strncmp(argv[i], "--conns=", 8)) { target = &g_conns; value = argv[i] + 8; }
        else if (!strncmp(argv[i], "--msgs=", 7)) { target = &g_msgs; value = argv[i] + 7; }
        else if (!strncmp(argv[i], "--size=", 7)) { target = &g_size; value = argv[i] + 7; }
        else if (!strncmp(argv[i], "--threads=", 10)) { num_threads = atoi(argv[i] + 10); continue; }
        else {
            fprintf(stderr, "usage: tcp_echo_asio [--st] [--threads=N] [--conns=N] [--msgs=N] [--size=N]\n");
            return 1;
        }
        *target = strtoull(value, nullptr, 10);
    }

    asio::io_context ctx;
    tcp::acceptor acceptor(ctx, tcp::endpoint(asio::ip::make_address_v4("127.0.0.1"), PORT));
    acceptor.listen(4096);

    auto start = std::chrono::steady_clock::now();

    asio::co_spawn(ctx, server(acceptor), asio::detached);
    for (size_t i = 0; i < g_conns; i++) {
        asio::co_spawn(ctx, client(), asio::detached);
    }

    std::vector<std::thread> threads;
    for (unsigned i = 1; i < num_threads; i++) {
        threads.emplace_back([&ctx] { ctx.run(); });
    }
    ctx.run();
    for (auto& t : threads) t.join();

    auto d = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    size_t total = g_conns * g_msgs;
    printf("Duration: %.3fms (%zu msgs over %zu conns, size %zu, %.0f msgs/s)\n",
           d, total, g_conns, g_size, total / (d / 1000.0));
    return 0;
}
