#![cfg(feature = "integration")]

use std::time::Duration;
use tokio::time::timeout;

#[tokio::test]
async fn execute_one_plus_one() {
    let runtime_dir = std::env::temp_dir().join("nvim-jupyter-integration-test");
    std::fs::create_dir_all(&runtime_dir).unwrap();

    let proc = nvim_jupyter::kernel::KernelProcess::spawn("python3", "/tmp", &runtime_dir)
        .await
        .expect("failed to spawn python3 kernel — is ipykernel installed?");

    tokio::time::sleep(Duration::from_millis(800)).await;

    let mut client = nvim_jupyter::client::KernelClient::connect(&proc.conn)
        .await
        .expect("ZMQ connect failed");

    client.heartbeat(5).await.expect("heartbeat failed");

    let msg_id = "test-msg-1";
    client.send_execute_request(msg_id, "1+1").await.expect("send failed");

    // Completion requires BOTH the shell execute_reply and the iopub idle
    // status. The idle status is published after all output, so draining until
    // idle guarantees we see execute_result. Breaking on execute_reply alone
    // races against the iopub output and can miss the result.
    let mut result_text = None;
    let mut reply_seen = false;
    let mut idle_seen = false;
    for _ in 0..50 {
        let iopub = timeout(Duration::from_millis(100), client.recv_iopub()).await;
        if let Ok(Ok(msg)) = iopub {
            match msg.msg_type() {
                "execute_result" => {
                    result_text = nvim_jupyter::client::KernelClient::extract_text(&msg);
                }
                "status" => {
                    if msg.content.get("execution_state").and_then(|v| v.as_str()) == Some("idle") {
                        idle_seen = true;
                    }
                }
                _ => {}
            }
        }

        if !reply_seen {
            let shell = timeout(Duration::from_millis(10), client.recv_shell()).await;
            if let Ok(Ok(msg)) = shell {
                if msg.msg_type() == "execute_reply" {
                    reply_seen = true;
                }
            }
        }

        if reply_seen && idle_seen { break; }
    }
    let done = reply_seen && idle_seen;

    proc.kill().await;

    assert_eq!(result_text.as_deref(), Some("2"), "expected 1+1=2");
    assert!(done, "never received execute_reply");
}
