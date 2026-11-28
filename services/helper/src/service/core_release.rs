//! Independent core authorization. A signed manifest is not a launch lease:
//! the caller must hold the verified executable and protected directory open.
use base64::{engine::general_purpose::STANDARD, Engine};
use ed25519_dalek::{Signature, VerifyingKey};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::io::{self, Read};

pub const MAX_MANIFEST: usize = 16 * 1024;
pub const MAX_BINARY: u64 = 256 * 1024 * 1024;
pub const CORE_NAME: &str = "FlClashCore.exe";
pub const IPC_REVISION: u32 = 1;
const PUBLIC_KEY: &str = env!("FLCLASHZ_CORE_UPDATE_PUBLIC_KEY");

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Manifest {
    schema: u32,
    product: String,
    version: String,
    mihomo_version: String,
    engine_revision: String,
    host_revision: String,
    ipc_revision: u32,
    os: String,
    arch: String,
    name: String,
    size: u64,
    sha256: String,
    // URLs are transport metadata, never authority to open a local file.
    #[serde(rename = "url")]
    _url: String,
    signature: String,
}

pub fn valid_hash(value: &str, length: usize) -> bool {
    value.len() == length && value.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn valid_number(value: &str) -> bool {
    !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit())
        && (value == "0" || !value.starts_with('0'))
}

fn upstream_version(value: &str) -> Option<&str> {
    if value.len() > 96 {
        return None;
    }
    let (upstream, revision) = value.split_once("-z.")?;
    let numbers: Vec<_> = upstream.strip_prefix('v')?.split('.').collect();
    if numbers.len() != 3 || !numbers.iter().all(|x| valid_number(x))
        || !valid_number(revision) || revision == "0" {
        return None;
    }
    Some(upstream)
}

impl Manifest {
    pub fn verify(bytes: &[u8]) -> io::Result<Self> {
        Self::verify_with_key(bytes, PUBLIC_KEY)
    }

    fn verify_with_key(bytes: &[u8], public_key: &str) -> io::Result<Self> {
        if bytes.is_empty() || bytes.len() > MAX_MANIFEST {
            return Err(io::Error::other("Invalid core manifest length"));
        }
        let manifest: Self = serde_json::from_slice(bytes)
            .map_err(|_| io::Error::other("Invalid core manifest JSON"))?;
        if manifest.schema != 1 || manifest.product != "FlClashZ-core"
            || upstream_version(&manifest.version) != Some(manifest.mihomo_version.as_str())
            || manifest.ipc_revision != IPC_REVISION || manifest.os != "windows"
            || manifest.arch != "amd64" || manifest.name != CORE_NAME
            || !valid_hash(&manifest.engine_revision, 40)
            || !valid_hash(&manifest.host_revision, 40)
            || !valid_hash(&manifest.sha256, 64)
            || manifest.size == 0 || manifest.size > MAX_BINARY {
            return Err(io::Error::other("Incompatible core manifest identity"));
        }
        let public_bytes: [u8; 32] = STANDARD.decode(public_key.trim())
            .ok().and_then(|x| x.try_into().ok())
            .ok_or_else(|| io::Error::other("Core release public key is not configured"))?;
        let key = VerifyingKey::from_bytes(&public_bytes)
            .map_err(|_| io::Error::other("Invalid core release public key"))?;
        let signature_bytes: [u8; 64] = STANDARD.decode(&manifest.signature)
            .ok().and_then(|x| x.try_into().ok())
            .ok_or_else(|| io::Error::other("Invalid core release signature encoding"))?;
        key.verify_strict(manifest.signing_bytes().as_bytes(), &Signature::from_bytes(&signature_bytes))
            .map_err(|_| io::Error::other("Core release signature mismatch"))?;
        Ok(manifest)
    }

    fn signing_bytes(&self) -> String {
        format!(
            "flclashz-core-manifest-v1\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n",
            self.schema, self.product, self.version, self.mihomo_version,
            self.engine_revision, self.host_revision, self.ipc_revision, self.os,
            self.arch, self.name, self.size, self.sha256
        )
    }

