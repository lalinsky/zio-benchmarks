Build:

```
zig build --release=safe
```

Run one benchmark:

```
hyperfine \
    './zig-out/bin/tcp_ping_pong --zio' \
    './zig-out/bin/tcp_ping_pong --threaded' \
    './zig-out/bin/tcp_ping_pong_go'
```

