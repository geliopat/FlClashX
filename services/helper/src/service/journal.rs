// Only the service account's private local data directory is used. No path
// is accepted from IPC. A different owner SID gets a separate journal.
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

const MAX_BYTES: u64 = 2 * 1024 * 1024;
const FILE_COUNT: usize = 4;
static DIRECTORY: OnceLock<PathBuf> = OnceLock::new();
static IO_LOCK: Mutex<()> = Mutex::new(());

pub(super) fn init(owner: &str) -> io::Result<()> {
    if !owner.starts_with("S-1-")
        || owner.len() <= 4
        || !owner[4..].chars().all(|c| c.is_ascii_digit() || c == '-')
    {
        return Err(io::Error::other("Invalid journal owner SID"));
    }
    let root = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .ok_or_else(|| io::Error::other("Service local data is unavailable"))?;
    let dir = root.join("FlClashZ").join("service-logs").join(owner);
    fs::create_dir_all(&dir)?;
    DIRECTORY
        .set(dir)
        .map_err(|_| io::Error::other("Journal already initialized"))
}

fn file_path(dir: &Path, index: usize) -> PathBuf {
    dir.join(format!("events-{index}.jsonl"))
}

fn append_at(dir: &Path, line: &[u8], max: u64) -> io::Result<()> {
    if line.len() as u64 + 1 > max {
        return Err(io::Error::other("Journal entry too large"));
    }
    let active = file_path(dir, 0);
    let len = match fs::metadata(&active) {
        Ok(meta) => meta.len(),
        Err(error) if error.kind() == io::ErrorKind::NotFound => 0,
        Err(error) => return Err(error),
    };
    if len + line.len() as u64 + 1 > max {
        let oldest = file_path(dir, FILE_COUNT - 1);
        if oldest.exists() {
            fs::remove_file(oldest)?;
        }
        for index in (0..FILE_COUNT - 1).rev() {
            let from = file_path(dir, index);
            if from.exists() {
                fs::rename(from, file_path(dir, index + 1))?;
            }
        }
    }
    let mut file = OpenOptions::new().create(true).append(true).open(active)?;
    file.write_all(line)?;
    file.write_all(b"\n")?;
    file.flush()
}

pub(super) fn append(line: &[u8]) -> io::Result<()> {
    let dir = DIRECTORY
        .get()
        .ok_or_else(|| io::Error::other("Journal unavailable"))?;
    let _guard = IO_LOCK.lock().unwrap_or_else(|error| error.into_inner());
    append_at(dir, line, MAX_BYTES)
}

pub(super) fn read() -> io::Result<String> {
    let dir = DIRECTORY
        .get()
        .ok_or_else(|| io::Error::other("Journal unavailable"))?;
    let _guard = IO_LOCK.lock().unwrap_or_else(|error| error.into_inner());
    let mut bytes = Vec::new();
    for index in (0..FILE_COUNT).rev() {
        match File::open(file_path(dir, index)) {
            Ok(file) => {
                file.take(MAX_BYTES).read_to_end(&mut bytes)?;
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
    }
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rotates_without_exceeding_the_limit() {
        let dir = std::env::temp_dir().join(format!(
            "flclashz-journal-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        for _ in 0..12 {
            append_at(&dir, b"123456789", 16).unwrap();
        }
        assert_eq!(fs::read_dir(&dir).unwrap().count(), FILE_COUNT);
        for entry in fs::read_dir(&dir).unwrap() {
            assert!(entry.unwrap().metadata().unwrap().len() <= 16);
        }
        fs::remove_dir_all(dir).unwrap();
    }
}
