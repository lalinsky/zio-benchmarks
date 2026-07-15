// TCP load driver ("wrk for raw TCP"): the fixed side of the client/server
// benchmarks. Plain C, one blocking thread per connection, no event loop, so
// the runtime under test is always the interesting side. Build:
//
//   cc -O2 -o tcp_driver tcp_driver.c -lpthread
//
// Modes (against the per-runtime tcp_server subjects):
//   echo   write --size bytes, read them back, --msgs times per connection;
//          --pipeline P keeps P messages in flight
//   send   stream --mb total (split across conns) to a sink server
//   recv   read --mb total (split across conns) from a source server
//
// usage: tcp_driver --mode=echo|send|recv [--host=H] [--port=P] [--conns=N]
//                   [--msgs=N] [--size=N] [--pipeline=N] [--mb=N]
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static const char* g_host = "127.0.0.1";
static int g_port = 18800;
static long g_conns = 1;
static long g_msgs = 100000;
static long g_size = 64;
static long g_pipeline = 1;
static long g_mb = 4096;
static enum { MODE_ECHO, MODE_SEND, MODE_RECV } g_mode = MODE_ECHO;

static pthread_barrier_t g_barrier;

static int connect_retry(void) {
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(g_port);
    inet_pton(AF_INET, g_host, &addr.sin_addr);
    for (int attempt = 0; attempt < 200; attempt++) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return -1;
        if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) == 0) {
            int one = 1;
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            return fd;
        }
        close(fd);
        usleep(10000); // server may still be starting
    }
    return -1;
}

static int write_full(int fd, const char* buf, size_t len) {
    while (len > 0) {
        ssize_t n = write(fd, buf, len);
        if (n <= 0) return -1;
        buf += n;
        len -= n;
    }
    return 0;
}

static int read_full(int fd, char* buf, size_t len) {
    while (len > 0) {
        ssize_t n = read(fd, buf, len);
        if (n <= 0) return -1;
        buf += n;
        len -= n;
    }
    return 0;
}

static void* worker(void* arg) {
    long* result = arg; // 0 = ok
    *result = -1;

    int fd = connect_retry();
    if (fd < 0) {
        fprintf(stderr, "connect failed\n");
        pthread_barrier_wait(&g_barrier);
        return NULL;
    }
    char* buf = calloc(1, g_size);

    pthread_barrier_wait(&g_barrier); // start together, after all connected

    switch (g_mode) {
    case MODE_ECHO: {
        long inflight = g_pipeline < g_msgs ? g_pipeline : g_msgs;
        long sent = 0, done = 0;
        for (; sent < inflight; sent++) {
            if (write_full(fd, buf, g_size) != 0) goto out;
        }
        while (done < g_msgs) {
            if (read_full(fd, buf, g_size) != 0) goto out;
            done++;
            if (sent < g_msgs) {
                if (write_full(fd, buf, g_size) != 0) goto out;
                sent++;
            }
        }
        break;
    }
    case MODE_SEND: {
        long left = g_mb * 1024 * 1024 / g_conns;
        while (left > 0) {
            long n = left < g_size ? left : g_size;
            if (write_full(fd, buf, n) != 0) goto out;
            left -= n;
        }
        break;
    }
    case MODE_RECV: {
        long left = g_mb * 1024 * 1024 / g_conns;
        while (left > 0) {
            ssize_t n = read(fd, buf, left < g_size ? left : g_size);
            if (n <= 0) goto out;
            left -= n;
        }
        break;
    }
    }
    *result = 0;
out:
    free(buf);
    close(fd);
    return NULL;
}

int main(int argc, char** argv) {
    for (int i = 1; i < argc; i++) {
        if (!strncmp(argv[i], "--mode=", 7)) {
            const char* m = argv[i] + 7;
            if (!strcmp(m, "echo")) g_mode = MODE_ECHO;
            else if (!strcmp(m, "send")) g_mode = MODE_SEND;
            else if (!strcmp(m, "recv")) g_mode = MODE_RECV;
            else goto usage;
        } else if (!strncmp(argv[i], "--host=", 7)) g_host = argv[i] + 7;
        else if (!strncmp(argv[i], "--port=", 7)) g_port = atoi(argv[i] + 7);
        else if (!strncmp(argv[i], "--conns=", 8)) g_conns = atol(argv[i] + 8);
        else if (!strncmp(argv[i], "--msgs=", 7)) g_msgs = atol(argv[i] + 7);
        else if (!strncmp(argv[i], "--size=", 7)) g_size = atol(argv[i] + 7);
        else if (!strncmp(argv[i], "--pipeline=", 11)) g_pipeline = atol(argv[i] + 11);
        else if (!strncmp(argv[i], "--mb=", 5)) g_mb = atol(argv[i] + 5);
        else goto usage;
    }
    if (g_conns < 1 || g_size < 1 || g_pipeline < 1) goto usage;

    pthread_barrier_init(&g_barrier, NULL, g_conns + 1);

    pthread_t* threads = calloc(g_conns, sizeof(pthread_t));
    long* results = calloc(g_conns, sizeof(long));
    for (long i = 0; i < g_conns; i++) {
        pthread_create(&threads[i], NULL, worker, &results[i]);
    }

    pthread_barrier_wait(&g_barrier); // all connected
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    long failed = 0;
    for (long i = 0; i < g_conns; i++) {
        pthread_join(threads[i], NULL);
        if (results[i] != 0) failed++;
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);

    double secs = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    if (failed) {
        fprintf(stderr, "%ld/%ld connections failed\n", failed, g_conns);
        return 1;
    }
    if (g_mode == MODE_ECHO) {
        long total = g_msgs * g_conns;
        printf("echo: %.3f ms, %ld msgs over %ld conns, size %ld, pipeline %ld, %.0f msgs/s\n",
               secs * 1000.0, total, g_conns, g_size, g_pipeline, total / secs);
    } else {
        double gb = g_mb * 1024.0 * 1024.0 / g_conns * g_conns / 1e9;
        printf("%s: %.3f ms, %ld MB over %ld conns, chunk %ld, %.2f GB/s\n",
               g_mode == MODE_SEND ? "send" : "recv",
               secs * 1000.0, g_mb, g_conns, g_size, gb / secs);
    }
    return 0;

usage:
    fprintf(stderr, "usage: tcp_driver --mode=echo|send|recv [--host=H] [--port=P] [--conns=N] [--msgs=N] [--size=N] [--pipeline=N] [--mb=N]\n");
    return 2;
}
