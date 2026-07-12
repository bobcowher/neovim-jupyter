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
        use std::net::TcpListener;
        let get_port = || -> u16 {
            TcpListener::bind("127.0.0.1:0")
                .and_then(|l| l.local_addr())
                .map(|a| a.port())
                .unwrap_or_else(|_| rand::random::<u16>() % 10000 + 50000)
        };
        
        let key = hex::encode(rand::random::<[u8; 32]>());

        ConnectionFile {
            shell_port: get_port(),
            iopub_port: get_port(),
            stdin_port: get_port(),
            control_port: get_port(),
            hb_port: get_port(),
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
    let mut specs = Vec::new();

    // 1. Standard Jupyter kernels
    if let Ok(output) = std::process::Command::new("jupyter")
        .args(["kernelspec", "list", "--json"])
        .output()
    {
        if output.status.success() {
            if let Ok(list) = serde_json::from_slice::<KernelspecList>(&output.stdout) {
                specs.extend(list.kernelspecs.into_iter().map(|(k, v)| (k, v.spec)));
            }
        }
    }

    // 2. Conda environments
    if let Ok(output) = std::process::Command::new("conda")
        .args(["env", "list", "--json"])
        .output()
    {
        if output.status.success() {
            #[derive(Deserialize)]
            struct CondaEnvList {
                envs: Vec<String>,
            }
            if let Ok(list) = serde_json::from_slice::<CondaEnvList>(&output.stdout) {
                for env_path_str in list.envs {
                    let env_path = std::path::Path::new(&env_path_str);
                    let py_bin = env_path.join("bin").join("python");
                    if py_bin.exists() {
                        let env_name = env_path.file_name().unwrap_or_default().to_string_lossy().to_string();
                        let kernel_name = format!("conda-env-{}", env_name);
                        let spec = KernelspecSpec {
                            argv: vec![
                                py_bin.to_string_lossy().to_string(),
                                "-m".into(),
                                "ipykernel_launcher".into(),
                                "-f".into(),
                                "{connection_file}".into(),
                            ],
                            display_name: format!("Python ({})", env_name),
                            language: "python".into(),
                        };
                        specs.push((kernel_name, spec));
                    }
                }
            }
        }
    }

    if specs.is_empty() {
        return Err(anyhow!("No Jupyter kernels found. Please install jupyter/ipykernel."));
    }

    Ok(specs)
}

pub fn get_kernelspec(kernel_name: &str) -> Result<KernelspecSpec> {
    let all = list_kernelspecs()?;
    all.into_iter()
        .find(|(name, _)| name == kernel_name)
        .map(|(_, spec)| spec)
        .ok_or_else(|| anyhow!("kernel '{}' not found", kernel_name))
}

pub fn build_launch_argv(spec: &KernelspecSpec, connection_file: &PathBuf) -> Vec<String> {
    spec.argv.iter().map(|arg| {
        if arg == "{connection_file}" {
            connection_file.to_string_lossy().to_string()
        } else {
            arg.clone()
        }
    }).collect()
}

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
