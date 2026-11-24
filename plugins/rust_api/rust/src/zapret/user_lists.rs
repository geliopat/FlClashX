use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    fs,
    net::Ipv4Addr,
    path::{Path, PathBuf},
    str::FromStr,
};

const ALLOWED_LISTS: [&str; 3] = [
    "list-general-user.txt",
    "list-exclude-user.txt",
    "ipset-exclude-user.txt",
];
const MAX_LIST_BYTES: u64 = 2 * 1024 * 1024;
const MAX_LIST_ENTRIES: usize = 10_000;

/// Resolve a user-editable list without following a symlink outside the
/// selected Flowseal installation.
fn resolve_path(root: &Path, filename: &str) -> Result<PathBuf, String> {
    if !ALLOWED_LISTS.contains(&filename) {
        return Err(format!("Unsupported Flowseal user list: {filename}"));
    }

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

    let path = lists.join(filename);
    match fs::symlink_metadata(&path) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            Err(format!("Flowseal user list must not be a symbolic link: {filename}"))
        }
        Ok(metadata) if !metadata.is_file() => {
            Err(format!("Flowseal user list is not a regular file: {filename}"))
        }
        Ok(_) => {
            let canonical = fs::canonicalize(&path)
                .map_err(|error| format!("Cannot resolve Flowseal user list {filename}: {error}"))?;
            if canonical.parent() != Some(lists.as_path()) {
                return Err(format!("Flowseal user list escapes its directory: {filename}"));
            }
            Ok(canonical)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(path),
        Err(error) => Err(format!("Cannot inspect Flowseal user list {filename}: {error}")),
    }
}

fn normalize_entry(filename: &str, value: &str) -> Result<String, String> {
    let mut value = value.trim().to_owned();
    if value.is_empty() || value.len() > 253 || value.chars().any(char::is_control) {
        return Err("List entry is empty, too long, or contains control characters".into());
    }

    if filename == "ipset-exclude-user.txt" {
        let (address, prefix) = match value.split_once('/') {
            Some((address, prefix)) => {
                let prefix = prefix
                    .parse::<u8>()
                    .map_err(|_| format!("Invalid IPv4 prefix length: {value}"))?;
                if prefix > 32 {
                    return Err(format!("IPv4 prefix length must be between 0 and 32: {value}"));
                }
                (address, Some(prefix))
            }
            None => (value.as_str(), None),
        };
        let address = Ipv4Addr::from_str(address)
            .map_err(|_| format!("Invalid IPv4 address or CIDR: {value}"))?;
        value = match prefix {
            Some(prefix) => format!("{address}/{prefix}"),
            None => address.to_string(),
        };
        return Ok(value);
    }

    let mut domain = value.to_ascii_lowercase();
    if let Some(rest) = domain.strip_prefix("https://") {
        domain = rest.to_owned();
    } else if let Some(rest) = domain.strip_prefix("http://") {
        domain = rest.to_owned();
    }
    if let Some(rest) = domain.strip_prefix("www.") {
        domain = rest.to_owned();
    }
    domain = domain.split('/').next().unwrap_or_default().to_owned();

    let valid = domain.len() <= 253
        && domain.contains('.')
        && domain.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && label.as_bytes()[0].is_ascii_alphanumeric()
                && label.as_bytes()[label.len() - 1].is_ascii_alphanumeric()
                && label
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
        && domain
            .rsplit('.')
            .next()
            .is_some_and(|suffix| {
                suffix.len() >= 2 && suffix.bytes().all(|byte| byte.is_ascii_lowercase())
            });
    if !valid {
        return Err(format!("Invalid domain name: {value}"));
    }
    Ok(domain)
}

fn read_raw_lines(path: &Path) -> Result<Vec<String>, String> {
    let data = match fs::read(path) {
        Ok(data) => data,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(format!("Cannot read Flowseal user list: {error}")),
    };
    if data.len() as u64 > MAX_LIST_BYTES {
        return Err("Flowseal user list exceeds the 2 MiB size limit".into());
    }
    let content = String::from_utf8(data)
        .map_err(|error| format!("Flowseal user list is not valid UTF-8: {error}"))?;
    let content = content.trim_start_matches('\u{feff}');
    Ok(content.lines().map(str::to_owned).collect())
}

