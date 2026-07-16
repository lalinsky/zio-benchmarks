// Counterpart of queue_ping_pong on PhotonLibOS: ping-pong between two
// coroutines over two capacity-1 slots, WorkPool with one vcpu per core.
// --pairs=N runs N independent pairs concurrently, splitting a fixed total of
// `total` messages evenly (each pair bounces total/N).
#include <photon/photon.h>
#include <photon/thread/thread.h>
#include <photon/thread/workerpool.h>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>

static constexpr uint64_t total = 100000;

struct Slot {
    uint64_t value = 0;
    photon::semaphore full{0}, empty{1};
    void send(uint64_t v) {
        empty.wait(1);
        value = v;
        full.signal(1);
    }
    uint64_t recv() {
        full.wait(1);
        uint64_t v = value;
        empty.signal(1);
        return v;
    }
};

// One pair owns its two slots; two coroutines ping-pong over them.
struct Pair {
    Slot ab, ba;
};

static photon::semaphore done{0};

int main(int argc, char** argv) {
    uint64_t pairs = 1;
    for (int i = 1; i < argc; i++) {
        if (!strncmp(argv[i], "--pairs=", 8)) pairs = strtoull(argv[i] + 8, nullptr, 10);
    }
    if (pairs == 0) pairs = 1;
    uint64_t per_pair = total / pairs;
    if (per_pair < 1) per_pair = 1;

    photon::init(photon::INIT_EVENT_DEFAULT, photon::INIT_IO_NONE);
    photon::WorkPool wp(std::thread::hardware_concurrency(), photon::INIT_EVENT_DEFAULT, photon::INIT_IO_NONE, 0);

    Pair* ps = new Pair[pairs];  // stable addresses; freed at process exit
    auto start = std::chrono::steady_clock::now();
    for (uint64_t i = 0; i < pairs; i++) {
        Pair* p = &ps[i];
        wp.async_call(new auto([p, per_pair] {
            p->ab.send(0);
            for (;;) {
                uint64_t next = p->ba.recv() + 1;
                if (next >= per_pair) {
                    p->ab.send(next); // release peer
                    break;
                }
                p->ab.send(next);
            }
            done.signal(1);
        }));
        wp.async_call(new auto([p, per_pair] {
            for (;;) {
                uint64_t next = p->ab.recv() + 1;
                if (next >= per_pair) {
                    p->ba.send(next); // release peer
                    break;
                }
                p->ba.send(next);
            }
            done.signal(1);
        }));
    }
    done.wait(2 * pairs);
    auto d = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    printf("Duration: %.3fms (photon, %lu pairs, %lu msgs each)\n", d, (unsigned long)pairs, (unsigned long)per_pair);
    return 0;
}
