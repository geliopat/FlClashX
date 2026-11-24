//! Safe, allow-listed editing of the bundled Zapret text lists.
//! User-managed lists are never overwritten by remote list synchronization.

use serde::Serialize;
use std::io::{Error, ErrorKind, Write};
use std::path::PathBuf;

const LIST_FILES: &[&str] = &[
    "list-general.txt",
    "list-general-user.txt",
    "list-google.txt",
    "list-exclude.txt",
    "list-exclude-user.txt",
    "ipset-all.txt",
    "ipset-exclude.txt",
    "ipset-exclude-user.txt",
];
const MAX_LIST_BYTES: usize = 2 * 1024 * 1024;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ZapretListInfo {
    pub filename: String,
    pub bytes: u64,
    pub entries: usize,
    pub user_managed: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ZapretListContent {
    pub filename: String,
    pub content: String,
}

fn validate_name(filename: &str) -> Result<&'static str, Error> {
    LIST_FILES.iter().copied().find(|name| *name == filename)
        .ok_or_else(|| Error::new(ErrorKind::InvalidInput, "Unsupported Zapret list filename"))
}

#[cfg(windows)]
fn lists_dir() -> Result<PathBuf, Error> {
    let helper = std::env::current_exe()?;
    let app_dir = helper.parent()
        .ok_or_else(|| Error::other("Helper executable has no parent directory"))?;
    let app_dir = std::fs::canonicalize(app_dir)?;
    let requested = app_dir.join("zapret").join("lists");
    let dir = std::fs::canonicalize(&requested).map_err(|error| {
        Error::other(format!("Zapret lists directory is unavailable: {error}"))
    })?;
    if !dir.is_dir() || !dir.starts_with(&app_dir) {
        return Err(Error::new(ErrorKind::PermissionDenied, "Zapret lists directory resolves outside the application directory"));
    }
    Ok(dir)
}

#[cfg(not(windows))]
fn lists_dir() -> Result<PathBuf, Error> {
    Err(Error::new(ErrorKind::Unsupported, "Zapret lists are available only on Windows"))
}

fn list_path(filename: &str) -> Result<PathBuf, Error> {
    let name = validate_name(filename)?;
    Ok(lists_dir()?.join(name))
}

fn count_entries(content: &str) -> usize {
    content.lines().filter(|line| {
        let line = line.trim();
        !line.is_empty() && !line.starts_with('#')
    }).count()
}

pub fn list() -> Result<Vec<ZapretListInfo>, Error> {
    let dir = lists_dir()?;
    LIST_FILES.iter().map(|filename| {
        let path = dir.join(filename);
        let content = if path.exists() { std::fs::read_to_string(&path)? } else { String::new() };
        let bytes = std::fs::metadata(&path).map(|meta| meta.len()).unwrap_or(0);
        Ok(ZapretListInfo {
            filename: (*filename).to_string(),
            bytes,
            entries: count_entries(&content),
            user_managed: filename.ends_with("-user.txt"),
        })
    }).collect()
}

pub fn read(filename: &str) -> Result<ZapretListContent, Error> {
    let name = validate_name(filename)?;
    let path = list_path(name)?;
    let content = std::fs::read_to_string(path)?;
    Ok(ZapretListContent { filename: name.to_string(), content })
}

pub fn write(filename: &str, content: String) -> Result<ZapretListInfo, Error> {
    let name = validate_name(filename)?;
    if content.len() > MAX_LIST_BYTES {
        return Err(Error::new(ErrorKind::InvalidInput, "Zapret list exceeds the 2 MiB limit"));
    }
    if content.contains('\0') {
        return Err(Error::new(ErrorKind::InvalidInput, "Zapret list contains a NUL byte"));
    }
    let normalized = content.replace("\r\n", "\n").replace('\r', "\n");
    if normalized.lines().any(|line| line.len() > 4096) {
        return Err(Error::new(ErrorKind::InvalidInput, "Zapret list contains a line longer than 4096 bytes"));
    }

    let target = list_path(name)?;
    let dir = target.parent().ok_or_else(|| Error::other("Invalid Zapret list path"))?;
    let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default().as_millis();
    let temp = dir.join(format!(".{name}.{}.{}.tmp", std::process::id(), stamp));
    let backup = dir.join(format!("{name}.bak"));

    let mut file = std::fs::OpenOptions::new().write(true).create_new(true).open(&temp)?;
    file.write_all(normalized.as_bytes())?;
    file.sync_all()?;
    drop(file);

    if target.exists() {
        std::fs::copy(&target, &backup)?;
    }

    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Storage::FileSystem::{MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH};
        let from: Vec<u16> = temp.as_os_str().encode_wide().chain(Some(0)).collect();
        let to: Vec<u16> = target.as_os_str().encode_wide().chain(Some(0)).collect();
        let moved = unsafe { MoveFileExW(from.as_ptr(), to.as_ptr(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) };
        if moved == 0 {
            let error = Error::last_os_error();
            let _ = std::fs::remove_file(&temp);
            return Err(error);
        }
    }
    #[cfg(not(windows))]
    {
        std::fs::rename(&temp, &target)?;
    }

    let metadata = std::fs::metadata(&target)?;
    Ok(ZapretListInfo {
        filename: name.to_string(),
        bytes: metadata.len(),
        entries: count_entries(&normalized),
        user_managed: name.ends_with("-user.txt"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_known_list_files_are_accepted() {
        assert!(validate_name("list-general.txt").is_ok());
        assert!(validate_name("list-general-user.txt").is_ok());
        assert!(validate_name("../secrets.txt").is_err());
        assert!(validate_name("list-general.txt.bak").is_err());
    }

    #[test]
    fn entry_count_ignores_comments_and_empty_lines() {
        assert_eq!(count_entries("# header\nexample.org\n\n^ads.example\n"), 2);
    }
}