fn write_raw_lines(path: &Path, lines: &[String]) -> Result<(), String> {
    if lines.len() > MAX_LIST_ENTRIES {
        return Err(format!("Flowseal user list exceeds {MAX_LIST_ENTRIES} entries"));
    }
    let content = lines.join("\r\n");
    fs::write(path, content).map_err(|error| format!("Cannot write Flowseal user list: {error}"))
}

fn visible_entries(lines: &[String]) -> Vec<String> {
    lines
        .iter()
        .map(|line| line.trim())
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(str::to_owned)
        .collect()
}

pub fn read(root: &Path, filename: &str) -> Result<Vec<String>, String> {
    let path = resolve_path(root, filename)?;
    Ok(visible_entries(&read_raw_lines(&path)?))
}

pub fn add(root: &Path, filename: &str, value: &str) -> Result<Vec<String>, String> {
    let path = resolve_path(root, filename)?;
    let entry = normalize_entry(filename, value)?;
    let mut lines = read_raw_lines(&path)?;
    let duplicate = lines.iter().any(|line| {
        let line = line.trim();
        !line.is_empty()
            && !line.starts_with('#')
            && line.eq_ignore_ascii_case(&entry)
    });
    if !duplicate {
        if visible_entries(&lines).len() >= MAX_LIST_ENTRIES {
            return Err(format!("Flowseal user list exceeds {MAX_LIST_ENTRIES} entries"));
        }
        lines.push(entry);
        write_raw_lines(&path, &lines)?;
    }
    Ok(visible_entries(&lines))
}

pub fn remove(root: &Path, filename: &str, value: &str) -> Result<Vec<String>, String> {
    let path = resolve_path(root, filename)?;
    let entry = normalize_entry(filename, value)?;
    let lines = read_raw_lines(&path)?;
    let remaining: Vec<String> = lines
        .into_iter()
        .filter(|line| {
            let trimmed = line.trim();
            trimmed.is_empty()
                || trimmed.starts_with('#')
                || !trimmed.eq_ignore_ascii_case(&entry)
        })
        .collect();
    write_raw_lines(&path, &remaining)?;
    Ok(visible_entries(&remaining))
}

