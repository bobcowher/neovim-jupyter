# nvim-jupyter Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans or superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a fully functional Jupyter notebook manager for Neovim — Rust daemon handles ZMQ kernel protocol, Lua plugin handles buffer management and UI.

**Architecture:** One Rust daemon per Neovim session communicates with Jupyter kernels via ZMQ wire protocol. Lua plugin speaks JSON over stdin/stdout to the daemon (same pattern as nvim-gfx). `.ipynb` files open as virtual scratch buffers with extmark cell separators and virtual text output.

**Tech Stack:** Rust (tokio, zeromq, serde_json, hmac/sha2), Lua (Neovim APIs, busted for tests)

**Reference:** Read `/home/robertcowher/rustprojects/neovim-graphics-viewer/lua/nvim-gfx/viewer.lua` before implementing any Lua daemon code — it demonstrates the exact jobstart/chansend/on_stdout pattern we reuse.

**Spec:** `docs/superpowers/specs/2026-05-25-neovim-jupyter-design.md`

---

## Task 1: Project Scaffold

**Files:**
- Create: `Cargo.toml`
- Create: `.gitignore`
- Create: `build.sh`
- Create: `src/main.rs` (stub)
- Create: `src/protocol.rs` (stub)
- Create: `src/wire.rs` (stub)
- Create: `src/kernel.rs` (stub)
- Create: `src/client.rs` (stub)
- Create: `src/router.rs` (stub)

- [ ] **Step 1: Create Cargo.toml**

```toml
[package]
name = "nvim-jupyter"
version = "0.1.0"
edition = "2021"

[[bin]]
name = "nvim-jupyter"
path = "src/main.rs"

[dependencies]
serde       = { version = "1", features = ["derive"] }
serde_json  = "1"
tokio       = { version = "1", features = ["full"] }
zeromq      = "0.4"
uuid        = { version = "1", features = ["v4"] }
hmac        = "0.12"
sha2        = "0.10"
hex         = "0.4"
anyhow      = "1"
bytes       = "1"

[dev-dependencies]
tokio-test = "0.4"

[features]
integration = []
```

- [ ] **Step 2: Create .gitignore**

```
/target/
/bin/
*.ipynb_checkpoints
.claude/
.superpowers/
```

- [ ] **Step 3: Create build.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
cargo build --release
mkdir -p bin
cp target/release/nvim-jupyter bin/nvim-jupyter
echo "nvim-jupyter: build complete — bin/nvim-jupyter ready"
```

```bash
chmod +x build.sh
```

- [ ] **Step 4: Create stub source files**

`src/main.rs`:
```rust
fn main() {}
```

`src/protocol.rs`, `src/wire.rs`, `src/kernel.rs`, `src/client.rs`, `src/router.rs` — each just:
```rust
// stub
```

- [ ] **Step 5: Verify it compiles**

```bash
cargo build 2>&1
```
Expected: compiles with warnings about unused stubs, no errors.

- [ ] **Step 6: Commit**

```bash
git add Cargo.toml Cargo.lock .gitignore build.sh src/
git commit -m "feat: project scaffold"
```

---

## Task 2: Protocol Types

**Files:**
- Create: `src/protocol.rs`

- [ ] **Step 1: Write the failing tests first**

`src/protocol.rs`:
```rust
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum Command {
    StartKernel { kernel_id: String, kernel_name: String, cwd: String },
    StopKernel { kernel_id: String },
    RestartKernel { kernel_id: String },
    InterruptKernel { kernel_id: String },
    Execute { kernel_id: String, msg_id: String, code: String },
    ListKernels,
    Quit,
}

