#!/usr/bin/env python3
"""Run the cross-runtime benchmark matrix and print the results as markdown.

Each benchmark is timed over --rounds runs (interleaved across runtimes) and the
median wall time in ms is reported, split into single-threaded and multi-threaded
tables.

Build the binaries first:
    zig build -Doptimize=ReleaseFast
    ./build_go.sh
    (cd rust && cargo build --release)
    (cd cpp && ./setup-asio.sh && ./setup-photon.sh && ./build.sh)

Examples (no arguments prints this help):
    ./bench.py --bench all                             # every benchmark
    ./bench.py --bench sleep --rounds 11               # one benchmark, more rounds
    ./bench.py --bench worker_pool --build             # rebuild its binaries first
    ./bench.py --bench worker_pool --quiet > out.md    # tables only, no progress
"""
import argparse
import os
import re
import statistics
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
B = os.path.join(ROOT, "zig-out", "bin")       # zig + go binaries
R = os.path.join(ROOT, "rust", "target", "release")
CPP = os.path.join(ROOT, "cpp")

UNIT_MS = {"s": 1e3, "ms": 1.0, "us": 1e-3, "µs": 1e-3, "ns": 1e-6}
_DUR = re.compile(r"Duration:\s*([0-9.]+)\s*(µs|us|ns|ms|s)\b")
_THRU = re.compile(r"([0-9.]+)\s*(msgs/s|GB/s)")
_ANSI = re.compile(r"\x1b\[[0-9;]*m")


def parse_ms(text):
    m = _DUR.search(_ANSI.sub("", text))
    return float(m.group(1)) * UNIT_MS[m.group(2)] if m else None


class Engine:
    """One runtime/mode row. `dash` is the flag prefix ('-' for go).

    `solo` marks an engine that exists only in its mode (e.g. photon is
    single-vcpu only); it is shown struck-out in the other mode's table so the
    matrix stays complete.
    """

    def __init__(self, label, mode, argv, env=None, dash="--", solo=False):
        self.label = label
        self.mode = mode  # 'st' or 'mt'
        self.argv = argv
        self.env = env or {}
        self.dash = dash
        self.solo = solo

    @property
    def bin(self):
        return self.argv[0]

    def command(self, params):
        argv = list(self.argv)
        for key, val in params.items():
            argv.append(f"{self.dash}{key}={val}")
        return argv


def build_command(engine):
    """Shell command (run from repo root) that rebuilds this engine's binary,
    derived from its path. cpp goes through cpp/build.sh (rebuilds all C++)."""
    b = engine.bin
    base = os.path.basename(b)
    if b.startswith(B):  # zig-out/bin: zig benches, plus go's *_go
        if base.endswith("_go"):
            return f"cd go && go build -o ../zig-out/bin/{base} ./{base[:-3]}"
        # backend-tagged zig binary, e.g. tcp_server_native_epoll
        for be in ("io_uring", "epoll", "poll"):
            if base.endswith("_" + be):
                bench = base[: -(len(be) + 1)]
                return f"zig build -Doptimize=ReleaseFast -Dbench={bench} -Dbackend={be}"
        return f"zig build -Doptimize=ReleaseFast -Dbench={base}"
    if b.startswith(R):
        return f"cd rust && cargo build --release --bin {base}"
    if b.startswith(CPP):
        return "cd cpp && ./build.sh"
    return None


def run_builds(engines, quiet):
    """Rebuild every binary the given engines need (deduped), in order."""
    cmds = []
    for e in engines:
        c = build_command(e)
        if c and c not in cmds:
            cmds.append(c)
    for cmd in cmds:
        if not quiet:
            print(f"building: {cmd}", file=sys.stderr, flush=True)
        # Send build chatter to stderr so stdout stays clean markdown.
        r = subprocess.run(cmd, shell=True, cwd=ROOT, stdout=sys.stderr)
        if r.returncode != 0:
            print(f"build failed ({r.returncode}): {cmd}", file=sys.stderr)
            sys.exit(1)


class Benchmark:
    def __init__(self, name, engines, cases):
        self.name = name
        self.engines = engines
        self.cases = cases  # ordered dict: column label -> params dict