pub fn replace(root: &Path, filename: &str, values: &[String]) -> Result<Vec<String>, String> {
    if values.len() > MAX_LIST_ENTRIES {
        return Err(format!("Import exceeds {MAX_LIST_ENTRIES} entries"));
    }
    let path = resolve_path(root, filename)?;
    let mut seen = HashSet::new();
    let mut normalized = Vec::new();
    for value in values {
        let value = value.trim();
        if value.is_empty() || value.starts_with('#') {
            continue;
        }
        let entry = normalize_entry(filename, value)?;
        let key = entry.to_ascii_lowercase();
        if seen.insert(key) {
            normalized.push(entry);
        }
    }
    write_raw_lines(&path, &normalized)?;
    Ok(normalized)
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
                "flowseal-user-lists-{}-{}",
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
    fn normalizes_domains_like_the_reference_ui() {
        assert_eq!(
            normalize_entry("list-general-user.txt", " HTTPS://WWW.Example.COM/path ")
                .unwrap(),
            "example.com"
        );
        assert_eq!(
            normalize_entry("list-exclude-user.txt", "sub-domain.example.org").unwrap(),
            "sub-domain.example.org"
        );
        for invalid in ["example", "-bad.example.com", "bad..example.com", "bad.example.1", "bad.example.com:443", "#comment"] {
            assert!(normalize_entry("list-general-user.txt", invalid).is_err(), "{invalid}");
        }
    }

    #[test]
    fn validates_ipv4_and_cidr_entries() {
        assert_eq!(
            normalize_entry("ipset-exclude-user.txt", "192.0.2.1/24").unwrap(),
            "192.0.2.1/24"
        );
        assert_eq!(
            normalize_entry("ipset-exclude-user.txt", "10.0.0.1").unwrap(),
            "10.0.0.1"
        );
        for invalid in ["256.0.0.1", "192.0.2.1/33", "192.0.2.1/-1", "1.2.3.4/8/9"] {
            assert!(normalize_entry("ipset-exclude-user.txt", invalid).is_err(), "{invalid}");
        }
    }

    #[test]
    fn only_allows_the_three_reference_user_lists() {
        let root = TestRoot::new();
        for filename in ["list-general-user.txt", "list-exclude-user.txt", "ipset-exclude-user.txt"] {
            assert!(read(&root.0, filename).unwrap().is_empty());
        }
        for filename in ["../../outside.txt", "ipset-all.txt", "strategies.json", "custom.txt"] {
            assert!(read(&root.0, filename).is_err(), "{filename}");
        }
    }

    #[test]
    fn add_and_remove_preserve_comments_and_deduplicate() {
        let root = TestRoot::new();
        let path = root.0.join("lists").join("list-general-user.txt");
        fs::write(&path, "# user comment\r\nold.example.com\r\n").unwrap();

        let added = add(&root.0, "list-general-user.txt", "HTTPS://WWW.New.Example/path").unwrap();
        assert_eq!(added, ["old.example.com", "new.example"]);
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "# user comment\r\nold.example.com\r\nnew.example"
        );
        let duplicate = add(&root.0, "list-general-user.txt", "NEW.EXAMPLE").unwrap();
        assert_eq!(duplicate.len(), 2);

        let removed = remove(&root.0, "list-general-user.txt", "old.example.com").unwrap();
        assert_eq!(removed, ["new.example"]);
        assert!(fs::read_to_string(path).unwrap().starts_with("# user comment"));
    }

    #[test]
    fn bulk_replace_validates_every_entry_before_changing_the_file() {
        let root = TestRoot::new();
        let path = root.0.join("lists").join("list-general-user.txt");
        fs::write(&path, "keep.example.com").unwrap();

        let invalid = vec!["valid.example.com".to_owned(), "not a domain".to_owned()];
        assert!(replace(&root.0, "list-general-user.txt", &invalid).is_err());
        assert_eq!(fs::read_to_string(&path).unwrap(), "keep.example.com");

        let imported = replace(
            &root.0,
            "list-general-user.txt",
            &[
                "Example.com".to_owned(),
                "example.com".to_owned(),
                "# ignored".to_owned(),
                "other.example.org".to_owned(),
            ],
        )
        .unwrap();
        assert_eq!(imported, ["example.com", "other.example.org"]);
    }

    #[test]
    fn rejects_symlinked_list_files() {
        let root = TestRoot::new();
        let outside = root.0.join("outside.txt");
        fs::write(&outside, "example.com").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&outside, root.0.join("lists/list-general-user.txt")).unwrap();
        #[cfg(windows)]
        std::os::windows::fs::symlink_file(&outside, root.0.join("lists/list-general-user.txt")).unwrap();
        assert!(read(&root.0, "list-general-user.txt").is_err());
    }
}


#[derive(Serialize, Deserialize)]
struct BackupData {
    version: u32,
    include: Vec<String>,
    exclude: Vec<String>,
    ips: Vec<String>,
}

pub struct BackupSnapshot {
    pub include: Vec<String>,
    pub exclude: Vec<String>,
    pub ips: Vec<String>,
}

fn normalize_backup_entries(filename: &str, values: &[String]) -> Result<Vec<String>, String> {
    if values.len() > MAX_LIST_ENTRIES {
        return Err(format!("Backup exceeds {MAX_LIST_ENTRIES} entries per list"));
    }
    let mut seen = HashSet::new();
    let mut result = Vec::new();
    for value in values {
        let value = value.trim();
        if value.is_empty() || value.starts_with('#') {
            continue;
        }
        let value = normalize_entry(filename, value)?;
        if seen.insert(value.to_ascii_lowercase()) {
            result.push(value);
        }
    }
    Ok(result)
}

pub fn export_backup(root: &Path) -> Result<String, String> {
    let backup = BackupData {
        version: 1,
        include: read(root, "list-general-user.txt")?,
        exclude: read(root, "list-exclude-user.txt")?,
        ips: read(root, "ipset-exclude-user.txt")?,
    };
    serde_json::to_string_pretty(&backup)
        .map_err(|error| format!("Cannot serialize Flowseal backup: {error}"))
}

