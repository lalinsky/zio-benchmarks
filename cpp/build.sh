#!/bin/sh
# Build the C++ benchmark counterparts (Asio + PhotonLibOS).
#
# By default the deps are taken from cpp/libs/ — run ./setup-asio.sh and
# ./setup-photon.sh first. Override with explicit paths:
#   ./build.sh /path/to/asio-dir /path/to/photon-dir
set -e
cd "$(dirname "$0")"

ASIO=${1:-libs/asio}
PHOTON=${2:-libs/photon}
PHOTON_BUILD=$PHOTON/build

if [ ! -f "$ASIO/asio/include/asio.hpp" ]; then
    echo "asio not found at $ASIO — run ./setup-asio.sh (or pass an asio dir)" >&2
    exit 1
fi
if [ ! -f "$PHOTON_BUILD/output/libphoton.a" ]; then
    echo "photon not built at $PHOTON — run ./setup-photon.sh (or pass a photon dir)" >&2
    exit 1
fi

PHOTON_LIBS="$PHOTON_BUILD/output/libphoton.a \
    $PHOTON_BUILD/openssl-build/lib/libssl.a \
    $PHOTON_BUILD/openssl-build/lib/libcrypto.a \
    $PHOTON_BUILD/aio-build/lib/libaio.a"
if [ -f "$PHOTON_BUILD/uring-build/lib/liburing.a" ]; then
    PHOTON_LIBS="$PHOTON_LIBS $PHOTON_BUILD/uring-build/lib/liburing.a"
fi

for f in queue_ping_pong; do
    g++ -std=c++20 -O3 -I"$ASIO/asio/include" -o ${f}_asio $f.cpp -lpthread
done
g++ -std=c++20 -O3 -I"$ASIO/asio/include" -o tcp_server_asio tcp_server_asio.cpp -lpthread
g++ -std=c++20 -O3 -I"$ASIO/asio/include" -o sleep_asio sleep_asio.cpp -lpthread
g++ -std=c++20 -O3 -I"$ASIO/asio/include" -o worker_pool_asio worker_pool_asio.cpp -lpthread

for f in queue_ping_pong_photon tcp_server_photon worker_pool_photon sleep_photon; do
    g++ -std=c++17 -O3 -I"$PHOTON/include" -o $f $f.cpp $PHOTON_LIBS -lpthread -ldl -lz
done
