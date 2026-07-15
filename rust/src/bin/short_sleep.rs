// Counterpart of short_sleep: 10k concurrent 1ms sleeps.
const NUM_TASKS: usize = 10_000;

async fn run() {
    let mut tasks = Vec::with_capacity(NUM_TASKS);
    for _ in 0..NUM_TASKS {
        tasks.push(tokio::spawn(tokio::time::sleep(std::time::Duration::from_millis(1))));
    }
    for t in tasks {
        t.await.ok();
    }
}

fn main() {
    let start = std::time::Instant::now();
    tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap().block_on(run());
    let d = start.elapsed();
    println!("Duration: {:.3}ms (tokio, {} sleeps)", d.as_secs_f64() * 1e3, NUM_TASKS);
}
