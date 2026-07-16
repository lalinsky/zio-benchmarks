// TCP benchmark subject on PhotonLibOS, driven by driver/tcp_driver.go.
// Accepts connections forever (the bench runner kills the process); one
// coroutine per connection, all on a single vcpu (photon's intended
// shared-nothing configuration).
//
//   echo    write back whatever arrives (works with driver pipelining)
//   sink    read and discard until EOF
//   source  write zeros until the client closes
//
// usage: tcp_server_photon [--uring] [--mode=echo|sink|source] [--port=N]
#include <photon/photon.h>
#include <photon/thread/thread.h>
#include <photon/thread/stack-allocator.h>
#include <photon/net/socket.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static const size_t BUF_SIZE = 64 * 1024;
static const uint64_t STACK_SIZE = 64 * 1024;

enum class Mode { echo, sink, source };
static Mode g_mode = Mode::echo;

static void* handler(void* arg) {
    auto stream = (photon::net::ISocketStream*)arg;
    std::vector<char> buf(BUF_SIZE);
    switch (g_mode) {
    case Mode::echo:
        for (;;) {
            ssize_t n = stream->recv(buf.data(), BUF_SIZE);
            if (n <= 0) break;
            if (stream->write(buf.data(), n) != n) break;
        }
        break;
    case Mode::sink:
        for (;;) {
            ssize_t n = stream->recv(buf.data(), BUF_SIZE);
            if (n <= 0) break;
        }
        break;
    case Mode::source:
        for (;;) {
            if (stream->write(buf.data(), BUF_SIZE) != (ssize_t)BUF_SIZE) break;
        }
        break;
    }
    delete stream;
    return nullptr;
}

int main(int argc, char** argv) {
    uint64_t event_engine = photon::INIT_EVENT_DEFAULT;
    uint16_t port = 18800;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--uring")) event_engine = photon::INIT_EVENT_IOURING | photon::INIT_EVENT_SIGNAL;
        else if (!strncmp(argv[i], "--port=", 7)) port = atoi(argv[i] + 7);
        else if (!strncmp(argv[i], "--mode=", 7)) {
            const char* m = argv[i] + 7;
            if (!strcmp(m, "echo")) g_mode = Mode::echo;
            else if (!strcmp(m, "sink")) g_mode = Mode::sink;
            else if (!strcmp(m, "source")) g_mode = Mode::source;
            else { fprintf(stderr, "unknown mode '%s'\n", m); return 2; }
        } else {
            fprintf(stderr, "usage: tcp_server_photon [--uring] [--mode=echo|sink|source] [--port=N]\n");
            return 2;
        }
    }

    photon::use_pooled_stack_allocator();
    if (photon::init(event_engine, photon::INIT_IO_NONE) != 0) {
        fprintf(stderr, "photon init failed\n");
        return 1;
    }

    auto server = photon::net::new_tcp_socket_server();
    if (server->bind(photon::net::EndPoint("127.0.0.1", port)) != 0 || server->listen(4096) != 0) {
        fprintf(stderr, "bind/listen failed\n");
        return 1;
    }
    printf("tcp_server_photon listening on 127.0.0.1:%u\n", port);
    fflush(stdout);

    for (;;) {
        auto stream = server->accept();
        if (!stream) break;
        photon::thread_create(handler, stream, STACK_SIZE);
    }
    delete server;
    return 0;
}
