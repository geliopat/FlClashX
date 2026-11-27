//! Content-addressed releases are immutable. The service owns this directory;
//! never write a caller-supplied path or overwrite a bundled executable.
use super::core_release::{valid_hash, Manifest, CORE_NAME, MAX_BINARY, MAX_MANIFEST};
use std::ffi::{c_void, OsStr};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::windows::ffi::OsStrExt;
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::os::windows::io::AsRawHandle;
use std::path::{Component, Path, PathBuf, Prefix};
use std::ptr::null_mut;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};
use windows_sys::Win32::Foundation::{LocalFree, HANDLE};
use windows_sys::Win32::Security::Authorization::{
    ConvertSecurityDescriptorToStringSecurityDescriptorW,
    ConvertStringSecurityDescriptorToSecurityDescriptorW, GetSecurityInfo, SDDL_REVISION_1,
    SE_FILE_OBJECT,
};
use windows_sys::Win32::Security::{
    DACL_SECURITY_INFORMATION, OWNER_SECURITY_INFORMATION, SECURITY_ATTRIBUTES,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateDirectoryW, FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS,
    FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_READ, FILE_SHARE_WRITE,
};

pub const MAX_PACKAGE: u64 = MAX_BINARY + MAX_MANIFEST as u64 + 4;
const MANIFEST_NAME: &str = "core-manifest.json";
const STORE_NAME: &str = "core-releases";
// Protected DACL: only SYSTEM and local Administrators, inherited by children.
// Explicit SYSTEM owner prevents an ordinary account from planting a lookalike.
const STORE_SDDL: &str = "O:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";
const READ_ATTRIBUTES: u32 = 0x80;
const READ_CONTROL: u32 = 0x20000;
static STAGE_SEQ: AtomicU64 = AtomicU64::new(0);

struct LocalAllocation(*mut c_void);
impl Drop for LocalAllocation {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: this pointer was returned by a LocalAlloc-based API.
            unsafe { LocalFree(self.0) };
        }
    }
}

fn wide(value: &OsStr) -> Vec<u16> {
    value.encode_wide().chain(Some(0)).collect()
}

fn directory_handle(path: &Path) -> io::Result<File> {
    let file = OpenOptions::new()
        .access_mode(READ_ATTRIBUTES | READ_CONTROL)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_dir() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(io::Error::other("Core store directory is not a real directory"));
    }
    Ok(file)
}

fn file_handle(path: &Path) -> io::Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .share_mode(FILE_SHARE_READ)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(io::Error::other("Core release is not a real file"));
    }
    Ok(file)
}

fn security_descriptor() -> io::Result<LocalAllocation> {
    let sddl = wide(OsStr::new(STORE_SDDL));
    let mut descriptor = null_mut();
    // SAFETY: SDDL is NUL-terminated and the output is LocalFree-owned.
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(), SDDL_REVISION_1, &mut descriptor, null_mut(),
        )
    } == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(LocalAllocation(descriptor))
}

fn descriptor_string(descriptor: *mut c_void) -> io::Result<String> {
    let mut value = null_mut();
    let mut length = 0;
    // SAFETY: descriptor is live and output buffer is owned by LocalFree.
    if unsafe {
        ConvertSecurityDescriptorToStringSecurityDescriptorW(
            descriptor, SDDL_REVISION_1, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            &mut value, &mut length,
        )
    } == 0 {
        return Err(io::Error::last_os_error());
    }
    let _guard = LocalAllocation(value.cast());
    if value.is_null() || length == 0 || length > 16 * 1024 {
        return Err(io::Error::other("Invalid core store security descriptor"));
    }
    // The reported length includes the terminal NUL.
    let text = String::from_utf16_lossy(unsafe {
        std::slice::from_raw_parts(value, length as usize)
    });
    Ok(text.trim_end_matches('\0').replace("D:PAI", "D:P"))
}

fn verify_store_security(handle: &File) -> io::Result<()> {
    let mut actual = null_mut();
    // SAFETY: open handle is kept alive, output descriptor is LocalFree-owned.
    let error = unsafe {
        GetSecurityInfo(
            handle.as_raw_handle() as HANDLE, SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            null_mut(), null_mut(), null_mut(), null_mut(), &mut actual,
        )
    };
    if error != 0 {
        return Err(io::Error::from_raw_os_error(error as i32));
    }
    let actual = LocalAllocation(actual);
    let expected = security_descriptor()?;
    if descriptor_string(actual.0)? != descriptor_string(expected.0)? {
        return Err(io::Error::other("Core store ACL/owner mismatch; no unsafe fallback"));
    }
    Ok(())
}

fn create_store(path: &Path) -> io::Result<()> {
    let descriptor = security_descriptor()?;
    let attrs = SECURITY_ATTRIBUTES {
        nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor.0,
        bInheritHandle: 0,
    };
    let path = wide(path.as_os_str());
    // SAFETY: NUL-terminated local path and live security descriptor.
    if unsafe { CreateDirectoryW(path.as_ptr(), &attrs) } == 0 {
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::AlreadyExists {
            return Err(error);
        }
    }
    Ok(())
}

struct Store {
    path: PathBuf,
    // Hold ancestors and the store without delete sharing so a path cannot be
    // renamed or replaced between validation and CreateProcess.
    guards: Vec<File>,
}

