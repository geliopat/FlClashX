use crate::zapret::{
    channel::{compare_versions, resolve_stable, VersionComparison, FLOWSEAL_USER_AGENT},
    core::{CoreManifest, CoreProvider},
    providers::flowseal::FlowsealProvider,
    runtime,
};
use futures_util::StreamExt;
use reqwest::header::{CACHE_CONTROL, USER_AGENT};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::{self, Write},
    path::{Component, Path, PathBuf},
    sync::OnceLock,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use zip::ZipArchive;

const MAX_ARCHIVE_BYTES: u64 = 1024 * 1024 * 1024;
const MAX_UNPACKED_BYTES: u64 = 2 * 1024 * 1024 * 1024;
const MAX_ARCHIVE_ENTRIES: usize = 20_000;
const USER_LIST_FILES: [&str; 4] = [
    "list-general-user.txt",
    "list-exclude-user.txt",
    "ipset-exclude-user.txt",
    crate::zapret::ipset::USER_INCLUDE_FILE,
];
const ACTIVE_FAKE_FILES: [&str; 2] = ["ACTIVE_DISCORD_UDP.bin", "ACTIVE_GAME_UDP.bin"];
const CUSTOM_STRATEGIES_DIR: &str = "custom-strategies";

fn operation_lock() -> &'static tokio::sync::Mutex<()> {
    static LOCK: OnceLock<tokio::sync::Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| tokio::sync::Mutex::new(()))
}

struct DirectoryCleanup {
    path: PathBuf,
}

impl DirectoryCleanup {
    fn new(path: PathBuf) -> Self {
        Self { path }
    }
}

impl Drop for DirectoryCleanup {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

fn timestamp() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
}

fn prepare_root(requested: &Path) -> Result<(PathBuf, PathBuf, String), String> {
    let name = requested
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty() && *value != "." && *value != "..")
        .ok_or_else(|| "Flowseal installation path must name a directory".to_string())?;
    let parent = requested.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)
        .map_err(|error| format!("Cannot create Flowseal parent directory: {error}"))?;
    let parent = fs::canonicalize(parent)
        .map_err(|error| format!("Cannot resolve Flowseal parent directory: {error}"))?;
    let root = parent.join(name);
    if let Ok(metadata) = fs::symlink_metadata(&root) {
        if metadata.file_type().is_symlink() {
            return Err("Flowseal installation directory must not be a symbolic link".into());
        }
        if !metadata.is_dir() {
            return Err("Flowseal installation path is not a directory".into());
        }
    }
    Ok((root, parent, name.to_owned()))
}

fn is_empty_directory(path: &Path) -> Result<bool, String> {
    let mut entries = fs::read_dir(path)
        .map_err(|error| format!("Cannot inspect Flowseal destination: {error}"))?;
    Ok(entries.next().is_none())
}

fn is_managed_flowseal_backup(path: &Path) -> bool {
    if fs::symlink_metadata(path)
        .is_ok_and(|metadata| metadata.file_type().is_symlink() || !metadata.is_dir())
    {
        return false;
    }
    CoreManifest::read(path).is_ok_and(|manifest| manifest.provider == "flowseal")
}

fn recover_previous(root: &Path, previous: &Path) -> Result<(), String> {
    if !root.exists() && previous.exists() {
        if !is_managed_flowseal_backup(previous) {
            return Err(
                "A previous Flowseal backup exists but its manifest is invalid; manual recovery is required"
                    .into(),
            );
        }
        fs::rename(previous, root)
            .map_err(|error| format!("Cannot recover previous Flowseal installation: {error}"))?;
    }
    Ok(())
}

fn write_legacy_manifest(root: &Path, provider: &FlowsealProvider) -> Result<String, String> {
    let (version, strategy_count) = provider.validate_installation()?;
    if !root.join(".zapret-ui-core.json").is_file() {
        let manifest = CoreManifest::new(
            provider.provider_name().to_owned(),
            version.clone(),
            None,
            None,
            strategy_count,
            true,
        );
        manifest.write_atomic(root)?;
    }
    provider.finalize_installation()?;
    Ok(version)
}

