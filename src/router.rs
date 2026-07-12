use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::time::timeout;
use zeromq::SocketRecv;

use crate::client::KernelClient;
use crate::kernel::{self, KernelProcess};
use crate::protocol::{Command, Event, KernelSpec};

enum KernelCmd {
    Execute { msg_id: String, code: String },
    Complete { msg_id: String, code: String, cursor_pos: u32 },
    Inspect { msg_id: String, code: String, cursor_pos: u32, detail_level: u32 },
    Interrupt,
    Shutdown { restart: bool },
}

struct KernelHandle {
    tx: mpsc::Sender<KernelCmd>,
}

pub struct Router {
    kernels: HashMap<String, KernelHandle>,
    event_tx: mpsc::Sender<Event>,
    runtime_dir: PathBuf,
}

impl Router {
    pub fn new(event_tx: mpsc::Sender<Event>, runtime_dir: PathBuf) -> Self {
        Router { kernels: HashMap::new(), event_tx, runtime_dir }
    }

    pub async fn handle(&mut self, cmd: Command) -> bool {
        match cmd {
            Command::Quit => return false,

            Command::ListKernels => {
                match kernel::list_kernelspecs() {
                    Ok(specs) => {
                        let kernels = specs.into_iter().map(|(name, spec)| KernelSpec {
                            name,
                            display_name: spec.display_name,
                            language: spec.language,
                            argv: spec.argv,
                        }).collect();
                        let _ = self.event_tx.send(Event::KernelsList { kernels }).await;
                    }
                    Err(e) => {
                        let _ = self.event_tx.send(Event::Error { msg: e.to_string() }).await;
                    }
                }
            }

            Command::StartKernel { kernel_id, kernel_name, cwd } => {
                let event_tx = self.event_tx.clone();
                let runtime_dir = self.runtime_dir.clone();
                let kid = kernel_id.clone();
                let (cmd_tx, cmd_rx) = mpsc::channel::<KernelCmd>(32);

                self.kernels.insert(kernel_id, KernelHandle { tx: cmd_tx });

                tokio::spawn(async move {
                    run_kernel_task(kid, kernel_name, cwd, runtime_dir, cmd_rx, event_tx).await;
                });
            }

            Command::StopKernel { kernel_id } => {
                if let Some(handle) = self.kernels.remove(&kernel_id) {
                    let _ = handle.tx.send(KernelCmd::Shutdown { restart: false }).await;
                }
            }

            Command::RestartKernel { kernel_id } => {
                if let Some(handle) = self.kernels.get(&kernel_id) {
                    let _ = handle.tx.send(KernelCmd::Shutdown { restart: true }).await;
                }
            }

            Command::InterruptKernel { kernel_id } => {
                if let Some(handle) = self.kernels.get(&kernel_id) {
                    let _ = handle.tx.send(KernelCmd::Interrupt).await;
                }
            }

            Command::Execute { kernel_id, msg_id, code } => {
                if let Some(handle) = self.kernels.get(&kernel_id) {
                    let _ = handle.tx.send(KernelCmd::Execute { msg_id, code }).await;
                } else {
                    let _ = self.event_tx.send(Event::Error {
                        msg: format!("no kernel for id {}", kernel_id),
                    }).await;
                }
            }

            Command::Complete { kernel_id, msg_id, code, cursor_pos } => {
                if let Some(handle) = self.kernels.get(&kernel_id) {
                    let _ = handle.tx.send(KernelCmd::Complete { msg_id, code, cursor_pos }).await;
                } else {
                    let _ = self.event_tx.send(Event::Error {
                        msg: format!("no kernel for id {}", kernel_id),
                    }).await;
                }
            }

            Command::Inspect { kernel_id, msg_id, code, cursor_pos, detail_level } => {
                if let Some(handle) = self.kernels.get(&kernel_id) {
                    let _ = handle.tx.send(KernelCmd::Inspect { msg_id, code, cursor_pos, detail_level }).await;
                } else {
                    let _ = self.event_tx.send(Event::Error {
                        msg: format!("no kernel for id {}", kernel_id),
                    }).await;
                }
            }
        }
        true
    }
}