# --- sleep: 10k tasks each sleeping N ms. spawn=0ms (pure spawn), golden=10ms.
_SLEEP_ENGINES = [
    Engine("zio-st-stdio", "st", [os.path.join(B, "sleep"), "--zio"]),
    Engine("zio-mt-stdio", "mt", [os.path.join(B, "sleep"), "--zio-mt"]),
    Engine("zio-st-native", "st", [os.path.join(B, "sleep_native"), "--zio"]),
    Engine("zio-mt-native", "mt", [os.path.join(B, "sleep_native"), "--zio-mt"]),
    Engine("tokio-st", "st", [os.path.join(R, "sleep"), "--st"]),
    Engine("tokio-mt", "mt", [os.path.join(R, "sleep")]),
    Engine("asio-st", "st", [os.path.join(CPP, "sleep_asio"), "--st"]),
    Engine("asio-mt", "mt", [os.path.join(CPP, "sleep_asio")]),
    Engine("go-st", "st", [os.path.join(B, "sleep_go")], env={"GOMAXPROCS": "1"}, dash="-"),
    Engine("go-mt", "mt", [os.path.join(B, "sleep_go")], dash="-"),
    Engine("photon", "st", [os.path.join(CPP, "sleep_photon")], solo=True),
]


def sleep_benchmark(tasks):
    return Benchmark(
        "sleep",
        _SLEEP_ENGINES,
        {
            "spawn (0ms)": {"tasks": tasks, "sleep-ms": 0},
            "sleep (10ms)": {"tasks": tasks, "sleep-ms": 10},
        },
    )


# --- queue_ping_pong: 100k messages bounced between two tasks.
_PP = "queue_ping_pong"
_PING_PONG_ENGINES = [
    Engine("zio-st-stdio", "st", [os.path.join(B, _PP), "--zio"]),
    Engine("zio-mt-stdio", "mt", [os.path.join(B, _PP), "--zio-mt"]),
    Engine("zio-st-native", "st", [os.path.join(B, _PP + "_native"), "--zio"]),
    Engine("zio-mt-native", "mt", [os.path.join(B, _PP + "_native"), "--zio-mt"]),
    Engine("tokio-st", "st", [os.path.join(R, _PP), "--st"]),
    Engine("tokio-mt", "mt", [os.path.join(R, _PP)]),
    Engine("asio-st", "st", [os.path.join(CPP, _PP + "_asio"), "--st"]),
    Engine("asio-mt", "mt", [os.path.join(CPP, _PP + "_asio")]),
    Engine("go-st", "st", [os.path.join(B, _PP + "_go")], env={"GOMAXPROCS": "1"}, dash="-"),
    Engine("go-mt", "mt", [os.path.join(B, _PP + "_go")], dash="-"),
    Engine("photon", "st", [os.path.join(CPP, _PP + "_photon")], solo=True),
]


def ping_pong_benchmark(_tasks):
    return Benchmark(
        "queue_ping_pong",
        _PING_PONG_ENGINES,
        {"1 pair": {"pairs": 1}, "100 pairs": {"pairs": 100}},
    )


# --- worker_pool: producers push items through one queue to consumers.
_WP = "worker_pool"
_WORKER_POOL_ENGINES = [
    Engine("zio-st-stdio", "st", [os.path.join(B, _WP), "--zio"]),
    Engine("zio-mt-stdio", "mt", [os.path.join(B, _WP), "--zio-mt"]),
    Engine("zio-st-native", "st", [os.path.join(B, _WP + "_native"), "--zio"]),
    Engine("zio-mt-native", "mt", [os.path.join(B, _WP + "_native"), "--zio-mt"]),
    Engine("tokio-st", "st", [os.path.join(R, _WP), "--st"]),
    Engine("tokio-mt", "mt", [os.path.join(R, _WP)]),
    Engine("asio-st", "st", [os.path.join(CPP, _WP + "_asio"), "--st"]),
    Engine("asio-mt", "mt", [os.path.join(CPP, _WP + "_asio")]),
    Engine("go-st", "st", [os.path.join(B, _WP + "_go")], env={"GOMAXPROCS": "1"}, dash="-"),
    Engine("go-mt", "mt", [os.path.join(B, _WP + "_go")], dash="-"),
    Engine("photon", "st", [os.path.join(CPP, _WP + "_photon")], solo=True),
]

