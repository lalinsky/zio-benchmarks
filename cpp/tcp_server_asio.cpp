// TCP benchmark subject on standalone Asio + C++20 coroutines, driven by
// driver/tcp_driver.go. Accepts connections forever (the bench runner kills
// the process); one coroutine per connection. io_context run by
// hardware_concurrency threads (--st for one).
//
//   echo    write back whatever arrives (works with driver pipelining)
//   sink    read and discard until EOF
//   source  write zeros until the client closes
//
// usage: tcp_server_asio [--st] [--threads=N] [--mode=echo|sink|source] [--port=N]
#include <asio.hpp>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>

using asio::ip::tcp;

static const size_t BUF_SIZE = 64 * 1024;

enum class Mode { echo, sink, source };
static Mode g_mode = Mode::echo;

asio::awaitable<void> handler(tcp::socket sock) {
    sock.set_option(tcp::no_delay(true));
    std::vector<char> buf(BUF_SIZE);
    try {
        switch (g_mode) {
        case Mode::echo:
            for (;;) {
                size_t n = co_await sock.async_read_some(asio::buffer(buf), asio::use_awaitable);
                co_await asio::async_write(sock, asio::buffer(buf.data(), n), asio::use_awaitable);
            }
        case Mode::sink:
            for (;;) {
                co_await sock.async_read_some(asio::buffer(buf), asio::use_awaitable);
            }
        case Mode::source:
            for (;;) {
                co_await asio::async_write(sock, asio::buffer(buf), asio::use_awaitable);
            }
        }
    } catch (const std::exception&) {
        // connection closed
    }
}

asio::awaitable<void> server(tcp::acceptor& acceptor) {
    auto executor = co_await asio::this_coro::executor;
    for (;;) {
        tcp::socket sock = co_await acceptor.async_accept(asio::use_awaitable);
        asio::co_spawn(executor, handler(std::move(sock)), asio::detached);
    }
}

int main(int argc, char** argv) {
    unsigned num_threads = std::thread::hardware_concurrency();
    uint16_t port = 18800;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--st")) num_threads = 1;
        else if (!strncmp(argv[i], "--threads=", 10)) num_threads = atoi(argv[i] + 10);
        else if (!strncmp(argv[i], "--port=", 7)) port = atoi(argv[i] + 7);
        else if (!strncmp(argv[i], "--mode=", 7)) {
            const char* m = argv[i] + 7;
            if (!strcmp(m, "echo")) g_mode = Mode::echo;
            else if (!strcmp(m, "sink")) g_mode = Mode::sink;
            else if (!strcmp(m, "source")) g_mode = Mode::source;
            else { fprintf(stderr, "unknown mode '%s'\n", m); return 2; }
        } else {
            fprintf(stderr, "usage: tcp_server_asio [--st] [--threads=N] [--mode=echo|sink|source] [--port=N]\n");
            return 2;
        }
    }

    asio::io_context ctx;
    tcp::acceptor acceptor(ctx, tcp::endpoint(asio::ip::make_address_v4("127.0.0.1"), port));
    acceptor.listen(4096);
    printf("tcp_server_asio listening on 127.0.0.1:%u\n", port);
    fflush(stdout);

    asio::co_spawn(ctx, server(acceptor), asio::detached);

    std::vector<std::thread> threads;
    for (unsigned i = 1; i < num_threads; i++) {
        threads.emplace_back([&ctx] { ctx.run(); });
    }
    ctx.run();
    for (auto& t : threads) t.join();
    return 0;
}
