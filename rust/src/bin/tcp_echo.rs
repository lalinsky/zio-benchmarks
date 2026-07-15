// Golden TCP benchmark on tokio: --conns concurrent loopback connections, each
// doing --msgs request/response round-trips of --size bytes against a
// per-connection echo handler. Presets:
//
//   defaults (1000 conns x 100 msgs x 64B)   many-connection throughput
//   --conns=1 --msgs=100000 --size=4096      single-connection latency chain
use std::time::Instant;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

const ADDR: &str = "127.0.0.1:18768";

fn parse_args() -> (usize, usize, usize, bool) {
    let (mut conns, mut msgs, mut size) = (1000usize, 100usize, 64usize);
    let mut single_thread = false;
    for arg in std::env::args().skip(1) {
        if arg == "--st" {
            single_thread = true;
            continue;
        }
        let (key, value) = match arg.split_once('=') {
            Some(kv) => kv,
            None => {
                eprintln!("usage: tcp_echo [--st] [--conns=N] [--msgs=N] [--size=N]");
                std::process::exit(1);
            }
        };
        let target = match key {
            "--conns" => &mut conns,
            "--msgs" => &mut msgs,
            "--size" => &mut size,
            _ => {
                eprintln!("unknown argument '{}'", arg);
                std::process::exit(1);
            }
        };
        *target = value.parse().expect("invalid number");
    }
    (conns, msgs, size, single_thread)
}

async fn echo_handler(mut stream: TcpStream, size: usize) {
    let mut msg = vec![0u8; size];
    loop {
        if stream.read_exact(&mut msg).await.is_err() {
            return;
        }
        if stream.write_all(&msg).await.is_err() {
            return;
        }
    }
}

async fn client(msgs: usize, size: usize) {
    let mut stream = TcpStream::connect(ADDR).await.expect("connect failed");
    stream.set_nodelay(true).ok();
    let mut msg = vec![0u8; size];
    for _ in 0..msgs {
        if stream.write_all(&msg).await.is_err() {
            return;
        }
        if stream.read_exact(&mut msg).await.is_err() {
            return;
        }
    }
}

async fn run(conns: usize, msgs: usize, size: usize) {
    let listener = TcpListener::bind(ADDR).await.expect("listen failed");

    let server = tokio::spawn(async move {
        let mut handlers = Vec::with_capacity(conns);
        for _ in 0..conns {
            let (stream, _) = match listener.accept().await {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("server: accept failed: {}", e);
                    break;
                }
            };
            stream.set_nodelay(true).ok();
            handlers.push(tokio::spawn(echo_handler(stream, size)));
        }
        for h in handlers {
            h.await.ok();
        }
    });

    let mut clients = Vec::with_capacity(conns);
    for _ in 0..conns {
        clients.push(tokio::spawn(client(msgs, size)));
    }
    for c in clients {
        c.await.ok();
    }
    server.await.ok();
}

fn main() {
    let (conns, msgs, size, single_thread) = parse_args();
    let rt = if single_thread {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
    } else {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .unwrap()
    };
    let start = Instant::now();
    rt.block_on(run(conns, msgs, size));
    let d = start.elapsed();
    let total = (conns * msgs) as f64;
    println!(
        "Duration: {:.3}ms ({} msgs over {} conns, size {}, {:.0} msgs/s)",
        d.as_secs_f64() * 1000.0,
        conns * msgs,
        conns,
        size,
        total / d.as_secs_f64()
    );
}
