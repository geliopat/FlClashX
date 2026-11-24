use serde::{Deserialize, Serialize};
use std::{
    fs,
    path::{Path, PathBuf},
};

#[derive(Clone, Debug)]
pub struct CorePaths {
    root: PathBuf,
}

impl CorePaths {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn bin_dir(&self) -> PathBuf {
        self.root.join("bin")
    }

    pub fn lists_dir(&self) -> PathBuf {
        self.root.join("lists")
    }

    pub fn utils_dir(&self) -> PathBuf {
        self.root.join("utils")
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GameFilterSettings {
    pub mode: String,
    pub tcp_range: String,
    pub udp_range: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CoreArtifact {
    pub url: String,
    pub sha256: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CoreRelease {
    pub provider: String,
    pub channel: String,
    pub version: String,
    pub artifacts: Vec<CoreArtifact>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CoreManifest {
    pub schema_version: u32,
    pub provider: String,
    #[serde(default)]
    pub channel: Option<String>,
    pub version: String,
    pub source_url: Option<String>,
    pub checksum: Option<serde_json::Value>,
    pub strategy_count: usize,
    #[serde(default)]
    pub imported_legacy: bool,
}

impl CoreManifest {
    pub fn new(
        provider: String,
        version: String,
        source_url: Option<String>,
        checksum: Option<serde_json::Value>,
        strategy_count: usize,
        imported_legacy: bool,
    ) -> Self {
        Self {
            schema_version: 1,
            provider,
            channel: None,
            version,
            source_url,
            checksum,
            strategy_count,
            imported_legacy,
        }
    }

    /// Persist the provider manifest using a recoverable temp/backup swap.
    /// This mirrors zapret-ui's installation manifest semantics.
    pub fn write_atomic(&self, root: &Path) -> Result<(), String> {
        static MANIFEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
        let _guard = MANIFEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let path = root.join(".zapret-ui-core.json");
        let backup = root.join(".zapret-ui-core.json.backup");
        let temporary = root.join(format!(".zapret-ui-core.json.tmp-{}", std::process::id()));

        if temporary.exists() {
            fs::remove_file(&temporary)
                .map_err(|e| format!("Cannot remove stale temporary core manifest: {e}"))?;
        }
        if backup.exists() {
            if path.exists() {
                fs::remove_file(&backup)
                    .map_err(|e| format!("Cannot remove stale core manifest backup: {e}"))?;
            } else {
                fs::rename(&backup, &path)
                    .map_err(|e| format!("Cannot recover core manifest before writing: {e}"))?;
            }
        }

        let data = serde_json::to_vec_pretty(self)
            .map_err(|e| format!("Cannot serialize core manifest: {e}"))?;
        fs::write(&temporary, data)
            .map_err(|e| format!("Cannot write temporary core manifest: {e}"))?;

        if path.exists() {
            fs::rename(&path, &backup)
                .map_err(|e| format!("Cannot back up current core manifest: {e}"))?;
        }
        if let Err(error) = fs::rename(&temporary, &path) {
            if backup.exists() {
                let _ = fs::rename(&backup, &path);
            }
            let _ = fs::remove_file(&temporary);
            return Err(format!("Cannot activate core manifest: {error}"));
        }
        if backup.exists() {
            fs::remove_file(&backup)
                .map_err(|e| format!("Cannot remove committed core manifest backup: {e}"))?;
        }
        Ok(())
    }

    pub fn read(root: &Path) -> Result<Self, String> {
        let path = root.join(".zapret-ui-core.json");
        let data = fs::read(&path).map_err(|e| {
            format!(
                "Core manifest is missing or unreadable ({}): {e}",
                path.display()
            )
        })?;
        let value: Self = serde_json::from_slice(&data)
            .map_err(|e| format!("Core manifest is corrupted: {e}"))?;
        if value.schema_version != 1 {
            return Err(format!(
                "Unsupported core manifest schema version: {}",
                value.schema_version
            ));
        }
        Ok(value)
    }
}

pub trait CoreProvider: Send + Sync {
    fn provider_name(&self) -> &'static str;
    fn paths(&self) -> &CorePaths;
    fn ipset_url(&self) -> &'static str;
    fn winws_executable(&self) -> PathBuf;
    fn local_version(&self) -> String;
    fn is_installed(&self) -> bool;
    fn strategies(&self) -> Result<Vec<String>, String>;

    fn strategies_readonly(&self) -> Result<Vec<String>, String> {
        self.strategies()
    }

    fn parse_strategy(
        &self,
        strategy: &str,
        game_filter: &GameFilterSettings,
    ) -> Result<String, String>;

    fn import_custom_strategy(&self, name: &str, content: &str) -> Result<(), String>;
    fn validate_installation(&self) -> Result<(String, usize), String>;
    fn finalize_installation(&self) -> Result<(), String>;
}
