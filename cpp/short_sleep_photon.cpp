// Counterpart of short_sleep on PhotonLibOS: spawn 10k coroutines that each
// sleep 1ms, wait for all. Measures spawn cost + timer pressure. Single vcpu.
#include <photon/photon.h>
#include <photon/thread/thread.h>
#include <photon/thread/stack-allocator.h>
#include <chrono>
#include <cstdio>

static const uint64_t NUM_TASKS = 10000;
static const uint64_t STACK_SIZE = 64 * 1024;

static photon::semaphore done{0};

static void* sleeper(void*) {
    photon::thread_usleep(1000);
    done.signal(1);
    return nullptr;
}

int main() {
    photon::use_pooled_stack_allocator();
    if (photon::init(photon::INIT_EVENT_DEFAULT, photon::INIT_IO_NONE) != 0) {
        fprintf(stderr, "photon init failed\n");
        return 1;
    }

    auto start = std::chrono::steady_clock::now();
    for (uint64_t i = 0; i < NUM_TASKS; i++) {
        photon::thread_create(sleeper, nullptr, STACK_SIZE);
    }
    done.wait(NUM_TASKS);
    auto d = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    printf("Duration: %.3fms (%lu sleeps of 1ms)\n", d, (unsigned long)NUM_TASKS);
    return 0;
}
