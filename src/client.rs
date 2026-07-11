use anyhow::{anyhow, Result};
use bytes::Bytes;
use serde_json::json;
use std::convert::TryFrom;
use std::time::Duration;
use tokio::time::timeout;
use zeromq::{DealerSocket, ReqSocket, Socket, SocketRecv, SocketSend, SubSocket, ZmqMessage};

use crate::wire::{self, JupyterMessage};

pub struct KernelClient {
    pub shell: DealerSocket,
    pub iopub: SubSocket,
    pub control: DealerSocket,
    pub hb: ReqSocket,
    pub key: String,
    pub session: String,
}

impl KernelClient {
    pub async fn connect(conn: &crate::kernel::ConnectionFile) -> Result<Self> {
        let session = uuid::Uuid::new_v4().to_string();

        let mut shell = DealerSocket::new();
        shell.connect(&conn.shell_addr()).await?;

        let mut iopub = SubSocket::new();
        iopub.connect(&conn.iopub_addr()).await?;
        iopub.subscribe("").await?;

        let mut control = DealerSocket::new();
        control.connect(&conn.control_addr()).await?;

        let mut hb = ReqSocket::new();
        hb.connect(&conn.hb_addr()).await?;

        Ok(KernelClient {
            shell, iopub, control, hb,
            key: conn.key.clone(),
            session,
        })
    }

    pub async fn heartbeat(&mut self, secs: u64) -> Result<()> {
        let ping = ZmqMessage::from(b"ping".to_vec());
        self.hb.send(ping).await?;
        let _pong = timeout(Duration::from_secs(secs), self.hb.recv()).await
            .map_err(|_| anyhow!("heartbeat timeout after {}s", secs))??;
        Ok(())
    }

    pub async fn send_execute_request(&mut self, msg_id: &str, code: &str) -> Result<()> {
        let content = json!({
            "code": code,
            "silent": false,
            "store_history": true,
            "user_expressions": {},
            "allow_stdin": false,
            "stop_on_error": true,
        });
        let mut msg = JupyterMessage::new("execute_request", &self.session, content);
        msg.header["msg_id"] = serde_json::Value::String(msg_id.to_string());

        let frames = wire::encode(&msg, &self.key);
        let zmq_msg = ZmqMessage::try_from(frames)
            .map_err(|_| anyhow!("empty message"))?;
        self.shell.send(zmq_msg).await?;
        Ok(())
    }

    pub async fn send_complete_request(&mut self, msg_id: &str, code: &str, cursor_pos: u32) -> Result<()> {
        let content = json!({
            "code": code,
            "cursor_pos": cursor_pos,
        });
        let mut msg = JupyterMessage::new("complete_request", &self.session, content);
        msg.header["msg_id"] = serde_json::Value::String(msg_id.to_string());
        let frames = wire::encode(&msg, &self.key);
        let zmq_msg = ZmqMessage::try_from(frames).map_err(|_| anyhow!("empty msg"))?;
        self.shell.send(zmq_msg).await?;
        Ok(())
    }

    pub async fn send_inspect_request(&mut self, msg_id: &str, code: &str, cursor_pos: u32, detail_level: u32) -> Result<()> {
        let content = json!({
            "code": code,
            "cursor_pos": cursor_pos,
            "detail_level": detail_level,
        });
        let mut msg = JupyterMessage::new("inspect_request", &self.session, content);
        msg.header["msg_id"] = serde_json::Value::String(msg_id.to_string());
        let frames = wire::encode(&msg, &self.key);
        let zmq_msg = ZmqMessage::try_from(frames).map_err(|_| anyhow!("empty msg"))?;
        self.shell.send(zmq_msg).await?;
        Ok(())
    }

    pub async fn recv_iopub(&mut self) -> Result<JupyterMessage> {
        let zmq_msg: ZmqMessage = self.iopub.recv().await?;
        let frames: Vec<Bytes> = zmq_msg.into_vec();
        wire::decode_iopub(&frames, &self.key)
    }

    pub async fn recv_shell(&mut self) -> Result<JupyterMessage> {
        let zmq_msg: ZmqMessage = self.shell.recv().await?;
        let frames: Vec<Bytes> = zmq_msg.into_vec();
        wire::decode_shell(&frames, &self.key)
    }

    pub async fn send_shutdown(&mut self, restart: bool) -> Result<()> {
        let content = json!({ "restart": restart });
        let msg = JupyterMessage::new("shutdown_request", &self.session, content);
        let frames = wire::encode(&msg, &self.key);
        let zmq_msg = ZmqMessage::try_from(frames)
            .map_err(|_| anyhow!("empty message"))?;
        self.control.send(zmq_msg).await?;
        Ok(())
    }

    pub fn extract_text(msg: &JupyterMessage) -> Option<String> {
        msg.content.get("data")
            .and_then(|d| d.get("text/plain"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
    }

    pub fn extract_image_png(msg: &JupyterMessage) -> Option<String> {
        msg.content.get("data")
            .and_then(|d| d.get("image/png"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
    }
}
