// TCP benchmark subject on tokio, driven by driver/tcp_driver.c. Accepts
// connections forever (the bench runner kills the process); one task per
// connection.
//
//   echo    write back whatever arrives (works with driver pipelining)
//   sink    read and discard until EOF
//   source  write zeros until the client closes
//
// usage: tcp_server [--st] [--mode=echo|sink|source] [--port=N]
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

const BUF_SIZE: usize = 64 * 1024;

#[derive(Clone, Copy, PartialEq)]
enum Mode {
    Echo,
    Sink,
    Source,
}

async fn handler(mut stream: TcpStream, mode: Mode) {
    let mut buf = vec![0u8; BUF_SIZE];
    match mode {
        Mode::Echo => loop {
            let n = match stream.read(&mut buf).await {
                Ok(0) | Err(_) => return,
                Ok(n) => n,
            };
            if stream.write_all(&buf[..n]).await.is_err() {
                return;
            }
        },
        Mode::Sink => loop {
            match stream.read(&mut buf).await {
                Ok(0) | Err(_) => return,
                Ok(_) => {}
            }
        },
        Mode::Source => loop {
            if stream.write_all(&buf).await.is_err() {
                return;
            }
        },
    }
}

async fn run(port: u16, mode: Mode) {
    let listener = TcpListener::bind(("127.0.0.1", port)).await.expect("bind failed");
    println!("tcp_server_tokio listening on 127.0.0.1:{}", port);
    loop {
        let (stream, _) = match listener.accept().await {
            Ok(s) => s,
            Err(_) => return,
        };
        stream.set_nodelay(true).ok();
        tokio::spawn(handler(stream, mode));
    }
}

fn main() {
    let mut port = 18800u16;
    let mut mode = Mode::Echo;
    let mut single_thread = false;
    for arg in std::env::args().skip(1) {
        if arg == "--st" {
            single_thread = true;
        } else if let Some(v) = arg.strip_prefix("--port=") {
            port = v.parse().expect("invalid port");
        } else if let Some(v) = arg.strip_prefix("--mode=") {
            mode = match v {
                "echo" => Mode::Echo,
                "sink" => Mode::Sink,
                "source" => Mode::Source,
                _ => {
                    eprintln!("unknown mode '{}'", v);
                    std::process::exit(2);
                }
            };
        } else {
            eprintln!("usage: tcp_server [--st] [--mode=echo|sink|source] [--port=N]");
            std::process::exit(2);
        }
    }
    let rt = if single_thread {
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap()
    } else {
        tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap()
    };
    rt.block_on(run(port, mode));
}