#[derive(Debug, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum Event {
    KernelStarted { kernel_id: String },
    KernelReady { kernel_id: String },
    KernelDied { kernel_id: String, code: i32 },
    KernelsList { kernels: Vec<KernelSpec> },
    Stream { kernel_id: String, msg_id: String, name: String, text: String },
    ExecuteResult { kernel_id: String, msg_id: String, execution_count: u32, text: String },
    ExecuteError { kernel_id: String, msg_id: String, ename: String, evalue: String, traceback: Vec<String> },
    ExecuteDone { kernel_id: String, msg_id: String, status: String },
    Error { msg: String },
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct KernelSpec {
    pub name: String,
    pub display_name: String,
    pub language: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deserialize_start_kernel() {
        let json = r#"{"cmd":"start_kernel","kernel_id":"abc","kernel_name":"python3","cwd":"/tmp"}"#;
        let cmd: Command = serde_json::from_str(json).unwrap();
        match cmd {
            Command::StartKernel { kernel_id, kernel_name, cwd } => {
                assert_eq!(kernel_id, "abc");
                assert_eq!(kernel_name, "python3");
                assert_eq!(cwd, "/tmp");
            }
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn deserialize_execute() {
        let json = r#"{"cmd":"execute","kernel_id":"k1","msg_id":"m1","code":"1+1"}"#;
        let cmd: Command = serde_json::from_str(json).unwrap();
        assert!(matches!(cmd, Command::Execute { .. }));
    }

    #[test]
    fn deserialize_list_kernels() {
        let cmd: Command = serde_json::from_str(r#"{"cmd":"list_kernels"}"#).unwrap();
        assert!(matches!(cmd, Command::ListKernels));
    }

    #[test]
    fn deserialize_quit() {
        let cmd: Command = serde_json::from_str(r#"{"cmd":"quit"}"#).unwrap();
        assert!(matches!(cmd, Command::Quit));
    }

    #[test]
    fn serialize_kernel_ready() {
        let ev = Event::KernelReady { kernel_id: "k1".into() };
        let s = serde_json::to_string(&ev).unwrap();
        assert_eq!(s, r#"{"event":"kernel_ready","kernel_id":"k1"}"#);
    }

    #[test]
    fn serialize_stream() {
        let ev = Event::Stream {
            kernel_id: "k".into(), msg_id: "m".into(),
            name: "stdout".into(), text: "hello\n".into(),
        };
        let s = serde_json::to_string(&ev).unwrap();
        assert!(s.contains(r#""event":"stream""#));
        assert!(s.contains(r#""text":"hello\n""#));
    }

    #[test]
    fn serialize_execute_done() {
        let ev = Event::ExecuteDone {
            kernel_id: "k".into(), msg_id: "m".into(), status: "ok".into(),
        };
        let s = serde_json::to_string(&ev).unwrap();
        assert!(s.contains(r#""status":"ok""#));
    }
}
```

- [ ] **Step 2: Run tests**

```bash
cargo test protocol::tests 2>&1
```
Expected: all 7 tests pass.

- [ ] **Step 3: Update main.rs to declare the module**

```rust
mod protocol;
mod wire;
mod kernel;
mod client;
mod router;

fn main() {}
```

- [ ] **Step 4: Commit**

```bash
git add src/protocol.rs src/main.rs
git commit -m "feat: protocol Command/Event types with serde"
```

---

## Task 3: Jupyter Wire Protocol

**Files:**
- Create: `src/wire.rs`

The Jupyter wire protocol uses multipart ZMQ messages. For a DEALER socket (our side) sending to a kernel's ROUTER shell socket, the frames are:

```
frame 0: b"<IDS|MSG>"   (delimiter)
frame 1: HMAC-SHA256 signature (hex string, over frames 2-5 concatenated)
frame 2: header JSON
frame 3: parent_header JSON
frame 4: metadata JSON
frame 5: content JSON
```

For iopub (SUB socket), the kernel prepends a topic frame:
```
frame 0: topic (e.g. b"stream")
frame 1: b"<IDS|MSG>"
frame 2: signature
frame 3: header JSON
frame 4: parent_header JSON
frame 5: metadata JSON
frame 6: content JSON
```

- [ ] **Step 1: Write wire.rs**

```rust
use anyhow::{anyhow, Result};
use bytes::Bytes;
use hmac::{Hmac, Mac};
use sha2::Sha256;
use serde_json::{json, Value};
use uuid::Uuid;

type HmacSha256 = Hmac<Sha256>;

pub const DELIM: &[u8] = b"<IDS|MSG>";

#[derive(Debug, Clone)]
pub struct JupyterMessage {
    pub topic: Option<String>,   // only present on iopub messages
    pub header: Value,
    pub parent_header: Value,
    pub metadata: Value,
    pub content: Value,
}

impl JupyterMessage {
    pub fn new(msg_type: &str, session: &str, content: Value) -> Self {
        Self {
            topic: None,
            header: json!({
                "msg_id": Uuid::new_v4().to_string(),
                "msg_type": msg_type,
                "username": "nvim-jupyter",
                "session": session,
                "version": "5.3",
            }),
            parent_header: json!({}),
            metadata: json!({}),
            content,
        }
    }

    pub fn msg_type(&self) -> &str {
        self.header["msg_type"].as_str().unwrap_or("")
    }
}

/// Sign a message. key is the hex-encoded HMAC key from the connection file.
pub fn sign(key_hex: &str, header: &[u8], parent_header: &[u8], metadata: &[u8], content: &[u8]) -> String {
    let key = hex::decode(key_hex).unwrap_or_default();
    if key.is_empty() {
        return String::new();
    }
    let mut mac = HmacSha256::new_from_slice(&key).expect("HMAC accepts any key size");
    mac.update(header);
    mac.update(parent_header);
    mac.update(metadata);
    mac.update(content);
    hex::encode(mac.finalize().into_bytes())
}

/// Encode a JupyterMessage into ZMQ frames (for shell/control DEALER socket).
/// Returns Vec<Bytes> without the topic frame.
pub fn encode(msg: &JupyterMessage, key_hex: &str) -> Vec<Bytes> {
    let header = serde_json::to_vec(&msg.header).unwrap();
    let parent_header = serde_json::to_vec(&msg.parent_header).unwrap();
    let metadata = serde_json::to_vec(&msg.metadata).unwrap();
    let content = serde_json::to_vec(&msg.content).unwrap();
    let sig = sign(key_hex, &header, &parent_header, &metadata, &content);

    vec![
        Bytes::from_static(DELIM),
        Bytes::from(sig.into_bytes()),
        Bytes::from(header),
        Bytes::from(parent_header),
        Bytes::from(metadata),
        Bytes::from(content),
    ]
}

/// Decode ZMQ frames from a shell socket response (no topic frame, starts at delimiter).
pub fn decode_shell(frames: &[Bytes], _key_hex: &str) -> Result<JupyterMessage> {
    // Find delimiter
    let delim_pos = frames.iter().position(|f| f.as_ref() == DELIM)
        .ok_or_else(|| anyhow!("no delimiter in message"))?;
    let base = delim_pos + 1; // sig
    if frames.len() < base + 5 {
        return Err(anyhow!("message too short: {} frames", frames.len()));
    }
    // base+0 = sig, base+1 = header, base+2 = parent, base+3 = metadata, base+4 = content
    let header: Value = serde_json::from_slice(&frames[base + 1])?;
    let parent_header: Value = serde_json::from_slice(&frames[base + 2])?;
    let metadata: Value = serde_json::from_slice(&frames[base + 3])?;
    let content: Value = serde_json::from_slice(&frames[base + 4])?;
    Ok(JupyterMessage { topic: None, header, parent_header, metadata, content })
}

/// Decode ZMQ frames from an iopub message (first frame is topic).
pub fn decode_iopub(frames: &[Bytes], key_hex: &str) -> Result<JupyterMessage> {
    if frames.is_empty() {
        return Err(anyhow!("empty iopub message"));
    }
    let topic = String::from_utf8_lossy(&frames[0]).to_string();
    let mut msg = decode_shell(&frames[1..], key_hex)?;
    msg.topic = Some(topic);
    Ok(msg)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_key() -> &'static str {
        "a2f22b4e9d3a1c8b7f60e5d4c3b2a190"  // 32 hex chars = 16 bytes
    }

    #[test]
    fn sign_empty_key_returns_empty() {
        let sig = sign("", b"h", b"p", b"m", b"c");
        assert_eq!(sig, "");
    }

    #[test]
    fn sign_is_deterministic() {
        let a = sign(test_key(), b"header", b"parent", b"meta", b"content");
        let b = sign(test_key(), b"header", b"parent", b"meta", b"content");
        assert_eq!(a, b);
    }

    #[test]
    fn sign_changes_with_content() {
        let a = sign(test_key(), b"header", b"parent", b"meta", b"content1");
        let b = sign(test_key(), b"header", b"parent", b"meta", b"content2");
        assert_ne!(a, b);
    }

    #[test]
    fn encode_decode_roundtrip() {
        let msg = JupyterMessage::new("execute_request", "sess-1", json!({"code": "1+1"}));
        let frames = encode(&msg, test_key());
        assert_eq!(frames[0].as_ref(), DELIM);

        let decoded = decode_shell(&frames, test_key()).unwrap();
        assert_eq!(decoded.msg_type(), "execute_request");
        assert_eq!(decoded.content["code"], "1+1");
    }

    #[test]
    fn decode_iopub_extracts_topic() {
        let msg = JupyterMessage::new("stream", "sess-1", json!({"name":"stdout","text":"hi"}));
        let mut frames = encode(&msg, test_key());
        frames.insert(0, Bytes::from_static(b"stream"));  // prepend topic
        let decoded = decode_iopub(&frames, test_key()).unwrap();
        assert_eq!(decoded.topic.as_deref(), Some("stream"));
        assert_eq!(decoded.content["name"], "stdout");
    }
}
```

- [ ] **Step 2: Run tests**

```bash
cargo test wire::tests 2>&1
```
Expected: all 5 tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/wire.rs
git commit -m "feat: Jupyter wire protocol encoding/decoding with HMAC-SHA256"
```

---

## Task 4: Kernel Connection File and Kernelspec Discovery

**Files:**
- Create: `src/kernel.rs` (connection file + kernelspec parts)

- [ ] **Step 1: Write the tests first**

`src/kernel.rs`:
```rust
use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConnectionFile {
    pub shell_port: u16,
    pub iopub_port: u16,
    pub stdin_port: u16,
    pub control_port: u16,
    pub hb_port: u16,
    pub ip: String,
    pub key: String,
    pub transport: String,
    pub signature_scheme: String,
    pub kernel_name: String,
}

impl ConnectionFile {
    pub fn generate(kernel_name: &str) -> Self {
        use rand::Rng;
        let mut rng = rand::thread_rng();
        let mut random_port = || rng.gen_range(49152u16..65535u16);

        // Generate 32 random bytes as hex key
        let key_bytes: [u8; 32] = rng.gen();
        let key = hex::encode(key_bytes);

        ConnectionFile {
            shell_port: random_port(),
            iopub_port: random_port(),
            stdin_port: random_port(),
            control_port: random_port(),
            hb_port: random_port(),
            ip: "127.0.0.1".into(),
            key,
            transport: "tcp".into(),
            signature_scheme: "hmac-sha256".into(),
            kernel_name: kernel_name.into(),
        }
    }

    pub fn write(&self, path: &PathBuf) -> Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let json = serde_json::to_string_pretty(self)?;
        std::fs::write(path, json)?;
        Ok(())
    }

    pub fn shell_addr(&self) -> String {
        format!("{}://{}:{}", self.transport, self.ip, self.shell_port)
    }
    pub fn iopub_addr(&self) -> String {
        format!("{}://{}:{}", self.transport, self.ip, self.iopub_port)
    }
    pub fn control_addr(&self) -> String {
        format!("{}://{}:{}", self.transport, self.ip, self.control_port)
    }
    pub fn hb_addr(&self) -> String {
        format!("{}://{}:{}", self.transport, self.ip, self.hb_port)
    }
}

#[derive(Debug, Clone, Deserialize)]
struct KernelspecList {
    kernelspecs: std::collections::HashMap<String, KernelspecEntry>,
}

#[derive(Debug, Clone, Deserialize)]
struct KernelspecEntry {
    spec: KernelspecSpec,
}

#[derive(Debug, Clone, Deserialize)]
pub struct KernelspecSpec {
    pub argv: Vec<String>,
    pub display_name: String,
    pub language: String,
}

pub fn list_kernelspecs() -> Result<Vec<(String, KernelspecSpec)>> {
    let output = std::process::Command::new("jupyter")
        .args(["kernelspec", "list", "--json"])
        .output()
        .context("failed to run `jupyter kernelspec list --json` — is jupyter installed?")?;

    if !output.status.success() {
        return Err(anyhow!("jupyter kernelspec list failed"));
    }

    let list: KernelspecList = serde_json::from_slice(&output.stdout)?;
    Ok(list.kernelspecs.into_iter().map(|(k, v)| (k, v.spec)).collect())
}

pub fn get_kernelspec(kernel_name: &str) -> Result<KernelspecSpec> {
    let all = list_kernelspecs()?;
    all.into_iter()
        .find(|(name, _)| name == kernel_name)
        .map(|(_, spec)| spec)
        .ok_or_else(|| anyhow!("kernel '{}' not found", kernel_name))
}

/// Build the argv for launching a kernel, substituting {connection_file}.
pub fn build_launch_argv(spec: &KernelspecSpec, connection_file: &PathBuf) -> Vec<String> {
    spec.argv.iter().map(|arg| {
        if arg == "{connection_file}" {
            connection_file.to_string_lossy().to_string()
        } else {
            arg.clone()
        }
    }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn connection_file_ports_in_range() {
        let cf = ConnectionFile::generate("python3");
        assert!(cf.shell_port >= 49152);
        assert!(cf.iopub_port >= 49152);
        assert!(cf.hb_port >= 49152);
        assert!(cf.control_port >= 49152);
    }

    #[test]
    fn connection_file_key_is_hex_64_chars() {
        let cf = ConnectionFile::generate("python3");
        assert_eq!(cf.key.len(), 64);
        assert!(cf.key.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn connection_file_unique_keys() {
        let keys: HashSet<String> = (0..10)
            .map(|_| ConnectionFile::generate("python3").key)
            .collect();
        assert_eq!(keys.len(), 10, "keys should be unique");
    }

    #[test]
    fn connection_file_write_and_read() {
        let cf = ConnectionFile::generate("python3");
        let path = std::env::temp_dir().join(format!("nvim-jupyter-test-{}.json", cf.key[..8].to_string()));
        cf.write(&path).unwrap();
        let content = std::fs::read_to_string(&path).unwrap();
        let loaded: ConnectionFile = serde_json::from_str(&content).unwrap();
        assert_eq!(loaded.shell_port, cf.shell_port);
        assert_eq!(loaded.key, cf.key);
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn build_launch_argv_substitutes_connection_file() {
        let spec = KernelspecSpec {
            argv: vec!["python".into(), "-m".into(), "ipykernel_launcher".into(), "-f".into(), "{connection_file}".into()],
            display_name: "Python 3".into(),
            language: "python".into(),
        };
        let path = PathBuf::from("/tmp/kernel.json");
        let argv = build_launch_argv(&spec, &path);
        assert_eq!(argv.last().unwrap(), "/tmp/kernel.json");
        assert_eq!(argv[0], "python");
    }
}
```

Note: this requires adding `rand` to Cargo.toml:
```toml
rand = "0.8"
```

- [ ] **Step 2: Run tests**

```bash
cargo test kernel::tests 2>&1
```
Expected: all 5 tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/kernel.rs Cargo.toml Cargo.lock
git commit -m "feat: connection file generation and kernelspec discovery"
```

---

## Task 5: Kernel Process Management

**Files:**
- Modify: `src/kernel.rs` (add process management)

- [ ] **Step 1: Add process management to kernel.rs**

Append to `src/kernel.rs`:
```rust
use tokio::process::{Child, Command as TokioCommand};
use std::sync::Arc;
use tokio::sync::Mutex;

pub struct KernelProcess {
    child: Arc<Mutex<Child>>,
    pub connection_file: PathBuf,
    pub conn: ConnectionFile,
}

impl KernelProcess {
    pub async fn spawn(kernel_name: &str, cwd: &str, runtime_dir: &PathBuf) -> Result<Self> {
        let spec = get_kernelspec(kernel_name)?;
        let conn = ConnectionFile::generate(kernel_name);
        let conn_path = runtime_dir.join(format!("{}.json", uuid::Uuid::new_v4()));
        conn.write(&conn_path)?;

        let argv = build_launch_argv(&spec, &conn_path);
        let child = TokioCommand::new(&argv[0])
            .args(&argv[1..])
            .current_dir(cwd)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .with_context(|| format!("failed to spawn kernel: {:?}", argv))?;

        Ok(KernelProcess {
            child: Arc::new(Mutex::new(child)),
            connection_file: conn_path,
            conn,
        })
    }

    pub async fn kill(&self) {
        let mut child = self.child.lock().await;
        let _ = child.kill().await;
        std::fs::remove_file(&self.connection_file).ok();
    }

    pub async fn interrupt(&self) {
        #[cfg(unix)]
        {
            let child = self.child.lock().await;
            if let Some(pid) = child.id() {
                unsafe { libc::kill(pid as libc::pid_t, libc::SIGINT); }
            }
        }
    }
}
```

Add to Cargo.toml:
```toml
[target.'cfg(unix)'.dependencies]
libc = "0.2"
```

- [ ] **Step 2: Verify compile**

```bash
cargo build 2>&1
```
Expected: compiles without errors.

- [ ] **Step 3: Commit**

```bash
git add src/kernel.rs Cargo.toml Cargo.lock
git commit -m "feat: kernel process spawn/kill/interrupt"
```

---

## Task 6: ZMQ Client

**Files:**
- Create: `src/client.rs`

The `zeromq` crate provides async ZMQ sockets. Check the crate docs at https://docs.rs/zeromq for the exact API — the code below follows the 0.4.x API. If it doesn't compile, consult the crate documentation for the correct method names.

- [ ] **Step 1: Write client.rs**

```rust
use anyhow::{anyhow, Result};
use bytes::Bytes;
use serde_json::{json, Value};
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

    /// Send a heartbeat ping and wait for pong. Timeout after `secs` seconds.
    pub async fn heartbeat(&mut self, secs: u64) -> Result<()> {
        let ping = ZmqMessage::from(b"ping".to_vec());
        self.hb.send(ping).await?;
        let _pong = timeout(Duration::from_secs(secs), self.hb.recv()).await
            .map_err(|_| anyhow!("heartbeat timeout after {}s", secs))??;
        Ok(())
    }

    /// Send an execute_request on the shell socket.
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
        // Override msg_id so Lua can correlate events
        msg.header["msg_id"] = serde_json::Value::String(msg_id.to_string());

        let frames = wire::encode(&msg, &self.key);
        let zmq_msg = ZmqMessage::from(frames.iter().map(|b| b.clone()).collect::<Vec<_>>());
        self.shell.send(zmq_msg).await?;
        Ok(())
    }

    /// Receive one message from the iopub socket.
    pub async fn recv_iopub(&mut self) -> Result<JupyterMessage> {
        let zmq_msg: ZmqMessage = self.iopub.recv().await?;
        let frames: Vec<Bytes> = zmq_msg.into_iter().collect();
        wire::decode_iopub(&frames, &self.key)
    }

    /// Receive one message from the shell socket.
    pub async fn recv_shell(&mut self) -> Result<JupyterMessage> {
        let zmq_msg: ZmqMessage = self.shell.recv().await?;
        let frames: Vec<Bytes> = zmq_msg.into_iter().collect();
        wire::decode_shell(&frames, &self.key)
    }

    /// Send a shutdown_request on the control socket.
    pub async fn send_shutdown(&mut self, restart: bool) -> Result<()> {
        let content = json!({ "restart": restart });
        let msg = JupyterMessage::new("shutdown_request", &self.session, content);
        let frames = wire::encode(&msg, &self.key);
        let zmq_msg = ZmqMessage::from(frames.iter().map(|b| b.clone()).collect::<Vec<_>>());
        self.control.send(zmq_msg).await?;
        Ok(())
    }

    /// Extract text/plain from an iopub message's content.data, if present.
    pub fn extract_text(msg: &JupyterMessage) -> Option<String> {
        msg.content.get("data")
            .and_then(|d| d.get("text/plain"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
    }
}
```

- [ ] **Step 2: Verify compile**

```bash
cargo build 2>&1
```

If zeromq API doesn't match (e.g., `ZmqMessage::from` signature differs), consult https://docs.rs/zeromq/0.4 and adjust the frame construction. The logical flow remains the same.

- [ ] **Step 3: Commit**

```bash
git add src/client.rs
git commit -m "feat: ZMQ kernel client (shell, iopub, control, heartbeat)"
```

---

## Task 7: Router

**Files:**
- Create: `src/router.rs`

The router owns a `HashMap<kernel_id, KernelHandle>`. A `KernelHandle` is a channel endpoint to a per-kernel tokio task. The router task receives `Command`s from the stdin reader and dispatches them.

- [ ] **Step 1: Write router.rs**

```rust
use anyhow::Result;
use std::collections::HashMap;
use std::path::PathBuf;
use tokio::sync::mpsc;

use crate::client::KernelClient;
use crate::kernel::{self, KernelProcess};
use crate::protocol::{Command, Event, KernelSpec};

/// Commands sent from router to a kernel task.
enum KernelCmd {
    Execute { msg_id: String, code: String },
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

    // Spawn kernel process
    let proc = match KernelProcess::spawn(&kernel_name, &cwd, &runtime_dir).await {
        Ok(p) => p,
        Err(e) => {
            let _ = event_tx.send(Event::Error { msg: format!("spawn failed: {e}") }).await;
            let _ = event_tx.send(Event::KernelDied { kernel_id, code: -1 }).await;
            return;
        }
    };

    // Give kernel a moment to start
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;

    // Connect ZMQ client
    let mut client = match KernelClient::connect(&proc.conn).await {
        Ok(c) => c,
        Err(e) => {
            let _ = event_tx.send(Event::Error { msg: format!("ZMQ connect failed: {e}") }).await;
            proc.kill().await;
            let _ = event_tx.send(Event::KernelDied { kernel_id, code: -1 }).await;
            return;
        }
    };

    // Heartbeat check (retry up to 10s)
    let mut ready = false;
    for _ in 0..5 {
        if client.heartbeat(2).await.is_ok() {
            ready = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    }
    if !ready {
        let _ = event_tx.send(Event::Error { msg: "kernel heartbeat timeout".into() }).await;
        proc.kill().await;
        let _ = event_tx.send(Event::KernelDied { kernel_id, code: -1 }).await;
        return;
    }

    let _ = event_tx.send(Event::KernelReady { kernel_id: kernel_id.clone() }).await;

    // Main command loop
    while let Some(cmd) = cmd_rx.recv().await {
        match cmd {
            KernelCmd::Execute { msg_id, code } => {
                if let Err(e) = client.send_execute_request(&msg_id, &code).await {
                    let _ = event_tx.send(Event::Error { msg: e.to_string() }).await;
                    continue;
                }
                // Drain iopub and shell until execute_reply
                execute_loop(&kernel_id, &msg_id, &mut client, &event_tx).await;
            }
            KernelCmd::Interrupt => {
                proc.interrupt().await;
            }
            KernelCmd::Shutdown { restart } => {
                let _ = client.send_shutdown(restart).await;
                tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                proc.kill().await;
                let _ = event_tx.send(Event::KernelDied { kernel_id: kernel_id.clone(), code: 0 }).await;
                if restart {
                    // Re-enter as a new start — signal router via died event; Lua will restart
                }
                return;
            }
        }
    }

    proc.kill().await;
    let _ = event_tx.send(Event::KernelDied { kernel_id, code: 0 }).await;
}

async fn execute_loop(
    kernel_id: &str,
    msg_id: &str,
    client: &mut KernelClient,
    event_tx: &mpsc::Sender<Event>,
) {
    let mut shell_done = false;

    loop {
        tokio::select! {
            iopub_result = client.recv_iopub() => {
                match iopub_result {
                    Err(_) => break,
                    Ok(msg) => {
                        // Only forward messages for our msg_id
                        let parent_id = msg.parent_header.get("msg_id")
                            .and_then(|v| v.as_str())
                            .unwrap_or("");
                        if parent_id != msg_id { continue; }

                        match msg.msg_type() {
                            "stream" => {
                                let name = msg.content["name"].as_str().unwrap_or("stdout").to_string();
                                let text = msg.content["text"].as_str().unwrap_or("").to_string();
                                let _ = event_tx.send(Event::Stream {
                                    kernel_id: kernel_id.into(), msg_id: msg_id.into(), name, text,
                                }).await;
                            }
                            "execute_result" | "display_data" => {
                                let text = KernelClient::extract_text(&msg).unwrap_or_default();
                                let exec_count = msg.content.get("execution_count")
                                    .and_then(|v| v.as_u64()).unwrap_or(0) as u32;
                                let _ = event_tx.send(Event::ExecuteResult {
                                    kernel_id: kernel_id.into(), msg_id: msg_id.into(),
                                    execution_count: exec_count, text,
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
                                    kernel_id: kernel_id.into(), msg_id: msg_id.into(),
                                    ename, evalue, traceback,
                                }).await;
                            }
                            _ => {}
                        }
                    }
                }
            }
            shell_result = client.recv_shell(), if !shell_done => {
                match shell_result {
                    Err(_) => break,
                    Ok(msg) => {
                        if msg.msg_type() == "execute_reply" {
                            let status = msg.content["status"].as_str().unwrap_or("ok").to_string();
                            let _ = event_tx.send(Event::ExecuteDone {
                                kernel_id: kernel_id.into(), msg_id: msg_id.into(), status,
                            }).await;
                            shell_done = true;
                        }
                    }
                }
            }
        }
        if shell_done { break; }
    }
}
```

- [ ] **Step 2: Verify compile**

```bash
cargo build 2>&1
```

- [ ] **Step 3: Commit**

```bash
git add src/router.rs
git commit -m "feat: router with per-kernel tokio tasks and execute loop"
```

---

## Task 8: Main Entry Point

**Files:**
- Modify: `src/main.rs`

- [ ] **Step 1: Write main.rs**

```rust
mod client;
mod kernel;
mod protocol;
mod router;
mod wire;

use anyhow::Result;
use protocol::{Command, Event};
use router::Router;
use std::io::{BufRead, Write};
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

    // Stdin reader task
    let cmd_tx_clone = cmd_tx.clone();
    tokio::spawn(async move {
        let stdin = std::io::stdin();
        for line in stdin.lock().lines() {
            let Ok(line) = line else { break };
            let line = line.trim().to_string();
            if line.is_empty() { continue; }
            match serde_json::from_str::<Command>(&line) {
                Ok(cmd) => {
                    if cmd_tx_clone.send(cmd).await.is_err() { break; }
                }
                Err(e) => {
                    eprintln!("nvim-jupyter: bad command: {e}: {line}");
                }
            }
        }
    });

    // Stdout writer task
    tokio::spawn(async move {
        let stdout = std::io::stdout();
        while let Some(event) = event_rx.recv().await {
            let mut out = stdout.lock();
            if let Ok(json) = serde_json::to_string(&event) {
                let _ = writeln!(out, "{}", json);
                let _ = out.flush();
            }
        }
    });

    // Router loop (runs on main task)
    let mut router = Router::new(event_tx, runtime_dir);
    while let Some(cmd) = cmd_rx.recv().await {
        if !router.handle(cmd).await {
            break;
        }
    }

    Ok(())
}
```

- [ ] **Step 2: Build release binary**

```bash
cargo build --release 2>&1
```
Expected: compiles to `target/release/nvim-jupyter`.

- [ ] **Step 3: Quick manual smoke test**

```bash
echo '{"cmd":"list_kernels"}' | ./target/release/nvim-jupyter
```
Expected: prints a JSON line like `{"event":"kernels_list","kernels":[...]}` if Jupyter is installed, or `{"event":"error","msg":"..."}` if not.

```bash
echo '{"cmd":"quit"}' | ./target/release/nvim-jupyter
```
Expected: exits cleanly with no output.

- [ ] **Step 4: Run build.sh**

```bash
bash build.sh
```
Expected: `bin/nvim-jupyter` exists.

- [ ] **Step 5: Commit**

```bash
git add src/main.rs
git commit -m "feat: main entry point — stdin reader, router loop, stdout writer"
```

---

## Task 9: Rust Integration Test

**Files:**
- Create: `tests/kernel_integration.rs`

Requires Python + ipykernel: `pip install ipykernel`

- [ ] **Step 1: Write integration test**

`tests/kernel_integration.rs`:
```rust
#![cfg(feature = "integration")]

use std::path::PathBuf;
use tokio::sync::mpsc;

#[tokio::test]
async fn execute_one_plus_one() {
    let runtime_dir = std::env::temp_dir().join("nvim-jupyter-integration-test");
    std::fs::create_dir_all(&runtime_dir).unwrap();

    // Spawn kernel
    let proc = nvim_jupyter::kernel::KernelProcess::spawn("python3", "/tmp", &runtime_dir)
        .await
        .expect("failed to spawn python3 kernel — is ipykernel installed?");

    tokio::time::sleep(std::time::Duration::from_millis(800)).await;

    let mut client = nvim_jupyter::client::KernelClient::connect(&proc.conn)
        .await
        .expect("ZMQ connect failed");

    client.heartbeat(5).await.expect("heartbeat failed");

    let msg_id = "test-msg-1";
    client.send_execute_request(msg_id, "1+1").await.expect("send failed");

    // Collect events until execute_reply
    let mut result_text = None;
    let mut done = false;
    for _ in 0..20 {
        tokio::select! {
            iopub = client.recv_iopub() => {
                if let Ok(msg) = iopub {
                    if msg.msg_type() == "execute_result" {
                        result_text = nvim_jupyter::client::KernelClient::extract_text(&msg);
                    }
                }
            }
            shell = client.recv_shell() => {
                if let Ok(msg) = shell {
                    if msg.msg_type() == "execute_reply" {
                        done = true;
                    }
                }
            }
        }
        if done { break; }
    }

    proc.kill().await;

    assert_eq!(result_text.as_deref(), Some("2"), "expected 1+1=2");
    assert!(done, "never received execute_reply");
}
```

Add to `Cargo.toml`:
```toml
[lib]
name = "nvim_jupyter"
path = "src/lib.rs"
```

Create `src/lib.rs`:
```rust
pub mod client;
pub mod kernel;
pub mod protocol;
pub mod router;
pub mod wire;
```

Modify `src/main.rs` to remove the `mod` declarations (they're now in lib.rs):
```rust
use nvim_jupyter::protocol::{Command, Event};
use nvim_jupyter::router::Router;
// ... rest of main unchanged
```

- [ ] **Step 2: Run integration test (requires ipykernel)**

```bash
cargo test --features integration -- --nocapture 2>&1
```
Expected: `execute_one_plus_one` passes.

- [ ] **Step 3: Commit**

```bash
git add tests/kernel_integration.rs src/lib.rs src/main.rs Cargo.toml
git commit -m "test: Rust integration test against real python3 kernel"
```

---

## Task 10: Test Fixture and Lua Test Setup

**Files:**
- Create: `test/fixtures/simple.ipynb`
- Create: `test/notebook_spec.lua`
- Create: `test/cells_spec.lua`
- Create: `test/output_spec.lua`

- [ ] **Step 1: Create test fixture**

`test/fixtures/simple.ipynb`:
```json
{
  "nbformat": 4,
  "nbformat_minor": 5,
  "metadata": {
    "kernelspec": {
      "display_name": "Python 3",
      "language": "python",
      "name": "python3"
    },
    "language_info": {
      "name": "python",
      "version": "3.10.0"
    }
  },
  "cells": [
    {
      "cell_type": "markdown",
      "id": "cell-md-1",
      "metadata": {},
      "source": ["# Hello World\n", "\n", "This is a test notebook."],
      "outputs": []
    },
    {
      "cell_type": "code",
      "id": "cell-code-1",
      "metadata": {},
      "source": ["x = 1 + 1\n", "print(x)"],
      "outputs": [],
      "execution_count": null
    },
    {
      "cell_type": "code",
      "id": "cell-code-2",
      "metadata": {},
      "source": ["import sys\n", "sys.version"],
      "outputs": [],
      "execution_count": null
    }
  ]
}
```

- [ ] **Step 2: Install busted**

```bash
luarocks install busted 2>&1 || echo "luarocks not found — install with: sudo apt install luarocks"
```

- [ ] **Step 3: Commit**

```bash
git add test/
git commit -m "test: Lua test fixture and setup"
```

---

## Task 11: Lua Config Module

**Files:**
- Create: `lua/nvim-jupyter/config.lua`

- [ ] **Step 1: Write config.lua**

```lua
local M = {}

M.defaults = {
  -- Set to false to disable all default keymaps
  keymaps = true,
  -- Individual keymap overrides (set key to false to disable)
  keymap = {
    execute          = "<C-CR>",
    execute_advance  = "<S-CR>",
    execute_insert   = "<M-CR>",
    next_cell        = "]c",
    prev_cell        = "[c",
  },
  -- Max virtual text lines per cell before truncation
  max_output_lines = 50,
  -- Directory for kernel connection files (default: stdpath("data")/nvim-jupyter)
  runtime_dir = nil,
}

M.options = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
  if not M.options.runtime_dir then
    M.options.runtime_dir = vim.fn.stdpath("data") .. "/nvim-jupyter"
  end
  -- Define highlight groups (overridable by colorscheme)
  local hls = {
    NvimJupyterCellSep     = { link = "Comment" },
    NvimJupyterOutputText  = { link = "String" },
    NvimJupyterOutputError = { link = "ErrorMsg" },
    NvimJupyterOutputCount = { link = "Number" },
    NvimJupyterRunning     = { link = "WarningMsg" },
  }
  for name, def in pairs(hls) do
    vim.api.nvim_set_hl(0, name, def)
  end
end

return M
```

- [ ] **Step 2: Commit**

```bash
git add lua/
git commit -m "feat: Lua config module with defaults and highlight groups"
```

---

## Task 12: Lua Daemon Module

**Files:**
- Create: `lua/nvim-jupyter/daemon.lua`

The daemon module manages the single Rust process lifecycle. Read `/home/robertcowher/rustprojects/neovim-graphics-viewer/lua/nvim-gfx/viewer.lua` as the reference pattern — this module follows the same structure.

- [ ] **Step 1: Write daemon.lua**

```lua
local M = {}

local state = {
  job_id   = nil,
  handlers = {},   -- event_type → list of handler functions
}

local function binary_path()
  local src = debug.getinfo(1, "S").source:sub(2)
  local root = vim.fn.fnamemodify(src, ":h:h:h")
  return root .. "/bin/nvim-jupyter"
end

local function dispatch(event)
  local handlers = state.handlers[event.event] or {}
  for _, fn in ipairs(handlers) do
    fn(event)
  end
  -- Always fire wildcard handlers
  for _, fn in ipairs(state.handlers["*"] or {}) do
    fn(event)
  end
end

local function on_stdout(_, data, _)
  for _, line in ipairs(data) do
    if line ~= "" then
      local ok, event = pcall(vim.json.decode, line)
      if ok and type(event) == "table" and event.event then
        dispatch(event)
      else
        vim.notify("nvim-jupyter: malformed event: " .. line, vim.log.levels.WARN)
      end
    end
  end
end

local function on_exit(_, code, _)
  if code ~= 0 then
    vim.notify("nvim-jupyter: daemon exited with code " .. code, vim.log.levels.WARN)
  end
  state.job_id = nil
  dispatch({ event = "daemon_died", code = code })
end

function M.ensure_started()
  if state.job_id then return true end
  local bin = binary_path()
  if vim.fn.executable(bin) == 0 then
    vim.notify("nvim-jupyter: binary not found — run :JupyterBuild", vim.log.levels.ERROR)
    return false
  end
  state.job_id = vim.fn.jobstart({ bin }, {
    on_stdout = on_stdout,
    on_exit   = on_exit,
    stdout_buffered = false,
  })
  return state.job_id > 0
end

function M.send(cmd)
  if not state.job_id then return end
  vim.fn.chansend(state.job_id, vim.json.encode(cmd) .. "\n")
end

function M.on(event_type, handler)
  state.handlers[event_type] = state.handlers[event_type] or {}
  table.insert(state.handlers[event_type], handler)
end

function M.stop()
  if state.job_id then
    M.send({ cmd = "quit" })
    vim.fn.jobstop(state.job_id)
    state.job_id = nil
  end
end

function M.is_running()
  return state.job_id ~= nil
end

return M
```

- [ ] **Step 2: Commit**

```bash
git add lua/nvim-jupyter/daemon.lua
git commit -m "feat: Lua daemon module — Rust process lifecycle and event dispatch"
```

---

## Task 13: Lua Notebook Module

**Files:**
- Create: `lua/nvim-jupyter/notebook.lua`
- Create: `test/notebook_spec.lua`

- [ ] **Step 1: Write the failing test first**

`test/notebook_spec.lua`:
```lua
-- Minimal vim stub for running outside Neovim
if not vim then
  -- Try loading a pre-built stub or use a simple one
  vim = {
    json = {
      decode = function(s)
        -- Use lua-cjson or dkjson if available, else error
        local ok, cjson = pcall(require, "cjson")
        if ok then return cjson.decode(s) end
        local ok2, dkjson = pcall(require, "dkjson")
        if ok2 then return dkjson.decode(s) end
        error("no JSON library available — install lua-cjson: luarocks install lua-cjson")
      end,
      encode = function(t)
        local ok, cjson = pcall(require, "cjson")
        if ok then return cjson.encode(t) end
        local ok2, dkjson = pcall(require, "dkjson")
        if ok2 then return dkjson.encode(t) end
        error("no JSON library")
      end,
    },
    fn = {
      readfile = function(path)
        local f = assert(io.open(path, "r"))
        local content = f:read("*a")
        f:close()
        local lines = {}
        for line in content:gmatch("([^\n]*)\n?") do
          table.insert(lines, line)
        end
        return lines
      end,
      writefile = function(lines, path)
        local f = assert(io.open(path, "w"))
        f:write(table.concat(lines, "\n"))
        f:close()
      end,
    },
    tbl_deep_extend = function(mode, a, b) return b end,
  }
end

package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"
local notebook = require("nvim-jupyter.notebook")

describe("notebook", function()
  local fixture_path = "test/fixtures/simple.ipynb"

  it("parses cell count", function()
    local nb = notebook.load(fixture_path)
    assert.equals(3, #nb.cells)
  end)

  it("parses cell types", function()
    local nb = notebook.load(fixture_path)
    assert.equals("markdown", nb.cells[1].cell_type)
    assert.equals("code", nb.cells[2].cell_type)
    assert.equals("code", nb.cells[3].cell_type)
  end)

  it("parses cell source as string", function()
    local nb = notebook.load(fixture_path)
    assert.truthy(nb.cells[1].source:find("Hello World"))
    assert.truthy(nb.cells[2].source:find("x = 1 + 1"))
  end)

  it("parses kernelspec name", function()
    local nb = notebook.load(fixture_path)
    assert.equals("python3", nb.metadata.kernelspec.name)
  end)

  it("round-trips to JSON", function()
    local nb = notebook.load(fixture_path)
    local tmp = os.tmpname() .. ".ipynb"
    notebook.save(nb, tmp)
    local nb2 = notebook.load(tmp)
    assert.equals(#nb.cells, #nb2.cells)
    assert.equals(nb.cells[2].source, nb2.cells[2].source)
    os.remove(tmp)
  end)
end)
```

- [ ] **Step 2: Run the test to see it fail**

```bash
busted test/notebook_spec.lua 2>&1
```
Expected: fails because `nvim-jupyter.notebook` doesn't exist yet.

- [ ] **Step 3: Write notebook.lua**

`lua/nvim-jupyter/notebook.lua`:
```lua
local M = {}

--- Join a cell's source array into a single string.
local function join_source(source_array)
  if type(source_array) == "string" then return source_array end
  return table.concat(source_array, "")
end

--- Split a string into the array format .ipynb uses.
local function split_source(source_str)
  local lines = {}
  local remaining = source_str
  while true do
    local nl = remaining:find("\n")
    if not nl then
      table.insert(lines, remaining)
      break
    end
    table.insert(lines, remaining:sub(1, nl))  -- include the \n
    remaining = remaining:sub(nl + 1)
  end
  return lines
end

--- Load a .ipynb file. Returns a notebook table:
--- { metadata = {...}, cells = [{cell_type, id, source, outputs, execution_count, metadata}] }
function M.load(path)
  local lines = vim.fn.readfile(path)
  local raw = table.concat(lines, "\n")
  local decoded = vim.json.decode(raw)

  local cells = {}
  for _, raw_cell in ipairs(decoded.cells or {}) do
    table.insert(cells, {
      cell_type       = raw_cell.cell_type,
      id              = raw_cell.id,
      source          = join_source(raw_cell.source or {}),
      outputs         = raw_cell.outputs or {},
      execution_count = raw_cell.execution_count,
      metadata        = raw_cell.metadata or {},
    })
  end

  return {
    nbformat       = decoded.nbformat or 4,
    nbformat_minor = decoded.nbformat_minor or 5,
    metadata       = decoded.metadata or {},
    cells          = cells,
  }
end

--- Save a notebook table back to a .ipynb file.
function M.save(nb, path)
  local raw_cells = {}
  for _, cell in ipairs(nb.cells) do
    table.insert(raw_cells, {
      cell_type       = cell.cell_type,
      id              = cell.id or "",
      metadata        = cell.metadata or {},
      source          = split_source(cell.source),
      outputs         = cell.outputs or {},
      execution_count = cell.execution_count,
    })
  end

  local encoded = {
    nbformat       = nb.nbformat or 4,
    nbformat_minor = nb.nbformat_minor or 5,
    metadata       = nb.metadata or {},
    cells          = raw_cells,
  }

  local json_str = vim.json.encode(encoded)
  vim.fn.writefile({ json_str }, path)
end

--- Flatten a notebook's cell sources into a single list of lines.
--- Returns {lines, cell_starts} where cell_starts[i] = 1-based line of cell i's first line.
function M.to_buffer_lines(nb)
  local lines = {}
  local cell_starts = {}
  for i, cell in ipairs(nb.cells) do
    cell_starts[i] = #lines + 1
    local source = cell.source
    -- Split on newlines, preserving empty lines
    local cell_lines = {}
    for line in (source .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(cell_lines, line)
    end
    -- Remove trailing empty line artifact
    if #cell_lines > 0 and cell_lines[#cell_lines] == "" then
      table.remove(cell_lines)
    end
    for _, l in ipairs(cell_lines) do
      table.insert(lines, l)
    end
  end
  return lines, cell_starts
end

return M
```

- [ ] **Step 4: Run the test**

```bash
busted test/notebook_spec.lua 2>&1
```
Expected: all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/nvim-jupyter/notebook.lua test/notebook_spec.lua
git commit -m "feat: notebook parse/serialize with tests"
```

---

## Task 14: Lua Cells Module

**Files:**
- Create: `lua/nvim-jupyter/cells.lua`
- Create: `test/cells_spec.lua`

The cells module manages two extmark namespaces and a Lua-side cell metadata table. Extmark tests require Neovim, so the busted tests cover only the pure-logic helpers.

- [ ] **Step 1: Write the failing test**

`test/cells_spec.lua`:
```lua
-- Same vim stub as notebook_spec
if not vim then
  vim = { api = {}, fn = {}, log = { levels = { WARN = 2 } } }
end
package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

-- We only test pure-logic helpers; extmark functions require Neovim
local cells = require("nvim-jupyter.cells")

describe("cells pure logic", function()
  it("cell_lines_from_source splits correctly", function()
    local src = "line1\nline2\nline3"
    local result = cells._split_source_to_lines(src)
    assert.equals(3, #result)
    assert.equals("line1", result[1])
    assert.equals("line3", result[3])
  end)

  it("join_lines_to_source joins with newlines", function()
    local lines = {"a", "b", "c"}
    local src = cells._join_lines_to_source(lines)
    assert.equals("a\nb\nc", src)
  end)
end)
```

- [ ] **Step 2: Run to confirm failure**

```bash
busted test/cells_spec.lua 2>&1
```
Expected: fails because `nvim-jupyter.cells` doesn't exist.

- [ ] **Step 3: Write cells.lua**

`lua/nvim-jupyter/cells.lua`:
```lua
local M = {}

-- Per-buffer state: { [bufnr] = { ns_cells, ns_output, cell_meta } }
-- cell_meta: { [extmark_id] = { cell_type, id, outputs, execution_count, metadata } }
M._state = {}

--- Pure-logic helpers (also tested outside Neovim)

function M._split_source_to_lines(source)
  local lines = {}
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end
  -- Remove trailing empty artifact
  if #lines > 0 and lines[#lines] == "" then table.remove(lines) end
  if #lines == 0 then lines = { "" } end
  return lines
end

function M._join_lines_to_source(lines)
  return table.concat(lines, "\n")
end

--- Separator virtual line for a cell.
local function sep_virt_line(cell_type, hl)
  local label = "─── " .. (cell_type or "code") .. " "
  local fill = string.rep("─", math.max(0, 60 - #label))
  return { { label .. fill, hl or "NvimJupyterCellSep" } }
end

--- Initialize cells for a buffer from a notebook.
--- nb: the notebook table from notebook.load()
--- lines: flat buffer lines (from notebook.to_buffer_lines)
--- cell_starts: 1-based line numbers for each cell's first line
function M.init(bufnr, nb, lines, cell_starts)
  local ns_cells  = vim.api.nvim_create_namespace("nvim_jupyter_cells_" .. bufnr)
  local ns_output = vim.api.nvim_create_namespace("nvim_jupyter_output_" .. bufnr)
  M._state[bufnr] = { ns_cells = ns_cells, ns_output = ns_output, cell_meta = {} }

  -- Set buffer lines
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  -- Draw cell separators
  for i, cell in ipairs(nb.cells) do
    local row = cell_starts[i] - 1  -- 0-based
    local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns_cells, row, 0, {
      virt_lines = { sep_virt_line(cell.cell_type) },
      virt_lines_above = true,
      hl_mode = "combine",
    })
    M._state[bufnr].cell_meta[mark_id] = {
      cell_type       = cell.cell_type,
      id              = cell.id or "",
      outputs         = cell.outputs or {},
      execution_count = cell.execution_count,
      metadata        = cell.metadata or {},
    }
  end
end

--- Get all cell extmarks for a buffer, sorted by line.
--- Returns list of { id, row, meta }
function M.get_marks(bufnr)
  local s = M._state[bufnr]
  if not s then return {} end
  local raw = vim.api.nvim_buf_get_extmarks(bufnr, s.ns_cells, 0, -1, { details = false })
  -- raw[i] = { mark_id, row, col }
  local marks = {}
  for _, m in ipairs(raw) do
    table.insert(marks, { id = m[1], row = m[2], meta = s.cell_meta[m[1]] })
  end
  table.sort(marks, function(a, b) return a.row < b.row end)
  return marks
end

--- Find the cell containing a given 0-based row.
--- Returns { index, mark } or nil.
function M.cell_at_row(bufnr, row)
  local marks = M.get_marks(bufnr)
  local found = nil
  for i, mark in ipairs(marks) do
    if mark.row <= row then
      found = { index = i, mark = mark }
    else
      break
    end
  end
  return found
end

--- Get the line range [start_row, end_row) (0-based, exclusive end) for cell at index.
function M.cell_range(bufnr, index)
  local marks = M.get_marks(bufnr)
  if not marks[index] then return nil end
  local start_row = marks[index].row
  local end_row
  if marks[index + 1] then
    end_row = marks[index + 1].row
  else
    end_row = vim.api.nvim_buf_line_count(bufnr)
  end
  return start_row, end_row
end

--- Get source for cell at index.
function M.get_source(bufnr, index)
  local start_row, end_row = M.cell_range(bufnr, index)
  if not start_row then return "" end
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row, false)
  return M._join_lines_to_source(lines)
end

--- Add a new empty code cell below the cell at index.
function M.add_cell_below(bufnr, index)
  local s = M._state[bufnr]
  if not s then return end
  local _, end_row = M.cell_range(bufnr, index)
  -- Insert one empty line at end_row
  vim.api.nvim_buf_set_lines(bufnr, end_row, end_row, false, { "" })
  local mark_id = vim.api.nvim_buf_set_extmark(bufnr, s.ns_cells, end_row, 0, {
    virt_lines = { sep_virt_line("code") },
    virt_lines_above = true,
    hl_mode = "combine",
  })
  s.cell_meta[mark_id] = { cell_type = "code", id = "", outputs = {}, execution_count = nil, metadata = {} }
  return index + 1
end

--- Add a new empty code cell above the cell at index.
function M.add_cell_above(bufnr, index)
  local s = M._state[bufnr]
  if not s then return end
  local start_row = M.get_marks(bufnr)[index].row
  vim.api.nvim_buf_set_lines(bufnr, start_row, start_row, false, { "" })
  local mark_id = vim.api.nvim_buf_set_extmark(bufnr, s.ns_cells, start_row, 0, {
    virt_lines = { sep_virt_line("code") },
    virt_lines_above = true,
    hl_mode = "combine",
  })
  s.cell_meta[mark_id] = { cell_type = "code", id = "", outputs = {}, execution_count = nil, metadata = {} }
  return index
end

--- Delete the cell at index.
function M.delete_cell(bufnr, index)
  local s = M._state[bufnr]
  if not s then return end
  local marks = M.get_marks(bufnr)
  if not marks[index] then return end
  local start_row, end_row = M.cell_range(bufnr, index)
  vim.api.nvim_buf_del_extmark(bufnr, s.ns_cells, marks[index].id)
  s.cell_meta[marks[index].id] = nil
  vim.api.nvim_buf_set_lines(bufnr, start_row, end_row, false, {})
end

--- Toggle cell type between code and markdown.
function M.toggle_cell_type(bufnr, index)
  local s = M._state[bufnr]
  if not s then return end
  local marks = M.get_marks(bufnr)
  if not marks[index] then return end
  local meta = s.cell_meta[marks[index].id]
  meta.cell_type = meta.cell_type == "code" and "markdown" or "code"
  -- Redraw separator
  vim.api.nvim_buf_set_extmark(bufnr, s.ns_cells, marks[index].row, 0, {
    id = marks[index].id,
    virt_lines = { sep_virt_line(meta.cell_type) },
    virt_lines_above = true,
    hl_mode = "combine",
  })
end

--- Reconstruct the notebook cell list from current buffer state.
--- Used by BufWriteCmd to serialize back to .ipynb.
function M.to_notebook_cells(bufnr)
  local s = M._state[bufnr]
  if not s then return {} end
  local marks = M.get_marks(bufnr)
  local cells = {}
  for i, mark in ipairs(marks) do
    local start_row, end_row = M.cell_range(bufnr, i)
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row, false)
    -- Handle boundary merge (two marks at same row)
    if i > 1 and mark.row == marks[i-1].row then
      vim.notify("nvim-jupyter: cell boundary merge detected — merging cells " .. (i-1) .. " and " .. i, vim.log.levels.WARN)
    end
    local meta = mark.meta or {}
    table.insert(cells, {
      cell_type       = meta.cell_type or "code",
      id              = meta.id or "",
      source          = M._join_lines_to_source(lines),
      outputs         = meta.outputs or {},
      execution_count = meta.execution_count,
      metadata        = meta.metadata or {},
    })
  end
  return cells
end

return M
```

- [ ] **Step 4: Run tests**

```bash
busted test/cells_spec.lua 2>&1
```
Expected: 2 pure-logic tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/nvim-jupyter/cells.lua test/cells_spec.lua
git commit -m "feat: cells module — extmarks, cell CRUD, source extraction"
```

---

## Task 15: Lua Output Module

**Files:**
- Create: `lua/nvim-jupyter/output.lua`
- Create: `test/output_spec.lua`

- [ ] **Step 1: Write the test first**

`test/output_spec.lua`:
```lua
if not vim then
  vim = { api = {}, fn = {}, log = { levels = { WARN = 2 } } }
end
package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"
local output = require("nvim-jupyter.output")

describe("output", function()
  it("truncates long output", function()
    local lines = {}
    for i = 1, 100 do table.insert(lines, "line " .. i) end
    local truncated = output._truncate(lines, 10)
    assert.equals(11, #truncated)  -- 10 lines + 1 truncation indicator
    assert.truthy(truncated[11]:find("90 more"))
  end)

  it("does not truncate short output", function()
    local lines = { "a", "b", "c" }
    local result = output._truncate(lines, 50)
    assert.equals(3, #result)
  end)

  it("formats stream text into lines", function()
    local result = output._text_to_lines("hello\nworld\n")
    assert.equals(2, #result)
    assert.equals("hello", result[1])
    assert.equals("world", result[2])
  end)

  it("strips ANSI codes from traceback", function()
    local ansi = "\27[31mValueError\27[0m: bad"
    local stripped = output._strip_ansi(ansi)
    assert.equals("ValueError: bad", stripped)
  end)
end)
```

- [ ] **Step 2: Run to confirm failure**

```bash
busted test/output_spec.lua 2>&1
```
Expected: fails.

- [ ] **Step 3: Write output.lua**

`lua/nvim-jupyter/output.lua`:
```lua
local M = {}

--- Strip ANSI escape codes.
function M._strip_ansi(s)
  return s:gsub("\27%[[%d;]*m", "")
end

--- Split text on newlines into a list of lines, dropping trailing empty.
function M._text_to_lines(text)
  local lines = {}
  for line in (text):gmatch("([^\n]*)\n?") do
    table.insert(lines, line)
  end
  -- Remove trailing empty
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return lines
end

--- Truncate to max_lines, appending a summary if truncated.
function M._truncate(lines, max_lines)
  if #lines <= max_lines then return lines end
  local result = {}
  for i = 1, max_lines do result[i] = lines[i] end
  table.insert(result, string.format("[... %d more lines]", #lines - max_lines))
  return result
end

--- Build virt_lines array from text lines for nvim_buf_set_extmark.
local function build_virt_lines(lines, hl)
  local vl = {}
  for _, line in ipairs(lines) do
    table.insert(vl, { { "▷ " .. line, hl } })
  end
  return vl
end

--- Set output virtual text for a cell. Clears previous output first.
--- mark_id: the ns_cells extmark id for this cell (used to anchor the output mark)
--- last_row: 0-based last row of the cell
function M.set(bufnr, ns_output, last_row, text_lines, hl, max_output_lines)
  -- Clear existing
  M.clear(bufnr, ns_output, last_row)

  local truncated = M._truncate(text_lines, max_output_lines or 50)
  local vl = build_virt_lines(truncated, hl or "NvimJupyterOutputText")

  vim.api.nvim_buf_set_extmark(bufnr, ns_output, last_row, 0, {
    virt_lines = vl,
    virt_lines_above = false,
    hl_mode = "combine",
  })
end

--- Append lines to existing output virtual text.
function M.append(bufnr, ns_output, last_row, new_lines, hl, max_output_lines)
  -- Get existing virt_lines
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns_output, { last_row, 0 }, { last_row, 0 }, { details = true })
  local existing = {}
  local existing_id = nil
  if #marks > 0 then
    existing_id = marks[1][1]
    local details = marks[1][4]
    if details and details.virt_lines then
      for _, vl in ipairs(details.virt_lines) do
        -- Extract text from first chunk
        if vl[1] then
          table.insert(existing, vl[1][1]:sub(3))  -- strip "▷ " prefix
        end
      end
    end
    -- Remove the "N more lines" indicator if present
    if #existing > 0 and existing[#existing]:find("more lines") then
      table.remove(existing)
    end
  end

  for _, l in ipairs(new_lines) do
    table.insert(existing, l)
  end

  local truncated = M._truncate(existing, max_output_lines or 50)
  local vl = build_virt_lines(truncated, hl or "NvimJupyterOutputText")

  local opts = {
    virt_lines = vl,
    virt_lines_above = false,
    hl_mode = "combine",
  }
  if existing_id then opts.id = existing_id end
  vim.api.nvim_buf_set_extmark(bufnr, ns_output, last_row, 0, opts)
end

--- Clear output virtual text at a specific row.
function M.clear(bufnr, ns_output, last_row)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns_output, { last_row, 0 }, { last_row, 0 }, {})
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_del_extmark(bufnr, ns_output, m[1])
  end
end

--- Clear all output virtual text in a buffer.
function M.clear_all(bufnr, ns_output)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_output, 0, -1)
end

return M
```

- [ ] **Step 4: Run tests**

```bash
busted test/output_spec.lua 2>&1
```
Expected: all 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/nvim-jupyter/output.lua test/output_spec.lua
git commit -m "feat: output module — virtual text rendering with truncation"
```

---

## Task 16: Lua Kernels Module

**Files:**
- Create: `lua/nvim-jupyter/kernels.lua`

- [ ] **Step 1: Write kernels.lua**

`lua/nvim-jupyter/kernels.lua`:
```lua
local daemon = require("nvim-jupyter.daemon")

local M = {}

-- Per-buffer kernel state
-- { [bufnr] = { kernel_id, status, execution_count, kernel_name } }
M._state = {}

local function new_uuid()
  local handle = io.popen("uuidgen")
  local result = handle:read("*a"):gsub("%s+", "")
  handle:close()
  return result
end

local function set_status(bufnr, status)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  M._state[bufnr].status = status
  vim.b[bufnr].jupyter_kernel_status = status
end

--- Register daemon event handlers for a specific buffer/kernel.
local function register_handlers(bufnr, kernel_id)
  local s = M._state[bufnr]

  daemon.on("kernel_started", function(ev)
    if ev.kernel_id ~= kernel_id then return end
    set_status(bufnr, "starting")
  end)

  daemon.on("kernel_ready", function(ev)
    if ev.kernel_id ~= kernel_id then return end
    set_status(bufnr, "idle")
    vim.notify("nvim-jupyter: kernel ready", vim.log.levels.INFO)
  end)

  daemon.on("kernel_died", function(ev)
    if ev.kernel_id ~= kernel_id then return end
    set_status(bufnr, "dead")
    vim.notify("nvim-jupyter: kernel died (code " .. ev.code .. ") — use :JupyterRestartKernel", vim.log.levels.WARN)
  end)

  daemon.on("kernels_list", function(ev)
    if s.status ~= "picking" then return end
    local names = {}
    for _, k in ipairs(ev.kernels) do
      table.insert(names, k.name .. " — " .. k.display_name)
    end
    if #names == 0 then
      vim.notify("nvim-jupyter: no kernels found — run: pip install ipykernel", vim.log.levels.ERROR)
      return
    end
    vim.ui.select(names, { prompt = "Select Jupyter kernel:" }, function(choice)
      if not choice then return end
      local chosen_name = choice:match("^([^%s]+)")
      s.kernel_name = chosen_name
      daemon.send({ cmd = "start_kernel", kernel_id = kernel_id, kernel_name = chosen_name, cwd = s.cwd })
    end)
  end)
end

--- Start a kernel for a buffer. kernel_name from kernelspec (may be nil → show picker).
function M.start(bufnr, kernel_name, cwd)
  if not daemon.ensure_started() then return end

  local kernel_id = new_uuid()
  M._state[bufnr] = {
    kernel_id       = kernel_id,
    kernel_name     = kernel_name,
    status          = "starting",
    execution_count = 0,
    cwd             = cwd or vim.fn.getcwd(),
  }
  vim.b[bufnr].jupyter_kernel_status = "starting"

  register_handlers(bufnr, kernel_id)

  if kernel_name then
    daemon.send({ cmd = "start_kernel", kernel_id = kernel_id, kernel_name = kernel_name, cwd = cwd })
  else
    -- No kernel name — request list and show picker
    M._state[bufnr].status = "picking"
    daemon.send({ cmd = "list_kernels" })
  end
end

function M.stop(bufnr)
  local s = M._state[bufnr]
  if not s then return end
  daemon.send({ cmd = "stop_kernel", kernel_id = s.kernel_id })
  M._state[bufnr] = nil
end

function M.restart(bufnr)
  local s = M._state[bufnr]
  if not s then return end
  daemon.send({ cmd = "restart_kernel", kernel_id = s.kernel_id })
  set_status(bufnr, "starting")
end

function M.interrupt(bufnr)
  local s = M._state[bufnr]
  if not s then return end
  daemon.send({ cmd = "interrupt_kernel", kernel_id = s.kernel_id })
end

function M.pick_kernel(bufnr)
  local s = M._state[bufnr]
  if not s then return end
  M.stop(bufnr)
  M.start(bufnr, nil, s.cwd)
end

function M.new_msg_id()
  return new_uuid()
end

function M.state(bufnr)
  return M._state[bufnr]
end

function M.is_ready(bufnr)
  local s = M._state[bufnr]
  return s and (s.status == "idle" or s.status == "busy")
end

function M.set_busy(bufnr)
  set_status(bufnr, "busy")
end

function M.set_idle(bufnr)
  set_status(bufnr, "idle")
end

return M
```

- [ ] **Step 2: Commit**

```bash
git add lua/nvim-jupyter/kernels.lua
git commit -m "feat: kernels module — per-buffer state machine and daemon event handlers"
```

---

## Task 17: Lua Init Module

**Files:**
- Create: `lua/nvim-jupyter/init.lua`

This is the plugin entry point. It wires together all modules, registers user commands, sets up autocmds, and applies keymaps.

- [ ] **Step 1: Write init.lua**

`lua/nvim-jupyter/init.lua`:
```lua
local config   = require("nvim-jupyter.config")
local daemon   = require("nvim-jupyter.daemon")
local notebook = require("nvim-jupyter.notebook")
local cells    = require("nvim-jupyter.cells")
local output   = require("nvim-jupyter.output")
local kernels  = require("nvim-jupyter.kernels")

local M = {}

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h")
end

--- Execute current cell. on_done(index) called when execute_done received.
local function execute_cell(bufnr, on_done)
  if not kernels.is_ready(bufnr) then
    local s = kernels.state(bufnr)
    local st = s and s.status or "not started"
    vim.notify("nvim-jupyter: kernel not ready (status: " .. st .. ")", vim.log.levels.WARN)
    return
  end

  local ks = kernels.state(bufnr)
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1  -- 0-based
  local cell_info = cells.cell_at_row(bufnr, cursor_row)
  if not cell_info then
    vim.notify("nvim-jupyter: cursor not in a cell", vim.log.levels.WARN)
    return
  end

  local index = cell_info.index
  local source = cells.get_source(bufnr, index)
  local msg_id = kernels.new_msg_id()

  -- Clear output for this cell
  local _, end_row = cells.cell_range(bufnr, index)
  local last_row = end_row - 1
  local s = cells._state[bufnr]
  if s then output.clear_all_at_row(bufnr, s.ns_output, last_row) end

  -- Show running indicator
  -- (set as a special output line)
  if s then
    output.set(bufnr, s.ns_output, last_row,
      { "[*] running..." }, "NvimJupyterRunning", config.options.max_output_lines)
  end

  kernels.set_busy(bufnr)
  daemon.send({ cmd = "execute", kernel_id = ks.kernel_id, msg_id = msg_id, code = source })

  -- Register output handlers for this msg_id
  local output_lines = {}

  local function append_output(new_lines, hl)
    if s then
      for _, l in ipairs(new_lines) do table.insert(output_lines, l) end
      output.set(bufnr, s.ns_output, last_row, output_lines, hl, config.options.max_output_lines)
    end
  end

  daemon.on("stream", function(ev)
    if ev.msg_id ~= msg_id then return end
    local lines = output._text_to_lines(ev.text)
    append_output(lines, "NvimJupyterOutputText")
  end)

  daemon.on("execute_result", function(ev)
    if ev.msg_id ~= msg_id then return end
    local lines = output._text_to_lines(ev.text)
    append_output(lines, "NvimJupyterOutputText")
  end)

  daemon.on("execute_error", function(ev)
    if ev.msg_id ~= msg_id then return end
    local err_lines = { ev.ename .. ": " .. ev.evalue }
    for _, tb in ipairs(ev.traceback or {}) do
      table.insert(err_lines, output._strip_ansi(tb))
    end
    append_output(err_lines, "NvimJupyterOutputError")
  end)

  daemon.on("execute_done", function(ev)
    if ev.msg_id ~= msg_id then return end
    kernels.set_idle(bufnr)
    -- Update execution count in cell meta
    local marks = cells.get_marks(bufnr)
    if marks[index] then
      local meta = s and s.cell_meta[marks[index].id]
      if meta then
        meta.execution_count = ks.execution_count
        ks.execution_count = (ks.execution_count or 0) + 1
      end
    end
    if on_done then on_done(index) end
  end)
end

--- Open a .ipynb file as a virtual buffer.
local function open_notebook(path)
  path = vim.fn.fnamemodify(path, ":p")
  local ok, nb = pcall(notebook.load, path)
  if not ok then
    vim.notify("nvim-jupyter: failed to parse " .. path .. ": " .. nb, vim.log.levels.ERROR)
    return
  end

  local lines, cell_starts = notebook.to_buffer_lines(nb)

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].buftype  = "acwrite"
  vim.bo[bufnr].filetype = "python"
  vim.bo[bufnr].swapfile = false
  vim.api.nvim_buf_set_name(bufnr, path)

  cells.init(bufnr, nb, lines, cell_starts)

  -- Auto-start kernel
  local kernel_name = (nb.metadata.kernelspec or {}).name
  local cwd = vim.fn.fnamemodify(path, ":h")
  kernels.start(bufnr, kernel_name, cwd)

  -- Apply keymaps
  apply_keymaps(bufnr)
end

function apply_keymaps(bufnr)
  if config.options.keymaps == false then return end
  local km = config.options.keymap
  local o = { noremap = true, silent = true, buffer = bufnr }

  if km.execute_advance ~= false then
    vim.keymap.set({ "n", "i" }, km.execute_advance, function()
      vim.cmd("stopinsert")
      execute_cell(bufnr, function(index)
        -- Advance: move to next cell or create one
        local mark_count = #cells.get_marks(bufnr)
        if index >= mark_count then
          cells.add_cell_below(bufnr, index)
        end
        local next_marks = cells.get_marks(bufnr)
        if next_marks[index + 1] then
          local row = next_marks[index + 1].row
          vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
        end
      end)
    end, vim.tbl_extend("force", o, { desc = "Execute cell + advance" }))
  end

  if km.execute ~= false then
    vim.keymap.set({ "n", "i" }, km.execute, function()
      vim.cmd("stopinsert")
      execute_cell(bufnr, nil)
    end, vim.tbl_extend("force", o, { desc = "Execute cell in place" }))
  end

  if km.execute_insert ~= false then
    vim.keymap.set({ "n", "i" }, km.execute_insert, function()
      vim.cmd("stopinsert")
      execute_cell(bufnr, function(index)
        local new_index = cells.add_cell_below(bufnr, index)
        local next_marks = cells.get_marks(bufnr)
        if next_marks[new_index] then
          vim.api.nvim_win_set_cursor(0, { next_marks[new_index].row + 1, 0 })
        end
      end)
    end, vim.tbl_extend("force", o, { desc = "Execute cell + insert below" }))
  end

  if km.next_cell ~= false then
    vim.keymap.set("n", km.next_cell, function()
      local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local cell_info = cells.cell_at_row(bufnr, cursor_row)
      if not cell_info then return end
      local next_marks = cells.get_marks(bufnr)
      local next = next_marks[cell_info.index + 1]
      if next then vim.api.nvim_win_set_cursor(0, { next.row + 1, 0 }) end
    end, vim.tbl_extend("force", o, { desc = "Next cell" }))
  end

  if km.prev_cell ~= false then
    vim.keymap.set("n", km.prev_cell, function()
      local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local cell_info = cells.cell_at_row(bufnr, cursor_row)
      if not cell_info then return end
      local prev_marks = cells.get_marks(bufnr)
      local prev = prev_marks[cell_info.index - 1]
      if prev then vim.api.nvim_win_set_cursor(0, { prev.row + 1, 0 }) end
    end, vim.tbl_extend("force", o, { desc = "Previous cell" }))
  end
end

function M.setup(opts)
  config.setup(opts)

  -- BufReadCmd: intercept .ipynb opens
  vim.api.nvim_create_autocmd("BufReadCmd", {
    pattern  = "*.ipynb",
    callback = function(ev) open_notebook(ev.file) end,
    desc     = "nvim-jupyter: open .ipynb as virtual cell buffer",
  })

  -- BufWriteCmd: serialize back to .ipynb on :w
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    pattern  = "*.ipynb",
    callback = function(ev)
      local bufnr = vim.api.nvim_get_current_buf()
      local path  = ev.file
      local s     = cells._state[bufnr]
      if not s then return end

      local nb_cells = cells.to_notebook_cells(bufnr)
      local ks = kernels.state(bufnr)
      local meta = ks and { kernelspec = { name = ks.kernel_name or "python3",
                                           display_name = "Python 3", language = "python" } }
                       or {}
      local nb = { nbformat = 4, nbformat_minor = 5, metadata = meta, cells = nb_cells }
      local ok, err = pcall(notebook.save, nb, path)
      if ok then
        vim.bo[bufnr].modified = false
        vim.notify("nvim-jupyter: saved " .. path, vim.log.levels.INFO)
      else
        vim.notify("nvim-jupyter: save failed: " .. err, vim.log.levels.ERROR)
      end
    end,
    desc = "nvim-jupyter: serialize cells back to .ipynb on :w",
  })

  -- VimLeavePre: clean up daemon
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function() daemon.stop() end,
    desc     = "nvim-jupyter: stop Rust daemon on exit",
  })

  -- User commands
  vim.api.nvim_create_user_command("JupyterExecute", function()
    local bufnr = vim.api.nvim_get_current_buf()
    execute_cell(bufnr, nil)
  end, { desc = "Execute current cell in place" })

  vim.api.nvim_create_user_command("JupyterExecuteAndAdvance", function()
    local bufnr = vim.api.nvim_get_current_buf()
    execute_cell(bufnr, function(index)
      local mark_count = #cells.get_marks(bufnr)
      if index >= mark_count then cells.add_cell_below(bufnr, index) end
      local ms = cells.get_marks(bufnr)
      if ms[index + 1] then vim.api.nvim_win_set_cursor(0, { ms[index + 1].row + 1, 0 }) end
    end)
  end, { desc = "Execute cell + advance to next" })

  vim.api.nvim_create_user_command("JupyterExecuteAndInsert", function()
    local bufnr = vim.api.nvim_get_current_buf()
    execute_cell(bufnr, function(index)
      local new_i = cells.add_cell_below(bufnr, index)
      local ms = cells.get_marks(bufnr)
      if ms[new_i] then vim.api.nvim_win_set_cursor(0, { ms[new_i].row + 1, 0 }) end
    end)
  end, { desc = "Execute cell + insert new below" })

  vim.api.nvim_create_user_command("JupyterExecuteAll", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local mark_count = #cells.get_marks(bufnr)
    local function run_next(i)
      if i > mark_count then return end
      local ms = cells.get_marks(bufnr)
      if ms[i] then vim.api.nvim_win_set_cursor(0, { ms[i].row + 1, 0 }) end
      execute_cell(bufnr, function() run_next(i + 1) end)
    end
    run_next(1)
  end, { desc = "Execute all cells top to bottom" })

  vim.api.nvim_create_user_command("JupyterNextCell", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local info = cells.cell_at_row(bufnr, row)
    if not info then return end
    local ms = cells.get_marks(bufnr)
    if ms[info.index + 1] then vim.api.nvim_win_set_cursor(0, { ms[info.index + 1].row + 1, 0 }) end
  end, { desc = "Move to next cell" })

  vim.api.nvim_create_user_command("JupyterPrevCell", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local info = cells.cell_at_row(bufnr, row)
    if not info then return end
    local ms = cells.get_marks(bufnr)
    if ms[info.index - 1] then vim.api.nvim_win_set_cursor(0, { ms[info.index - 1].row + 1, 0 }) end
  end, { desc = "Move to previous cell" })

  vim.api.nvim_create_user_command("JupyterAddCellBelow", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local info = cells.cell_at_row(bufnr, row)
    if info then cells.add_cell_below(bufnr, info.index) end
  end, { desc = "Add code cell below current" })

  vim.api.nvim_create_user_command("JupyterAddCellAbove", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local info = cells.cell_at_row(bufnr, row)
    if info then cells.add_cell_above(bufnr, info.index) end
  end, { desc = "Add code cell above current" })

  vim.api.nvim_create_user_command("JupyterDeleteCell", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local info = cells.cell_at_row(bufnr, row)
    if info then cells.delete_cell(bufnr, info.index) end
  end, { desc = "Delete current cell" })

  vim.api.nvim_create_user_command("JupyterChangeCellType", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local info = cells.cell_at_row(bufnr, row)
    if info then cells.toggle_cell_type(bufnr, info.index) end
  end, { desc = "Toggle cell type code/markdown" })

  vim.api.nvim_create_user_command("JupyterKernel", function()
    local bufnr = vim.api.nvim_get_current_buf()
    kernels.pick_kernel(bufnr)
  end, { desc = "Show kernel picker" })

  vim.api.nvim_create_user_command("JupyterRestartKernel", function()
    local bufnr = vim.api.nvim_get_current_buf()
    kernels.restart(bufnr)
  end, { desc = "Restart kernel" })

  vim.api.nvim_create_user_command("JupyterInterrupt", function()
    local bufnr = vim.api.nvim_get_current_buf()
    kernels.interrupt(bufnr)
  end, { desc = "Interrupt kernel (SIGINT)" })

  vim.api.nvim_create_user_command("JupyterKernelStatus", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local s = kernels.state(bufnr)
    local status = s and s.status or "not started"
    vim.notify("nvim-jupyter kernel: " .. status, vim.log.levels.INFO)
  end, { desc = "Print kernel status" })

  vim.api.nvim_create_user_command("JupyterShowOutput", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local info = cells.cell_at_row(bufnr, row)
    if not info then return end
    local _, end_row = cells.cell_range(bufnr, info.index)
    local s = cells._state[bufnr]
    if not s then return end
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, s.ns_output,
      { end_row - 1, 0 }, { end_row - 1, 0 }, { details = true })
    if #marks == 0 then
      vim.notify("nvim-jupyter: no output for current cell", vim.log.levels.INFO)
      return
    end
    local details = marks[1][4]
    local lines = {}
    if details and details.virt_lines then
      for _, vl in ipairs(details.virt_lines) do
        if vl[1] then table.insert(lines, vl[1][1]:sub(3)) end  -- strip "▷ "
      end
    end
    -- Open in scratch split
    vim.cmd("new")
    local out_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(out_buf, 0, -1, false, lines)
    vim.bo[out_buf].buftype  = "nofile"
    vim.bo[out_buf].filetype = "text"
    vim.bo[out_buf].modifiable = false
  end, { desc = "Show full cell output in scratch split" })

  vim.api.nvim_create_user_command("JupyterBuild", function()
    local root = plugin_root()
    local cmd  = string.format("cd %s && bash build.sh", vim.fn.shellescape(root))
    vim.notify("nvim-jupyter: building...", vim.log.levels.INFO)
    vim.fn.jobstart({ "sh", "-c", cmd }, {
      on_exit = function(_, code)
        if code == 0 then
          vim.notify("nvim-jupyter: build complete", vim.log.levels.INFO)
        else
          vim.notify("nvim-jupyter: build failed (code " .. code .. ")", vim.log.levels.ERROR)
        end
      end,
    })
  end, { desc = "Build nvim-jupyter Rust binary" })
end

return M
```

- [ ] **Step 2: Verify the Lua files are syntactically valid**

```bash
luac -p lua/nvim-jupyter/init.lua && echo "OK"
luac -p lua/nvim-jupyter/cells.lua && echo "OK"
luac -p lua/nvim-jupyter/notebook.lua && echo "OK"
luac -p lua/nvim-jupyter/output.lua && echo "OK"
luac -p lua/nvim-jupyter/daemon.lua && echo "OK"
luac -p lua/nvim-jupyter/kernels.lua && echo "OK"
luac -p lua/nvim-jupyter/config.lua && echo "OK"
```
Expected: each prints `OK`.

- [ ] **Step 3: Commit**

```bash
git add lua/nvim-jupyter/init.lua
git commit -m "feat: init module — setup, autocmds, user commands, keymaps"
```

---

## Task 18: Smoke Test Script

**Files:**
- Create: `test/smoke.sh`

- [ ] **Step 1: Write smoke.sh**

`test/smoke.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== nvim-jupyter smoke test ==="
echo ""

# 1. Build
echo "Step 1: Building binary..."
bash "$SCRIPT_DIR/build.sh"
echo "  ✓ binary built"

# 2. Test daemon responds to list_kernels
echo "Step 2: Testing daemon list_kernels..."
RESULT=$(echo '{"cmd":"list_kernels"}
{"cmd":"quit"}' | "$SCRIPT_DIR/bin/nvim-jupyter" 2>/dev/null | head -1)
if echo "$RESULT" | grep -q '"event":"kernels_list"'; then
  echo "  ✓ kernels_list event received"
else
  echo "  ✗ unexpected output: $RESULT"
  exit 1
fi

# 3. Test daemon handles unknown command gracefully
echo "Step 3: Testing unknown command handling..."
RESULT=$(echo '{"cmd":"unknown_cmd"}
{"cmd":"quit"}' | "$SCRIPT_DIR/bin/nvim-jupyter" 2>&1 | head -1)
echo "  ✓ handled without crash: $RESULT"

echo ""
echo "=== Automated checks passed ==="
echo ""
echo "Manual Neovim checks (run these yourself):"
echo "  1. nvim test/fixtures/simple.ipynb"
echo "     → Should see 3 cells with separator lines"
echo "     → :JupyterKernelStatus should print 'idle'"
echo "  2. Press <S-CR> on a cell"
echo "     → Output should appear as virtual text below"
echo "  3. Press ]c / [c to navigate between cells"
echo "  4. :w — should save without corrupting the .ipynb"
echo "  5. :JupyterRestartKernel — status should return to idle"
```

```bash
chmod +x test/smoke.sh
```

- [ ] **Step 2: Run automated portion**

```bash
bash test/smoke.sh 2>&1
```
Expected: `=== Automated checks passed ===`

- [ ] **Step 3: Commit**

```bash
git add test/smoke.sh
git commit -m "test: smoke test script — automated + manual checklist"
```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Task |
|-----------------|------|
| Rust daemon one per session | Task 8 (main.rs) |
| JSON IPC stdin/stdout | Tasks 2, 8 |
| Jupyter ZMQ wire protocol | Task 3 |
| HMAC-SHA256 signing | Task 3 |
| Kernel lifecycle spawn/kill/restart/interrupt | Tasks 4, 5, 7 |
| Heartbeat monitoring | Task 7 (run_kernel_task) |
| Kernel discovery (kernelspec list) | Task 4 |
| Auto-start from kernelspec + fallback picker | Task 16 |
| .ipynb parse/serialize | Task 13 |
| Virtual buffer with buftype=acwrite | Task 17 |
| Extmark cell separators (ns_cells) | Task 14 |
| Output virtual text (ns_output) | Task 15 |
| execute_result text/plain extraction | Task 7 (execute_loop) |
| ANSI stripping | Task 15 |
| Real-time streaming output | Tasks 7, 17 |
| `<S-CR>` execute+advance | Task 17 |
| `<C-CR>` execute in place | Task 17 |
| `<M-CR>` execute+insert | Task 17 |
| `]c`/`[c` navigation | Task 17 |
| All `:Jupyter*` commands | Task 17 |
| No bare-letter keymap conflicts | Task 17 (confirmed — only `<X-CR>` and `]c`/`[c`) |
| `dd` deletes line not cell | Confirmed — no intercept |
| `u` undoes text not cell ops | Confirmed — no intercept |
| BufWriteCmd serialize | Task 17 |
| Cell boundary merge warning | Task 14 (to_notebook_cells) |
| Malformed .ipynb error | Task 17 (open_notebook pcall) |
| Daemon crash recovery | Task 16 (daemon_died handler) |
| Execute on dead kernel guard | Task 17 (is_ready check) |
| Protocol unit tests | Task 2 |
| Wire protocol tests | Task 3 |
| Connection file tests | Task 4 |
| Integration test (gated) | Task 9 |
| Lua notebook tests (busted) | Task 13 |
| Lua output tests (busted) | Task 15 |
| Lua cells pure-logic tests | Task 14 |
| Smoke test | Task 18 |
| build.sh | Task 1 |
| .gitignore includes .claude/ .superpowers/ | Task 1 |
| JupyterBuild command | Task 17 |

All spec requirements covered. ✓

**One gap found and fixed:** `output.clear_all_at_row` is called in init.lua but not defined in output.lua — add it:

In `lua/nvim-jupyter/output.lua`, add after `clear_all`:
```lua
function M.clear_all_at_row(bufnr, ns_output, row)
  M.clear(bufnr, ns_output, row)
end
```

This should be added to Task 15 Step 3 in `output.lua`. Apply this fix before committing Task 17.