pub fn import_backup(root: &Path, content: &str) -> Result<BackupSnapshot, String> {
    if content.len() > 8 * 1024 * 1024 {
        return Err("Flowseal backup exceeds the 8 MiB size limit".into());
    }
    let backup: BackupData = serde_json::from_str(content.trim_start_matches('\u{feff}'))
        .map_err(|error| format!("Invalid Flowseal backup file: {error}"))?;
    if backup.version != 1 {
        return Err(format!("Unsupported Flowseal backup version: {}", backup.version));
    }

    // Validate and normalize every list before reading or writing any target.
    let include = normalize_backup_entries("list-general-user.txt", &backup.include)?;
    let exclude = normalize_backup_entries("list-exclude-user.txt", &backup.exclude)?;
    let ips = normalize_backup_entries("ipset-exclude-user.txt", &backup.ips)?;
    let paths = [
        resolve_path(root, "list-general-user.txt")?,
        resolve_path(root, "list-exclude-user.txt")?,
        resolve_path(root, "ipset-exclude-user.txt")?,
    ];
    let originals: Vec<Option<Vec<u8>>> = paths
        .iter()
        .map(|path| match fs::read(path) {
            Ok(data) => {
                if data.len() as u64 > MAX_LIST_BYTES {
                    Err(format!("Existing list is too large to back up: {}", path.display()))
                } else {
                    Ok(Some(data))
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(format!("Cannot read existing list {}: {error}", path.display())),
        })
        .collect::<Result<_, _>>()?;

    let lists = [&include, &exclude, &ips];
    for (index, (path, entries)) in paths.iter().zip(lists).enumerate() {
        if let Err(error) = write_raw_lines(path, entries) {
            let mut message = format!("Cannot restore Flowseal backup: {error}");
            // The failed write may have truncated its target, so restore it too.
            for (restore_path, original) in paths[..=index].iter().zip(&originals) {
                let restored = match original {
                    Some(data) => fs::write(restore_path, data),
                    None => match fs::remove_file(restore_path) {
                        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
                        result => result,
                    },
                };
                if let Err(restore_error) = restored {
                    message.push_str(&format!(
                        "; failed to restore {}: {restore_error}",
                        restore_path.display()
                    ));
                }
            }
            return Err(message);
        }
    }

    Ok(BackupSnapshot {
        include,
        exclude,
        ips,
    })
}


#[cfg(test)]
mod backup_tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static NEXT_DIRECTORY: AtomicUsize = AtomicUsize::new(0);

    struct TestRoot(PathBuf);

    impl TestRoot {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "flowseal-user-list-backup-{}-{}",
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
    fn exports_and_restores_all_three_lists() {
        let root = TestRoot::new();
        replace(&root.0, "list-general-user.txt", &["include.example.com".into()]).unwrap();
        replace(&root.0, "list-exclude-user.txt", &["exclude.example.com".into()]).unwrap();
        replace(&root.0, "ipset-exclude-user.txt", &["192.0.2.0/24".into()]).unwrap();

        let backup = export_backup(&root.0).unwrap();
        replace(&root.0, "list-general-user.txt", &[]).unwrap();
        replace(&root.0, "list-exclude-user.txt", &[]).unwrap();
        replace(&root.0, "ipset-exclude-user.txt", &[]).unwrap();

        let snapshot = import_backup(&root.0, &backup).unwrap();
        assert_eq!(snapshot.include, ["include.example.com"]);
        assert_eq!(snapshot.exclude, ["exclude.example.com"]);
        assert_eq!(snapshot.ips, ["192.0.2.0/24"]);
    }

    #[test]
    fn validates_every_list_before_replacing_any_file() {
        let root = TestRoot::new();
        let include_path = root.0.join("lists/list-general-user.txt");
        let exclude_path = root.0.join("lists/list-exclude-user.txt");
        fs::write(&include_path, "# preserve comment\nold.example.com\n").unwrap();
        fs::write(&exclude_path, "old-exclude.example.com").unwrap();

        let invalid = r#"{"version":1,"include":["new.example.com"],"exclude":["not a domain"],"ips":[]}"#;
        assert!(import_backup(&root.0, invalid).is_err());
        assert_eq!(fs::read_to_string(include_path).unwrap(), "# preserve comment\nold.example.com\n");
        assert_eq!(fs::read_to_string(exclude_path).unwrap(), "old-exclude.example.com");
    }

    #[test]
    fn rejects_unsupported_version_and_deduplicates_entries() {
        let root = TestRoot::new();
        assert!(import_backup(&root.0, r#"{"version":2,"include":[],"exclude":[],"ips":[]}"#).is_err());

        let content = r#"{"version":1,"include":["Example.com","example.com"],"exclude":[],"ips":["192.0.2.1","192.0.2.1"]}"#;
        let snapshot = import_backup(&root.0, content).unwrap();
        assert_eq!(snapshot.include, ["example.com"]);
        assert_eq!(snapshot.ips, ["192.0.2.1"]);
    }
}
