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
