// Counterpart of queue_ping_pong on PhotonLibOS: 100k messages ping-ponged
// between two coroutines over two capacity-1 slots, WorkPool with one vcpu
// per core.
#include <photon/photon.h>
#include <photon/thread/thread.h>
#include <photon/thread/workerpool.h>
#include <chrono>
#include <cstdio>
#include <thread>

static constexpr uint64_t LIMIT = 100000;

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

static Slot ab, ba;
static photon::semaphore done{0};

int main() {
    photon::init(photon::INIT_EVENT_DEFAULT, photon::INIT_IO_NONE);
    photon::WorkPool wp(std::thread::hardware_concurrency(), photon::INIT_EVENT_DEFAULT, photon::INIT_IO_NONE, 0);

    auto start = std::chrono::steady_clock::now();
    wp.async_call(new auto([] {
        ab.send(0);
        for (;;) {
            uint64_t v = ba.recv();
            uint64_t next = v + 1;
            if (next >= LIMIT) {
                ab.send(next); // release peer
                break;
            }
            ab.send(next);
        }
        done.signal(1);
    }));
    wp.async_call(new auto([] {
        for (;;) {
            uint64_t v = ab.recv();
            uint64_t next = v + 1;
            if (next >= LIMIT) {
                ba.send(next); // release peer
                break;
            }
            ba.send(next);
        }
        done.signal(1);
    }));
    done.wait(2);
    auto d = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    printf("Duration: %.3fms (photon, %lu msgs)\n", d, (unsigned long)LIMIT);
    return 0;
}
