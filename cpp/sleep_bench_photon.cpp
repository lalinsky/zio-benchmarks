// Golden sleep/spawn benchmark on PhotonLibOS: --tasks coroutines each
// sleeping --sleep-ms, wait for all. --sleep-ms=0 is a pure no-op spawn
// benchmark. Single vcpu.
#include <photon/photon.h>
#include <photon/thread/thread.h>
#include <photon/thread/stack-allocator.h>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>

static uint64_t g_tasks = 10000;
static uint64_t g_sleep_ms = 1;
static const uint64_t STACK_SIZE = 64 * 1024;

static photon::semaphore done{0};

static void* sleeper(void*) {
    if (g_sleep_ms > 0) photon::thread_usleep(g_sleep_ms * 1000);
    done.signal(1);
    return nullptr;
}

int main(int argc, char** argv) {
    for (int i = 1; i < argc; i++) {
        uint64_t* target = nullptr;
        const char* value = nullptr;
        if (!strncmp(argv[i], "--tasks=", 8)) { target = &g_tasks; value = argv[i] + 8; }
        else if (!strncmp(argv[i], "--sleep-ms=", 11)) { target = &g_sleep_ms; value = argv[i] + 11; }
        else {
            fprintf(stderr, "usage: sleep_bench_photon [--tasks=N] [--sleep-ms=N]\n");
            return 2;
        }
        *target = strtoull(value, nullptr, 10);
    }
    photon::use_pooled_stack_allocator();
    if (photon::init(photon::INIT_EVENT_DEFAULT, photon::INIT_IO_NONE) != 0) {
        fprintf(stderr, "photon init failed\n");
        return 1;
    }

    auto start = std::chrono::steady_clock::now();
    for (uint64_t i = 0; i < g_tasks; i++) {
        photon::thread_create(sleeper, nullptr, STACK_SIZE);
    }
    done.wait(g_tasks);
    auto d = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    printf("Duration: %.3fms (%lu tasks, sleep %lums)\n", d, (unsigned long)g_tasks, (unsigned long)g_sleep_ms);
    return 0;
}