fn preserve_user_files(from: &Path, to: &Path) -> Result<(), String> {
    let destination_lists = to.join("lists");
    fs::create_dir_all(&destination_lists)
        .map_err(|error| format!("Cannot create Flowseal lists directory: {error}"))?;
    for name in USER_LIST_FILES {
        let source = from.join("lists").join(name);
        match fs::symlink_metadata(&source) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err(format!("User list cannot be a symbolic link: {}", source.display()));
            }
            Ok(metadata) if metadata.is_file() => {
                fs::copy(&source, destination_lists.join(name))
                    .map_err(|error| format!("Cannot preserve {name}: {error}"))?;
            }
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(format!("Cannot inspect user list {}: {error}", source.display()));
            }
        }
    }

    let destination_bin = to.join("bin");
    fs::create_dir_all(&destination_bin)
        .map_err(|error| format!("Cannot create Flowseal bin directory: {error}"))?;
    for name in ACTIVE_FAKE_FILES {
        let source = from.join("bin").join(name);
        match fs::symlink_metadata(&source) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err(format!("Flowseal fake file cannot be a symbolic link: {}", source.display()));
            }
            Ok(metadata) if metadata.is_file() => {
                fs::copy(&source, destination_bin.join(name))
                    .map_err(|error| format!("Cannot preserve {name}: {error}"))?;
            }
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(format!("Cannot inspect Flowseal fake file {}: {error}", source.display()));
            }
        }
    }

    let custom_source = from.join(CUSTOM_STRATEGIES_DIR);
    if !custom_source.exists() {
        return Ok(());
    }
    let metadata = fs::symlink_metadata(&custom_source)
        .map_err(|error| format!("Cannot inspect custom strategies directory: {error}"))?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err("Flowseal custom strategies path must be a real directory".into());
    }
    let custom_destination = to.join(CUSTOM_STRATEGIES_DIR);
    fs::create_dir_all(&custom_destination)
        .map_err(|error| format!("Cannot create custom strategies directory: {error}"))?;
    for entry in fs::read_dir(&custom_source)
        .map_err(|error| format!("Cannot read custom strategies directory: {error}"))?
    {
        let entry = entry.map_err(|error| format!("Cannot read custom strategy entry: {error}"))?;
        let metadata = entry
            .file_type()
            .map_err(|error| format!("Cannot inspect custom strategy: {error}"))?;
        if metadata.is_symlink() {
            return Err(format!(
                "Custom strategy cannot be a symbolic link: {}",
                entry.path().display()
            ));
        }
        let source = entry.path();
        if !metadata.is_file()
            || !source
                .extension()
                .and_then(|extension| extension.to_str())
                .is_some_and(|extension| extension.eq_ignore_ascii_case("bat"))
        {
            continue;
        }
        fs::copy(&source, custom_destination.join(entry.file_name())).map_err(|error| {
            format!("Cannot preserve custom strategy {}: {error}", source.display())
        })?;
    }
    Ok(())
}

async fn download_and_verify(
    client: &reqwest::Client,
    url: &str,
    expected_sha256: &str,
    destination: &Path,
) -> Result<(), String> {
    let response = client
        .get(url)
        .header(CACHE_CONTROL, "no-cache")
        .header(USER_AGENT, FLOWSEAL_USER_AGENT)
        .send()
        .await
        .map_err(|error| format!("Flowseal download request failed: {error}"))?;
    if !response.status().is_success() {
        return Err(format!(
            "Flowseal download returned HTTP {}",
            response.status()
        ));
    }
    if response.url().scheme() != "https" {
        return Err("Flowseal download redirected away from HTTPS".into());
    }
    if response
        .content_length()
        .is_some_and(|length| length > MAX_ARCHIVE_BYTES)
    {
        return Err("Flowseal archive exceeds the 1 GiB download limit".into());
    }

    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(destination)
        .map_err(|error| format!("Cannot create Flowseal archive file: {error}"))?;
    let mut hasher = Sha256::new();
    let mut downloaded = 0u64;
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|error| format!("Flowseal download stream failed: {error}"))?;
        downloaded = downloaded.saturating_add(chunk.len() as u64);
        if downloaded > MAX_ARCHIVE_BYTES {
            return Err("Flowseal archive exceeds the 1 GiB download limit".into());
        }
        file.write_all(&chunk)
            .map_err(|error| format!("Cannot write Flowseal archive: {error}"))?;
        hasher.update(&chunk);
    }
    file.sync_all()
        .map_err(|error| format!("Cannot flush Flowseal archive: {error}"))?;
    let actual = format!("{:x}", hasher.finalize());
    if actual != expected_sha256 {
        let _ = fs::remove_file(destination);
        return Err("Flowseal archive SHA-256 does not match the signed channel".into());
    }
    Ok(())
}

