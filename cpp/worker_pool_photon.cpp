// Counterpart of worker_pool on PhotonLibOS: --num-producers coroutines push
// --num-items values (split evenly) into one bounded queue (capacity 256),
// --num-consumers workers race to drain it, each doing --work iterations of a
// data-dependent hash recurrence per item. Everything runs on a single vcpu
// (photon's intended shared-nothing configuration). Golden presets:
//
//   defaults                                  fan-out worker pool (1 -> 1000)
//   --num-producers=1000 --num-consumers=1 --work=0   fan-in shape
#include <photon/photon.h>
#include <photon/thread/thread.h>
#include <photon/thread/stack-allocator.h>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>

static const size_t CAP = 256;
static const uint64_t STACK_SIZE = 64 * 1024;

static uint64_t g_items = 100000, g_producers = 1, g_consumers = 1000, g_work = 64;

struct Queue {
    uint64_t buf[CAP];
    size_t head = 0, tail = 0;
    photon::mutex mu;
    photon::semaphore items{0}, space{CAP};
    void push(uint64_t v) {
        space.wait(1);
        {
            photon::scoped_lock l(mu);
            buf[tail++ % CAP] = v;
        }
        items.signal(1);
    }
    uint64_t pop() {
        items.wait(1);
        uint64_t v;
        {
            photon::scoped_lock l(mu);
            v = buf[head++ % CAP];
        }
        space.signal(1);
        return v;
    }
};

static Queue q;
static photon::semaphore producers_done{0}, consumers_done{0};
static uint64_t g_checksum = 0; // single vcpu: no lock needed

static uint64_t work(uint64_t seed, uint64_t iters) {
    uint64_t x = seed, acc = 0;
    for (uint64_t i = 0; i < iters; i++) {
        x = x * 6364136223846793005ULL + 1442695040888963407ULL;
        acc ^= x >> 29;
    }
    return acc;
}

static void* producer(void* arg) {
    size_t p = (size_t)arg;
    uint64_t start = p * g_items / g_producers;
    uint64_t end = (p + 1) * g_items / g_producers;
    for (uint64_t i = start; i < end; i++) q.push(i + 1);
    producers_done.signal(1);
    return nullptr;
}

static void* consumer(void*) {
    uint64_t acc = 0;
    for (;;) {
        uint64_t item = q.pop();
        if (item == 0) break; // sentinel: producers finished
        acc ^= work(item, g_work);
    }
    g_checksum ^= acc;
    consumers_done.signal(1);
    return nullptr;
}

int main(int argc, char** argv) {
    for (int i = 1; i < argc; i++) {
        uint64_t* target = nullptr;
        const char* value = nullptr;
        if (!strncmp(argv[i], "--num-items=", 12)) { target = &g_items; value = argv[i] + 12; }
        else if (!strncmp(argv[i], "--num-producers=", 16)) { target = &g_producers; value = argv[i] + 16; }
        else if (!strncmp(argv[i], "--num-consumers=", 16)) { target = &g_consumers; value = argv[i] + 16; }
        else if (!strncmp(argv[i], "--work=", 7)) { target = &g_work; value = argv[i] + 7; }
        else {
            fprintf(stderr, "usage: worker_pool_photon [--num-items=N] [--num-producers=N] [--num-consumers=N] [--work=N]\n");
            return 1;
        }
        *target = strtoull(value, nullptr, 10);
    }

    photon::use_pooled_stack_allocator();
    if (photon::init(photon::INIT_EVENT_DEFAULT, photon::INIT_IO_NONE) != 0) {
        fprintf(stderr, "photon init failed\n");
        return 1;
    }

    auto start = std::chrono::steady_clock::now();

    for (uint64_t c = 0; c < g_consumers; c++) photon::thread_create(consumer, nullptr, STACK_SIZE);
    for (uint64_t p = 0; p < g_producers; p++) photon::thread_create(producer, (void*)(size_t)p, STACK_SIZE);

    producers_done.wait(g_producers);
    // Zero is never a real item (values are i+1), so it works as a stop sentinel.
    for (uint64_t c = 0; c < g_consumers; c++) q.push(0);
    consumers_done.wait(g_consumers);

    auto d = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    printf("Duration: %.3fms (%lu items, %lu producers, %lu consumers, work=%lu, %.0f msgs/s, checksum=%lx)\n",
           d, (unsigned long)g_items, (unsigned long)g_producers, (unsigned long)g_consumers,
           (unsigned long)g_work, g_items / (d / 1000.0), (unsigned long)g_checksum);
    return 0;
}
