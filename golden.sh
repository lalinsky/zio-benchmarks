#!/bin/sh
# Run the in-process golden benchmarks across all runtimes, interleaved.
# TCP benchmarks live in tcp_bench.sh (separate driver process + core pinning).
#
# Build first:
#   zig build -Doptimize=ReleaseFast          (zig binaries)
#   ./build_go.sh                             (go counterparts)
#   (cd rust && cargo build --release)        (tokio)
#   (cd cpp && ./build.sh <asio> <photon>)    (asio + photon, see cpp/README.md)
#
# N=5 ./golden.sh   to change the number of interleaved rounds (default 3).
set -u

N=${N:-3}
B=zig-out/bin
R=rust/target/release

run() { # label command...
    label=$1; shift
    [ -x "$1" ] || return 0
    out=$("$@" 2>&1 | grep -a Duration | tail -1)
    [ -n "$out" ] && echo "$label: $out"
}

section() {
    echo ""
    echo "===== $* ====="
}

i=0
while [ $i -lt "$N" ]; do
    section "queue_ping_pong (round $((i + 1)))"
    run "zio-st-stdio " $B/queue_ping_pong --zio
    run "zio-mt-stdio " $B/queue_ping_pong --zio-mt
    run "zio-st-native" $B/queue_ping_pong_native --zio
    run "zio-mt-native" $B/queue_ping_pong_native --zio-mt
    run "go           " $B/queue_ping_pong_go
    run "tokio        " $R/queue_ping_pong
    run "asio         " cpp/queue_ping_pong_asio
    run "photon       " cpp/queue_ping_pong_photon

    section "worker_pool: 1 -> 1000, work=64 (round $((i + 1)))"
    run "zio-st-stdio " $B/worker_pool --zio
    run "zio-mt-stdio " $B/worker_pool --zio-mt
    run "zio-st-native" $B/worker_pool_native --zio
    run "zio-mt-native" $B/worker_pool_native --zio-mt
    run "go           " $B/worker_pool_go
    run "tokio        " $R/worker_pool
    run "photon       " cpp/worker_pool_photon

    section "worker_pool: 1000 -> 1, work=0, fan-in (round $((i + 1)))"
    FI="--num-producers=1000 --num-consumers=1 --work=0"
    run "zio-st-stdio " $B/worker_pool --zio $FI
    run "zio-mt-stdio " $B/worker_pool --zio-mt $FI
    run "zio-st-native" $B/worker_pool_native --zio $FI
    run "zio-mt-native" $B/worker_pool_native --zio-mt $FI
    run "go           " $B/worker_pool_go -num-producers=1000 -num-consumers=1 -work=0
    run "tokio        " $R/worker_pool $FI
    run "photon       " cpp/worker_pool_photon $FI

    section "sleep: 10k tasks x 1ms (round $((i + 1)))"
    run "zio-st       " $B/sleep_bench --zio
    run "zio-mt       " $B/sleep_bench --zio-mt
    run "go           " $B/sleep_bench_go
    run "tokio        " $R/sleep_bench
    run "photon       " cpp/sleep_bench_photon

    section "spawn (sleep-0): 10k no-op tasks (round $((i + 1)))"
    run "zio-st       " $B/sleep_bench --zio --sleep-ms=0
    run "zio-mt       " $B/sleep_bench --zio-mt --sleep-ms=0
    run "go           " $B/sleep_bench_go -sleep-ms=0
    run "tokio        " $R/sleep_bench --sleep-ms=0
    run "photon       " cpp/sleep_bench_photon --sleep-ms=0

    i=$((i + 1))
done
