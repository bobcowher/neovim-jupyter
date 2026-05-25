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

        let key_bytes: [u8; 32] = rng.gen();
        let key = hex::encode(key_bytes);

        ConnectionFile {
            shell_port: rng.gen_range(49152u16..65535u16),
            iopub_port: rng.gen_range(49152u16..65535u16),
            stdin_port: rng.gen_range(49152u16..65535u16),
            control_port: rng.gen_range(49152u16..65535u16),
            hb_port: rng.gen_range(49152u16..65535u16),
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
