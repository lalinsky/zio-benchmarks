#!/bin/sh
# TCP benchmarks with a separate driver process (driver/tcp_driver.c) so the
# runtime under test is always the server side. Driver and server are pinned
# to disjoint core sets, so task placement inside one process can't skew the
# comparison.
#
# Build first:
#   zig build -Doptimize=ReleaseFast          (zig servers)
#   ./build_go.sh                             (go server)
#   (cd rust && cargo build --release)        (tokio server)
#   (cd cpp && ./build.sh <asio> <photon>)    (asio + photon servers)
#
# N=5 ./tcp_bench.sh   to change rounds (default 3).
set -u

N=${N:-3}
PORT=18800
B=zig-out/bin
R=rust/target/release

NPROC=$(nproc)
HALF=$((NPROC / 2))
DRIVER_CORES="0-$((HALF - 1))"
SERVER_CORES="$HALF-$((NPROC - 1))"

DRIVER=driver/tcp_driver
if [ ! -x $DRIVER ] || [ driver/tcp_driver.c -nt $DRIVER ]; then
    cc -O2 -o $DRIVER driver/tcp_driver.c -lpthread || exit 1
fi

# run_subject <label> <mode> <server command...>
# starts the server pinned to SERVER_CORES, runs the scenarios for <mode>,
# kills the server.
run_subject() {
    label=$1
    mode=$2
    shift 2
    [ -x "$1" ] || return 0

    taskset -c "$SERVER_CORES" "$@" --mode="$mode" --port=$PORT >/dev/null 2>&1 &
    server_pid=$!

    case $mode in
    echo)
        drive "$label lat  " --mode=echo --conns=1 --msgs=100000 --size=4096
        drive "$label many " --mode=echo --conns=1000 --msgs=100 --size=64
        drive "$label pipe " --mode=echo --conns=64 --msgs=10000 --size=64 --pipeline=16
        ;;
    sink)
        drive "$label send1" --mode=send --mb=8192 --size=65536 --conns=1
        drive "$label send8" --mode=send --mb=8192 --size=65536 --conns=8
        ;;
    source)
        drive "$label recv1" --mode=recv --mb=8192 --size=65536 --conns=1
        drive "$label recv8" --mode=recv --mb=8192 --size=65536 --conns=8
        ;;
    esac

    kill $server_pid 2>/dev/null
    wait $server_pid 2>/dev/null
    sleep 0.3 # let the port free up before the next server binds
}

drive() {
    dlabel=$1
    shift
    out=$(taskset -c "$DRIVER_CORES" $DRIVER --port=$PORT "$@" 2>&1 | tail -1)
    echo "$dlabel: $out"
}

round() {
    for mode in echo sink source; do
        echo ""
        echo "===== $mode ====="
        run_subject "zio-st       " $mode $B/tcp_server_native --zio
        run_subject "zio-mt       " $mode $B/tcp_server_native --zio-mt
        run_subject "zio-st-stdio " $mode $B/tcp_server --zio
        run_subject "zio-mt-stdio " $mode $B/tcp_server --zio-mt
        run_subject "go           " $mode $B/tcp_server_go
        run_subject "tokio        " $mode $R/tcp_server
        run_subject "asio         " $mode cpp/tcp_server_asio
        run_subject "photon       " $mode cpp/tcp_server_photon
        run_subject "photon-uring " $mode cpp/tcp_server_photon --uring
    done
}

i=0
while [ $i -lt "$N" ]; do
    echo ""
    echo "########## round $((i + 1)) ##########"
    round
    i=$((i + 1))
done
