// Counterpart of queue_ping_pong: ping-pong between two tasks over two
// capacity-1 channels. --pairs=N runs N independent pairs concurrently,
// splitting a fixed total of TOTAL messages evenly (each pair bounces TOTAL/N).
// Multi-threaded runtime by default; --st for current-thread.
use tokio::sync::mpsc;

const TOTAL: u64 = 100_000;

// One pair: owns its two channels and runs the two ping-pong tasks to completion.
async fn pair(limit: u64) {
    let (tx_ab, mut rx_ab) = mpsc::channel::<u64>(1);
    let (tx_ba, mut rx_ba) = mpsc::channel::<u64>(1);

    let a = tokio::spawn(async move {
        tx_ab.send(0).await.ok();
        while let Some(v) = rx_ba.recv().await {
            let next = v + 1;
            if next >= limit {
                return;
            }
            if tx_ab.send(next).await.is_err() {
                return;
            }
        }
    });
    let b = tokio::spawn(async move {
        while let Some(v) = rx_ab.recv().await {
            let next = v + 1;
            if next >= limit {
                return;
            }
            if tx_ba.send(next).await.is_err() {
                return;
            }
        }
    });
    a.await.ok();
    b.await.ok();
}

async fn run(pairs: u64, per_pair: u64) {
    let mut handles = Vec::with_capacity(pairs as usize);
    for _ in 0..pairs {
        handles.push(tokio::spawn(pair(per_pair)));
    }
    for h in handles {
        h.await.ok();
    }
}

fn main() {
    let mut st = false;
    let mut pairs: u64 = 1;
    for arg in std::env::args().skip(1) {
        if arg == "--st" {
            st = true;
        } else if let Some(v) = arg.strip_prefix("--pairs=") {
            pairs = v.parse().expect("invalid --pairs");
        }
    }
    if pairs == 0 {
        pairs = 1;
    }
    let per_pair = (TOTAL / pairs).max(1);

    let mut builder = if st {
        tokio::runtime::Builder::new_current_thread()
    } else {
        tokio::runtime::Builder::new_multi_thread()
    };
    let rt = builder.enable_all().build().unwrap();

    let start = std::time::Instant::now();
    rt.block_on(run(pairs, per_pair));
    let d = start.elapsed();
    println!(
        "Duration: {:.3}ms (tokio{}, {} pairs, {} msgs each)",
        d.as_secs_f64() * 1e3,
        if st { "-st" } else { "" },
        pairs,
        per_pair
    );
}