async fn run_kernel_task(
    kernel_id: String,
    kernel_name: String,
    cwd: String,
    runtime_dir: PathBuf,
    mut cmd_rx: mpsc::Receiver<KernelCmd>,
    event_tx: mpsc::Sender<Event>,
) {
    let _ = event_tx.send(Event::KernelStarted { kernel_id: kernel_id.clone() }).await;

    let proc = match KernelProcess::spawn(&kernel_name, &cwd, &runtime_dir).await {
        Ok(p) => p,
        Err(e) => {
            let _ = event_tx.send(Event::Error { msg: format!("spawn failed: {e}") }).await;
            let _ = event_tx.send(Event::KernelDied { kernel_id, code: -1 }).await;
            return;
        }
    };

    tokio::time::sleep(Duration::from_millis(500)).await;

    let mut client = match KernelClient::connect(&proc.conn).await {
        Ok(c) => c,
        Err(e) => {
            let _ = event_tx.send(Event::Error { msg: format!("ZMQ connect failed: {e}") }).await;
            proc.kill().await;
            let _ = event_tx.send(Event::KernelDied { kernel_id, code: -1 }).await;
            return;
        }
    };

    let mut ready = false;
    for _ in 0..5 {
        if client.heartbeat(2).await.is_ok() {
            ready = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    if !ready {
        let _ = event_tx.send(Event::Error { msg: "kernel heartbeat timeout".into() }).await;
        proc.kill().await;
        let _ = event_tx.send(Event::KernelDied { kernel_id, code: -1 }).await;
        return;
    }

    let _ = event_tx.send(Event::KernelReady { kernel_id: kernel_id.clone() }).await;

    let mut exec_queue: std::collections::VecDeque<(String, String)> = std::collections::VecDeque::new();
    let mut exec_msg_id: Option<String> = None;
    let mut iopub_idle = true;
    let mut shell_done = true;
    let mut reply_status = String::from("ok");
    let mut reply_exec_count: Option<u32> = None;

    loop {
        tokio::select! {
            Some(cmd) = cmd_rx.recv() => {
                match cmd {
                    KernelCmd::Execute { msg_id, code } => {
                        if exec_msg_id.is_some() {
                            exec_queue.push_back((msg_id, code));
                            continue;
                        }
                        if let Err(e) = client.send_execute_request(&msg_id, &code).await {
                            let _ = event_tx.send(Event::Error { msg: e.to_string() }).await;
                            continue;
                        }
                        exec_msg_id = Some(msg_id);
                        iopub_idle = false;
                        shell_done = false;
                        reply_exec_count = None;
                    }
                    KernelCmd::Complete { msg_id, code, cursor_pos } => {
                        if let Err(e) = client.send_complete_request(&msg_id, &code, cursor_pos).await {
                            let _ = event_tx.send(Event::Error { msg: e.to_string() }).await;
                        }
                    }
                    KernelCmd::Inspect { msg_id, code, cursor_pos, detail_level } => {
                        if let Err(e) = client.send_inspect_request(&msg_id, &code, cursor_pos, detail_level).await {
                            let _ = event_tx.send(Event::Error { msg: e.to_string() }).await;
                        }
                    }
                    KernelCmd::Interrupt => {
                        proc.interrupt().await;
                    }
                    KernelCmd::Shutdown { restart } => {
                        let _ = client.send_shutdown(restart).await;
                        tokio::time::sleep(Duration::from_millis(500)).await;
                        proc.kill().await;
                        let _ = event_tx.send(Event::KernelDied { kernel_id: kernel_id.clone(), code: 0 }).await;
                        return;
                    }
                }
            }
            Ok(zmq_msg) = client.iopub.recv() => {
                if let Ok(msg) = crate::wire::decode_iopub(&zmq_msg.into_vec(), &client.key) {
                    if let Some(ref mid) = exec_msg_id {
                        let parent_id = msg.parent_header.get("msg_id")
                            .and_then(|v| v.as_str())
                            .unwrap_or("");
                        if parent_id != mid { continue; }
                        
                        let msg_type = msg.msg_type();
                        match msg_type {
                            "status" => {
                                if msg.content.get("execution_state").and_then(|v| v.as_str()) == Some("idle") {
                                    iopub_idle = true;
                                }
                            }
                            "stream" => {
                                let name = msg.content["name"].as_str().unwrap_or("stdout").to_string();
                                let text = msg.content["text"].as_str().unwrap_or("").to_string();
                                let _ = event_tx.send(Event::Stream {
                                    kernel_id: kernel_id.clone(), msg_id: mid.clone(), name, text,
                                }).await;
                            }
                            "execute_result" | "display_data" => {
                                let text = KernelClient::extract_text(&msg).unwrap_or_default();
                                let image_png = KernelClient::extract_image_png(&msg);
                                let exec_count = msg.content.get("execution_count")
                                    .and_then(|v| v.as_u64()).unwrap_or(0) as u32;
                                let _ = event_tx.send(Event::ExecuteResult {
                                    kernel_id: kernel_id.clone(), msg_id: mid.clone(),
                                    execution_count: exec_count, text, image_png,
                                }).await;
                            }
                            "error" => {
                                let ename = msg.content["ename"].as_str().unwrap_or("").to_string();
                                let evalue = msg.content["evalue"].as_str().unwrap_or("").to_string();
                                let traceback = msg.content["traceback"]
                                    .as_array()
                                    .map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect())
                                    .unwrap_or_default();
                                let _ = event_tx.send(Event::ExecuteError {
                                    kernel_id: kernel_id.clone(), msg_id: mid.clone(),
                                    ename, evalue, traceback,
                                }).await;
                            }
                            _ => {}
                        }
                    }
                }
            }
            Ok(zmq_msg) = client.shell.recv() => {
                if let Ok(msg) = crate::wire::decode_shell(&zmq_msg.into_vec(), &client.key) {
                    let msg_type = msg.msg_type();
                    match msg_type {
                        "execute_reply" => {
                            reply_status = msg.content["status"].as_str().unwrap_or("ok").to_string();
                            reply_exec_count = msg.content.get("execution_count").and_then(|v| v.as_u64()).map(|v| v as u32);
                            shell_done = true;
                        }
                        "complete_reply" => {
                            let msg_id = msg.parent_header.get("msg_id").and_then(|v| v.as_str()).unwrap_or("").to_string();
                            let matches = msg.content["matches"]
                                .as_array()
                                .map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect())
                                .unwrap_or_default();
                            let cursor_start = msg.content["cursor_start"].as_u64().unwrap_or(0) as u32;
                            let cursor_end = msg.content["cursor_end"].as_u64().unwrap_or(0) as u32;
                            let _ = event_tx.send(Event::CompleteReply {
                                kernel_id: kernel_id.clone(), msg_id,
                                matches, cursor_start, cursor_end,
                            }).await;
                        }
                        "inspect_reply" => {
                            let msg_id = msg.parent_header.get("msg_id").and_then(|v| v.as_str()).unwrap_or("").to_string();
                            let found = msg.content["found"].as_bool().unwrap_or(false);
                            let mut text = String::new();
                            if found {
                                if let Some(data) = msg.content.get("data") {
                                    text = data.get("text/plain").and_then(|v| v.as_str()).unwrap_or("").to_string();
                                }
                            }
                            let _ = event_tx.send(Event::InspectReply {
                                kernel_id: kernel_id.clone(), msg_id,
                                found, text,
                            }).await;
                        }
                        _ => {}
                    }
                }
            }
        }
        
        if shell_done && iopub_idle {
            if let Some(mid) = exec_msg_id.take() {
                let _ = event_tx.send(Event::ExecuteDone {
                    kernel_id: kernel_id.clone(), msg_id: mid, status: reply_status.clone(), execution_count: reply_exec_count,
                }).await;
                
                while let Some((next_msg_id, next_code)) = exec_queue.pop_front() {
                    if let Err(e) = client.send_execute_request(&next_msg_id, &next_code).await {
                        let _ = event_tx.send(Event::Error { msg: e.to_string() }).await;
                    } else {
                        exec_msg_id = Some(next_msg_id);
                        iopub_idle = false;
                        shell_done = false;
                        reply_exec_count = None;
                        break;
                    }
                }
            }
        }
    }
}
