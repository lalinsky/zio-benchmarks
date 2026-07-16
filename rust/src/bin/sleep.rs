// Golden sleep/spawn benchmark on tokio: --tasks concurrent tasks each
// sleeping --sleep-ms, wait for all. --sleep-ms=0 is a pure no-op spawn
// benchmark.
use std::time::{Duration, Instant};

fn parse_args() -> (usize, u64, bool) {
    let (mut tasks, mut sleep_ms, mut st) = (10_000usize, 1u64, false);
    for arg in std::env::args().skip(1) {
        if arg == "--st" {
            st = true;
            continue;
        }
        let (key, value) = match arg.split_once('=') {
            Some(kv) => kv,
            None => {
                eprintln!("usage: sleep [--st] [--tasks=N] [--sleep-ms=N]");
                std::process::exit(1);
            }
        };
        match key {
            "--tasks" => tasks = value.parse().expect("invalid number"),
            "--sleep-ms" => sleep_ms = value.parse().expect("invalid number"),
            _ => {
                eprintln!("unknown argument '{}'", arg);
                std::process::exit(1);
            }
        }
    }
    (tasks, sleep_ms, st)
}

async fn run(tasks: usize, sleep_ms: u64) {
    let mut handles = Vec::with_capacity(tasks);
    for _ in 0..tasks {
        handles.push(tokio::spawn(async move {
            if sleep_ms > 0 {
                tokio::time::sleep(Duration::from_millis(sleep_ms)).await;
            }
        }));
    }
    for h in handles {
        h.await.ok();
    }
}

fn main() {
    let (tasks, sleep_ms, st) = parse_args();
    let mut builder = if st {
        tokio::runtime::Builder::new_current_thread()
    } else {
        tokio::runtime::Builder::new_multi_thread()
    };
    let rt = builder.enable_all().build().unwrap();
    let start = Instant::now();
    rt.block_on(run(tasks, sleep_ms));
    let d = start.elapsed();
    println!(
        "Duration: {:.3}ms ({} tasks, sleep {}ms)",
        d.as_secs_f64() * 1e3,
        tasks,
        sleep_ms
    );
}
