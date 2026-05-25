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

    let mut result_text = None;
    let mut done = false;
    for _ in 0..30 {
        let iopub = timeout(Duration::from_millis(100), client.recv_iopub()).await;
        if let Ok(Ok(msg)) = iopub {
            if msg.msg_type() == "execute_result" {
                result_text = nvim_jupyter::client::KernelClient::extract_text(&msg);
            }
        }

        let shell = timeout(Duration::from_millis(10), client.recv_shell()).await;
        if let Ok(Ok(msg)) = shell {
            if msg.msg_type() == "execute_reply" {
                done = true;
            }
        }

        if done { break; }
    }

    proc.kill().await;

    assert_eq!(result_text.as_deref(), Some("2"), "expected 1+1=2");
    assert!(done, "never received execute_reply");
}
