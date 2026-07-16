#!/usr/bin/env bash
# Provision a fresh Ubuntu 24.04 VM to build and run the zio-benchmarks suite.
#
# Run as root on a clean box. Idempotent — safe to re-run. Installs Zig, Go,
# Rust, wrk, and the C++ (asio/photon) build deps, clones zio + zio-benchmarks
# as siblings (the benchmarks reference ../zio by path), and builds everything.
#
#   curl -fsSL <this> | bash            # or: scp it over, then: bash provision-ubuntu.sh
#
# Override anything via env, e.g.:
#   ZIG_VERSION=0.16.0 GO_VERSION=1.23.4 WORKDIR=/root/projects DO_CPP=0 bash provision-ubuntu.sh
set -euo pipefail

# ---- config -----------------------------------------------------------------
ZIG_VERSION=${ZIG_VERSION:-0.16.0}
GO_VERSION=${GO_VERSION:-$(curl -fsSL "https://go.dev/VERSION?m=text" 2>/dev/null | head -1 | sed 's/^go//' || true)}
GO_VERSION=${GO_VERSION:-1.23.4}
WORKDIR=${WORKDIR:-/root/projects}
REPO_ZIO=${REPO_ZIO:-https://github.com/lalinsky/zio}
REPO_BENCH=${REPO_BENCH:-https://github.com/lalinsky/zio-benchmarks}
DO_CLONE=${DO_CLONE:-1}     # clone the repos (skip if you rsync them yourself)
DO_BUILD=${DO_BUILD:-1}     # build all benchmark binaries
DO_CPP=${DO_CPP:-1}         # also build asio + photon (heavy; optional)
DO_TUNE=${DO_TUNE:-1}       # best-effort perf governor + sysctls

case "$(uname -m)" in
  x86_64)  ZIG_ARCH=x86_64;  GO_ARCH=amd64 ;;
  aarch64) ZIG_ARCH=aarch64; GO_ARCH=arm64 ;;
  *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
esac

log() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

# ---- 1. system packages -----------------------------------------------------
log "apt packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
# build-essential/cmake/perl/zlib: C++ (asio/photon, which builds its own
# openssl/libaio/liburing). xz-utils: zig tarball. python3: bench.py.
apt-get install -y --no-install-recommends \
    build-essential cmake pkg-config git curl wget ca-certificates \
    xz-utils unzip perl zlib1g-dev libssl-dev python3

# ---- 2. wrk (apt from universe; fall back to building from source) ----------
if ! command -v wrk >/dev/null; then
    log "wrk"
    if ! apt-get install -y wrk 2>/dev/null; then
        echo "apt wrk unavailable; building from source"
        tmp=$(mktemp -d); git clone --depth 1 https://github.com/wg/wrk "$tmp/wrk"
        make -C "$tmp/wrk" -j"$(nproc)"; install -m755 "$tmp/wrk/wrk" /usr/local/bin/wrk
        rm -rf "$tmp"
    fi
fi
wrk --version 2>&1 | head -1 || true

# ---- 3. Zig -----------------------------------------------------------------
if [ "$(zig version 2>/dev/null || true)" != "$ZIG_VERSION" ]; then
    log "zig $ZIG_VERSION"
    tarball="zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz"
    url="https://ziglang.org/download/${ZIG_VERSION}/${tarball}"
    curl -fSL -o "/tmp/${tarball}" "$url"
    rm -rf "/opt/zig-${ZIG_VERSION}"; mkdir -p "/opt/zig-${ZIG_VERSION}"
    tar -xJf "/tmp/${tarball}" -C "/opt/zig-${ZIG_VERSION}" --strip-components=1
    ln -sf "/opt/zig-${ZIG_VERSION}/zig" /usr/local/bin/zig
fi
zig version

# ---- 4. Go ------------------------------------------------------------------
if [ "$(go version 2>/dev/null | awk '{print $3}' || true)" != "go${GO_VERSION}" ]; then
    log "go $GO_VERSION"
    tarball="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
    curl -fSL -o "/tmp/${tarball}" "https://go.dev/dl/${tarball}"
    rm -rf /usr/local/go; tar -C /usr/local -xzf "/tmp/${tarball}"
    ln -sf /usr/local/go/bin/go /usr/local/bin/go
    ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
