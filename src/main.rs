mod client;
mod kernel;
mod protocol;
mod router;
mod wire;

use anyhow::Result;
use protocol::{Command, Event};
use router::Router;
use std::io::BufRead;
use std::path::PathBuf;
use tokio::sync::mpsc;

#[tokio::main]
async fn main() -> Result<()> {
    let runtime_dir: PathBuf = {
        let base = std::env::var("XDG_DATA_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
                PathBuf::from(home).join(".local/share")
            });
        base.join("nvim-jupyter")
    };
    std::fs::create_dir_all(&runtime_dir)?;

    let (event_tx, mut event_rx) = mpsc::channel::<Event>(256);
    let (cmd_tx, mut cmd_rx) = mpsc::channel::<Command>(64);

    let cmd_tx_clone = cmd_tx.clone();
    tokio::task::spawn_blocking(move || {
        let stdin = std::io::stdin();
        for line in stdin.lock().lines() {
            let Ok(line) = line else { break };
            let line = line.trim().to_string();
            if line.is_empty() { continue; }
            match serde_json::from_str::<Command>(&line) {
                Ok(cmd) => {
                    if cmd_tx_clone.blocking_send(cmd).is_err() { break; }
                }
                Err(e) => {
                    eprintln!("nvim-jupyter: bad command: {e}: {line}");
                }
            }
        }
    });

    tokio::spawn(async move {
        let stdout = std::io::stdout();
        while let Some(event) = event_rx.recv().await {
            let mut out = stdout.lock();
            if let Ok(json) = serde_json::to_string(&event) {
                use std::io::Write;
                let _ = writeln!(out, "{}", json);
                let _ = out.flush();
            }
        }
    });

    let mut router = Router::new(event_tx, runtime_dir);
    while let Some(cmd) = cmd_rx.recv().await {
        if !router.handle(cmd).await {
            break;
        }
    }

    Ok(())
}
