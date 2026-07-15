#!/bin/sh
# Build the C++ benchmark counterparts. See README.md for fetching the deps.
# usage: ./build.sh /path/to/asio-asio-1-30-2 /path/to/photon
set -e

ASIO=${1:?usage: ./build.sh <asio-dir> <photon-dir>}
PHOTON=${2:?usage: ./build.sh <asio-dir> <photon-dir>}
PHOTON_BUILD=$PHOTON/build

PHOTON_LIBS="$PHOTON_BUILD/output/libphoton.a \
    $PHOTON_BUILD/openssl-build/lib/libssl.a \
    $PHOTON_BUILD/openssl-build/lib/libcrypto.a \
    $PHOTON_BUILD/aio-build/lib/libaio.a"
if [ -f "$PHOTON_BUILD/uring-build/lib/liburing.a" ]; then
    PHOTON_LIBS="$PHOTON_LIBS $PHOTON_BUILD/uring-build/lib/liburing.a"
fi

for f in queue_ping_pong; do
    g++ -std=c++20 -O2 -I"$ASIO/asio/include" -o ${f}_asio $f.cpp -lpthread
done
g++ -std=c++20 -O2 -I"$ASIO/asio/include" -o tcp_server_asio tcp_server_asio.cpp -lpthread

for f in queue_ping_pong_photon tcp_server_photon worker_pool_photon short_sleep_photon; do
    g++ -std=c++17 -O2 -I"$PHOTON/include" -o $f $f.cpp $PHOTON_LIBS -lpthread -ldl -lz
done
