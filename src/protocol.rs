use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum Command {
    StartKernel { kernel_id: String, kernel_name: String, cwd: String },
    StopKernel { kernel_id: String },
    RestartKernel { kernel_id: String },
    InterruptKernel { kernel_id: String },
    Execute { kernel_id: String, msg_id: String, code: String },
    Complete { kernel_id: String, msg_id: String, code: String, cursor_pos: u32 },
    Inspect { kernel_id: String, msg_id: String, code: String, cursor_pos: u32, detail_level: u32 },
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
    ExecuteResult { kernel_id: String, msg_id: String, execution_count: u32, text: String, image_png: Option<String> },
    ExecuteError { kernel_id: String, msg_id: String, ename: String, evalue: String, traceback: Vec<String> },
    ExecuteDone { kernel_id: String, msg_id: String, status: String },
    CompleteReply { kernel_id: String, msg_id: String, matches: Vec<String>, cursor_start: u32, cursor_end: u32 },
    InspectReply { kernel_id: String, msg_id: String, found: bool, text: String },
    Error { msg: String },
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct KernelSpec {
    pub name: String,
    pub display_name: String,
    pub language: String,
    pub argv: Vec<String>,
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
