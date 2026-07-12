Build:

```
zig build --release=safe
```

Run one benchmark:

```
./run.sh tcp_ping_pong
```

This compares `--zio` (single-threaded), `--zio-mt` (multi-threaded), `--threaded` (std.Io.Threaded), and the Go equivalent.

Available benchmarks:

- `hostname_lookup` — 10,000 repeated DNS lookups of `example.com`, max 1,000 in-flight
- `short_sleep` — 10,000 concurrent 1ms sleeps
- `long_sleep` — 10,000 concurrent 1s sleeps
- `queue_ping_pong` — 100,000 messages ping-ponged between two tasks over an in-process queue/channel
- `tcp_ping_pong` — 100,000 messages ping-ponged between two tasks over a loopback TCP connection
- `tcp_echo` — many-connection echo throughput: thousands of concurrent loopback connections doing request/response round-trips
- `queue_fan_in` — 1,000 producers pushing 100 items each into one queue drained by a single consumer (channel contention)
- `cpu_parallel` — CPU-bound parallel reduction split into one task per chunk, no I/O (raw parallel compute throughput)

Zig-only benchmarks (no Go counterpart, so `run.sh` doesn't apply; run the binaries directly with `--zio` / `--zio-mt`):

- `queue_ping_pong_native` — `queue_ping_pong` over zio's native `Channel(u64)` instead of the generic `std.Io.Queue` (zio backends only)
- `queue_ping_pong_futex` — `queue_ping_pong` over a channel built directly on the `std.Io` futex primitives, skipping `std.Io.Condition` (also runs with `--threaded`)
- `task_chain` — chain of tasks, each spawning the next: per-task spawn/schedule/teardown throughput
- `spawn_tree` — balanced binary spawn tree with parents awaiting children: fan-out/join (spawn + suspend + wake) path
- `fanout_cpu` — single producer feeding CPU-heavy consumers over a single-slot channel: work-stealing acceptance test
- `zio_echo_server` — standalone multithreaded zio TCP echo server for cross-runtime comparisons (e.g. against tardy)
