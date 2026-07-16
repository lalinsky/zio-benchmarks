# zio benchmarks

Cross-runtime benchmarks for [zio](https://github.com/lalinsky/zio), with
counterparts for Go, tokio, Asio and PhotonLibOS where it makes sense.

zio always appears as separate engines: `--zio` (single-threaded) and
`--zio-mt` (multi-threaded) are different schedulers with different
trade-offs, and most benchmarks also exist in two API flavors — via `std.Io`
(comparable with `--threaded`, i.e. `std.Io.Threaded`) and via zio's native
API (`*_native`).

## Building

```
zig build -Doptimize=ReleaseFast               # zig binaries
zig build -Doptimize=ReleaseFast -Dbench=NAME  # just one benchmark
./build_go.sh                                  # go counterparts
(cd rust && cargo build --release)             # tokio counterparts
(cd cpp && ./setup-asio.sh && ./setup-photon.sh && ./build.sh)   # asio + photon, see cpp/README.md
```

Plain `zig build` produces Debug binaries — never benchmark those.

## Golden benchmarks

The in-process set is run by `./bench.py` (below); TCP is separate (a driver
process — see "TCP benchmarks"). Every benchmark runs across the same engines
and reports one result column per case.

### Engines

Each runtime appears as single- and multi-threaded rows; `bench.py` groups them
into a single-threaded and a multi-threaded table.

| engine | runtime |
|---|---|
| `zio-st-stdio`, `zio-mt-stdio` | zio via `std.Io` (comparable with `--threaded`) |
| `zio-st-native`, `zio-mt-native` | zio's native API |
| `tokio-st`, `tokio-mt` | tokio `current_thread` / `multi_thread` |
| `asio-st`, `asio-mt` | Asio `thread_pool` sized 1 / `hardware_concurrency` |
| `go-st`, `go-mt` | Go with `GOMAXPROCS=1` / default |
| `photon` | PhotonLibOS — single-vcpu only, so no multi-threaded row |

### Benchmarks and cases

| benchmark | case | what it measures |
|---|---|---|
| **queue_ping_pong** | `1 pair` | one two-task wake-latency chain, a single message in flight |
| | `100 pairs` | 100 independent chains sharing the same total messages — scheduling many concurrent wake-chains (parallelizes on mt) |
| **worker_pool** | `fan_in` | 1000 producers → 1 consumer, 100k tiny items — many-to-one queue + wakeups |
| | `fan_out` | 1 producer → 1000 consumers, 100k tiny items — one-to-many queue + scheduling |
| | `fan_in-cpu` | fan-in with 10k heavy items (`--work=10000`) — serial consumer compute |
| | `fan_out-cpu` | fan-out with 10k heavy items — parallel consumer compute (mt should scale) |
| **sleep** | `spawn (0ms)` | 10k no-op tasks — pure spawn/teardown throughput |
| | `sleep (10ms)` | 10k tasks kept alive 10 ms — spawn + liveness + timer pressure |
| **tcp** — echo | `lat` / `many` / `pipe` | 1-conn round-trip latency / 1000-conn spread / 64-conn pipelined echo throughput |
| **tcp** — sink/source | `send1`,`send8` / `recv1`,`recv8` | bulk one-way throughput over 1 / 8 connections |

Notes on comparability: **queue_ping_pong** splits a fixed total of 100k
messages across `--pairs`, so `1 pair` and `100 pairs` do equal total work. The
`-cpu` **worker_pool** cases use fewer but heavier items (same total hashing) so
per-item compute — not queue speed — dominates; an order-independent xor
checksum verifies every runtime agrees on the work done. **sleep** tasks bump a
shared atomic counter the driver checks against `--tasks`.

### Running

```
./bench.py --bench all                    # every benchmark, both tables
./bench.py --bench worker_pool --build    # rebuild that benchmark's binaries first
./bench.py --bench sleep --rounds 11      # more rounds
./bench.py --bench queue_ping_pong --no-photon --no-asio   # skip runtimes
```

`bench.py` interleaves the cells across `--rounds` and reports the median in ms,
split into single- and multi-threaded tables (engines with no counterpart in a
mode, e.g. photon, render struck-out). `--quiet` prints tables only; running it
with no arguments prints help.

## TCP benchmarks

TCP is measured with a separate driver process (`driver/tcp_driver.go`, Go, one
goroutine per connection over the netpoller) so the runtime under test is only
ever the server side. The Go driver multiplexes thousands of connections over a
few OS threads, so it stays out of the way at high connection counts — a
thread-per-connection driver becomes the bottleneck there and flatters or
distorts the comparison.

Per-runtime servers (`tcp_server` / `tcp_server_native`, `go/tcp_server`,
`rust/src/bin/tcp_server.rs`, `cpp/tcp_server_{asio,photon}.cpp`) implement
three modes: `echo` (write back whatever arrives), `sink` (read and discard),
`source` (write until the client closes). zio's event-loop backend is a
compile-time choice, so io_uring and epoll are separate binaries and appear as
separate rows (native API).

`./bench.py --bench tcp` runs the matrix (one server start per mode, the driver
run per scenario) and reports throughput, higher-is-better:

- `echo` — `lat` (1 conn × 4KB, latency chain), `many` (1000 conns × 64B,
  concurrency), `pipe` (64 conns pipelined ×16, message throughput) → msgs/s
- `send` — driver streams to a sink server over 1 / 8 conns (server read
  path) → GB/s
- `recv` — driver drains a source server over 1 / 8 conns (server write
  path) → GB/s

## Secondary benchmarks

With a Go counterpart (`./run.sh NAME` compares all backends): `cpu_parallel`.

Zig-only (run directly with `--zio` / `--zio-mt`):

- `queue_ping_pong_native`, `worker_pool_native`, `sleep_native` — native-API golden variants
- `queue_ping_pong_futex` — channel built directly on `std.Io` futex
  primitives (also `--threaded`)
- `task_chain` — chain of tasks, each spawning the next: spawn/teardown path
- `spawn_tree` — balanced binary spawn tree with parents awaiting children
- `fanout_cpu` — single producer feeding CPU-heavy consumers: work stealing
- `yield_bench` — two tasks yielding in a loop (scheduler switch cost);
  `--solo` for the empty-queue yield fast path
- `mutex_bench_native`, `condition_bench_native`, `rwlock_bench_native` —
  sync primitive microbenchmarks

xsync variants (`*_xsync`, `mutex_bench`, `condition_bench`) swap the
`std.Io`-based primitives for [xsync](https://github.com/lalinsky/xsync.zig)
ones.

## Methodology notes

- Interleave A/B runs (alternate binaries within a round) rather than
  batching; report medians over several rounds.
- When comparing scheduler changes in zio, build each variant into its own
  binary set, and check the baseline checkout is actually current.
- `worker_pool` checksums must match across all runtimes and configurations;
  a mismatch means a broken implementation, not noise.
