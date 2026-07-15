// Golden TCP benchmark on PhotonLibOS: --conns concurrent loopback
// connections, each doing --msgs request/response round-trips of --size bytes
// against a per-connection echo handler. Presets:
//
//   defaults (1000 conns x 100 msgs x 64B)   many-connection throughput
//   --conns=1 --msgs=100000 --size=4096      single-connection latency chain
//
// Everything runs on a single vcpu (photon's intended shared-nothing
// configuration); cross-vcpu wakes would dominate otherwise.
#include <photon/photon.h>
#include <photon/thread/thread.h>
#include <photon/thread/stack-allocator.h>
#include <photon/net/socket.h>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static const uint16_t PORT = 18769;
static const uint64_t STACK_SIZE = 64 * 1024;

static size_t g_conns = 1000, g_msgs = 100, g_size = 64;
static photon::net::ISocketServer* g_server;
static photon::net::ISocketClient* g_client;
static photon::semaphore clients_done{0}, handlers_done{0};

static void* handler(void* arg) {
    auto stream = (photon::net::ISocketStream*)arg;
    std::vector<char> msg(g_size);
    while (true) {
        if (stream->read(msg.data(), g_size) != (ssize_t)g_size) break;
        if (stream->write(msg.data(), g_size) != (ssize_t)g_size) break;
    }
    delete stream;
    handlers_done.signal(1);
    return nullptr;
}

static void* acceptor(void*) {
    for (size_t i = 0; i < g_conns; i++) {
        auto stream = g_server->accept();
        if (!stream) {
            fprintf(stderr, "server: accept failed\n");
            handlers_done.signal(g_conns - i);
            break;
        }
        photon::thread_create(handler, stream, STACK_SIZE);
    }
    return nullptr;
}

static void* client(void*) {
    auto stream = g_client->connect(photon::net::EndPoint("127.0.0.1", PORT));
    if (!stream) {
        fprintf(stderr, "client: connect failed\n");
        clients_done.signal(1);
        return nullptr;
    }
    std::vector<char> msg(g_size, 0);
    for (size_t i = 0; i < g_msgs; i++) {
        if (stream->write(msg.data(), g_size) != (ssize_t)g_size) break;
        if (stream->read(msg.data(), g_size) != (ssize_t)g_size) break;
    }
    delete stream;
    clients_done.signal(1);
    return nullptr;
}

int main(int argc, char** argv) {
    uint64_t event_engine = photon::INIT_EVENT_DEFAULT;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--uring")) { event_engine = photon::INIT_EVENT_IOURING | photon::INIT_EVENT_SIGNAL; continue; }
        size_t* target = nullptr;
        const char* value = nullptr;
        if (!strncmp(argv[i], "--conns=", 8)) { target = &g_conns; value = argv[i] + 8; }
        else if (!strncmp(argv[i], "--msgs=", 7)) { target = &g_msgs; value = argv[i] + 7; }
        else if (!strncmp(argv[i], "--size=", 7)) { target = &g_size; value = argv[i] + 7; }
        else {
            fprintf(stderr, "usage: tcp_echo_photon [--uring] [--conns=N] [--msgs=N] [--size=N]\n");
            return 1;
        }
        *target = strtoull(value, nullptr, 10);
    }

    photon::use_pooled_stack_allocator();
    if (photon::init(event_engine, photon::INIT_IO_NONE) != 0) {
        fprintf(stderr, "photon init failed\n");
        return 1;
    }

    auto start = std::chrono::steady_clock::now();

    g_server = photon::net::new_tcp_socket_server();
    g_client = photon::net::new_tcp_socket_client();
    if (g_server->bind(photon::net::EndPoint("127.0.0.1", PORT)) != 0 || g_server->listen(4096) != 0) {
        fprintf(stderr, "server: bind/listen failed\n");
        return 1;
    }

    photon::thread_create(acceptor, nullptr, STACK_SIZE);
    for (size_t i = 0; i < g_conns; i++) {
        photon::thread_create(client, nullptr, STACK_SIZE);
    }

    clients_done.wait(g_conns);
    handlers_done.wait(g_conns);

    auto d = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    size_t total = g_conns * g_msgs;
    printf("Duration: %.3fms (%zu msgs over %zu conns, size %zu, %.0f msgs/s)\n",
           d, total, g_conns, g_size, total / (d / 1000.0));

    delete g_server;
    delete g_client;
    return 0;
}