# fan-in = 1000 producers -> 1 consumer; fan-out = 1 producer -> 1000 consumers.
_FANIN = {"num-producers": 1000, "num-consumers": 1}
_FANOUT = {"num-producers": 1, "num-consumers": 1000}
# light: many tiny items -> queue/scheduling bound. cpu: fewer but heavy items
# (same total hashing) so per-item compute dominates the queue cost -> measures
# parallelism, not queue speed.
_LIGHT = {"num-items": 100000, "work": 0}
_CPU = {"num-items": 10000, "work": 10000}


def worker_pool_benchmark(_tasks):
    return Benchmark(
        "worker_pool",
        _WORKER_POOL_ENGINES,
        {
            "fan_in": {**_FANIN, **_LIGHT},
            "fan_out": {**_FANOUT, **_LIGHT},
            "fan_in-cpu": {**_FANIN, **_CPU},
            "fan_out-cpu": {**_FANOUT, **_CPU},
        },
    )


BENCHMARKS = {
    "sleep": sleep_benchmark,
    "queue_ping_pong": ping_pong_benchmark,
    "worker_pool": worker_pool_benchmark,
}

# Engine families (label prefix) across all benchmarks — drive the --no-<family> flags.
FAMILIES = sorted({e.label.split("-")[0] for fn in BENCHMARKS.values() for e in fn(0).engines})


def without(bench, excluded):
    """A copy of `bench` with the given engine families dropped."""
    engines = [e for e in bench.engines if e.label.split("-")[0] not in excluded]
    return Benchmark(bench.name, engines, bench.cases)


def run_one(engine, params):
    env = dict(os.environ, **engine.env)
    out = subprocess.run(engine.command(params), capture_output=True, text=True, env=env)
    return parse_ms(out.stdout + out.stderr)


def med_dev(vals):
    """(median, standard deviation) for a cell, or None if it never ran.
    Deviation is 0 with a single sample."""
    if not vals:
        return None
    return (statistics.median(vals), statistics.stdev(vals) if len(vals) > 1 else 0.0)


def run_matrix(bench, rounds, quiet=False):
    """Interleaved: every cell once per round, then take medians."""
    def progress(msg):
        if not quiet:
            print(msg, file=sys.stderr, flush=True)

    built = {e.label: os.path.exists(e.bin) for e in bench.engines}
    missing = [e.label for e in bench.engines if not built[e.label]]
    if missing:
        progress(f"[{bench.name}] not built, skipped: {', '.join(missing)}")
    samples = {(e.label, c): [] for e in bench.engines for c in bench.cases}
    for r in range(1, rounds + 1):
        for e in bench.engines:
            if not built[e.label]:
                continue
            progress(f"[{bench.name} {r}/{rounds}] {e.label}")
            for c, params in bench.cases.items():
                ms = run_one(e, params)
                if ms is not None:
                    samples[(e.label, c)].append(ms)
    medians = {}
    for e in bench.engines:
        medians[e.label] = None if not built[e.label] else {
            c: med_dev(samples[(e.label, c)])
            for c in bench.cases
        }
    return medians


def emit_table(title, mode, engines, cases, medians):
    cols = list(cases)
    print(f"\n### {title}\n")
    print("| engine | " + " | ".join(cols) + " |")
    print("|" + "---|" * (len(cols) + 1))
    for e in engines:
        if e.mode == mode:
            row = medians.get(e.label)
            if row is None:
                cells = ["_not built_"] * len(cols)
            else:
                cells = [("n/a" if row[c] is None else f"{row[c][0]:.2f} ±{row[c][1]:.2f}") for c in cols]
            print(f"| {e.label} | " + " | ".join(cells) + " |")
        elif e.solo:  # exists only in the other mode — show struck-out for completeness
            print(f"| ~~{e.label}~~ | " + " | ".join(["—"] * len(cols)) + " |")


def emit(bench, rounds, tasks, quiet=False):
    medians = run_matrix(bench, rounds, quiet)
    print(f"\n## {bench.name} (median ±stdev of {rounds} rounds, ms)")
    modes = [e.mode for e in bench.engines]
    if "st" in modes:
        emit_table("Single-threaded", "st", bench.engines, bench.cases, medians)
    if "mt" in modes:
        emit_table("Multi-threaded", "mt", bench.engines, bench.cases, medians)


