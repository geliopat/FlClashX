use crate::zapret::{
    channel::FLOWSEAL_USER_AGENT,
    core::CoreProvider,
    ipset::{self, UpdateResult},
    providers::flowseal::FlowsealProvider,
};
use futures_util::StreamExt;
use std::{
    fs,
    net::IpAddr,
    path::{Path, PathBuf},
    str::FromStr,
    time::Duration,
};

const ACTIVE_LIST: &str = "ipset-all.txt";
const BACKUP_LIST: &str = "ipset-all.txt.backup";
const NONE_SENTINEL: &str = "203.0.113.113/32";
const DEFAULT_IPSET: &str = "185.65.148.0/22\r\n192.229.128.0/17\r\n";
const MAX_DOWNLOAD_BYTES: usize = 32 * 1024 * 1024;

fn resolve_paths(root: &Path) -> Result<(PathBuf, PathBuf), String> {
    let root_metadata = fs::symlink_metadata(root)
        .map_err(|error| format!("Cannot inspect Flowseal directory: {error}"))?;
    if root_metadata.file_type().is_symlink() || !root_metadata.is_dir() {
        return Err("Flowseal installation directory must be a real directory".into());
    }
    let root = fs::canonicalize(root)
        .map_err(|error| format!("Cannot resolve Flowseal directory: {error}"))?;

    let requested_lists = root.join("lists");
    let lists_metadata = fs::symlink_metadata(&requested_lists)
        .map_err(|error| format!("Cannot inspect Flowseal lists directory: {error}"))?;
    if lists_metadata.file_type().is_symlink() || !lists_metadata.is_dir() {
        return Err("Flowseal lists path must be a real directory".into());
    }
    let lists = fs::canonicalize(&requested_lists)
        .map_err(|error| format!("Cannot resolve Flowseal lists directory: {error}"))?;
    if !lists.starts_with(&root) {
        return Err("Flowseal lists directory resolves outside the installation".into());
    }

    let active = lists.join(ACTIVE_LIST);
    let backup = lists.join(BACKUP_LIST);
    for (path, label) in [(&active, "active IPSet list"), (&backup, "IPSet backup")] {
        match fs::symlink_metadata(path) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err(format!("Flowseal {label} must not be a symbolic link"));
            }
            Ok(metadata) if !metadata.is_file() => {
                return Err(format!("Flowseal {label} is not a regular file"));
            }
            Ok(_) => {
                let canonical = fs::canonicalize(path)
                    .map_err(|error| format!("Cannot resolve Flowseal {label}: {error}"))?;
                if canonical.parent() != Some(lists.as_path()) {
                    return Err(format!("Flowseal {label} escapes the lists directory"));
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(format!("Cannot inspect Flowseal {label}: {error}")),
        }
    }
    Ok((active, backup))
}

fn valid_ip_or_cidr(value: &str) -> bool {
    if value.is_empty() || value.len() > 128 {
        return false;
    }
    let (address, prefix) = match value.split_once('/') {
        Some((address, prefix)) if !prefix.is_empty() => {
            let Ok(prefix) = prefix.parse::<u8>() else {
                return false;
            };
            (address, Some(prefix))
        }
        Some(_) => return false,
        None => (value, None),
    };
    let Ok(address) = IpAddr::from_str(address) else {
        return false;
    };
    match (address, prefix) {
        (IpAddr::V4(_), Some(prefix)) => prefix <= 32,
        (IpAddr::V6(_), Some(prefix)) => prefix <= 128,
        (_, None) => true,
    }
}

fn validate_download(content: &str) -> Result<usize, String> {
    let mut count = 0usize;
    for (index, raw) in content.lines().enumerate() {
        let line = raw.trim().trim_start_matches('\u{feff}');
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if !valid_ip_or_cidr(line) {
            return Err(format!(
                "Downloaded IPSet contains an invalid address at line {}",
                index + 1
            ));
        }
        count += 1;
        if count > 1_000_000 {
            return Err("Downloaded IPSet contains too many entries".into());
        }
    }
    if count == 0 {
        return Err("Downloaded IPSet does not contain any IP ranges".into());
    }
    Ok(count)
}

pub fn status(root: &Path) -> Result<String, String> {
    let (active, _) = resolve_paths(root)?;
    let content = match fs::read_to_string(&active) {
        Ok(content) => content,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(error) => return Err(format!("Cannot read Flowseal IPSet list: {error}")),
    };
    Ok(crate::zapret::ipset_mode(&content).to_owned())
}

