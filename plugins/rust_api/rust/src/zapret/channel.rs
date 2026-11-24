use base64::Engine as _;
use futures_util::StreamExt;
use minisign_verify::{PublicKey, Signature};
use reqwest::header::{CACHE_CONTROL, USER_AGENT};
use serde::Deserialize;
use std::cmp::Ordering;

use crate::zapret::core::{CoreArtifact, CoreRelease};

const PRODUCTION_URL: &str =
    "https://raw.githubusercontent.com/larrriiin/zapret-ui/main/core-channel/stable.json";
const PRODUCTION_SIGNATURE_URL: &str =
    "https://raw.githubusercontent.com/larrriiin/zapret-ui/main/core-channel/stable.json.sig";
const CORE_CHANNEL_PUBLIC_KEY: &str = "RWSF180m7EnKBXIHk0nI+xssrK0ft4gpVAuq3H1BtC3ICzDhZV7pHFji";
const MAX_MANIFEST_BYTES: usize = 256 * 1024;
const MAX_SIGNATURE_BYTES: usize = 16 * 1024;

pub const FLOWSEAL_USER_AGENT: &str = "FlClashX-Flowseal-Installer";

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StableManifest {
    schema_version: u32,
    channel: String,
    provider: String,
    version: String,
    artifacts: Vec<ManifestArtifact>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ManifestArtifact {
    url: String,
    checksum: ManifestChecksum,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ManifestChecksum {
    algorithm: String,
    value: String,
}

impl StableManifest {
    fn parse_and_validate(bytes: &[u8], provider: &str) -> Result<CoreRelease, String> {
        if bytes.len() > MAX_MANIFEST_BYTES {
            return Err("Flowseal channel manifest exceeds 256 KiB".into());
        }
        let value: Self = serde_json::from_slice(bytes)
            .map_err(|_| "Flowseal channel manifest is not valid schema v1 JSON".to_string())?;
        if value.schema_version != 1 {
            return Err(format!(
                "Unsupported Flowseal channel schema: {}",
                value.schema_version
            ));
        }
        if value.channel != "stable" {
            return Err("Flowseal channel must be stable".into());
        }
        if value.provider != provider {
            return Err("Flowseal channel provider does not match".into());
        }
        if value.version.trim().is_empty() {
            return Err("Flowseal channel version is empty".into());
        }
        if value.artifacts.is_empty() {
            return Err("Flowseal stable channel contains no artifacts".into());
        }

        let artifacts = value
            .artifacts
            .into_iter()
            .map(|artifact| {
                let url = reqwest::Url::parse(&artifact.url)
                    .map_err(|_| "Flowseal artifact URL is invalid".to_string())?;
                if url.scheme() != "https" {
                    return Err("Flowseal artifacts must use HTTPS".into());
                }
                if artifact.checksum.algorithm != "sha256" {
                    return Err("Flowseal artifacts require SHA-256".into());
                }
                let digest = artifact.checksum.value;
                if digest.len() != 64 || !digest.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                    return Err("Flowseal SHA-256 must contain 64 hexadecimal characters".into());
                }
                if digest.bytes().any(|byte| byte.is_ascii_uppercase()) {
                    return Err("Flowseal SHA-256 must be lowercase".into());
                }
                Ok(CoreArtifact {
                    url: artifact.url,
                    sha256: digest,
                })
            })
            .collect::<Result<Vec<_>, String>>()?;

        Ok(CoreRelease {
            provider: value.provider,
            channel: value.channel,
            version: value.version,
            artifacts,
        })
    }
}

fn verify_signature(bytes: &[u8], signature_bytes: &[u8]) -> Result<(), String> {
    if signature_bytes.len() > MAX_SIGNATURE_BYTES {
        return Err("Flowseal channel signature exceeds 16 KiB".into());
    }
    let encoded = std::str::from_utf8(signature_bytes)
        .map_err(|_| "Flowseal channel signature is not UTF-8".to_string())?;
    let public_key = PublicKey::from_base64(CORE_CHANNEL_PUBLIC_KEY)
        .map_err(|error| format!("Embedded Flowseal channel public key is invalid: {error}"))?;

    let signature = match Signature::decode(encoded.trim()) {
        Ok(signature) => signature,
        Err(_) => {
            // The upstream channel publishes Tauri's Base64-encoded minisign
            // document. Plain minisign text remains accepted as well.
            let decoded = base64::engine::general_purpose::STANDARD
                .decode(encoded.trim())
                .map_err(|error| format!("Flowseal channel signature is invalid: {error}"))?;
            let decoded = std::str::from_utf8(&decoded)
                .map_err(|_| "Decoded Flowseal signature is not UTF-8".to_string())?;
            Signature::decode(decoded)
                .map_err(|error| format!("Flowseal channel signature is invalid: {error}"))?
        }
    };

    public_key
        .verify(bytes, &signature, false)
        .map_err(|error| format!("Flowseal channel signature verification failed: {error}"))
}

async fn download_limited(
    client: &reqwest::Client,
    url: &str,
    limit: usize,
) -> Result<Vec<u8>, String> {
    let response = client
        .get(url)
        .header(CACHE_CONTROL, "no-cache")
        .header(USER_AGENT, FLOWSEAL_USER_AGENT)
        .send()
        .await
        .map_err(|error| format!("Flowseal channel request failed: {error}"))?;
    if !response.status().is_success() {
        return Err(format!(
            "Flowseal channel returned HTTP {}",
            response.status()
        ));
    }
    if response
        .content_length()
        .is_some_and(|length| length > limit as u64)
    {
        return Err("Flowseal channel response is too large".into());
    }

    let mut body = Vec::new();
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|error| format!("Cannot read Flowseal channel: {error}"))?;
        if body.len().saturating_add(chunk.len()) > limit {
            return Err("Flowseal channel response is too large".into());
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

/// Resolves the signed stable Flowseal channel published by zapret-ui.
pub async fn resolve_stable(
    client: &reqwest::Client,
    provider: &str,
) -> Result<CoreRelease, String> {
    let manifest = download_limited(client, PRODUCTION_URL, MAX_MANIFEST_BYTES);
    let signature = download_limited(
        client,
        PRODUCTION_SIGNATURE_URL,
        MAX_SIGNATURE_BYTES,
    );
    let (manifest, signature) = futures_util::future::join(manifest, signature).await;
    let manifest = manifest?;
    let signature = signature?;
    verify_signature(&manifest, &signature)?;
    StableManifest::parse_and_validate(&manifest, provider)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VersionComparison {
    UpdateAvailable,
    UpToDate,
    Ahead,
    Unknown,
}

pub fn compare_versions(local: &str, stable: &str) -> VersionComparison {
    fn parse(value: &str) -> Option<Vec<u64>> {
        let trimmed = value.trim();
        let value = trimmed.strip_prefix('v').unwrap_or(trimmed);
        let mut parts: Vec<u64> = value
            .split('.')
            .map(str::parse)
            .collect::<Result<_, _>>()
            .ok()?;
        if !(2..=4).contains(&parts.len()) {
            return None;
        }
        while parts.last() == Some(&0) {
            parts.pop();
        }
        Some(parts)
    }

    match (parse(local), parse(stable)) {
        (Some(local), Some(stable)) => match local.cmp(&stable) {
            Ordering::Less => VersionComparison::UpdateAvailable,
            Ordering::Equal => VersionComparison::UpToDate,
            Ordering::Greater => VersionComparison::Ahead,
        },
        _ => VersionComparison::Unknown,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_manifest() -> Vec<u8> {
        format!(
            r#"{{"schemaVersion":1,"channel":"stable","provider":"flowseal","version":"1.2.3","artifacts":[{{"url":"https://example.invalid/a.zip","checksum":{{"algorithm":"sha256","value":"{}"}}}}]}}"#,
            "a".repeat(64)
        )
        .into_bytes()
    }

    #[test]
    fn validates_signed_manifest_payload_shape() {
        StableManifest::parse_and_validate(&valid_manifest(), "flowseal").unwrap();
    }

    #[test]
    fn rejects_wrong_provider_and_non_https_artifacts() {
        let valid = String::from_utf8(valid_manifest()).unwrap();
        assert!(StableManifest::parse_and_validate(valid.as_bytes(), "other").is_err());
        let http = valid.replace("https://", "http://");
        assert!(StableManifest::parse_and_validate(http.as_bytes(), "flowseal").is_err());
    }

    #[test]
    fn rejects_unsupported_schema_and_checksum_algorithm() {
        let valid = String::from_utf8(valid_manifest()).unwrap();
        let schema = valid.replace("\"schemaVersion\":1", "\"schemaVersion\":2");
        assert!(StableManifest::parse_and_validate(schema.as_bytes(), "flowseal").is_err());
        let checksum = valid.replace("\"algorithm\":\"sha256\"", "\"algorithm\":\"md5\"");
        assert!(StableManifest::parse_and_validate(checksum.as_bytes(), "flowseal").is_err());
    }

    #[test]
    fn rejects_uppercase_or_invalid_sha256() {
        let valid = String::from_utf8(valid_manifest()).unwrap();
        let uppercase = valid.replace(&"a".repeat(64), &"A".repeat(64));
        assert!(StableManifest::parse_and_validate(uppercase.as_bytes(), "flowseal").is_err());
        let invalid = valid.replace(&"a".repeat(64), &"g".repeat(64));
        assert!(StableManifest::parse_and_validate(invalid.as_bytes(), "flowseal").is_err());
    }

    #[test]
    fn compares_versions_without_treating_zero_suffix_as_an_update() {
        assert_eq!(
            compare_versions("1.2.2", "1.2.3"),
            VersionComparison::UpdateAvailable
        );
        assert_eq!(
            compare_versions("1.2", "1.2.0"),
            VersionComparison::UpToDate
        );
        assert_eq!(
            compare_versions("1.3.0", "1.2.3"),
            VersionComparison::Ahead
        );
        assert_eq!(
            compare_versions("Err", "1.2.3"),
            VersionComparison::Unknown
        );
    }

    #[test]
    fn refuses_invalid_signature_before_manifest_parsing() {
        assert!(verify_signature(b"not json", b"not a signature").is_err());
    }
}
