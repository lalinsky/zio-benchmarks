# C++ benchmark counterparts (Asio, PhotonLibOS)

These are not built by `zig build`; they need the two libraries fetched and
built once, then `./build.sh <asio-dir> <photon-dir>`.

## Asio (standalone, header-only)

```sh
curl -LO https://github.com/chriskohlhoff/asio/archive/refs/tags/asio-1-30-2.tar.gz
tar xf asio-1-30-2.tar.gz
# headers in asio-asio-1-30-2/asio/include
```

## PhotonLibOS

Requires `liburing-dev` at runtime kernel >= 5.8 for `--uring`; the vendored
build also compiles its own OpenSSL/libaio/liburing.

```sh
git clone https://github.com/alibaba/PhotonLibOS photon
cd photon
cmake -B build -D CMAKE_BUILD_TYPE=Release -D PHOTON_BUILD_TESTING=OFF \
      -D PHOTON_ENABLE_LIBCURL=OFF -D PHOTON_ENABLE_URING=ON \
      -D PHOTON_BUILD_DEPENDENCIES=ON \
      -D CMAKE_CXX_FLAGS="-Wno-error=unused-value"
cmake --build build -j$(nproc)
```

## Building the benchmarks

```sh
./build.sh /path/to/asio-asio-1-30-2 /path/to/photon
```

Photon benches run everything on a single vcpu — its intended shared-nothing
configuration; cross-vcpu synchronization is its slow path and would dominate
otherwise. `tcp_echo_photon` takes `--uring` to use the io_uring event engine
instead of epoll.