pub fn set_mode(root: &Path, mode: &str) -> Result<String, String> {
    let (active, backup) = resolve_paths(root)?;
    match mode {
        "none" => {
            fs::write(&active, format!("{NONE_SENTINEL}\r\n"))
                .map_err(|error| format!("Cannot disable Flowseal IPSet filter: {error}"))?;
        }
        "any" => {
            if active.exists() && !backup.exists() {
                let content = fs::read_to_string(&active)
                    .map_err(|error| format!("Cannot read active Flowseal IPSet list: {error}"))?;
                let nonempty = content
                    .lines()
                    .map(str::trim)
                    .filter(|line| !line.is_empty())
                    .collect::<Vec<_>>();
                if !nonempty.is_empty() && !nonempty.iter().any(|line| *line == NONE_SENTINEL) {
                    fs::copy(&active, &backup)
                        .map_err(|error| format!("Cannot back up Flowseal IPSet list: {error}"))?;
                }
            }
            fs::write(&active, "")
                .map_err(|error| format!("Cannot clear Flowseal IPSet list: {error}"))?;
        }
        "loaded" => {
            if backup.exists() {
                let content = fs::read_to_string(&backup)
                    .map_err(|error| format!("Cannot read Flowseal IPSet backup: {error}"))?;
                let nonempty = content
                    .lines()
                    .map(str::trim)
                    .filter(|line| !line.is_empty())
                    .collect::<Vec<_>>();
                if !nonempty.is_empty() && !nonempty.iter().any(|line| *line == NONE_SENTINEL) {
                    fs::copy(&backup, &active)
                        .map_err(|error| format!("Cannot restore Flowseal IPSet backup: {error}"))?;
                } else {
                    fs::write(&active, DEFAULT_IPSET)
                        .map_err(|error| format!("Cannot initialize Flowseal IPSet list: {error}"))?;
                }
            } else {
                fs::write(&active, DEFAULT_IPSET)
                    .map_err(|error| format!("Cannot initialize Flowseal IPSet list: {error}"))?;
            }
        }
        _ => return Err("Unsupported Flowseal IPSet filter mode".into()),
    }
    status(root)
}

pub async fn update(root: &Path) -> Result<UpdateResult, String> {
    let (active, _) = resolve_paths(root)?;
    let provider = FlowsealProvider::new(root.to_path_buf());
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|error| format!("Cannot create IPSet download client: {error}"))?;
    let response = client
        .get(provider.ipset_url())
        .header(reqwest::header::USER_AGENT, FLOWSEAL_USER_AGENT)
        .header(reqwest::header::CACHE_CONTROL, "no-cache")
        .send()
        .await
        .map_err(|error| format!("Cannot download Flowseal IPSet list: {error}"))?
        .error_for_status()
        .map_err(|error| format!("Flowseal IPSet download failed: {error}"))?;

    if response
        .content_length()
        .is_some_and(|length| length > MAX_DOWNLOAD_BYTES as u64)
    {
        return Err("Downloaded Flowseal IPSet exceeds the 32 MiB size limit".into());
    }

    let mut stream = response.bytes_stream();
    let mut bytes = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|error| format!("Cannot read Flowseal IPSet response: {error}"))?;
        if bytes.len().saturating_add(chunk.len()) > MAX_DOWNLOAD_BYTES {
            return Err("Downloaded Flowseal IPSet exceeds the 32 MiB size limit".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    let content = String::from_utf8(bytes)
        .map_err(|error| format!("Flowseal IPSet response is not valid UTF-8: {error}"))?;
    let count = validate_download(&content)?;
    let mut result = ipset::install_if_changed(&active, &content)?;
    result.count = count;
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static NEXT_DIRECTORY: AtomicUsize = AtomicUsize::new(0);

    struct TestRoot(PathBuf);

    impl TestRoot {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "flowseal-ipset-{}-{}",
                std::process::id(),
                NEXT_DIRECTORY.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(root.join("lists")).unwrap();
            Self(root)
        }
    }

    impl Drop for TestRoot {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn validates_ipv4_and_ipv6_addresses_and_ranges() {
        for valid in [
            "192.0.2.1",
            "192.0.2.0/24",
            "0.0.0.0/0",
            "2001:db8::1",
            "2001:db8::/32",
            "::/0",
        ] {
            assert!(valid_ip_or_cidr(valid), "{valid}");
        }
        for invalid in [
            "",
            "256.0.0.1",
            "192.0.2.1/33",
            "2001:db8::/129",
            "192.0.2.1/-1",
            "192.0.2.1/",
            "example.com",
            "1.2.3.4/8/9",
        ] {
            assert!(!valid_ip_or_cidr(invalid), "{invalid}");
        }
    }

    #[test]
    fn rejects_empty_and_non_ip_downloads() {
        assert!(validate_download("").is_err());
        assert!(validate_download("# only a comment\n").is_err());
        assert!(validate_download("<html>not a list</html>").is_err());
        assert!(validate_download("192.0.2.1\nnot-an-ip").is_err());
        assert_eq!(validate_download("192.0.2.1\n2001:db8::/32\n").unwrap(), 2);
    }

    #[test]
    fn changes_ipset_modes_and_restores_the_previous_list() {
        let root = TestRoot::new();
        let active = root.0.join("lists").join(ACTIVE_LIST);
        fs::write(&active, "# comment\r\n192.0.2.0/24\r\n").unwrap();

        assert_eq!(set_mode(&root.0, "any").unwrap(), "any");
        assert_eq!(
            fs::read_to_string(root.0.join("lists").join(BACKUP_LIST)).unwrap(),
            "# comment\r\n192.0.2.0/24\r\n"
        );
        assert_eq!(set_mode(&root.0, "loaded").unwrap(), "loaded");
        assert_eq!(fs::read_to_string(active).unwrap(), "# comment\r\n192.0.2.0/24\r\n");
        assert_eq!(set_mode(&root.0, "none").unwrap(), "none");
        assert_eq!(set_mode(&root.0, "loaded").unwrap(), "loaded");
    }

    #[test]
    fn rejects_invalid_mode_and_symlinked_files() {
        let root = TestRoot::new();
        assert!(set_mode(&root.0, "bad").is_err());

        let outside = root.0.join("outside.txt");
        fs::write(&outside, "192.0.2.1").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&outside, root.0.join("lists").join(ACTIVE_LIST)).unwrap();
        #[cfg(windows)]
        std::os::windows::fs::symlink_file(&outside, root.0.join("lists").join(ACTIVE_LIST)).unwrap();
        assert!(status(&root.0).is_err());
    }
}
