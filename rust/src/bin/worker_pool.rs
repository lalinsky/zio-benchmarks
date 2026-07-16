// Counterpart of worker_pool on tokio: --num-producers tasks push --num-items
// values (split evenly) into one bounded MPMC channel (capacity 256),
// --num-consumers workers race to drain it, each doing --work iterations of a
// data-dependent hash recurrence per item. async-channel provides the MPMC
// queue (tokio's mpsc is single-consumer). Golden presets:
//
//   defaults                                  fan-out worker pool (1 -> 1000)
//   --num-producers=1000 --num-consumers=1 --work=0   fan-in shape
use std::time::Instant;

fn work(seed: u64, iters: u64) -> u64 {
    let mut x = seed;
    let mut acc = 0u64;
    for _ in 0..iters {
        x = x
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        acc ^= x >> 29;
    }
    acc
}

async fn producer(tx: async_channel::Sender<u64>, start: u64, end: u64) {
    for i in start..end {
        if tx.send(i + 1).await.is_err() {
            return;
        }
    }
    // Channel closes when the last sender is dropped.
}

async fn consumer(rx: async_channel::Receiver<u64>, work_iters: u64) -> u64 {
    let mut acc = 0u64;
    while let Ok(item) = rx.recv().await {
        acc ^= work(item, work_iters);
    }
    acc
}

fn parse_args() -> (u64, u64, u64, u64, bool) {
    let (mut items, mut producers, mut consumers, mut work_iters, mut st) =
        (100_000u64, 1u64, 1000u64, 64u64, false);
    for arg in std::env::args().skip(1) {
        if arg == "--st" {
            st = true;
            continue;
        }
        let (key, value) = match arg.split_once('=') {
            Some(kv) => kv,
            None => {
                eprintln!("usage: worker_pool [--st] [--num-items=N] [--num-producers=N] [--num-consumers=N] [--work=N]");
                std::process::exit(1);
            }
        };
        let target = match key {
            "--num-items" => &mut items,
            "--num-producers" => &mut producers,
            "--num-consumers" => &mut consumers,
            "--work" => &mut work_iters,
            _ => {
                eprintln!("unknown argument '{}'", arg);
                std::process::exit(1);
            }
        };
        *target = value.parse().expect("invalid number");
    }
    (items, producers, consumers, work_iters, st)
}

async fn run(items: u64, producers: u64, consumers: u64, work_iters: u64) -> u64 {
    let (tx, rx) = async_channel::bounded::<u64>(256);

    let mut consumer_handles = Vec::with_capacity(consumers as usize);
    for _ in 0..consumers {
        consumer_handles.push(tokio::spawn(consumer(rx.clone(), work_iters)));
    }
    drop(rx);

    let mut producer_handles = Vec::with_capacity(producers as usize);
    for p in 0..producers {
        let start = p * items / producers;
        let end = (p + 1) * items / producers;
        producer_handles.push(tokio::spawn(producer(tx.clone(), start, end)));
    }
    drop(tx);

    for h in producer_handles {
        h.await.ok();
    }
    let mut checksum = 0u64;
    for h in consumer_handles {
        checksum ^= h.await.unwrap_or(0);
    }
    checksum
}

fn main() {
    let (items, producers, consumers, work_iters, st) = parse_args();
    let mut builder = if st {
        tokio::runtime::Builder::new_current_thread()
    } else {
        tokio::runtime::Builder::new_multi_thread()
    };
    let rt = builder.enable_all().build().unwrap();
    let start = Instant::now();
    let checksum = rt.block_on(run(items, producers, consumers, work_iters));
    let d = start.elapsed();
    println!(
        "Duration: {:.3}ms ({} items, {} producers, {} consumers, work={}, {:.0} msgs/s, checksum={:x})",
        d.as_secs_f64() * 1000.0,
        items,
        producers,
        consumers,
        work_iters,
        items as f64 / d.as_secs_f64(),
        checksum
    );
}