fn safe_archive_path(name: &str) -> Result<PathBuf, String> {
    let path = Path::new(name);
    if path.components().any(|component| {
        matches!(
            component,
            Component::ParentDir | Component::RootDir | Component::Prefix(_)
        )
    }) {
        return Err(format!("Unsafe path in Flowseal archive: {name}"));
    }
    path.components()
        .next()
        .ok_or_else(|| "Flowseal archive contains an empty path".to_string())?;
    Ok(path.to_path_buf())
}

fn extract_zip_safely(zip_path: &Path, destination: &Path) -> Result<(), String> {
    let file = File::open(zip_path)
        .map_err(|error| format!("Cannot open Flowseal archive: {error}"))?;
    let mut archive = ZipArchive::new(file)
        .map_err(|error| format!("Flowseal archive is not a valid ZIP: {error}"))?;
    if archive.len() > MAX_ARCHIVE_ENTRIES {
        return Err("Flowseal archive contains too many entries".into());
    }
    let canonical_destination = fs::canonicalize(destination)
        .map_err(|error| format!("Cannot resolve Flowseal extraction directory: {error}"))?;
    let mut total_unpacked = 0u64;

    for index in 0..archive.len() {
        let mut entry = archive
            .by_index(index)
            .map_err(|error| format!("Cannot read Flowseal archive entry: {error}"))?;
        let relative = entry
            .enclosed_name()
            .ok_or_else(|| format!("Unsafe path in Flowseal archive: {}", entry.name()))?;
        let relative = safe_archive_path(&relative.to_string_lossy())?;
        if entry
            .unix_mode()
            .is_some_and(|mode| mode & 0o170000 == 0o120000)
        {
            return Err(format!(
                "Flowseal archive contains a symbolic link: {}",
                relative.display()
            ));
        }

        total_unpacked = total_unpacked.saturating_add(entry.size());
        if total_unpacked > MAX_UNPACKED_BYTES {
            return Err("Flowseal archive expands beyond the 2 GiB limit".into());
        }
        let output = canonical_destination.join(&relative);
        if !output.starts_with(&canonical_destination) {
            return Err(format!(
                "Flowseal archive entry escapes the destination: {}",
                relative.display()
            ));
        }
        if entry.is_dir() {
            fs::create_dir_all(&output)
                .map_err(|error| format!("Cannot create Flowseal directory: {error}"))?;
            continue;
        }

        let parent = output
            .parent()
            .ok_or_else(|| "Flowseal archive entry has no parent directory".to_string())?;
        fs::create_dir_all(parent)
            .map_err(|error| format!("Cannot create Flowseal parent directory: {error}"))?;
        let mut output_file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&output)
            .map_err(|error| format!("Cannot create extracted Flowseal file: {error}"))?;
        let copied = io::copy(&mut entry, &mut output_file)
            .map_err(|error| format!("Cannot extract Flowseal file: {error}"))?;
        if copied != entry.size() {
            return Err(format!(
                "Flowseal archive entry was truncated: {}",
                relative.display()
            ));
        }
    }
    Ok(())
}

fn copy_directory_contents(source: &Path, destination: &Path) -> Result<(), String> {
    for entry in fs::read_dir(source)
        .map_err(|error| format!("Cannot read extracted Flowseal package: {error}"))?
    {
        let entry = entry.map_err(|error| format!("Cannot read extracted Flowseal entry: {error}"))?;
        let source_path = entry.path();
        let target_path = destination.join(entry.file_name());
        let metadata = fs::symlink_metadata(&source_path)
            .map_err(|error| format!("Cannot inspect extracted Flowseal entry: {error}"))?;
        if metadata.file_type().is_symlink() {
            return Err(format!(
                "Flowseal package contains a symbolic link: {}",
                source_path.display()
            ));
        }
        if metadata.is_dir() {
            fs::create_dir_all(&target_path)
                .map_err(|error| format!("Cannot create Flowseal directory: {error}"))?;
            copy_directory_contents(&source_path, &target_path)?;
        } else if metadata.is_file() {
            fs::copy(&source_path, &target_path)
                .map_err(|error| format!("Cannot copy Flowseal package file: {error}"))?;
        } else {
            return Err(format!(
                "Unsupported filesystem entry in Flowseal package: {}",
                source_path.display()
            ));
        }
    }
    Ok(())
}