fi
go version

# ---- 5. Rust (rustup, stable) ----------------------------------------------
if ! command -v cargo >/dev/null && [ ! -x "$HOME/.cargo/bin/cargo" ]; then
    log "rust (rustup)"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --profile minimal --no-modify-path
fi
export PATH="$HOME/.cargo/bin:$PATH"
grep -q '.cargo/bin' "$HOME/.bashrc" 2>/dev/null || \
    echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> "$HOME/.bashrc"
cargo --version

# ---- 6. clone repos (siblings: zio-benchmarks references ../zio) ------------
if [ "$DO_CLONE" = 1 ]; then
    log "repos -> $WORKDIR"
    mkdir -p "$WORKDIR"
    [ -d "$WORKDIR/zio/.git" ]            || git clone "$REPO_ZIO"   "$WORKDIR/zio"
    [ -d "$WORKDIR/zio-benchmarks/.git" ] || git clone "$REPO_BENCH" "$WORKDIR/zio-benchmarks"
fi
BENCH="$WORKDIR/zio-benchmarks"
[ -d "$BENCH" ] || { echo "no $BENCH — set DO_CLONE=1 or rsync the repos first" >&2; exit 1; }

# ---- 7. build ---------------------------------------------------------------
if [ "$DO_BUILD" = 1 ]; then
    cd "$BENCH"

    log "zig benchmarks (ReleaseFast)"
    for b in sleep sleep_native queue_ping_pong queue_ping_pong_native \
             worker_pool worker_pool_native tcp_server; do
        zig build -Doptimize=ReleaseFast -Dbench="$b"
    done
    # zio's event loop is a compile-time choice -> one binary per backend
    zig build -Doptimize=ReleaseFast -Dbench=tcp_server_native -Dbackend=io_uring
    zig build -Doptimize=ReleaseFast -Dbench=tcp_server_native -Dbackend=epoll

    log "go counterparts + tcp driver"
    ./build_go.sh
    go build -o driver/tcp_driver driver/tcp_driver.go

    log "rust (tokio)"
    ( cd rust && cargo build --release )

    if [ "$DO_CPP" = 1 ]; then
        log "cpp: asio + photon (heavy — builds its own openssl/libaio/liburing)"
        ( cd cpp && ./setup-asio.sh && ./setup-photon.sh && ./build.sh ) \
            || echo "WARN: cpp (asio/photon) failed — the suite still runs without it (use --no-asio --no-photon)"
    fi
fi

# ---- 8. best-effort benchmark tuning ---------------------------------------
if [ "$DO_TUNE" = 1 ]; then
    log "tuning (best-effort)"
    # performance governor
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -w "$g" ] && echo performance > "$g" 2>/dev/null || true
    done
    # headroom for the http/tcp benchmarks (many connections)
    sysctl -w net.core.somaxconn=65535 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_max_syn_backlog=65535 >/dev/null 2>&1 || true
    grep -q 'zio-bench nofile' /etc/security/limits.conf 2>/dev/null || \
        printf '* soft nofile 1048576\n* hard nofile 1048576\n# zio-bench nofile\n' >> /etc/security/limits.conf || true
fi

# ---- done -------------------------------------------------------------------
log "done"
cat <<EOF
Toolchains: $(zig version) | $(go version | awk '{print $3}') | $(cargo --version | awk '{print $2}') | wrk $(wrk --version 2>&1 | awk 'NR==1{print $2}')
Repos:      $WORKDIR/zio  +  $BENCH

Run the suite:
  cd $BENCH
  ./bench.py --bench all --rounds 9              # everything (median of 9)
  ./bench.py --bench http --rounds 9             # just the HTTP benchmark
  ./bench.py --bench tcp --no-asio --no-photon   # skip C++ if it didn't build
EOF
