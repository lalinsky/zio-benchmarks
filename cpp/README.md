# C++ benchmark counterparts (Asio, PhotonLibOS)

These are not built by `zig build`, and the two libraries are **not vendored**.
Prepare each one into `cpp/libs/` (git-ignored) with its setup script, then
build the benchmarks:

```sh
./setup-asio.sh      # downloads standalone Asio  -> libs/asio
./setup-photon.sh    # clones + builds PhotonLibOS -> libs/photon
./build.sh           # builds the *_asio and *_photon binaries
```

Run the setup scripts once; re-running is cheap (asio is skipped if already
present). Both scripts and `build.sh` are directory-independent — they operate
relative to `cpp/`.

## Asio (standalone, header-only)

`./setup-asio.sh` downloads a pinned release and unpacks the headers to
`libs/asio/asio/include`. Pin a different version with:

```sh
ASIO_VERSION=1-38-1 ./setup-asio.sh
```

## PhotonLibOS

`./setup-photon.sh` clones PhotonLibOS to `libs/photon` and builds it (Release,
`PHOTON_BUILD_DEPENDENCIES=ON`, so it compiles its own OpenSSL/libaio/liburing).
Needs `cmake` and a C++ toolchain; `--uring` needs kernel >= 5.8 at runtime.
Pin a ref (tag/branch/commit) with:

```sh
PHOTON_REF=<tag> ./setup-photon.sh
```

## Building

`./build.sh` reads the deps from `libs/` by default; pass explicit paths to
override:

```sh
./build.sh /path/to/asio-dir /path/to/photon-dir
```

Photon benches run everything on a single vcpu — its intended shared-nothing
configuration; cross-vcpu synchronization is its slow path and would dominate
otherwise. The photon TCP server takes `--uring` to use the io_uring event
engine instead of epoll.
