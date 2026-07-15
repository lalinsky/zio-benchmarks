// Counterpart of mutex_bench_native: 4 tasks x 100k lock/inc/unlock on a
// shared std::sync::Mutex (the recommended lock for short critical sections
// in tokio). --async-mutex switches to tokio::sync::Mutex.
use std::sync::{Arc, Mutex};

const NUM_WORKERS: u64 = 4;
const ITERATIONS: u64 = 100_000;

async fn run_std() {
    let counter = Arc::new(Mutex::new(0u64));
    let mut workers = Vec::new();
    for _ in 0..NUM_WORKERS {
        let counter = counter.clone();
        workers.push(tokio::spawn(async move {
            for _ in 0..ITERATIONS {
                *counter.lock().unwrap() += 1;
            }
        }));
    }
    for w in workers {
        w.await.ok();
    }
    assert_eq!(*counter.lock().unwrap(), NUM_WORKERS * ITERATIONS);
}

async fn run_async() {
    let counter = Arc::new(tokio::sync::Mutex::new(0u64));
    let mut workers = Vec::new();
    for _ in 0..NUM_WORKERS {
        let counter = counter.clone();
        workers.push(tokio::spawn(async move {
            for _ in 0..ITERATIONS {
                *counter.lock().await += 1;
            }
        }));
    }
    for w in workers {
        w.await.ok();
    }
    assert_eq!(*counter.lock().await, NUM_WORKERS * ITERATIONS);
}

fn main() {
    let async_mutex = std::env::args().any(|a| a == "--async-mutex");
    let start = std::time::Instant::now();
    let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
    if async_mutex {
        rt.block_on(run_async());
    } else {
        rt.block_on(run_std());
    }
    let d = start.elapsed();
    println!("Duration: {:.3}ms (tokio {}, {} locks)", d.as_secs_f64() * 1e3, if async_mutex { "async-mutex" } else { "std-mutex" }, NUM_WORKERS * ITERATIONS);
}
