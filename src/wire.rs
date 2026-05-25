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
    pub topic: Option<String>,
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

pub fn decode_shell(frames: &[Bytes], _key_hex: &str) -> Result<JupyterMessage> {
    let delim_pos = frames.iter().position(|f| f.as_ref() == DELIM)
        .ok_or_else(|| anyhow!("no delimiter in message"))?;
    let base = delim_pos + 1;
    if frames.len() < base + 5 {
        return Err(anyhow!("message too short: {} frames", frames.len()));
    }
    let header: Value = serde_json::from_slice(&frames[base + 1])?;
    let parent_header: Value = serde_json::from_slice(&frames[base + 2])?;
    let metadata: Value = serde_json::from_slice(&frames[base + 3])?;
    let content: Value = serde_json::from_slice(&frames[base + 4])?;
    Ok(JupyterMessage { topic: None, header, parent_header, metadata, content })
}

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
        "a2f22b4e9d3a1c8b7f60e5d4c3b2a190"
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
        frames.insert(0, Bytes::from_static(b"stream"));
        let decoded = decode_iopub(&frames, test_key()).unwrap();
        assert_eq!(decoded.topic.as_deref(), Some("stream"));
        assert_eq!(decoded.content["name"], "stdout");
    }
}