impl Store {
    fn open(create: bool) -> io::Result<Self> {
        let exe = std::env::current_exe()?;
        let parent = exe.parent().ok_or_else(|| io::Error::other("Missing Helper directory"))?;
        if !matches!(parent.components().next(), Some(Component::Prefix(p))
            if matches!(p.kind(), Prefix::Disk(_) | Prefix::VerbatimDisk(_)))
            || !parent.is_absolute()
        {
            return Err(io::Error::other("Independent core store requires a local drive"));
        }
        let mut ancestors: Vec<_> = parent.ancestors().collect();
        ancestors.reverse();
        let mut guards = Vec::new();
        for path in ancestors {
            // Path::ancestors may include a drive prefix with no root separator.
            if path.is_absolute() {
                guards.push(directory_handle(path)?);
            }
        }
        let path = parent.join(STORE_NAME);
        if create {
            create_store(&path)?;
        }
        let guard = directory_handle(&path)?;
        verify_store_security(&guard)?;
        guards.push(guard);
        Ok(Self { path, guards })
    }
}

pub struct VerifiedRelease {
    pub path: PathBuf,
    pub file: File,
    pub guards: Vec<File>,
}

pub fn open_release(hash: &str) -> io::Result<VerifiedRelease> {
    if !valid_hash(hash, 64) {
        return Err(io::Error::other("Invalid core release hash"));
    }
    open_in_store(Store::open(false)?, hash)
}

fn open_in_store(mut store: Store, hash: &str) -> io::Result<VerifiedRelease> {
    let dir = store.path.join(hash);
    store.guards.push(directory_handle(&dir)?);
    let mut manifest_file = file_handle(&dir.join(MANIFEST_NAME))?;
    let mut bytes = Vec::new();
    (&mut manifest_file).take((MAX_MANIFEST + 1) as u64).read_to_end(&mut bytes)?;
    let manifest = Manifest::verify(&bytes)?;
    if manifest.hash() != hash {
        return Err(io::Error::other("Core store identity mismatch"));
    }
    let path = dir.join(CORE_NAME);
    let mut file = file_handle(&path)?;
    if file.metadata()?.len() != manifest.size() {
        return Err(io::Error::other("Core release size mismatch"));
    }
    manifest.verify_reader(&mut file)?;
    // Keep both the immutable manifest and binary locked through launch.
    store.guards.push(manifest_file);
    Ok(VerifiedRelease { path, file, guards: store.guards })
}

fn write_new(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut file = OpenOptions::new()
        .write(true).create_new(true).share_mode(0)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT).open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

/// Package: four-byte big-endian manifest length, JSON bytes, exact EXE bytes.
/// No path from the wire is used to write a privileged file.
pub fn stage(package: &[u8]) -> io::Result<String> {
    let (manifest_bytes, binary) = split_package(package)?;
    let manifest = Manifest::verify(manifest_bytes)?;
    manifest.verify_reader(binary)?;
    let hash = manifest.hash().to_owned();
    let store = Store::open(true)?;
    let destination = store.path.join(&hash);
    if destination.try_exists()? {
        open_in_store(store, &hash)?;
        return Ok(hash);
    }

    // A new directory, under a verified protected parent. Never overwrite
    // an existing slot. If interrupted before rename the incomplete slot
    // remains invisible to the launch path.
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH)
        .map_err(io::Error::other)?.as_nanos();
    let sequence = STAGE_SEQ.fetch_add(1, Ordering::Relaxed);
    let staged = store.path.join(format!(".stage-{}-{stamp}-{sequence}", std::process::id()));
    fs::create_dir(&staged)?;
    let result = (|| {
        write_new(&staged.join(MANIFEST_NAME), manifest_bytes)?;
        write_new(&staged.join(CORE_NAME), binary)?;
        // The protected directory is writable only by the trusted service
        // or administrators; no other caller can plant a DLL or hardlink.
        fs::rename(&staged, &destination)?;
        open_in_store(store, &hash)?;
        Ok(hash)
    })();
    if result.is_err() {
        let _ = fs::remove_dir_all(&staged);
    }
    result
}

fn split_package(bytes: &[u8]) -> io::Result<(&[u8], &[u8])> {
    if bytes.len() as u64 > MAX_PACKAGE || bytes.len() < 4 {
        return Err(io::Error::other("Invalid core package length"));
    }
    let length = u32::from_be_bytes(bytes[..4].try_into().unwrap()) as usize;
    if length == 0 || length > MAX_MANIFEST || bytes.len() <= 4 + length {
        return Err(io::Error::other("Invalid core package manifest length"));
    }
    Ok((&bytes[4..4 + length], &bytes[4 + length..]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refuses_malformed_package_framing() {
        assert!(split_package(&[0, 0, 0, 0]).is_err());
        assert!(split_package(&[0, 0, 0, 5, 1, 2]).is_err());
        let (manifest, binary) = split_package(&[0, 0, 0, 2, 1, 2, 3, 4]).unwrap();
        assert_eq!(manifest, &[1, 2]);
        assert_eq!(binary, &[3, 4]);
    }

    #[test]
    fn rejects_non_hash_release_paths() {
        for value in ["..", "../x", "C:\\Windows", "FlClashCore.exe"] {
            assert!(open_release(value).is_err());
        }
    }
}
