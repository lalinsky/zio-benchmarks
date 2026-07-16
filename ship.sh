#!/bin/bash
# Build every benchmark (+ the Go load driver) here, then rsync a minimal,
# runnable tree to a remote host. Toolchains (zig/go/cargo/cmake/g++) are only
# needed on THIS machine; the target just needs Python 3 and a matching glibc —
# it runs the binaries, never builds. C++ deps come from cpp/setup-*.sh into
# cpp/libs/ (not shipped).
#
# usage: ./ship.sh user@host:/path/to/dest      (or a local dir, for testing)
# then on the host:  cd /path/to/dest && ./bench.py --bench all --rounds 9
set -euo pipefail
cd "$(dirname "$0")"

DEST=${1:?usage: ./ship.sh user@host:/dest/dir}

# Exactly the binaries bench.py references (keep in sync with the engine lists).
ZIG_BENCHES="sleep sleep_native queue_ping_pong queue_ping_pong_native worker_pool worker_pool_native"
ZIG_BINS="$ZIG_BENCHES tcp_server_native_io_uring tcp_server_native_epoll \
          sleep_go queue_ping_pong_go worker_pool_go tcp_server_go"
RUST_BINS="sleep queue_ping_pong worker_pool tcp_server"
CPP_BINS="sleep_asio sleep_photon queue_ping_pong_asio queue_ping_pong_photon \
          worker_pool_asio worker_pool_photon tcp_server_asio tcp_server_photon"

echo "== zig (ReleaseFast) =="
for b in $ZIG_BENCHES; do zig build -Doptimize=ReleaseFast -Dbench="$b"; done
# zio's TCP server needs both event-loop backends as separate binaries.
zig build -Doptimize=ReleaseFast -Dbench=tcp_server_native -Dbackend=io_uring
zig build -Doptimize=ReleaseFast -Dbench=tcp_server_native -Dbackend=epoll

echo "== go (counterparts + load driver) =="
for d in sleep queue_ping_pong worker_pool tcp_server; do
    ( cd go && go build -o "../zig-out/bin/${d}_go" "./$d" )
done
go build -o driver/tcp_driver driver/tcp_driver.go

echo "== rust (tokio) =="
( cd rust && cargo build --release $(printf ' --bin %s' $RUST_BINS) )

echo "== cpp (asio + photon) =="
( cd cpp && ./setup-asio.sh && ./setup-photon.sh && ./build.sh )

echo "== stage minimal tree =="
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE"/{zig-out/bin,rust/target/release,cpp,driver}
cp bench.py "$STAGE"/
cp driver/tcp_driver "$STAGE"/driver/
for b in $ZIG_BINS;  do cp "zig-out/bin/$b"        "$STAGE/zig-out/bin/";         done
for b in $RUST_BINS; do cp "rust/target/release/$b" "$STAGE/rust/target/release/"; done
for b in $CPP_BINS;  do cp "cpp/$b"                "$STAGE/cpp/";                 done

echo "== ship to $DEST =="
rsync -a --delete "$STAGE"/ "$DEST"/
echo "done. on the host:  cd <dest> && ./bench.py --bench all --rounds 9"
