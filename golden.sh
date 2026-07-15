#!/bin/sh
# Run the golden benchmarks across all runtimes, interleaved.
#
# Build first:
#   zig build -Doptimize=ReleaseFast          (zig + go binaries)
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
    section "tcp_echo: 1000 conns x 100 msgs x 64B (round $((i + 1)))"
    run "zio-st-stdio " $B/tcp_echo --zio
    run "zio-mt-stdio " $B/tcp_echo --zio-mt
    run "zio-st-native" $B/tcp_echo_native --zio
    run "zio-mt-native" $B/tcp_echo_native --zio-mt
    run "go           " $B/tcp_echo_go
    run "tokio        " $R/tcp_echo
    run "asio         " cpp/tcp_echo_asio
    run "photon       " cpp/tcp_echo_photon
    run "photon-uring " cpp/tcp_echo_photon --uring

    section "tcp_echo: 1 conn x 100k msgs x 4096B (round $((i + 1)))"
    P="--conns=1 --msgs=100000 --size=4096"
    run "zio-st-stdio " $B/tcp_echo --zio $P
    run "zio-st-native" $B/tcp_echo_native --zio $P
    run "go           " $B/tcp_echo_go -conns=1 -msgs=100000 -size=4096
    run "tokio        " $R/tcp_echo $P
    run "asio-st      " cpp/tcp_echo_asio --st $P
    run "photon       " cpp/tcp_echo_photon $P

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

    section "short_sleep: 10k tasks x 1ms (round $((i + 1)))"
    run "zio-st       " $B/short_sleep --zio
    run "zio-mt       " $B/short_sleep --zio-mt
    run "go           " $B/short_sleep_go
    run "tokio        " $R/short_sleep
    run "photon       " cpp/short_sleep_photon

    i=$((i + 1))
done