fn preserve_previous_if_managed(previous: &Path) -> Result<(), String> {
    if !previous.exists() {
        return Ok(());
    }
    if !is_managed_flowseal_backup(previous) {
        return Err(
            "Reserved Flowseal previous-version path exists but is not a managed Flowseal backup"
                .into(),
        );
    }
    fs::remove_dir_all(previous)
        .map_err(|error| format!("Cannot remove the older Flowseal backup: {error}"))
}

/// Installs or updates the official signed Flowseal package into a user-writable
/// directory. No BAT, CMD, PowerShell, service manager, or SYSTEM process is run.
pub async fn install_or_update(requested_root: PathBuf) -> Result<String, String> {
    let _guard = operation_lock().lock().await;
    let (root, parent, name) = prepare_root(&requested_root)?;
    let previous = parent.join(format!(".flowseal-previous-{name}"));

    if runtime::status(&root)?.running {
        return Err("Stop winws.exe before installing or updating Flowseal".into());
    }
    recover_previous(&root, &previous)?;

    let active_provider = FlowsealProvider::new(root.clone());
    let active_installed = active_provider.is_installed();
    if root.exists() && !active_installed && !is_empty_directory(&root)? {
        return Err(
            "Flowseal destination is not empty and is not a recognized Flowseal installation"
                .into(),
        );
    }

    let client = reqwest::Client::builder()
        .user_agent(FLOWSEAL_USER_AGENT)
        .timeout(Duration::from_secs(15 * 60))
        .build()
        .map_err(|error| format!("Cannot create Flowseal HTTP client: {error}"))?;
    let release = resolve_stable(&client, "flowseal").await?;

    if active_installed {
        let local_version = active_provider.local_version();
        match compare_versions(&local_version, &release.version) {
            VersionComparison::UpToDate => {
                return Ok(format!("Flowseal is already up to date: {local_version}"));
            }
            VersionComparison::Ahead => {
                return Err(format!(
                    "Installed Flowseal version {local_version} is newer than stable {}",
                    release.version
                ));
            }
            VersionComparison::Unknown => {
                return Err(format!(
                    "Cannot safely compare installed Flowseal version '{local_version}' with stable {}",
                    release.version
                ));
            }
            VersionComparison::UpdateAvailable => {
                // Continue with the authenticated stable artifact.
            }
        }
        write_legacy_manifest(&root, &active_provider)?;
    }

    let temporary_root = std::env::temp_dir().join(format!(
        ".flowseal-download-{}-{}",
        std::process::id(),
        timestamp()
    ));
    fs::create_dir(&temporary_root)
        .map_err(|error| format!("Cannot create Flowseal temporary directory: {error}"))?;
    let _temporary_cleanup = DirectoryCleanup::new(temporary_root.clone());

    let archive_path = temporary_root.join("flowseal.zip");
    let mut selected = None;
    let mut last_error = None;
    for artifact in &release.artifacts {
        let _ = fs::remove_file(&archive_path);
        match download_and_verify(
            &client,
            &artifact.url,
            &artifact.sha256,
            &archive_path,
        )
        .await
        {
            Ok(()) => {
                selected = Some((artifact.url.clone(), artifact.sha256.clone()));
                break;
            }
            Err(error) => last_error = Some(error),
        }
    }
    let (source_url, verified_sha256) = selected.ok_or_else(|| {
        last_error.unwrap_or_else(|| "No verified Flowseal archive was available".into())
    })?;

    let staging = parent.join(format!(
        ".flowseal-staging-{}-{}",
        std::process::id(),
        timestamp()
    ));
    fs::create_dir(&staging)
        .map_err(|error| format!("Cannot create Flowseal staging directory: {error}"))?;
    let _staging_cleanup = DirectoryCleanup::new(staging.clone());
    let package = staging.join("package");
    fs::create_dir(&package)
        .map_err(|error| format!("Cannot prepare Flowseal extraction directory: {error}"))?;
    extract_zip_safely(&archive_path, &package)?;

    let entries = fs::read_dir(&package)
        .map_err(|error| format!("Cannot inspect extracted Flowseal package: {error}"))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("Cannot read extracted Flowseal package: {error}"))?;
    let extracted_root = if entries.len() == 1
        && entries[0]
            .file_type()
            .is_ok_and(|file_type| file_type.is_dir())
    {
        entries[0].path()
    } else {
        package.clone()
    };
    copy_directory_contents(&extracted_root, &staging)?;
    fs::remove_dir_all(&package)
        .map_err(|error| format!("Cannot clean Flowseal package staging: {error}"))?;

    if active_installed {
        preserve_user_files(&root, &staging)?;
    }

    let staging_provider = FlowsealProvider::new(staging.clone());
    let (actual_version, strategy_count) = staging_provider.validate_installation()?;
    if actual_version != release.version {
        return Err(format!(
            "Flowseal package version mismatch: signed channel {}, archive {}",
            release.version, actual_version
        ));
    }
    let manifest = CoreManifest::new(
        staging_provider.provider_name().to_owned(),
        actual_version.clone(),
        Some(source_url),
        Some(serde_json::json!({
            "algorithm": "sha256",
            "value": verified_sha256
        })),
        strategy_count,
        false,
    );
    let mut manifest = manifest;
    manifest.channel = Some(release.channel.clone());
    manifest.write_atomic(&staging)?;
    staging_provider.finalize_installation()?;
    staging_provider.validate_installation()?;

    let root_was_installed = active_installed && root.is_dir();
    if root_was_installed {
        preserve_previous_if_managed(&previous)?;
        fs::rename(&root, &previous)
            .map_err(|error| format!("Cannot move current Flowseal installation to backup: {error}"))?;
    } else if root.is_dir() {
        fs::remove_dir(&root)
            .map_err(|error| format!("Cannot replace empty Flowseal destination: {error}"))?;
    }

    if let Err(error) = fs::rename(&staging, &root) {
        if root_was_installed && previous.exists() {
            fs::rename(&previous, &root).map_err(|restore| {
                format!(
                    "Flowseal activation failed ({error}); restoring the previous installation also failed: {restore}"
                )
            })?;
        }
        return Err(format!("Cannot activate Flowseal installation: {error}"));
    }

    let installed_provider = FlowsealProvider::new(root.clone());
    let validation = installed_provider
        .validate_installation()
        .and_then(|_| installed_provider.finalize_installation());
    if let Err(error) = validation {
        let failed = parent.join(format!(
            ".flowseal-failed-{}-{}",
            std::process::id(),
            timestamp()
        ));
        fs::rename(&root, &failed).map_err(|move_error| {
            format!(
                "Installed Flowseal validation failed ({error}); cannot quarantine new package: {move_error}"
            )
        })?;
        if root_was_installed && previous.exists() {
            fs::rename(&previous, &root).map_err(|restore| {
                format!(
                    "Installed Flowseal validation failed ({error}); rollback failed: {restore}"
                )
            })?;
        }
        let _ = fs::remove_dir_all(&failed);
        return Err(format!(
            "Installed Flowseal package failed validation; previous installation restored: {error}"
        ));
    }

    Ok(format!(
        "{} ({strategy_count} Flowseal strategies)",
        release.version
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_archive_paths_with_parent_or_root_components() {
        assert!(safe_archive_path("../outside.txt").is_err());
        assert!(safe_archive_path(r"C:\outside.txt").is_err());
        assert!(safe_archive_path("/outside.txt").is_err());
        assert!(safe_archive_path("bin/winws.exe").is_ok());
    }

    #[test]
    fn cleanup_guard_removes_only_its_staging_directory() {
        let path = std::env::temp_dir().join(format!(
            "flowseal-cleanup-test-{}-{}",
            std::process::id(),
            timestamp()
        ));
        fs::create_dir(&path).unwrap();
        fs::write(path.join("marker"), b"test").unwrap();
        {
            let _cleanup = DirectoryCleanup::new(path.clone());
        }
        assert!(!path.exists());
    }
}
