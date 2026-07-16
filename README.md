# zio benchmarks

Cross-runtime benchmarks for [zio](https://github.com/lalinsky/zio), with Go,
tokio, Asio and PhotonLibOS counterparts wherever a comparison makes sense.

zio shows up as two separate engines. `--zio` is single-threaded and `--zio-mt`
is multi-threaded; they're different schedulers with different trade-offs, so I
keep them apart. Most benchmarks also come in two API flavors: one through
`std.Io` (which lines up with `--threaded`, i.e. `std.Io.Threaded`) and one
through zio's native API (`*_native`).

## Benchmark results

Measured on a bare-metal **Intel Xeon E-2176G** (6 cores / 12 threads,
3.7–4.7 GHz, 12 MiB L3, 62 GiB RAM), Ubuntu 24.04, kernel 6.8, glibc 2.39,
`performance` governor. Numbers are the median **±stdev** over 9 interleaved
rounds (`./bench.py --bench all --rounds 9`). Lower is better for the millisecond
benchmarks, higher for tcp. See [Golden benchmarks](#golden-benchmarks) for what
the engines and cases mean.

### sleep — spawn/teardown and timer pressure

`spawn` (0ms) is pure spawn/teardown: tasks finish immediately, so their stacks
free up and get reused right away. That plays to zio's strengths. Clearing a
finished task and reusing its stack on one executor is cheaper than migrating it,
so the single-threaded run (~2 ms) actually beats the multi-threaded
work-stealing path.

`sleep` (10ms) keeps all 10k tasks alive at once, so nothing gets recycled. Every
task needs its own live stack, and zio `mmap`s each one separately, which is
where the time goes. Preallocating stacks in bulk up front (planned, and handy
for server workloads too) should close the gap.

Single-threaded (ms):

| engine | spawn (0ms) | sleep (10ms) |
|---|---|---|
| zio-st-stdio | 2.09 ±0.17 | 53.76 ±1.86 |
| zio-st-native | 2.00 ±0.15 | 54.80 ±1.24 |
| tokio-st | 4.57 ±0.37 | 17.36 ±1.33 |
| asio-st | 10.10 ±1.37 | 17.44 ±1.21 |
| go-st | 16.10 ±0.53 | 28.61 ±1.21 |
| photon | 89.68 ±4.04 | 100.22 ±3.47 |

Multi-threaded (ms):

| engine | spawn (0ms) | sleep (10ms) |
|---|---|---|
| zio-mt-stdio | 17.86 ±1.10 | 62.96 ±1.98 |
| zio-mt-native | 18.29 ±1.11 | 61.41 ±3.19 |
| tokio-mt | 5.88 ±0.94 | 16.83 ±0.47 |
| asio-mt | 27.30 ±1.15 | 52.11 ±0.75 |
| go-mt | 2.81 ±0.14 | 25.09 ±0.46 |
| ~~photon~~ | — | — |

### queue_ping_pong — wake-latency chains

`1 pair` is a single two-task chain with one message in flight, so it measures
pure wake latency and context-switch cost. `100 pairs` runs 100 chains at once
over the same total number of messages, which adds the cost of scheduling many
wake chains (and gives `-mt` something to parallelize).

zio does well on both. The stackful coroutines context-switch tightly and
there's very little scheduler overhead on top. The split also shows how much the
channel implementation matters once the runtime itself is fast: zio's native
`Channel` is roughly 2× faster than the generic `std.Io.Queue` (`*-native` vs
`*-stdio`). That gap vanishes under `std.Io.Threaded`, where thread wake time
swamps everything else.

Single-threaded (ms):

| engine | 1 pair | 100 pairs |
|---|---|---|
| zio-st-stdio | 14.13 ±0.23 | 19.36 ±0.29 |
| zio-st-native | 7.56 ±0.70 | 10.63 ±0.39 |
| tokio-st | 17.37 ±1.49 | 17.05 ±0.44 |
| asio-st | 52.40 ±2.80 | 58.03 ±2.73 |
| go-st | 19.35 ±0.64 | 19.18 ±0.73 |
| photon | 410.12 ±12.60 | 23.48 ±3.36 |

Multi-threaded (ms):

| engine | 1 pair | 100 pairs |
|---|---|---|
| zio-mt-stdio | 26.96 ±0.63 | 2.76 ±0.32 |
| zio-mt-native | 13.22 ±0.28 | 1.69 ±0.07 |
| tokio-mt | 27.28 ±1.98 | 2.15 ±0.15 |
| asio-mt | 580.97 ±12.56 | 116.47 ±0.63 |
| go-mt | 17.16 ±1.31 | 3.43 ±0.23 |
| ~~photon~~ | — | — |

### worker_pool — one shared queue

Producers push items through one shared queue to consumers, each doing a bit of
work per item. An order-independent checksum confirms every runtime processed the
same set. `fan_in` is 1000 producers → 1 consumer, `fan_out` is 1 → 1000. The
light variants push many tiny items so the queue and scheduling dominate; the
`-cpu` variants use fewer, heavier items so per-item compute dominates instead.

Single-threaded (ms):

| engine | fan_in | fan_out | fan_in-cpu | fan_out-cpu |
|---|---|---|---|---|
| zio-st-stdio | 3.93 ±0.22 | 16.61 ±0.48 | 94.42 ±0.64 | 101.89 ±1.67 |
| zio-st-native | 3.83 ±0.06 | 13.09 ±0.78 | 94.78 ±1.01 | 101.55 ±1.09 |
| tokio-st | 26.20 ±5.09 | 27.54 ±5.38 | 95.70 ±1.40 | 96.94 ±1.40 |
| asio-st | 53.39 ±1.97 | 53.52 ±4.34 | 100.81 ±1.06 | 102.75 ±1.70 |
| go-st | 6.51 ±0.82 | 5.79 ±0.11 | 96.58 ±2.12 | 95.51 ±7.44 |
| photon | 32.88 ±2.39 | 47.41 ±5.62 | 105.64 ±1.44 | 107.82 ±1.95 |

Multi-threaded (ms):

| engine | fan_in | fan_out | fan_in-cpu | fan_out-cpu |
|---|---|---|---|---|
| zio-mt-stdio | 67.18 ±2.37 | 68.65 ±1.04 | 106.32 ±3.16 | 19.12 ±0.86 |
| zio-mt-native | 38.98 ±2.11 | 47.44 ±1.17 | 106.01 ±2.81 | 18.62 ±0.47 |
| tokio-mt | 113.17 ±11.70 | 116.50 ±8.81 | 106.49 ±1.35 | 16.18 ±0.79 |
| asio-mt | 608.94 ±25.66 | 604.01 ±21.92 | 146.69 ±0.45 | 75.92 ±3.10 |
| go-mt | 38.22 ±0.72 | 38.83 ±0.58 | 98.05 ±5.51 | 14.11 ±0.84 |
| ~~photon~~ | — | — | — | — |

### tcp — server under test

The server under test is driven by the Go load driver over loopback, with no core
pinning. `echo` bounces messages back: `lat` (1 conn, round-trip), `many`
(1000 conns), `pipe` (64 conns, 16 in flight). `send`/`recv` stream bulk data to
a sink or from a source over 1 or 8 connections. The throughput scenarios
(`many`, `pipe`, `send8`, `recv8`) get faster with more threads since the
connections spread across cores; the single-connection latency scenarios (`lat`,
`send1`, `recv1`) don't.

echo (msgs/s):

| engine | lat | many | pipe |
|---|---|---|---|
| zio-uring-st | 43k ±1k | 127k ±2k | 818k ±10k |
| zio-uring-mt | 44k ±1k | 425k ±23k | 773k ±29k |
| zio-epoll-st | 43k ±1k | 103k ±3k | 520k ±11k |
| zio-epoll-mt | 42k ±1k | 378k ±14k | 696k ±21k |
| go | 41k ±1k | 393k ±13k | 668k ±18k |
| tokio | 43k ±1k | 421k ±21k | 940k ±49k |
| asio | 35k ±1k | 373k ±14k | 846k ±17k |
| photon | 44k ±1k | 84k ±3k | 691k ±5k |
| photon-uring | 44k ±1k | 107k ±3k | 733k ±6k |

bulk transfer (GB/s):

| engine | send1 | send8 | recv1 | recv8 |
|---|---|---|---|---|
| zio-uring-st | 4.32 ±0.13 | 5.78 ±0.08 | 3.94 ±0.06 | 4.25 ±0.10 |
| zio-uring-mt | 4.38 ±0.07 | 14.17 ±0.22 | 3.80 ±0.09 | 16.13 ±0.34 |
| zio-epoll-st | 4.32 ±0.08 | 5.79 ±0.10 | 4.03 ±0.06 | 4.06 ±0.09 |
| zio-epoll-mt | 4.23 ±0.11 | 17.64 ±1.69 | 4.02 ±0.06 | 16.53 ±0.50 |
| go | 4.33 ±0.10 | 15.15 ±0.51 | 4.40 ±0.08 | 15.05 ±0.49 |
| tokio | 4.30 ±0.09 | 16.65 ±0.96 | 4.05 ±0.05 | 17.12 ±0.81 |
| asio | 3.73 ±0.21 | 13.34 ±0.27 | 3.67 ±0.06 | 14.81 ±0.35 |
| photon | 4.37 ±0.07 | 7.75 ±0.33 | 4.09 ±0.08 | 4.07 ±0.10 |
| photon-uring | 4.38 ±0.06 | 7.57 ±0.37 | 4.08 ±0.09 | 4.09 ±0.04 |

## Building

```
zig build -Doptimize=ReleaseFast               # zig binaries
zig build -Doptimize=ReleaseFast -Dbench=NAME  # just one benchmark
./build_go.sh                                  # go counterparts
(cd rust && cargo build --release)             # tokio counterparts
(cd cpp && ./setup-asio.sh && ./setup-photon.sh && ./build.sh)   # asio + photon, see cpp/README.md
```

Plain `zig build` produces Debug binaries. Don't benchmark those.

## Golden benchmarks

The in-process set is run by `./bench.py` (below). TCP is separate, since it needs
a driver process (see "TCP benchmarks"). Every benchmark runs across the same
engines and reports one result column per case.

### Engines

Each runtime appears as single- and multi-threaded rows, which `bench.py` groups
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

A few notes on keeping the cases comparable. **queue_ping_pong** splits a fixed
total of 100k messages across `--pairs`, so `1 pair` and `100 pairs` do the same
total work. The `-cpu` **worker_pool** cases use fewer but heavier items (same
total hashing) so per-item compute dominates instead of queue speed, and an
order-independent xor checksum verifies every runtime agrees on the work done.
**sleep** tasks bump a shared atomic counter that the driver checks against
`--tasks`.

### Running

```
./bench.py --bench all                    # every benchmark, both tables
./bench.py --bench worker_pool --build    # rebuild that benchmark's binaries first
./bench.py --bench sleep --rounds 11      # more rounds
./bench.py --bench queue_ping_pong --no-photon --no-asio   # skip runtimes
```

`bench.py` interleaves the cells across `--rounds` and reports the median in ms,
split into single- and multi-threaded tables (engines with no counterpart in a
mode, like photon, are struck out). `--quiet` prints tables only, and running it
with no arguments prints help.

## TCP benchmarks

TCP is measured with a separate driver process (`driver/tcp_driver.go`, Go, one
goroutine per connection over the netpoller) so the runtime under test is only
ever the server side. The Go driver multiplexes thousands of connections over a
handful of OS threads, so it stays out of the way at high connection counts. A
thread-per-connection driver would become the bottleneck instead and distort the
comparison.

Each runtime has its own server (`tcp_server` / `tcp_server_native`,
`go/tcp_server`, `rust/src/bin/tcp_server.rs`, `cpp/tcp_server_{asio,photon}.cpp`)
implementing three modes: `echo` (write back whatever arrives), `sink` (read and
discard), `source` (write until the client closes). zio picks its event-loop
backend at compile time, so io_uring and epoll are separate binaries and show up
as separate rows (native API).

`./bench.py --bench tcp` runs the matrix (one server start per mode, then the
driver once per scenario) and reports throughput, higher is better:

- `echo` — `lat` (1 conn × 4KB, latency chain), `many` (1000 conns × 64B,
  concurrency), `pipe` (64 conns pipelined ×16, message throughput) → msgs/s
- `send` — driver streams into a sink server over 1 / 8 conns, exercising the
  server read path → GB/s
- `recv` — driver drains a source server over 1 / 8 conns, exercising the
  server write path → GB/s

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