# --- tcp: a server process under test driven by the C driver process (no core
# pinning). The driver reports throughput (msgs/s for echo, GB/s for send/recv),
# so higher is better; results are a flat engine x scenario table, not st/mt.
TCP_DRIVER = os.path.join(ROOT, "driver", "tcp_driver")
TCP_PORT = 18800

# zio's event-loop backend is a compile-time choice, so io_uring and epoll are
# separate binaries (tcp_server_native_<backend>); native API only.
_URING = os.path.join(B, "tcp_server_native_io_uring")
_EPOLL = os.path.join(B, "tcp_server_native_epoll")
_TCP_SERVERS = [
    Engine("zio-uring-st", "mt", [_URING, "--zio"]),
    Engine("zio-uring-mt", "mt", [_URING, "--zio-mt"]),
    Engine("zio-epoll-st", "mt", [_EPOLL, "--zio"]),
    Engine("zio-epoll-mt", "mt", [_EPOLL, "--zio-mt"]),
    Engine("go", "mt", [os.path.join(B, "tcp_server_go")]),
    Engine("tokio", "mt", [os.path.join(R, "tcp_server")]),
    Engine("asio", "mt", [os.path.join(CPP, "tcp_server_asio")]),
    Engine("photon", "mt", [os.path.join(CPP, "tcp_server_photon")]),
    Engine("photon-uring", "mt", [os.path.join(CPP, "tcp_server_photon"), "--uring"]),
]

# (label, server --mode, driver args, unit). Server modes: echo / sink / source.
_TCP_SCENARIOS = [
    ("lat", "echo", ["--mode=echo", "--conns=1", "--msgs=100000", "--size=4096"], "msgs/s"),
    ("many", "echo", ["--mode=echo", "--conns=1000", "--msgs=100", "--size=64"], "msgs/s"),
    ("pipe", "echo", ["--mode=echo", "--conns=64", "--msgs=10000", "--size=64", "--pipeline=16"], "msgs/s"),
    ("send1", "sink", ["--mode=send", "--mb=8192", "--size=65536", "--conns=1"], "GB/s"),
    ("send8", "sink", ["--mode=send", "--mb=8192", "--size=65536", "--conns=8"], "GB/s"),
    ("recv1", "source", ["--mode=recv", "--mb=8192", "--size=65536", "--conns=1"], "GB/s"),
    ("recv8", "source", ["--mode=recv", "--mb=8192", "--size=65536", "--conns=8"], "GB/s"),
]


def parse_throughput(text):
    m = _THRU.search(_ANSI.sub("", text))
    return float(m.group(1)) if m else None


def ensure_driver(quiet):
    """Build the Go load driver if missing or stale."""
    src = TCP_DRIVER + ".go"
    if os.path.exists(TCP_DRIVER) and os.path.getmtime(TCP_DRIVER) >= os.path.getmtime(src):
        return
    cmd = f"go build -o {TCP_DRIVER} {src}"
    if not quiet:
        print(f"building: {cmd}", file=sys.stderr, flush=True)
    if subprocess.run(cmd, shell=True, cwd=ROOT, stdout=sys.stderr).returncode != 0:
        print("build failed: tcp driver", file=sys.stderr)
        sys.exit(1)


