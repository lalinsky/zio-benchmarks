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
zig build -Doptimize=ReleaseFast               # zig + go binaries
zig build -Doptimize=ReleaseFast -Dbench=NAME  # just one benchmark
(cd rust && cargo build --release)             # tokio counterparts
(cd cpp && ./build.sh <asio> <photon>)         # asio + photon, see cpp/README.md
```

Plain `zig build` produces Debug binaries — never benchmark those.

## Golden benchmarks

The primary set, each with go / tokio / photon / zio-std.Io / zio-native
implementations and stable parameters:

- **tcp** — see "TCP benchmarks" below; driver/server split across processes
- **queue_ping_pong** — 100k messages bounced between two tasks over two
  capacity-1 queues: the wake-latency chain
- **worker_pool** — `--num-producers` push `--num-items` into one shared queue
  drained by `--num-consumers` doing `--work` hash iterations per item; an
  order-independent checksum verifies all runtimes agree. Presets: defaults
  (1 → 1000 fan-out), `--num-producers=1000 --num-consumers=1 --work=0`
  (fan-in)
- **short_sleep** — 10k concurrent 1ms sleeps: spawn storm + timer pressure

`./golden.sh` runs the in-process golden set interleaved across every runtime
that is built (`N=5 ./golden.sh` for more rounds).

## TCP benchmarks

TCP is measured with a separate driver process (`driver/tcp_driver.c`, plain
C, one blocking thread per connection) so the runtime under test is only ever
the server side, and in-process task placement can't skew the comparison.
Driver and server are pinned to disjoint core sets.

Per-runtime servers (`tcp_server` / `tcp_server_native`, `go/tcp_server`,
`rust/src/bin/tcp_server.rs`, `cpp/tcp_server_{asio,photon}.cpp`) implement
three modes: `echo` (write back whatever arrives), `sink` (read and discard),
`source` (write until the client closes).

`./tcp_bench.sh` runs the full matrix:

- `echo` — 1 conn × 4KB (latency chain), 1000 conns × 64B (concurrency),
  64 conns pipelined ×16 (message throughput)
- `send` — driver streams to a sink server, 1 and 8 connections (server read
  path, GB/s)
- `recv` — driver drains a source server, 1 and 8 connections (server write
  path, GB/s)

## Secondary benchmarks

With Go counterparts (`./run.sh NAME` compares all backends):
`hostname_lookup`, `short_sleep`, `long_sleep`, `cpu_parallel`.

Zig-only (run directly with `--zio` / `--zio-mt`):

- `queue_ping_pong_native`, `worker_pool_native` — native-API golden variants
- `queue_ping_pong_futex` — channel built directly on `std.Io` futex
  primitives (also `--threaded`)
- `task_chain` — chain of tasks, each spawning the next: spawn/teardown path
- `spawn_tree` — balanced binary spawn tree with parents awaiting children
- `fanout_cpu` — single producer feeding CPU-heavy consumers: work stealing
- `yield_bench` — two tasks yielding in a loop (scheduler switch cost);
  `--solo` for the empty-queue yield fast path
- `spawn_bench` — 100k no-op task spawns
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
