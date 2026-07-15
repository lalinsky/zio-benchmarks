// Counterpart of queue_ping_pong: 100k messages ping-ponged between two
// tasks over two capacity-1 channels. Multi-threaded runtime by default.
use tokio::sync::mpsc;

const LIMIT: u64 = 100_000;

async fn run() {
    let (tx_ab, mut rx_ab) = mpsc::channel::<u64>(1);
    let (tx_ba, mut rx_ba) = mpsc::channel::<u64>(1);

    let a = tokio::spawn(async move {
        tx_ab.send(0).await.ok();
        while let Some(v) = rx_ba.recv().await {
            let next = v + 1;
            if next >= LIMIT {
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
            if next >= LIMIT {
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

fn main() {
    let st = std::env::args().any(|a| a == "--st");
    let start = std::time::Instant::now();
    if st {
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(run());
    } else {
        tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap().block_on(run());
    }
    let d = start.elapsed();
    println!("Duration: {:.3}ms (tokio{}, {} msgs)", d.as_secs_f64() * 1e3, if st { "-st" } else { "" }, LIMIT);
}