    pub fn hash(&self) -> &str {
        &self.sha256
    }

    pub fn size(&self) -> u64 {
        self.size
    }

    pub fn verify_reader(&self, mut reader: impl Read) -> io::Result<()> {
        let mut remaining = self.size;
        let mut hasher = Sha256::new();
        let mut buffer = [0u8; 64 * 1024];
        while remaining > 0 {
            let limit = remaining.min(buffer.len() as u64) as usize;
            let count = reader.read(&mut buffer[..limit])?;
            if count == 0 {
                return Err(io::Error::other("Core release truncated"));
            }
            hasher.update(&buffer[..count]);
            remaining -= count as u64;
        }
        if reader.read(&mut buffer[..1])? != 0 || format!("{:x}", hasher.finalize()) != self.sha256 {
            return Err(io::Error::other("Core release hash or size mismatch"));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    // Independently generated fixture using Ed25519 seed bytes 0..31. This is
    // a public test key, never the production release signing key.
    const KEY: &str = "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=";
    const JSON: &str = r#"{"schema":1,"product":"FlClashZ-core","version":"v1.19.34-z.2","mihomoVersion":"v1.19.34","engineRevision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","hostRevision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","ipcRevision":1,"os":"windows","arch":"amd64","name":"FlClashCore.exe","size":17,"sha256":"4b6add73f177ebfb9c02f0316b70a4bf1bc3c73d9199c1964194e5b4f078244e","url":"https://example.com/core.exe","signature":"uwHIJSmA8VVNi33h6dtCOQSL4lExnP/v9Spe6hOFFCxpE1Gsh+YvMorZVUJTgIeziCqQOPpXh4EIO562bJiaDw=="}"#;

    #[test]
    fn authenticates_same_contract_as_go_signer_and_dart() {
        let manifest = Manifest::verify_with_key(JSON.as_bytes(), KEY).unwrap();
        assert_eq!(manifest.size(), 17);
        assert!(manifest.verify_reader(&b"test core payload"[..]).is_ok());
        assert!(manifest.verify_reader(&b"test core payloae"[..]).is_err());
        assert!(manifest.verify_reader(&b"test core payload!"[..]).is_err());
        assert!(manifest.verify_reader(&b"test core"[..]).is_err());
    }

    #[test]
    fn authenticates_published_core_with_compiled_release_key() {
        let Some(directory) = std::env::var_os("FLCLASHZ_TEST_SIGNED_CORE_DIR") else {
            return;
        };
        let directory = std::path::PathBuf::from(directory);
        let bytes = std::fs::read(directory.join("core-manifest.json")).unwrap();
        let manifest = Manifest::verify(&bytes).unwrap();
        assert_eq!(manifest.version, "v1.19.34-z.2");
        assert_eq!(manifest.engine_revision, "88b3bc4604b0008ce08a8c5634b8f9ddd573d533");
        assert_eq!(manifest.host_revision, "8640948576d11e707a9306c17ac432ae29a125c4");
        let file = std::fs::File::open(directory.join(CORE_NAME)).unwrap();
        manifest.verify_reader(file).unwrap();
    }

    #[test]
    fn refuses_changed_identity_or_missing_key() {
        assert!(Manifest::verify_with_key(JSON.as_bytes(), "").is_err());
        for modified in [
            JSON.replace("v1.19.34-z.2", "v1.19.34-z.3"),
            JSON.replace("\"ipcRevision\":1", "\"ipcRevision\":2"),
            JSON.replace("amd64", "arm64"),
            JSON.replace("FlClashCore.exe", "..\\\\evil.exe"),
            JSON.replace("\"size\":17", "\"size\":18"),
        ] {
            assert!(Manifest::verify_with_key(modified.as_bytes(), KEY).is_err());
        }
        assert!(Manifest::verify_with_key(JSON.replace("example.com", "mirror.example.com").as_bytes(), KEY).is_ok());
    }
}
