use anyhow::Result;
use tokio::{
    io::{self, Interest},
    net::{TcpListener, TcpStream},
};

const BIND_ADDR: &str = "127.0.0.1:47912";

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    println!("Hello, world!");
    try_leader().await?;
    try_follower().await?;
    Ok(())
}

async fn try_leader() -> Result<()> {
    let listener = TcpListener::bind(BIND_ADDR).await?;
    dbg!(&listener);
    let mut handles: Vec<tokio::task::JoinHandle<Result<()>>> = vec![];
    loop {
        match listener.accept().await {
            Ok((stream, addr)) => {
                handles.push(tokio::spawn(async move {
                    dbg!(&stream);
                    dbg!(&addr);
                    loop {
                        let ready = stream
                            .ready(Interest::READABLE)
                            // .ready(Interest::READABLE | Interest::WRITABLE)
                            .await?;

                        if ready.is_readable() {
                            let mut data = vec![0; 1024];
                            // Try to read data, this may still fail with `WouldBlock`
                            // if the readiness event is a false positive.
                            match stream.try_read(&mut data) {
                                Ok(n) if n > 0 => {
                                    println!("read {} bytes: {}", n, String::from_utf8(data)?);
                                }
                                Ok(_) => {
                                    continue;
                                }
                                Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => {
                                    continue;
                                }
                                Err(e) => {
                                    return Err(e.into());
                                }
                            }
                        }

                        if ready.is_writable() {
                            // Try to write data, this may still fail with `WouldBlock`
                            // if the readiness event is a false positive.
                            match stream.try_write(b"hello world") {
                                Ok(n) => {
                                    println!("write {} bytes", n);
                                }
                                Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => continue,
                                Err(e) => {
                                    return Err(e.into());
                                }
                            }
                        }
                    }
                }))
            }
            Err(e) => println!("couldn't get client: {:?}", e),
        }
    }
    // Ok(())
}

async fn try_follower() -> Result<()> {
    let listener = TcpStream::connect(BIND_ADDR).await?;
    dbg!(listener);
    Ok(())
}