def tcp_run_matrix(servers, rounds, quiet):
    ensure_driver(quiet)
    built = {s.label: os.path.exists(s.bin) for s in servers}
    missing = [s.label for s in servers if not built[s.label]]
    if missing and not quiet:
        print(f"[tcp] not built, skipped: {', '.join(missing)}", file=sys.stderr)

    # Group scenarios by server mode (preserving order) so one server start
    # serves all of its scenarios.
    by_mode = []
    for sc in _TCP_SCENARIOS:
        if not by_mode or by_mode[-1][0] != sc[1]:
            by_mode.append((sc[1], []))
        by_mode[-1][1].append(sc)

    samples = {(s.label, sc[0]): [] for s in servers for sc in _TCP_SCENARIOS}
    for r in range(1, rounds + 1):
        for s in servers:
            if not built[s.label]:
                continue
            for mode, scs in by_mode:
                if not quiet:
                    print(f"[tcp {r}/{rounds}] {s.label} {mode}", file=sys.stderr, flush=True)
                proc = subprocess.Popen(
                    [*s.argv, f"--mode={mode}", f"--port={TCP_PORT}"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
                try:
                    time.sleep(0.5)  # let the server bind
                    for label, _m, dargs, _u in scs:
                        out = subprocess.run(
                            [TCP_DRIVER, f"--port={TCP_PORT}", *dargs],
                            capture_output=True, text=True,
                        )
                        v = parse_throughput(out.stdout + out.stderr)
                        if v is not None:
                            samples[(s.label, label)].append(v)
                finally:
                    proc.terminate()
                    proc.wait()
                    time.sleep(0.3)  # let the port free before the next bind

    return {
        s.label: (None if not built[s.label] else {
            sc[0]: med_dev(samples[(s.label, sc[0])])
            for sc in _TCP_SCENARIOS
        })
        for s in servers
    }


def _fmt_thru(pair, unit):
    if pair is None:
        return "n/a"
    m, d = pair
    if unit == "msgs/s":
        return f"{m / 1000:.0f}k ±{d / 1000:.0f}k"
    return f"{m:.2f} ±{d:.2f}"


def tcp_emit(servers, rounds, quiet=False):
    medians = tcp_run_matrix(servers, rounds, quiet)
    print(f"\n## tcp (median ±stdev of {rounds} rounds, higher is better)")
    for title, unit in (("echo (msgs/s)", "msgs/s"), ("bulk transfer (GB/s)", "GB/s")):
        cols = [sc for sc in _TCP_SCENARIOS if sc[3] == unit]
        labels = [c[0] for c in cols]
        print(f"\n### {title}\n")
        print("| engine | " + " | ".join(labels) + " |")
        print("|" + "---|" * (len(labels) + 1))
        for s in servers:
            row = medians.get(s.label)
            cells = (["_not built_"] * len(labels) if row is None
                     else [_fmt_thru(row[c[0]], unit) for c in cols])
            print(f"| {s.label} | " + " | ".join(cells) + " |")


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument(
        "--bench",
        choices=list(BENCHMARKS) + ["tcp", "all"],
        help="benchmark to run, or 'all' (required — with no args this help is shown)",
    )
    ap.add_argument("--rounds", type=int, default=7, help="rounds per cell (median reported)")
    ap.add_argument("--tasks", type=int, default=10000, help="task count for the sleep benchmark")
    ap.add_argument("--build", action="store_true", help="rebuild the benchmark's binaries first")
    ap.add_argument("--quiet", action="store_true", help="suppress progress output on stderr")
    for fam in FAMILIES:
        ap.add_argument(f"--no-{fam}", action="store_true", help=f"skip {fam}")

    # No arguments -> show help rather than running everything.
    if len(sys.argv) == 1:
        ap.print_help()
        return
    args = ap.parse_args()
    if args.bench is None:
        ap.print_help()
        return

    excluded = {fam for fam in FAMILIES if getattr(args, f"no_{fam}")}
    names = (list(BENCHMARKS) + ["tcp"]) if args.bench == "all" else [args.bench]

    # Resolve each name to something runnable: an in-process Benchmark, or the
    # filtered TCP server list.
    runnables = []  # (kind, obj)
    for name in names:
        if name == "tcp":
            servers = [s for s in _TCP_SERVERS if s.label.split("-")[0] not in excluded]
            runnables.append(("tcp", servers))
        else:
            runnables.append(("bench", without(BENCHMARKS[name](args.tasks), excluded)))

    if args.build:
        engines = []
        for kind, obj in runnables:
            engines += obj if kind == "tcp" else obj.engines
        run_builds(engines, args.quiet)
        if any(kind == "tcp" for kind, _ in runnables):
            ensure_driver(args.quiet)

    for kind, obj in runnables:
        if kind == "tcp":
            tcp_emit(obj, args.rounds, args.quiet)
        else:
            emit(obj, args.rounds, args.tasks, args.quiet)


if __name__ == "__main__":
    main()
