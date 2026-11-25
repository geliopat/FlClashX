use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::VecDeque;
use std::convert::Infallible;
#[cfg(windows)]
use std::fs;
use std::fs::{File, OpenOptions};
use std::future::{pending, Future};
use std::io::{BufRead, Error, Read};
#[cfg(windows)]
use std::os::windows::fs::OpenOptionsExt;
#[cfg(windows)]
use std::os::windows::io::AsRawHandle;
#[cfg(windows)]
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};
use std::{io, thread};
use tokio::sync::oneshot;
use warp::http::StatusCode;
use warp::{Filter, Rejection, Reply};
#[cfg(windows)]
use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
#[cfg(windows)]
use windows_sys::Win32::Storage::FileSystem::FILE_SHARE_READ;
#[cfg(windows)]
use windows_sys::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS,
};
#[cfg(windows)]
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
    SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
};
#[cfg(windows)]
use windows_sys::Win32::System::Threading::{
    OpenProcess, QueryFullProcessImageNameW, TerminateProcess, WaitForSingleObject,
    PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_TERMINATE,
};

#[cfg(not(any(
    all(feature = "windows-service", target_os = "windows"),
    target_os = "linux"
)))]
const LISTEN_PORT: u16 = 47890;
#[cfg(not(target_os = "linux"))]
const CORE_PIPE_PREFIX: &str = r"\\.\pipe\FlClashCore_";
#[cfg(target_os = "linux")]
const CORE_SOCKET_PREFIX: &str = "/tmp/FlClashSocket_";
#[cfg(target_os = "linux")]
const CORE_SOCKET_SUFFIX: &str = ".sock";
#[cfg(windows)]
const PROTOCOL_VERSION_HEADER: &str = "x-flclashz-helper-protocol";
#[cfg(not(windows))]
const PROTOCOL_VERSION_HEADER: &str = "x-flclashx-helper-protocol";
#[cfg(windows)]
const PROTOCOL_VERSION: &str = "11";
#[cfg(windows)]
const HELPER_SHA256_HEADER: &str = "x-flclashz-helper-sha256";
#[cfg(windows)]
static RUNNING_HELPER_SHA256: Lazy<Result<String, Error>> = Lazy::new(|| {
    let mut file = File::open(std::env::current_exe()?)?;
    sha256_file(&mut file)
});
#[cfg(not(windows))]
const PROTOCOL_VERSION: &str = "6";
const EXPECTED_CORE_SHA256: &str = env!("CORE_SHA256");
const LOG_CAPACITY: usize = 100;
const MAX_REQUEST_BODY_BYTES: u64 = 4096;
const MAX_ZAPRET_LIST_BODY_BYTES: u64 = 5 * 1024 * 1024;
const CORE_EXIT_TIMEOUT: Duration = Duration::from_millis(1500);
const CORE_GRACEFUL_EXIT_TIMEOUT: Duration = Duration::from_millis(3000);
const CORE_EXIT_POLL_INTERVAL: Duration = Duration::from_millis(20);
const SHUTDOWN_DRAIN_TIMEOUT: Duration = Duration::from_millis(3000);

#[derive(Debug, Deserialize, Serialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct StartParams {
    pub address: String,
    #[serde(rename = "sessionId")]
    pub session_id: String,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct StopParams {
    #[serde(rename = "sessionId")]
    pub session_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct PingParams {
    #[serde(rename = "coreSha256")]
    core_sha256: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StartResponse {
    session_id: String,
    pid: u32,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StopResponse {
    session_id: String,
    stopped: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    reason: Option<&'static str>,
}

#[cfg(windows)]
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ZapretStatusResponse {
    running: bool,
    uptime_ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pid: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    strategy_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    engine: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    mode: Option<super::zapret::ZapretLaunchMode>,
    win_divert_filters: Vec<String>,
    processing_lists: Vec<String>,
    cleaned_processes: usize,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ZapretStartRequest {
    strategy_id: String,
    #[serde(default)]
    reason: Option<String>,
    #[serde(default)]
    debug: bool,
    #[serde(default)]
    watchdog: Option<bool>,
    #[serde(default)]
    infrastructure: super::zapret::ZapretInfrastructure,
    #[serde(default)]
    mode: super::zapret::ZapretLaunchMode,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ZapretWatchdogRequest {
    enabled: bool,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ZapretListWriteRequest {
    content: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ErrorDetails {
    os_error: i32,
}

#[derive(Serialize)]
struct ErrorResponse {
    code: &'static str,
    message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    details: Option<ErrorDetails>,
}

fn wait_for_child_exit(child: &mut Child, timeout: Duration) -> Result<bool, Error> {
    let deadline = Instant::now() + timeout;
    loop {
        if child.try_wait()?.is_some() {
            return Ok(true);
        }
        if Instant::now() >= deadline {
            return Ok(false);
        }
        thread::sleep(CORE_EXIT_POLL_INTERVAL);
    }
}

struct ManagedCore {
    session_id: String,
    child: Child,
    #[cfg(windows)]
    _job: Option<CoreJob>,
}

/// A Core its job refused, kept when it did not exit so that it stays owned
/// and a later stop can try again, as for any Core whose exit is unconfirmed.
#[cfg_attr(not(windows), allow(dead_code))]
struct ConfinementFailed {
    error: Error,
    unconfirmed: Option<ManagedCore>,
}

impl std::fmt::Debug for ConfinementFailed {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.error.fmt(formatter)
    }
}

impl ManagedCore {
    fn adopt(session_id: String, child: Child) -> Result<Self, ConfinementFailed> {
        #[cfg(windows)]
        let job = match CoreJob::bind(&child) {
            Ok(job) => job,
            // Dropping a Child leaves its process running, here outside a job.
            Err(error) => {
                let mut child = child;
                let _ = child.kill();
                let exited = matches!(wait_for_child_exit(&mut child, CORE_EXIT_TIMEOUT), Ok(true));
                return Err(ConfinementFailed {
                    error,
                    unconfirmed: (!exited).then_some(Self {
                        session_id,
                        child,
                        _job: None,
                    }),
                });
            }
        };
        Ok(Self {
            session_id,
            child,
            #[cfg(windows)]
            _job: Some(job),
        })
    }

    fn terminate(&mut self) -> Result<(), Error> {
        if self.request_exit() && self.wait_for_exit(CORE_GRACEFUL_EXIT_TIMEOUT)? {
            return Ok(());
        }
        let _ = self.child.kill();
        if self.wait_for_exit(CORE_EXIT_TIMEOUT)? {
            return Ok(());
        }
        Err(Error::other("Core did not exit after termination"))
    }

    fn wait_for_exit(&mut self, timeout: Duration) -> Result<bool, Error> {
        wait_for_child_exit(&mut self.child, timeout)
    }

    /// Only the TUN device dies with the process; SIGTERM lets the Core remove
    /// the policy routes sing-tun installed for it.
    #[cfg(target_os = "linux")]
    fn request_exit(&mut self) -> bool {
        // SAFETY: the child is unreaped, so its pid cannot have been recycled.
        unsafe { libc::kill(self.child.id() as libc::pid_t, libc::SIGTERM) == 0 }
    }

    #[cfg(not(target_os = "linux"))]
    fn request_exit(&mut self) -> bool {
        false
    }
}

/// Windows has no cgroup to take the Core down with a crashed Helper, so the
/// Core lives in a job that the kernel kills when the Helper's handle closes.
#[cfg(windows)]
struct CoreJob(HANDLE);

#[cfg(windows)]
impl CoreJob {
    fn bind(child: &Child) -> Result<Self, Error> {
        // SAFETY: plain kernel32 calls on handles this process owns; the job
        // handle is closed by Drop and the process handle stays with `child`.
        unsafe {
            let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            if job == 0 {
                return Err(Error::last_os_error());
            }
            let job = Self(job);
            let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if SetInformationJobObject(
                job.0,
                JobObjectExtendedLimitInformation,
                &limits as *const _ as *const _,
                std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            ) == 0
            {
                return Err(Error::last_os_error());
            }
            if AssignProcessToJobObject(job.0, child.as_raw_handle() as HANDLE) == 0 {
                return Err(Error::last_os_error());
            }
            Ok(job)
        }
    }
}

#[cfg(windows)]
impl Drop for CoreJob {
    fn drop(&mut self) {
        // SAFETY: the handle came from CreateJobObjectW and is closed once.
        unsafe {
            CloseHandle(self.0);
        }
    }
}

struct VerifiedCore {
    path: PathBuf,
    directory: PathBuf,
    _handle: File,
}

impl VerifiedCore {
    fn open() -> Result<Self, Error> {
        let path = core_path()?;
        let directory = path
            .parent()
            .ok_or_else(|| Error::other("Core executable has no parent directory"))?
            .to_path_buf();
        let handle = open_verified_core(&path, EXPECTED_CORE_SHA256)?;
        Ok(Self {
            path,
            directory,
            _handle: handle,
        })
    }

    fn spawn(&self, address: &str) -> Result<Child, Error> {
        let mut command = Command::new(&self.path);
        command
            .current_dir(&self.directory)
            .stderr(Stdio::piped())
            .arg(address);
        #[cfg(target_os = "linux")]
        adopt_core_owner(&mut command)?;
        command.spawn()
    }
}

/// The Core hands files back to its real UID only when that differs from its
/// effective one, so the child needs a setuid Core's split credentials.
#[cfg(target_os = "linux")]
fn adopt_core_owner(command: &mut Command) -> Result<(), Error> {
    use std::os::unix::process::CommandExt;

    let (uid, gid) = super::linux::core_owner()?;
    // SAFETY: async-signal-safe calls touching only this child, before exec.
    unsafe {
        command.pre_exec(move || {
            if libc::setresgid(gid, 0, 0) != 0 || libc::setresuid(uid, 0, 0) != 0 {
                return Err(Error::last_os_error());
            }
            Ok(())
        });
    }
    Ok(())
}

#[derive(Debug, PartialEq, Eq)]
enum StopDecision {
    NotRunning,
    Stop,
    SessionMismatch,
}

fn core_path() -> Result<PathBuf, Error> {
    let helper_path = std::env::current_exe()?;
    let directory = helper_path
        .parent()
        .ok_or_else(|| Error::other("helper executable has no parent directory"))?;
    Ok(directory.join(env!("CORE_NAME")))
}

fn open_core(path: &Path) -> Result<File, Error> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(windows)]
    options.share_mode(FILE_SHARE_READ);
    options.open(path)
}

fn sha256_file(file: &mut File) -> Result<String, Error> {
    let mut hasher = Sha256::new();
    let mut buffer = [0; 4096];

    loop {
        let bytes_read = file.read(&mut buffer)?;
        if bytes_read == 0 {
            break;
        }
        hasher.update(&buffer[..bytes_read]);
    }

    Ok(format!("{:x}", hasher.finalize()))
}

fn open_verified_core(path: &Path, expected_sha256: &str) -> Result<File, Error> {
    if expected_sha256.is_empty() {
        return Err(Error::other("expected Core SHA256 is empty"));
    }
    let mut core_file = open_core(path)?;
    if sha256_file(&mut core_file)? != expected_sha256 {
        return Err(Error::other("Core executable SHA256 mismatch"));
    }
    Ok(core_file)
}

#[cfg(not(target_os = "linux"))]
fn is_allowed_core_address(address: &str) -> bool {
    let Some(suffix) = address.strip_prefix(CORE_PIPE_PREFIX) else {
        return false;
    };
    is_valid_session_id(suffix)
}

#[cfg(target_os = "linux")]
fn is_allowed_core_address(address: &str) -> bool {
    let Some(suffix) = address.strip_prefix(CORE_SOCKET_PREFIX) else {
        return false;
    };
    let Some(digits) = suffix.strip_suffix(CORE_SOCKET_SUFFIX) else {
        return false;
    };
    !digits.is_empty() && digits.len() <= 10 && digits.bytes().all(|byte| byte.is_ascii_digit())
}

fn is_valid_session_id(value: &str) -> bool {
    value.len() == 32
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn stop_decision(current: Option<&str>, requested: &str) -> StopDecision {
    match current {
        None => StopDecision::NotRunning,
        Some(session_id) if session_id == requested => StopDecision::Stop,
        Some(_) => StopDecision::SessionMismatch,
    }
}

static LOGS: Lazy<Mutex<VecDeque<String>>> =
    Lazy::new(|| Mutex::new(VecDeque::with_capacity(LOG_CAPACITY)));
static MANAGED_CORE: Lazy<Mutex<Option<ManagedCore>>> = Lazy::new(|| Mutex::new(None));
/// A request the bounded drain gave up on can still reach launch afterwards.
static SHUTTING_DOWN: AtomicBool = AtomicBool::new(false);

fn lock_surviving_poison<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// A Core whose app went away exits on its own, and stays a zombie until it is
/// waited on; without this nothing waits before the next start or stop.
fn reap_exited_core(session_id: &str) {
    let deadline = Instant::now() + CORE_EXIT_TIMEOUT;
    loop {
        {
            let mut managed = lock_surviving_poison(&MANAGED_CORE);
            let Some(core) = managed
                .as_mut()
                .filter(|core| core.session_id == session_id)
            else {
                return;
            };
            match core.child.try_wait() {
                Ok(Some(status)) => {
                    log_message(format!("Core exited on its own: {status}"));
                    *managed = None;
                    return;
                }
                Ok(None) => {}
                Err(_) => return,
            }
        }
        if Instant::now() >= deadline {
            return;
        }
        thread::sleep(CORE_EXIT_POLL_INTERVAL);
    }
}

fn release_managed_core(managed: &mut Option<ManagedCore>) -> Result<(), Error> {
    let Some(core) = managed.as_mut() else {
        return Ok(());
    };
    core.terminate()?;
    *managed = None;
    Ok(())
}

#[cfg(windows)]
struct ManagedZapret {
    child: Child,
    started_at: Instant,
    _job: CoreJob,
    strategy_id: String,
    engine: String,
    mode: super::zapret::ZapretLaunchMode,
    infrastructure: super::zapret::ZapretInfrastructure,
    args: Vec<String>,
}

#[cfg(windows)]
static MANAGED_ZAPRET: Lazy<Mutex<Option<ManagedZapret>>> = Lazy::new(|| Mutex::new(None));

#[cfg(windows)]
static ZAPRET_OPERATION: Mutex<()> = Mutex::new(());
#[cfg(windows)]
static ZAPRET_WATCHDOG: Mutex<bool> = Mutex::new(true);
#[cfg(windows)]
static ZAPRET_INTENT: Mutex<Option<ZapretIntent>> = Mutex::new(None);
#[cfg(windows)]
static ZAPRET_WATCHDOG_THREAD: std::sync::Once = std::sync::Once::new();

// A process handle, unlike a PID lookup, remains bound to the exact
// process even after Windows reuses its PID. Keep it after an explicit stop
// as well, so delayed requests cannot resurrect a stopped engine.
#[cfg(windows)]
static ZAPRET_OWNER: Mutex<Option<ZapretOwner>> = Mutex::new(None);

#[cfg(windows)]
struct ZapretOwner {
    pid: u32,
    process: HANDLE,
    sequence: u64,
}

#[cfg(windows)]
impl Drop for ZapretOwner {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.process);
        }
    }
}

#[cfg(windows)]
impl ZapretOwner {
    fn alive(&self) -> bool {
        // WAIT_TIMEOUT: the process handle is not signaled.
        unsafe { WaitForSingleObject(self.process, 0) == 258 }
    }

    fn open(pid: u32, sequence: u64) -> Result<Self, Error> {
        // SYNCHRONIZE is required to wait on a process handle.
        let process =
            unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | 0x00100000, 0, pid) };
        if process == 0 {
            return Err(Error::last_os_error());
        }
        let owner = Self {
            pid,
            process,
            sequence,
        };
        let actual = process_image_path(process)
            .ok_or_else(|| Error::other("Cannot identify Zapret owner"))?;
        let actual = fs::canonicalize(actual)?;
        let helper = fs::canonicalize(std::env::current_exe()?)?;
        let valid_name = actual
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| {
                name.eq_ignore_ascii_case("FlClashZ.exe")
                    || name.eq_ignore_ascii_case("FlClashZPre.exe")
            });
        let same_directory = actual.parent().zip(helper.parent()).is_some_and(|(a, b)| {
            a.to_string_lossy()
                .eq_ignore_ascii_case(&b.to_string_lossy())
        });
        if !owner.alive() || !valid_name || !same_directory {
            return Err(Error::other(
                "Zapret owner is not the running FlClashZ client",
            ));
        }
        Ok(owner)
    }
}

// Caller holds ZAPRET_OPERATION. Do not re-arm watchdog after owner death.
#[cfg(windows)]
fn reap_dead_zapret_owner() -> Result<(), Error> {
    let mut owner = lock_surviving_poison(&ZAPRET_OWNER);
    if owner.as_ref().is_some_and(|owner| !owner.alive()) {
        *lock_surviving_poison(&ZAPRET_INTENT) = None;
        let mut managed = lock_surviving_poison(&MANAGED_ZAPRET);
        stop_managed_zapret(&mut managed)?;
        *owner = None;
        zapret_log("info", "Zapret stopped: FlClashZ owner exited".into());
    }
    Ok(())
}

#[cfg(windows)]
fn validate_zapret_command(
    owner_pid: u32,
    last: u64,
    pid: u32,
    sequence: u64,
) -> Result<(), Error> {
    if owner_pid != pid {
        return Err(Error::other("Another FlClashZ process owns Zapret"));
    }
    if sequence <= last {
        return Err(Error::other("Stale Zapret operation rejected"));
    }
    Ok(())
}

#[cfg(all(windows, test))]
#[test]
fn zapret_rejects_competing_owner_and_out_of_order_commands() {
    assert!(validate_zapret_command(10, 7, 10, 8).is_ok());
    assert!(validate_zapret_command(10, 7, 10, 7).is_err());
    assert!(validate_zapret_command(10, 7, 10, 6).is_err());
    assert!(validate_zapret_command(10, 7, 11, 8).is_err());
}

#[cfg(windows)]
fn accept_zapret_command(pid: u32, sequence: u64) -> Result<(), Error> {
    reap_dead_zapret_owner()?;
    let mut owner = lock_surviving_poison(&ZAPRET_OWNER);
    if let Some(current) = owner.as_mut() {
        if !current.alive() {
            return Err(Error::other("Zapret owner exited during command"));
        }
        validate_zapret_command(current.pid, current.sequence, pid, sequence)?;
        current.sequence = sequence;
    } else {
        *owner = Some(ZapretOwner::open(pid, sequence)?);
    }
    Ok(())
}

#[cfg(windows)]
struct ZapretIntent {
    strategy_id: String,
    mode: super::zapret::ZapretLaunchMode,
    debug: bool,
    infrastructure: super::zapret::ZapretInfrastructure,
    attempts: u8,
    retry_at: Option<Instant>,
}

// The same operation lock guards every user launch/stop and each watchdog
// tick. A stop can never be followed by a stale, queued restart.
#[cfg(windows)]
fn ensure_zapret_watchdog() {
    ZAPRET_WATCHDOG_THREAD.call_once(|| {
        thread::spawn(|| loop {
            thread::sleep(Duration::from_secs(1));
            if SHUTTING_DOWN.load(Ordering::SeqCst) {
                break;
            }
            let _operation = lock_surviving_poison(&ZAPRET_OPERATION);
            if SHUTTING_DOWN.load(Ordering::SeqCst) {
                break;
            }
            if let Err(error) = reap_dead_zapret_owner() {
                zapret_log("error", format!("Zapret owner cleanup failed: {error}"));
                continue;
            }
            if lock_surviving_poison(&ZAPRET_OWNER).is_none() {
                continue;
            }
            if !*lock_surviving_poison(&ZAPRET_WATCHDOG) {
                continue;
            }
            let mut desired = lock_surviving_poison(&ZAPRET_INTENT);
            let Some(intent) = desired.as_mut() else {
                continue;
            };
            let mut managed = lock_surviving_poison(&MANAGED_ZAPRET);
            if let Some(active) = managed.as_mut() {
                match active.child.try_wait() {
                    Ok(None) => {
                        if active.started_at.elapsed() >= Duration::from_secs(30) {
                            intent.attempts = 0;
                        }
                        intent.retry_at = None;
                        continue;
                    }
                    Ok(Some(status)) => {
                        zapret_log("error", format!("Zapret engine exited: {status}"));
                        *managed = None;
                    }
                    Err(error) => {
                        zapret_log("error", format!("Watchdog status error: {error}"));
                        continue;
                    }
                }
            }
            drop(managed);
            if intent.attempts >= 3 {
                continue;
            }
            let now = Instant::now();
            let retry = *intent.retry_at.get_or_insert(now + Duration::from_secs(5));
            if now < retry {
                continue;
            }
            intent.attempts += 1;
            intent.retry_at = Some(now + Duration::from_secs(5));
            zapret_log(
                "info",
                format!(
                    "Watchdog recovery {}/3: {}",
                    intent.attempts, intent.strategy_id
                ),
            );
            let response = launch_zapret(
                true,
                intent.strategy_id.clone(),
                intent.mode,
                intent.debug,
                &intent.infrastructure,
                "watchdog",
            );
            if response.status() == StatusCode::OK {
                zapret_log("info", "Watchdog: replacement process started".into());
            } else {
                zapret_log(
                    "error",
                    format!("Watchdog recovery: HTTP {}", response.status()),
                );
            }
            if intent.attempts >= 3 && response.status() != StatusCode::OK {
                zapret_log("error", "Watchdog attempt limit reached".to_string());
            }
        });
    });
}

#[cfg(windows)]
fn launch_zapret_with_intent(
    restart: bool,
    pid: u32,
    sequence: u64,
    request: ZapretStartRequest,
) -> warp::reply::Response {
    let _operation = lock_surviving_poison(&ZAPRET_OPERATION);
    if let Err(error) = accept_zapret_command(pid, sequence) {
        return error_response(
            "zapretOwnerConflict",
            error.to_string(),
            StatusCode::CONFLICT,
        );
    }
    // Owner monitoring must run even when the recovery watchdog is disabled.
    ensure_zapret_watchdog();
    let response = launch_zapret(
        restart,
        request.strategy_id.clone(),
        request.mode,
        request.debug,
        &request.infrastructure,
        zapret_reason(request.reason.as_deref(), restart),
    );
    if response.status() == StatusCode::OK {
        if let Some(enabled) = request.watchdog {
            *lock_surviving_poison(&ZAPRET_WATCHDOG) = enabled;
        }
        *lock_surviving_poison(&ZAPRET_INTENT) = Some(ZapretIntent {
            strategy_id: request.strategy_id,
            mode: request.mode,
            debug: request.debug,
            infrastructure: request.infrastructure,
            attempts: 0,
            retry_at: None,
        });
    } else {
        // If replacement already stopped the previous engine, its stale
        // recovery intent must not resurrect it after a failed launch.
        if lock_surviving_poison(&MANAGED_ZAPRET).is_none() {
            *lock_surviving_poison(&ZAPRET_INTENT) = None;
        }
    }
    response
}

#[cfg(not(windows))]
fn launch_zapret_with_intent(
    restart: bool,
    _pid: u32,
    _sequence: u64,
    request: ZapretStartRequest,
) -> warp::reply::Response {
    let _ = request.watchdog;
    launch_zapret(
        restart,
        request.strategy_id,
        request.mode,
        request.debug,
        &request.infrastructure,
        zapret_reason(request.reason.as_deref(), restart),
    )
}

#[cfg(windows)]
fn update_zapret_watchdog(
    request: ZapretWatchdogRequest,
    pid: u32,
    sequence: u64,
) -> warp::reply::Response {
    let _operation = lock_surviving_poison(&ZAPRET_OPERATION);
    if let Err(error) = accept_zapret_command(pid, sequence) {
        return error_response(
            "zapretOwnerConflict",
            error.to_string(),
            StatusCode::CONFLICT,
        );
    }
    *lock_surviving_poison(&ZAPRET_WATCHDOG) = request.enabled;
    if let Some(intent) = lock_surviving_poison(&ZAPRET_INTENT).as_mut() {
        intent.retry_at = None;
        intent.attempts = 0;
    }
    zapret_log("info", format!("Watchdog enabled: {}", request.enabled));
    json_response(&request.enabled, StatusCode::OK)
}

#[cfg(not(windows))]
fn update_zapret_watchdog(
    request: ZapretWatchdogRequest,
    _pid: u32,
    _sequence: u64,
) -> warp::reply::Response {
    let _ = request.enabled;
    error_response(
        "unsupportedPlatform",
        "Zapret is available only on Windows",
        StatusCode::NOT_IMPLEMENTED,
    )
}

#[cfg(windows)]
const ZAPRET_CREATE_NO_WINDOW: u32 = 0x08000000;

#[cfg(windows)]
fn zapret_bin_dir() -> Result<PathBuf, Error> {
    let helper = std::env::current_exe()?;
    let app_dir = helper
        .parent()
        .ok_or_else(|| Error::other("Helper executable has no parent directory"))?;
    let app_dir = fs::canonicalize(app_dir)?;
    let requested = app_dir.join("zapret");
    let bin_dir = fs::canonicalize(&requested).map_err(|error| {
        Error::other(format!(
            "Zapret2 assets are not installed at {}: {error}",
            requested.display()
        ))
    })?;
    if !bin_dir.is_dir() || !bin_dir.starts_with(&app_dir) {
        return Err(Error::other(
            "Zapret2 asset directory resolves outside the application directory",
        ));
    }
    Ok(bin_dir)
}

#[cfg(windows)]
fn process_image_path(handle: HANDLE) -> Option<String> {
    unsafe {
        let mut buffer = [0u16; 1024];
        let mut size = buffer.len() as u32;
        if QueryFullProcessImageNameW(handle, 0, buffer.as_mut_ptr(), &mut size) == 0 {
            return None;
        }
        Some(String::from_utf16_lossy(&buffer[..size as usize]))
    }
}

#[cfg(windows)]
fn process_path_is_in_zapret_root(image_path: &str, zapret_root: &Path) -> bool {
    // QueryFullProcessImageNameW returns a DOS path; canonicalize returns
    // a verbatim path. Normalize both before checking process ownership.
    let Ok(image_path) = fs::canonicalize(image_path) else {
        return false;
    };
    let root = zapret_root
        .to_string_lossy()
        .trim_end_matches(|ch| ch == '\\' || ch == '/')
        .to_ascii_lowercase();
    image_path
        .to_string_lossy()
        .to_ascii_lowercase()
        .starts_with(&format!("{root}\\"))
}

#[cfg(windows)]
fn process_image_matches(handle: HANDLE, expected_exe_name: &str, zapret_root: &Path) -> bool {
    let Some(image_path) = process_image_path(handle) else {
        return false;
    };
    let Some(name) = Path::new(&image_path)
        .file_name()
        .and_then(|name| name.to_str())
    else {
        return false;
    };
    name.eq_ignore_ascii_case(expected_exe_name)
        && process_path_is_in_zapret_root(&image_path, zapret_root)
}

#[cfg(windows)]
fn find_winws_processes(
    zapret_root: &Path,
    include_local: bool,
    include_external: bool,
) -> Vec<String> {
    let targets = ["winws2.exe", "winws.exe", "winws2-split.exe"];
    let mut conflicts = Vec::new();
    unsafe {
        let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snapshot == 0 || snapshot == -1isize {
            return vec![format!(
                "Cannot enumerate winws processes: {}",
                Error::last_os_error()
            )];
        }
        let mut entry: PROCESSENTRY32W = std::mem::zeroed();
        entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
        if Process32FirstW(snapshot, &mut entry) != 0 {
            loop {
                let length = entry
                    .szExeFile
                    .iter()
                    .position(|unit| *unit == 0)
                    .unwrap_or(entry.szExeFile.len());
                let name = String::from_utf16_lossy(&entry.szExeFile[..length]);
                if targets
                    .iter()
                    .any(|target| name.eq_ignore_ascii_case(target))
                {
                    let process =
                        OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, entry.th32ProcessID);
                    if process != 0 {
                        if let Some(image_path) = process_image_path(process) {
                            let local = process_path_is_in_zapret_root(&image_path, zapret_root);
                            if (local && include_local) || (!local && include_external) {
                                conflicts
                                    .push(format!("{image_path} (PID {})", entry.th32ProcessID));
                            }
                        } else {
                            conflicts.push(format!(
                                "{name} (PID {}, image path unavailable)",
                                entry.th32ProcessID
                            ));
                        }
                        let _ = CloseHandle(process);
                    } else {
                        // The process may have exited; a fresh launch can retry.
                        conflicts.push(format!(
                            "{name} (PID {}, cannot inspect)",
                            entry.th32ProcessID
                        ));
                    }
                }
                if Process32NextW(snapshot, &mut entry) == 0 {
                    break;
                }
            }
        }
        let _ = CloseHandle(snapshot);
    }
    conflicts
}

/// Mirrors zapret2-gui's Windows doctor: enumerate by image name, open each
/// process, verify its full image path again through that handle, then terminate.
/// This second check avoids acting on a PID that was recycled during enumeration.
#[cfg(windows)]
fn kill_stray_winws2_processes(exclude_pid: Option<u32>) -> usize {
    let targets = ["winws2.exe", "winws.exe", "winws2-split.exe"];
    let Ok(zapret_root) = zapret_bin_dir() else {
        return 0;
    };
    let mut terminated = 0usize;
    unsafe {
        let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snapshot == 0 || snapshot == -1isize {
            return 0;
        }
        let mut entry: PROCESSENTRY32W = std::mem::zeroed();
        entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
        if Process32FirstW(snapshot, &mut entry) != 0 {
            loop {
                let length = entry
                    .szExeFile
                    .iter()
                    .position(|unit| *unit == 0)
                    .unwrap_or(entry.szExeFile.len());
                let image = String::from_utf16_lossy(&entry.szExeFile[..length]);
                if targets
                    .iter()
                    .any(|target| image.eq_ignore_ascii_case(target))
                {
                    let pid = entry.th32ProcessID;
                    if Some(pid) != exclude_pid {
                        let process = OpenProcess(
                            PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION | 0x00100000,
                            0,
                            pid,
                        );
                        if process != 0 {
                            let confirmed = targets
                                .iter()
                                .any(|target| process_image_matches(process, target, &zapret_root));
                            if confirmed
                                && TerminateProcess(process, 1) != 0
                                && WaitForSingleObject(
                                    process,
                                    CORE_EXIT_TIMEOUT.as_millis() as u32,
                                ) == 0
                            {
                                terminated += 1;
                            }
                            let _ = CloseHandle(process);
                        }
                    }
                }
                if Process32NextW(snapshot, &mut entry) == 0 {
                    break;
                }
            }
        }
        let _ = CloseHandle(snapshot);
    }
    terminated
}

fn zapret_win_divert_filters(args: &[String]) -> Vec<String> {
    args.iter()
        .filter(|arg| arg.starts_with("--wf-"))
        .cloned()
        .collect()
}

fn zapret_processing_lists(args: &[String]) -> Vec<String> {
    args.iter()
        .filter(|arg| {
            arg.starts_with("--hostlist=")
                || arg.starts_with("--hostlist-auto=")
                || arg.starts_with("--hostlist-domains=")
                || arg.starts_with("--hostlist-exclude=")
                || arg.starts_with("--ipset=")
                || arg.starts_with("--ipset-exclude=")
        })
        .cloned()
        .collect()
}

#[cfg(windows)]
fn zapret_status_response(
    managed: &mut Option<ManagedZapret>,
    cleaned_processes: usize,
) -> Result<warp::reply::Response, Error> {
    let (pid, exited_status, strategy_id, engine, mode, args) = match managed.as_mut() {
        Some(zapret) => match zapret.child.try_wait()? {
            Some(status) => (None, Some(status), None, None, None, Vec::new()),
            None => (
                Some(zapret.child.id()),
                None,
                Some(zapret.strategy_id.clone()),
                Some(zapret.engine.clone()),
                Some(zapret.mode),
                zapret.args.clone(),
            ),
        },
        None => (None, None, None, None, None, Vec::new()),
    };
    if let Some(status) = exited_status {
        zapret_log("error", format!("Zapret engine exited: {status}"));
        *managed = None;
    }
    let win_divert_filters = zapret_win_divert_filters(&args);
    let processing_lists = zapret_processing_lists(&args);
    Ok(json_response(
        &ZapretStatusResponse {
            running: pid.is_some(),
            uptime_ms: managed
                .as_ref()
                .map_or(0, |active| active.started_at.elapsed().as_millis() as u64),
            pid,
            strategy_id,
            engine,
            mode,
            win_divert_filters,
            processing_lists,
            cleaned_processes,
        },
        StatusCode::OK,
    ))
}

#[cfg(windows)]
fn stop_managed_zapret(managed: &mut Option<ManagedZapret>) -> Result<(), Error> {
    let Some(zapret) = managed.as_mut() else {
        return Ok(());
    };
    let pid = zapret.child.id();
    let strategy = zapret.strategy_id.clone();
    if wait_for_child_exit(&mut zapret.child, Duration::ZERO)? {
        zapret_log("info", format!("Process already exited: strategy {strategy}, PID {pid}"));
        *managed = None;
        return Ok(());
    }
    let _ = zapret.child.kill();
    if !wait_for_child_exit(&mut zapret.child, CORE_EXIT_TIMEOUT)? {
        return Err(Error::other(
            "Zapret2 engine did not exit after termination",
        ));
    }
    zapret_log("info", format!("Process stopped: strategy {strategy}, PID {pid}"));
    *managed = None;
    Ok(())
}

fn zapret_reason(reason: Option<&str>, restart: bool) -> &'static str {
    match reason {
        Some("manual") => "manual",
        Some("dashboard") => "dashboard",
        Some("mihomo_start") => "Mihomo start",
        Some("mihomo_restore") => "Mihomo recovery",
        Some("profile_apply") => "profile apply",
        Some("infrastructure_refresh") => "infrastructure refresh",
        Some("infrastructure_changed") => "infrastructure changed",
        Some("strategy_change") => "strategy change",
        Some("trial_screen") => "auto-tune screening",
        Some("trial_verify") => "auto-tune verification",
        Some("trial_restore") => "auto-tune restore",
        Some("fallback") => "automatic fallback",
        Some("fallback_restore") => "fallback restore",
        Some("watchdog") => "watchdog",
        _ if restart => "restart (unspecified)",
        _ => "start (unspecified)",
    }
}

#[cfg(windows)]
fn launch_zapret(
    restart: bool,
    strategy_id: String,
    mode: super::zapret::ZapretLaunchMode,
    debug: bool,
    infrastructure: &super::zapret::ZapretInfrastructure,
    reason: &str,
) -> warp::reply::Response {
    if SHUTTING_DOWN.load(Ordering::SeqCst) {
        return error_response(
            "helperStopping",
            "The Helper is shutting down",
            StatusCode::SERVICE_UNAVAILABLE,
        );
    }
    if let Err(error) = infrastructure.validate() {
        return error_response(
            "invalidZapretInfrastructure",
            error.to_string(),
            StatusCode::BAD_REQUEST,
        );
    }
    let mut managed = lock_surviving_poison(&MANAGED_ZAPRET);
    if !restart {
        match zapret_status_response(&mut managed, 0) {
            Ok(status) => {
                let same_strategy = managed.as_ref().is_some_and(|active| {
                    active.strategy_id == strategy_id
                        && active.mode == mode
                        && &active.infrastructure == infrastructure
                });
                if same_strategy {
                    return status;
                }
            }
            Err(error) => {
                return error_response(
                    "zapretStatusFailed",
                    error.to_string(),
                    StatusCode::INTERNAL_SERVER_ERROR,
                );
            }
        }
    }
    // Resolve and validate the requested profile before stopping a currently
    // working engine. A stale/unknown ID or missing asset must never take down
    // the user's active bypass.
    let bin_dir = match zapret_bin_dir() {
        Ok(path) => path,
        Err(error) => {
            return error_response(
                "zapretAssetsMissing",
                error.to_string(),
                StatusCode::CONFLICT,
            )
        }
    };
    let launch = match super::zapret::build_launch(&bin_dir, &strategy_id, mode) {
        Ok(launch) => launch,
        Err(error) if error.kind() == std::io::ErrorKind::InvalidInput => {
            return error_response(
                "invalidZapretStrategy",
                error.to_string(),
                StatusCode::BAD_REQUEST,
            );
        }
        Err(error) => {
            return error_response(
                "zapretAssetsMissing",
                error.to_string(),
                StatusCode::CONFLICT,
            );
        }
    };
    let executable = match fs::canonicalize(bin_dir.join(launch.executable)) {
        Ok(path) if path.starts_with(&bin_dir) && path.is_file() => path,
        Ok(_) => {
            return error_response(
                "zapretExecutableInvalid",
                format!(
                    "{} resolves outside the Zapret directory",
                    launch.executable
                ),
                StatusCode::CONFLICT,
            )
        }
        Err(error) => {
            return error_response(
                "zapretAssetsMissing",
                error.to_string(),
                StatusCode::CONFLICT,
            )
        }
    };
    let mut args = launch.args;
    if debug {
        if let Some(arg) = args.iter_mut().find(|arg| arg.as_str() == "--debug=0") {
            *arg = "--debug=1".to_string();
        }
    }
    let engine = launch.strategy.engine.to_string();
    let strategy_id = launch.strategy.id.to_string();

    let external_processes = find_winws_processes(&bin_dir, false, true);
    if !external_processes.is_empty() {
        return error_response(
            "zapretConflict",
            format!(
                "Другой экземпляр Zapret/WinDivert уже работает: {}",
                external_processes.join("; ")
            ),
            StatusCode::CONFLICT,
        );
    }

    if let Err(error) = infrastructure.prepare() {
        return error_response(
            "zapretInfrastructureFailed",
            error.to_string(),
            StatusCode::INTERNAL_SERVER_ERROR,
        );
    }
    infrastructure.apply(&mut args);
    if let Some(previous) = managed.as_ref() {
        zapret_log("info", format!("Replacing PID {}: {reason}", previous.child.id()));
    }
    if let Err(error) = stop_managed_zapret(&mut managed) {
        return error_response(
            "zapretStopFailed",
            error.to_string(),
            StatusCode::INTERNAL_SERVER_ERROR,
        );
    }

    let cleaned = kill_stray_winws2_processes(None);
    if cleaned > 0 {
        zapret_log(
            "info",
            format!("Zapret cleanup terminated {cleaned} orphaned winws processes"),
        );
    }

    // Never start another engine until cleanup is confirmed. External
    // processes that appeared after the initial scan also block this launch.
    let remaining = find_winws_processes(&bin_dir, true, true);
    if !remaining.is_empty() {
        return error_response(
            "zapretConflict",
            format!("Zapret process still running: {}", remaining.join("; ")),
            StatusCode::CONFLICT,
        );
    }

    let mut command = Command::new(&executable);
    command
        .args(&args)
        .current_dir(&bin_dir)
        .stdin(Stdio::null())
        .stdout(if debug { Stdio::piped() } else { Stdio::null() })
        .stderr(Stdio::piped())
        .creation_flags(ZAPRET_CREATE_NO_WINDOW);
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            zapret_log("error", format!("Zapret launch failed: {error}"));
            return launch_failure_response(&error);
        }
    };
    let pid = child.id();

    if let Some(stdout) = child.stdout.take() {
        thread::spawn(move || {
            for line in io::BufReader::new(stdout).lines() {
                match line {
                    Ok(output) => zapret_log("debug", format!("[PID {pid}] {output}")),
                    Err(_) => break,
                }
            }
        });
    }
    if let Some(stderr) = child.stderr.take() {
        let log_strategy = strategy_id.clone();
        thread::spawn(move || {
            for line in io::BufReader::new(stderr).lines() {
                match line {
                    Ok(output) => zapret_log("stderr", format!("[{log_strategy}, PID {pid}] {output}")),
                    Err(_) => break,
                }
            }
        });
    }

    let job = match CoreJob::bind(&child) {
        Ok(job) => job,
        Err(error) => {
            let _ = child.kill();
            let _ = wait_for_child_exit(&mut child, CORE_EXIT_TIMEOUT);
            return error_response(
                "zapretConfinementFailed",
                format!(
                    "Could not place {} in a kill-on-close job: {error}",
                    launch.executable
                ),
                StatusCode::INTERNAL_SERVER_ERROR,
            );
        }
    };
    zapret_log(
        "info",
        format!("Started {engine}, strategy {strategy_id}, mode {mode:?}, PID {pid}; reason: {reason}"),
    );
    *managed = Some(ManagedZapret {
        child,
        started_at: Instant::now(),
        _job: job,
        strategy_id: strategy_id.clone(),
        engine: engine.clone(),
        mode,
        infrastructure: infrastructure.clone(),
        args: args.clone(),
    });
    json_response(
        &ZapretStatusResponse {
            running: true,
            uptime_ms: 0,
            pid: Some(pid),
            strategy_id: Some(strategy_id),
            engine: Some(engine),
            mode: Some(mode),
            win_divert_filters: zapret_win_divert_filters(&args),
            processing_lists: zapret_processing_lists(&args),
            cleaned_processes: cleaned,
        },
        StatusCode::OK,
    )
}

#[cfg(windows)]
fn stop_zapret(pid: u32, sequence: u64) -> warp::reply::Response {
    let _operation = lock_surviving_poison(&ZAPRET_OPERATION);
    if let Err(error) = accept_zapret_command(pid, sequence) {
        return error_response(
            "zapretOwnerConflict",
            error.to_string(),
            StatusCode::CONFLICT,
        );
    }
    *lock_surviving_poison(&ZAPRET_INTENT) = None;
    let mut managed = lock_surviving_poison(&MANAGED_ZAPRET);
    let had_process = managed.is_some();
    if let Err(error) = stop_managed_zapret(&mut managed) {
        return error_response(
            "zapretStopFailed",
            error.to_string(),
            StatusCode::INTERNAL_SERVER_ERROR,
        );
    }
    let cleaned = kill_stray_winws2_processes(None);
    if cleaned > 0 {
        zapret_log(
            "info",
            format!("Zapret stop cleaned {cleaned} orphaned winws processes"),
        );
    }
    if let Ok(bin_dir) = zapret_bin_dir() {
        // Do not terminate or treat an unrelated external installation as
        // ours. A remaining local process, however, is not a successful stop.
        let remaining = find_winws_processes(&bin_dir, true, false);
        if !remaining.is_empty() {
            return error_response(
                "zapretStopFailed",
                format!("Cannot confirm local Zapret exit: {}", remaining.join("; ")),
                StatusCode::CONFLICT,
            );
        }
    }
    if had_process || cleaned > 0 {
        zapret_log("info", "Zapret stop confirmed".into());
    }
    json_response(
        &ZapretStatusResponse {
            running: false,
            uptime_ms: 0,
            pid: None,
            strategy_id: None,
            engine: None,
            mode: None,
            win_divert_filters: Vec::new(),
            processing_lists: Vec::new(),
            cleaned_processes: cleaned,
        },
        StatusCode::OK,
    )
}

fn get_zapret_strategies() -> warp::reply::Response {
    json_response(&super::zapret::strategy_info(), StatusCode::OK)
}

fn get_zapret_lists() -> warp::reply::Response {
    match super::zapret_lists::list() {
        Ok(lists) => json_response(&lists, StatusCode::OK),
        Err(error) => error_response(
            "zapretListsUnavailable",
            error.to_string(),
            StatusCode::CONFLICT,
        ),
    }
}

async fn restore_zapret_list(filename: String) -> Result<warp::reply::Response, Rejection> {
    match tokio::task::spawn_blocking(move || super::zapret_lists::restore(&filename)).await {
        Ok(Ok(list)) => Ok(json_response(&list, StatusCode::OK)),
        Ok(Err(error)) if error.kind() == std::io::ErrorKind::InvalidInput => Ok(error_response(
            "invalidZapretList",
            error.to_string(),
            StatusCode::BAD_REQUEST,
        )),
        Ok(Err(error)) if error.kind() == std::io::ErrorKind::NotFound => Ok(error_response(
            "zapretBackupMissing",
            error.to_string(),
            StatusCode::CONFLICT,
        )),
        Ok(Err(error)) => Ok(error_response(
            "zapretListRestoreFailed",
            error.to_string(),
            StatusCode::CONFLICT,
        )),
        Err(error) => Ok(error_response(
            "zapretListTaskFailed",
            error.to_string(),
            StatusCode::INTERNAL_SERVER_ERROR,
        )),
    }
}

fn get_zapret_list(filename: String) -> warp::reply::Response {
    match super::zapret_lists::read(&filename) {
        Ok(list) => json_response(&list, StatusCode::OK),
        Err(error) if error.kind() == std::io::ErrorKind::InvalidInput => error_response(
            "invalidZapretList",
            error.to_string(),
            StatusCode::BAD_REQUEST,
        ),
        Err(error) => error_response(
            "zapretListReadFailed",
            error.to_string(),
            StatusCode::CONFLICT,
        ),
    }
}

async fn put_zapret_list(
    filename: String,
    request: ZapretListWriteRequest,
) -> Result<warp::reply::Response, Rejection> {
    match tokio::task::spawn_blocking(move || {
        super::zapret_lists::write(&filename, request.content)
    })
    .await
    {
        Ok(Ok(list)) => Ok(json_response(&list, StatusCode::OK)),
        Ok(Err(error)) if error.kind() == std::io::ErrorKind::InvalidInput => Ok(error_response(
            "invalidZapretList",
            error.to_string(),
            StatusCode::BAD_REQUEST,
        )),
        Ok(Err(error)) => Ok(error_response(
            "zapretListWriteFailed",
            error.to_string(),
            StatusCode::CONFLICT,
        )),
        Err(error) => Ok(error_response(
            "zapretListTaskFailed",
            error.to_string(),
            StatusCode::INTERNAL_SERVER_ERROR,
        )),
    }
}

#[cfg(windows)]
fn get_zapret_status() -> warp::reply::Response {
    let mut managed = lock_surviving_poison(&MANAGED_ZAPRET);
    match zapret_status_response(&mut managed, 0) {
        Ok(response) => response,
        Err(error) => error_response(
            "zapretStatusFailed",
            error.to_string(),
            StatusCode::INTERNAL_SERVER_ERROR,
        ),
    }
}

#[cfg(not(windows))]
fn launch_zapret(
    _restart: bool,
    _strategy_id: String,
    _mode: super::zapret::ZapretLaunchMode,
    _debug: bool,
    _infrastructure: &super::zapret::ZapretInfrastructure,
    _reason: &str,
) -> warp::reply::Response {
    error_response(
        "unsupportedPlatform",
        "Zapret is available only on Windows",
        StatusCode::NOT_IMPLEMENTED,
    )
}
#[cfg(not(windows))]
fn stop_zapret(_pid: u32, _sequence: u64) -> warp::reply::Response {
    error_response(
        "unsupportedPlatform",
        "Zapret is available only on Windows",
        StatusCode::NOT_IMPLEMENTED,
    )
}
#[cfg(not(windows))]
fn get_zapret_status() -> warp::reply::Response {
    error_response(
        "unsupportedPlatform",
        "Zapret is available only on Windows",
        StatusCode::NOT_IMPLEMENTED,
    )
}

async fn launch_zapret_request(
    restart: bool,
    pid: u32,
    sequence: u64,
    request: ZapretStartRequest,
) -> Result<warp::reply::Response, Rejection> {
    match tokio::task::spawn_blocking(move || {
        launch_zapret_with_intent(restart, pid, sequence, request)
    })
    .await
    {
        Ok(response) => Ok(response),
        Err(error) => Ok(error_response(
            "zapretTaskFailed",
            error.to_string(),
            StatusCode::INTERNAL_SERVER_ERROR,
        )),
    }
}

async fn stop_zapret_request(pid: u32, sequence: u64) -> Result<warp::reply::Response, Rejection> {
    match tokio::task::spawn_blocking(move || stop_zapret(pid, sequence)).await {
        Ok(response) => Ok(response),
        Err(error) => Ok(error_response(
            "zapretTaskFailed",
            error.to_string(),
            StatusCode::INTERNAL_SERVER_ERROR,
        )),
    }
}

fn json_response<T: Serialize>(value: &T, status: StatusCode) -> warp::reply::Response {
    warp::reply::with_status(warp::reply::json(value), status).into_response()
}

fn error_response(
    code: &'static str,
    message: impl Into<String>,
    status: StatusCode,
) -> warp::reply::Response {
    let message = message.into();
    #[cfg(windows)]
    if code.to_ascii_lowercase().contains("zapret") && code != "zapretStatusFailed" {
        zapret_log("error", format!("{code}: {message}"));
    }
    json_response(
        &ErrorResponse {
            code,
            message,
            details: None,
        },
        status,
    )
}

/// The OS error code is what lets the app tell a Core that Windows refused on
/// policy grounds (Smart App Control, AppLocker) from one that is broken.
fn launch_failure_response(error: &Error) -> warp::reply::Response {
    json_response(
        &ErrorResponse {
            code: "processLaunchFailed",
            message: error.to_string(),
            details: error
                .raw_os_error()
                .map(|os_error| ErrorDetails { os_error }),
        },
        StatusCode::INTERNAL_SERVER_ERROR,
    )
}

fn start(start_params: StartParams) -> warp::reply::Response {
    if !is_allowed_core_address(&start_params.address) {
        return error_response(
            "invalidRequest",
            "invalid Core address",
            StatusCode::BAD_REQUEST,
        );
    }
    if !is_valid_session_id(&start_params.session_id) {
        return error_response(
            "invalidRequest",
            "invalid Core session ID",
            StatusCode::BAD_REQUEST,
        );
    }
    #[cfg(target_os = "linux")]
    if let Err(error) = super::linux::ensure_owner_socket(&start_params.address) {
        return error_response("invalidRequest", error.to_string(), StatusCode::BAD_REQUEST);
    }
    launch(start_params)
}

/// Releases the managed Core before anything else, so a request reaching this
/// point must already be accepted: a rejected one has to leave it running.
fn launch(start_params: StartParams) -> warp::reply::Response {
    let mut managed = lock_surviving_poison(&MANAGED_CORE);
    if SHUTTING_DOWN.load(Ordering::SeqCst) {
        return error_response(
            "helperStopping",
            "the Helper is shutting down",
            StatusCode::SERVICE_UNAVAILABLE,
        );
    }
    if let Err(error) = release_managed_core(&mut managed) {
        log_message(format!(
            "Helper could not release the managed Core: {error}"
        ));
        return error_response(
            "coreStopFailed",
            error.to_string(),
            StatusCode::INTERNAL_SERVER_ERROR,
        );
    }
    let core = match VerifiedCore::open() {
        Ok(core) => core,
        Err(error) => {
            return error_response(
                "coreVerificationFailed",
                error.to_string(),
                StatusCode::CONFLICT,
            )
        }
    };

    match core.spawn(&start_params.address) {
        Ok(mut child) => {
            let process_id = child.id();
            if let Some(stderr) = child.stderr.take() {
                let reader = io::BufReader::new(stderr);
                let session_id = start_params.session_id.clone();
                thread::spawn(move || {
                    for line in reader.lines() {
                        match line {
                            Ok(output) => {
                                log_message(output);
                            }
                            Err(_) => {
                                break;
                            }
                        }
                    }
                    reap_exited_core(&session_id);
                });
            }
            let core = match ManagedCore::adopt(start_params.session_id.clone(), child) {
                Ok(core) => core,
                Err(failed) => {
                    let error = &failed.error;
                    log_message(format!("Helper could not confine the Core: {error}"));
                    let response = error_response(
                        "internalError",
                        format!("Core confinement failed: {error}"),
                        StatusCode::INTERNAL_SERVER_ERROR,
                    );
                    *managed = failed.unconfirmed;
                    return response;
                }
            };
            *managed = Some(core);
            json_response(
                &StartResponse {
                    session_id: start_params.session_id,
                    pid: process_id,
                },
                StatusCode::OK,
            )
        }
        Err(e) => {
            log_message(e.to_string());
            launch_failure_response(&e)
        }
    }
}

fn stop_core(stop_params: StopParams) -> warp::reply::Response {
    if !is_valid_session_id(&stop_params.session_id) {
        return error_response(
            "invalidRequest",
            "invalid Core session ID",
            StatusCode::BAD_REQUEST,
        );
    }
    let mut managed = lock_surviving_poison(&MANAGED_CORE);
    match stop_decision(
        managed.as_ref().map(|core| core.session_id.as_str()),
        &stop_params.session_id,
    ) {
        StopDecision::NotRunning => json_response(
            &StopResponse {
                session_id: stop_params.session_id,
                stopped: false,
                reason: Some("notRunning"),
            },
            StatusCode::OK,
        ),
        StopDecision::SessionMismatch => json_response(
            &StopResponse {
                session_id: stop_params.session_id,
                stopped: false,
                reason: Some("sessionMismatch"),
            },
            StatusCode::CONFLICT,
        ),
        StopDecision::Stop => match release_managed_core(&mut managed) {
            Ok(()) => json_response(
                &StopResponse {
                    session_id: stop_params.session_id,
                    stopped: true,
                    reason: None,
                },
                StatusCode::OK,
            ),
            Err(error) => {
                log_message(format!("Helper could not stop the managed Core: {error}"));
                error_response(
                    "coreStopFailed",
                    error.to_string(),
                    StatusCode::INTERNAL_SERVER_ERROR,
                )
            }
        },
    }
}

pub(super) fn log_message(message: String) {
    let mut log_buffer = lock_surviving_poison(&LOGS);
    while log_buffer.len() >= LOG_CAPACITY {
        log_buffer.pop_front();
    }
    log_buffer.push_back(message);
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct ZapretLogEntry {
    timestamp_ms: u64,
    level: &'static str,
    message: String,
}

static ZAPRET_LOGS: Lazy<Mutex<VecDeque<ZapretLogEntry>>> =
    Lazy::new(|| Mutex::new(VecDeque::new()));

#[cfg(windows)]
fn zapret_log(level: &'static str, message: String) {
    let timestamp_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;
    let mut logs = lock_surviving_poison(&ZAPRET_LOGS);
    while logs.len() >= 500 {
        logs.pop_front();
    }
    logs.push_back(ZapretLogEntry {
        timestamp_ms,
        level,
        message: message.chars().take(2048).collect(),
    });
}

fn get_zapret_logs() -> warp::reply::Response {
    let logs = lock_surviving_poison(&ZAPRET_LOGS);
    let snapshot: Vec<_> = logs.iter().cloned().collect();
    json_response(&snapshot, StatusCode::OK)
}

fn clear_zapret_logs() -> warp::reply::Response {
    lock_surviving_poison(&ZAPRET_LOGS).clear();
    json_response(&true, StatusCode::OK)
}

fn get_logs() -> impl Reply {
    let log_buffer = lock_surviving_poison(&LOGS);
    let value = log_buffer
        .iter()
        .cloned()
        .collect::<Vec<String>>()
        .join("\n");
    warp::reply::with_header(
        warp::reply::with_header(value, "Content-Type", "text/plain; charset=utf-8"),
        "Cache-Control",
        "no-store",
    )
}

fn ping_response(result: Result<PathBuf, Error>) -> warp::reply::Response {
    let (value, status) = match result {
        Ok(path) => (path.to_string_lossy().into_owned(), StatusCode::OK),
        Err(error) => (error.to_string(), StatusCode::CONFLICT),
    };
    let response = warp::reply::with_header(
        warp::reply::with_status(value, status),
        PROTOCOL_VERSION_HEADER,
        PROTOCOL_VERSION,
    )
    .into_response();
    #[cfg(windows)]
    {
        // The digest was captured before the service accepted connections.
        // A new bundled Helper must not be mistaken for an older live image.
        if let Ok(hash) = &*RUNNING_HELPER_SHA256 {
            return warp::reply::with_header(response, HELPER_SHA256_HEADER, hash.as_str())
                .into_response();
        }
    }
    response
}

fn ping_core_sha256_mismatch() -> warp::reply::Response {
    warp::reply::with_header(
        error_response(
            "coreSha256Mismatch",
            "Core SHA256 mismatch",
            StatusCode::CONFLICT,
        ),
        PROTOCOL_VERSION_HEADER,
        PROTOCOL_VERSION,
    )
    .into_response()
}

fn probe_helper_path() -> Result<PathBuf, Error> {
    open_core(&core_path()?)?;
    std::env::current_exe()
}

fn ping(ping_params: PingParams) -> warp::reply::Response {
    if ping_params.core_sha256 != EXPECTED_CORE_SHA256 {
        log_message("Helper ping rejected a Core SHA256 mismatch".to_string());
        return ping_core_sha256_mismatch();
    }

    let result = probe_helper_path();
    if let Err(error) = &result {
        log_message(format!("Helper ping failed: {error}"));
    }
    ping_response(result)
}

async fn start_request(start_params: StartParams) -> Result<warp::reply::Response, Infallible> {
    Ok(
        match tokio::task::spawn_blocking(move || start(start_params)).await {
            Ok(response) => response,
            Err(error) => error_response(
                "internalError",
                format!("Core start task failed: {error}"),
                StatusCode::INTERNAL_SERVER_ERROR,
            ),
        },
    )
}

async fn stop_request(stop_params: StopParams) -> Result<warp::reply::Response, Infallible> {
    Ok(
        match tokio::task::spawn_blocking(move || stop_core(stop_params)).await {
            Ok(response) => response,
            Err(error) => error_response(
                "internalError",
                format!("Core stop task failed: {error}"),
                StatusCode::INTERNAL_SERVER_ERROR,
            ),
        },
    )
}

async fn ping_request(ping_params: PingParams) -> Result<warp::reply::Response, Infallible> {
    Ok(tokio::task::spawn_blocking(move || ping(ping_params))
        .await
        .unwrap_or_else(|error| {
            ping_response(Err(Error::other(format!(
                "Helper ping task failed: {error}"
            ))))
        }))
}

async fn handle_rejection(rejection: Rejection) -> Result<warp::reply::Response, Infallible> {
    if rejection.find::<ForbiddenClient>().is_some() {
        return Ok(warp::reply::with_header(
            error_response(
                "invalidRequest",
                "browser origins and non-local hosts are not allowed",
                StatusCode::FORBIDDEN,
            ),
            "connection",
            "close",
        )
        .into_response());
    }
    if rejection.find::<warp::reject::InvalidQuery>().is_some() {
        return Ok(warp::reply::with_header(
            error_response(
                "invalidRequest",
                "invalid ping query",
                StatusCode::BAD_REQUEST,
            ),
            PROTOCOL_VERSION_HEADER,
            PROTOCOL_VERSION,
        )
        .into_response());
    }
    if rejection
        .find::<warp::filters::body::BodyDeserializeError>()
        .is_some()
    {
        return Ok(error_response(
            "invalidRequest",
            "invalid JSON request body",
            StatusCode::BAD_REQUEST,
        ));
    }
    if rejection.find::<warp::reject::PayloadTooLarge>().is_some() {
        return Ok(warp::reply::with_header(
            error_response(
                "invalidRequest",
                "request body exceeds 4096 bytes",
                StatusCode::PAYLOAD_TOO_LARGE,
            ),
            "connection",
            "close",
        )
        .into_response());
    }
    if rejection.find::<warp::reject::LengthRequired>().is_some() {
        return Ok(error_response(
            "invalidRequest",
            "request body length is required",
            StatusCode::LENGTH_REQUIRED,
        ));
    }
    if rejection.is_not_found() {
        return Ok(error_response(
            "notFound",
            "Helper endpoint not found",
            StatusCode::NOT_FOUND,
        ));
    }
    if rejection.find::<warp::reject::InvalidHeader>().is_some() {
        return Ok(error_response(
            "invalidRequest",
            "invalid request header",
            StatusCode::BAD_REQUEST,
        ));
    }
    if rejection.find::<warp::reject::MethodNotAllowed>().is_some() {
        return Ok(error_response(
            "invalidRequest",
            "Helper endpoint does not accept this method",
            StatusCode::METHOD_NOT_ALLOWED,
        ));
    }
    Ok(error_response(
        "internalError",
        "unhandled Helper request rejection",
        StatusCode::INTERNAL_SERVER_ERROR,
    ))
}

#[derive(Debug)]
struct ForbiddenClient;

impl warp::reject::Reject for ForbiddenClient {}

pub(super) fn routes() -> impl Filter<Extract = (impl Reply,), Error = Infallible> + Clone {
    let native_client = warp::header::optional::<String>("origin")
        .and(warp::header::optional::<String>("host"))
        .and_then(|origin: Option<String>, host: Option<String>| async move {
            let local_host = host.is_none_or(|host| {
                host.parse::<warp::http::uri::Authority>()
                    .is_ok_and(|authority| {
                        ["127.0.0.1", "localhost", super::identity::helper_name()]
                            .iter()
                            .any(|host| authority.host().eq_ignore_ascii_case(host))
                    })
            });
            if origin.is_some() || !local_host {
                return Err(warp::reject::custom(ForbiddenClient));
            }
            Ok(())
        })
        .untuple_one();
    // Matching the path before the method keeps an unknown path rejecting as
    // "not found" instead of the method mismatch another endpoint reports.
    let api_ping = warp::path("ping")
        .and(warp::path::end())
        .and(warp::get())
        .and(warp::query::<PingParams>())
        .and_then(ping_request);

    let api_start = warp::path("start")
        .and(warp::path::end())
        .and(warp::post())
        .and(warp::body::content_length_limit(MAX_REQUEST_BODY_BYTES))
        .and(warp::body::json())
        .and_then(start_request);

    let api_stop = warp::path("stop")
        .and(warp::path::end())
        .and(warp::post())
        .and(warp::body::content_length_limit(MAX_REQUEST_BODY_BYTES))
        .and(warp::body::json())
        .and_then(stop_request);

    let api_logs = warp::path("logs")
        .and(warp::path::end())
        .and(warp::get())
        .map(get_logs);

    let zapret_logs_path = warp::path("zapret")
        .and(warp::path("logs"))
        .and(warp::path::end());
    let api_zapret_logs = zapret_logs_path
        .clone()
        .and(warp::get())
        .map(get_zapret_logs);
    let api_zapret_logs_clear = zapret_logs_path.and(warp::delete()).map(clear_zapret_logs);

    let api_zapret_strategies = warp::path("zapret")
        .and(warp::path("strategies"))
        .and(warp::path::end())
        .and(warp::get())
        .map(get_zapret_strategies);

    let api_zapret_status = warp::path("zapret")
        .and(warp::path::end())
        .and(warp::get())
        .map(get_zapret_status);

    let api_zapret_lists = warp::path("zapret")
        .and(warp::path("lists"))
        .and(warp::path::end())
        .and(warp::get())
        .map(get_zapret_lists);

    let zapret_list_path = warp::path("zapret")
        .and(warp::path("lists"))
        .and(warp::path::param::<String>())
        .and(warp::path::end());

    let api_zapret_list_get = zapret_list_path
        .clone()
        .and(warp::get())
        .map(get_zapret_list);

    let api_zapret_list_put = zapret_list_path
        .and(warp::put())
        .and(warp::body::content_length_limit(MAX_ZAPRET_LIST_BODY_BYTES))
        .and(warp::body::json())
        .and_then(put_zapret_list);

    let api_zapret_list_restore = warp::path("zapret")
        .and(warp::path("lists"))
        .and(warp::path::param::<String>())
        .and(warp::path("restore"))
        .and(warp::path::end())
        .and(warp::post())
        .and_then(restore_zapret_list);

    let api_zapret_watchdog = warp::path("zapret")
        .and(warp::path("watchdog"))
        .and(warp::path::end())
        .and(warp::put())
        .and(warp::body::content_length_limit(MAX_REQUEST_BODY_BYTES))
        .and(warp::body::json())
        .and(warp::header::<u32>("x-zapret-owner-pid"))
        .and(warp::header::<u64>("x-zapret-command"))
        .map(update_zapret_watchdog);

    let api_zapret_start = warp::path("zapret")
        .and(warp::path("start"))
        .and(warp::path::end())
        .and(warp::post())
        .and(warp::body::content_length_limit(MAX_ZAPRET_LIST_BODY_BYTES))
        .and(warp::body::json())
        .and(warp::header::<u32>("x-zapret-owner-pid"))
        .and(warp::header::<u64>("x-zapret-command"))
        .and_then(|request, pid, sequence| launch_zapret_request(false, pid, sequence, request));

    let api_zapret_restart = warp::path("zapret")
        .and(warp::path("restart"))
        .and(warp::path::end())
        .and(warp::post())
        .and(warp::body::content_length_limit(MAX_ZAPRET_LIST_BODY_BYTES))
        .and(warp::body::json())
        .and(warp::header::<u32>("x-zapret-owner-pid"))
        .and(warp::header::<u64>("x-zapret-command"))
        .and_then(|request, pid, sequence| launch_zapret_request(true, pid, sequence, request));

    let api_zapret_stop = warp::path("zapret")
        .and(warp::path("stop"))
        .and(warp::path::end())
        .and(warp::post())
        .and(warp::header::<u32>("x-zapret-owner-pid"))
        .and(warp::header::<u64>("x-zapret-command"))
        .and_then(stop_zapret_request);

    native_client
        .and(
            api_ping
                .or(api_start)
                .or(api_stop)
                .or(api_logs)
                .or(api_zapret_logs)
                .or(api_zapret_logs_clear)
                .or(api_zapret_strategies)
                .or(api_zapret_status)
                .or(api_zapret_lists)
                .or(api_zapret_list_get)
                .or(api_zapret_list_put)
                .or(api_zapret_list_restore)
                .or(api_zapret_watchdog)
                .or(api_zapret_start)
                .or(api_zapret_restart)
                .or(api_zapret_stop),
        )
        .recover(handle_rejection)
}

pub(super) fn ensure_core_sha256_configured() -> anyhow::Result<()> {
    if EXPECTED_CORE_SHA256.is_empty() {
        anyhow::bail!("expected Core SHA256 is empty");
    }
    #[cfg(windows)]
    if let Err(error) = &*RUNNING_HELPER_SHA256 {
        anyhow::bail!("cannot verify running Helper executable: {error}");
    }
    Ok(())
}

/// warp's graceful shutdown waits for every open request, so one a client
/// never finishes would keep the Helper stopping, and the Core it releases
/// afterwards running, for good.
pub(super) fn bounded_shutdown<F>(
    shutdown: F,
) -> (impl Future<Output = ()> + Send + 'static, ShutdownDrain)
where
    F: Future<Output = ()> + Send + 'static,
{
    bounded_shutdown_within(shutdown, SHUTDOWN_DRAIN_TIMEOUT)
}

fn bounded_shutdown_within<F>(
    shutdown: F,
    timeout: Duration,
) -> (impl Future<Output = ()> + Send + 'static, ShutdownDrain)
where
    F: Future<Output = ()> + Send + 'static,
{
    let (started, started_rx) = oneshot::channel();
    let signal = async move {
        shutdown.await;
        let _ = started.send(());
    };
    (
        signal,
        ShutdownDrain {
            started: started_rx,
            timeout,
        },
    )
}

pub(super) struct ShutdownDrain {
    started: oneshot::Receiver<()>,
    timeout: Duration,
}

impl ShutdownDrain {
    pub(super) async fn serve<S>(self, server: S)
    where
        S: Future<Output = ()>,
    {
        let timeout = self.timeout;
        let deadline = async move {
            match self.started.await {
                Ok(()) => tokio::time::sleep(timeout).await,
                Err(_) => pending::<()>().await,
            }
        };
        tokio::select! {
            () = server => {}
            () = deadline => log_message("Helper stopped waiting for unfinished requests".to_string()),
        }
    }
}

pub(super) fn release_managed_core_on_shutdown() {
    SHUTTING_DOWN.store(true, Ordering::SeqCst);
    let mut managed = lock_surviving_poison(&MANAGED_CORE);
    if let Err(error) = release_managed_core(&mut managed) {
        log_message(format!(
            "Helper could not stop the managed Core on shutdown: {error}"
        ));
    }
    #[cfg(windows)]
    {
        let _operation = lock_surviving_poison(&ZAPRET_OPERATION);
        *lock_surviving_poison(&ZAPRET_INTENT) = None;
        let mut zapret = lock_surviving_poison(&MANAGED_ZAPRET);
        if let Err(error) = stop_managed_zapret(&mut zapret) {
            log_message(format!("Helper could not stop Zapret on shutdown: {error}"));
        }
    }
}

#[cfg(all(
    not(all(feature = "windows-service", target_os = "windows")),
    not(target_os = "linux")
))]
pub async fn run_service() -> anyhow::Result<()> {
    run_service_until(pending(), || Ok(())).await
}

#[cfg(not(any(
    all(feature = "windows-service", target_os = "windows"),
    target_os = "linux"
)))]
async fn run_service_until<F, S>(shutdown: F, on_started: S) -> anyhow::Result<()>
where
    F: Future<Output = ()> + Send + 'static,
    S: FnOnce() -> anyhow::Result<()>,
{
    ensure_core_sha256_configured()?;

    let (shutdown, drain) = bounded_shutdown(shutdown);
    let (_, server) = warp::serve(routes())
        .try_bind_with_graceful_shutdown(([127, 0, 0, 1], LISTEN_PORT), shutdown)
        .map_err(|error| anyhow::anyhow!("bind helper server: {error}"))?;
    on_started()?;
    drain.serve(server).await;
    release_managed_core_on_shutdown();

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    static PROCESS_STATE: Mutex<()> = Mutex::new(());

    fn lock_process_state() -> std::sync::MutexGuard<'static, ()> {
        PROCESS_STATE
            .lock()
            .unwrap_or_else(|error| error.into_inner())
    }

    #[cfg(not(target_os = "linux"))]
    const ALLOWED_CORE_ADDRESS: &str = r"\\.\pipe\FlClashCore_0123456789abcdef0123456789abcdef";
    #[cfg(target_os = "linux")]
    const ALLOWED_CORE_ADDRESS: &str = "/tmp/FlClashSocket_4821.sock";

    fn spawn_placeholder_core() -> Child {
        #[cfg(windows)]
        let mut command = {
            let mut command = Command::new("cmd");
            command.args(["/c", "exit"]);
            command
        };
        #[cfg(not(windows))]
        let mut command = Command::new("true");
        command
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn placeholder Core")
    }

    fn spawn_running_core() -> Child {
        #[cfg(windows)]
        let mut command = {
            let mut command = Command::new("ping");
            command.args(["-n", "60", "127.0.0.1"]);
            command
        };
        #[cfg(not(windows))]
        let mut command = {
            let mut command = Command::new("sleep");
            command.arg("60");
            command
        };
        command
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn running Core")
    }

    fn adopt_core(session_id: &str) {
        *lock_surviving_poison(&MANAGED_CORE) =
            Some(ManagedCore::adopt(session_id.to_string(), spawn_running_core()).unwrap());
    }

    #[test]
    fn zapret_diagnostics_distinguish_capture_filters_from_processing_lists() {
        let args = vec![
            "--wf-tcp-out=80,443".to_string(),
            "--wf-udp-out=443".to_string(),
            "--hostlist=lists/list-general.txt".to_string(),
            "--hostlist-domains=discord.com".to_string(),
            "--hostlist-auto=lists/list-auto.txt".to_string(),
            "--ipset=lists/ipset-all.txt".to_string(),
        ];
        assert_eq!(
            zapret_win_divert_filters(&args),
            vec![
                "--wf-tcp-out=80,443".to_string(),
                "--wf-udp-out=443".to_string()
            ],
        );
        assert_eq!(
            zapret_processing_lists(&args),
            vec![
                "--hostlist=lists/list-general.txt".to_string(),
                "--hostlist-domains=discord.com".to_string(),
                "--hostlist-auto=lists/list-auto.txt".to_string(),
                "--ipset=lists/ipset-all.txt".to_string(),
            ],
        );
    }

    #[test]
    fn protocol_uses_lowercase_session_ownership() {
        assert_eq!(PROTOCOL_VERSION, if cfg!(windows) { "11" } else { "6" });
        assert!(is_valid_session_id("0123456789abcdef0123456789abcdef"));
        assert!(!is_valid_session_id("ABCDEF0123456789abcdef0123456789"));
        assert!(!is_valid_session_id("0123456789abcdef"));
    }

    #[test]
    fn stop_decision_never_touches_another_session() {
        let requested = "0123456789abcdef0123456789abcdef";
        let other = "fedcba9876543210fedcba9876543210";

        assert_eq!(stop_decision(None, requested), StopDecision::NotRunning);
        assert_eq!(
            stop_decision(Some(requested), requested),
            StopDecision::Stop
        );
        assert_eq!(
            stop_decision(Some(other), requested),
            StopDecision::SessionMismatch
        );
    }

    #[tokio::test]
    async fn ping_returns_running_helper_path_for_verified_core() {
        let response = ping_response(Ok(PathBuf::from("FlClashZHelperService.exe")));

        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response.headers().get(PROTOCOL_VERSION_HEADER).unwrap(),
            PROTOCOL_VERSION
        );
        assert_eq!(
            warp::hyper::body::to_bytes(response.into_body())
                .await
                .unwrap(),
            "FlClashZHelperService.exe"
        );
    }

    #[tokio::test]
    async fn ping_response_renders_core_verification_error() {
        let response = ping_response(Err(Error::other("Core executable SHA256 mismatch")));

        assert_eq!(response.status(), StatusCode::CONFLICT);
        assert_eq!(
            response.headers().get(PROTOCOL_VERSION_HEADER).unwrap(),
            PROTOCOL_VERSION
        );
        assert_eq!(
            warp::hyper::body::to_bytes(response.into_body())
                .await
                .unwrap(),
            "Core executable SHA256 mismatch"
        );
    }

    #[tokio::test]
    async fn unknown_endpoints_are_not_found() {
        let response = warp::test::request()
            .method("GET")
            .path("/nope")
            .reply(&routes())
            .await;

        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn known_endpoints_reject_the_wrong_method() {
        let response = warp::test::request()
            .method("POST")
            .path("/ping")
            .reply(&routes())
            .await;

        assert_eq!(response.status(), StatusCode::METHOD_NOT_ALLOWED);
    }

    #[tokio::test]
    async fn ping_is_available_without_authentication() {
        let response = warp::test::request()
            .method("GET")
            .path(&format!("/ping?coreSha256={EXPECTED_CORE_SHA256}"))
            .reply(&routes())
            .await;

        assert!(response.status() == StatusCode::OK || response.status() == StatusCode::CONFLICT);
        assert_eq!(
            response.headers().get(PROTOCOL_VERSION_HEADER).unwrap(),
            PROTOCOL_VERSION
        );
    }

    #[tokio::test]
    async fn ping_requires_the_core_sha256_query_parameter() {
        let response = warp::test::request()
            .method("GET")
            .path("/ping")
            .reply(&routes())
            .await;

        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        assert_eq!(
            response.headers().get(PROTOCOL_VERSION_HEADER).unwrap(),
            PROTOCOL_VERSION
        );
    }

    #[tokio::test]
    async fn ping_rejects_a_core_sha256_that_does_not_match() {
        let requested = if EXPECTED_CORE_SHA256.starts_with('0') {
            format!("1{}", EXPECTED_CORE_SHA256.get(1..).unwrap_or(""))
        } else {
            format!("0{}", EXPECTED_CORE_SHA256.get(1..).unwrap_or(""))
        };
        assert_ne!(requested, EXPECTED_CORE_SHA256);

        let response = warp::test::request()
            .method("GET")
            .path(&format!("/ping?coreSha256={requested}"))
            .reply(&routes())
            .await;

        assert_eq!(response.status(), StatusCode::CONFLICT);
        assert_eq!(
            response.headers().get(PROTOCOL_VERSION_HEADER).unwrap(),
            PROTOCOL_VERSION
        );
        let body: serde_json::Value = serde_json::from_slice(response.body()).unwrap();
        assert_eq!(body["code"], "coreSha256Mismatch");
    }

    #[tokio::test]
    async fn logs_are_available_without_authentication() {
        let response = warp::test::request()
            .method("GET")
            .path("/logs")
            .reply(&routes())
            .await;

        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response.headers().get("content-type").unwrap(),
            "text/plain; charset=utf-8"
        );
        assert_eq!(response.headers().get("cache-control").unwrap(), "no-store");
    }

    #[tokio::test]
    async fn a_launch_failure_carries_the_os_error_code() {
        let response = launch_failure_response(&Error::from_raw_os_error(577));

        assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
        let body: serde_json::Value = serde_json::from_slice(
            &warp::hyper::body::to_bytes(response.into_body())
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(body["code"], "processLaunchFailed");
        assert_eq!(body["details"]["osError"], 577);
    }

    #[tokio::test]
    async fn a_launch_failure_without_an_os_error_omits_the_details() {
        let response = launch_failure_response(&Error::other("spawn refused"));

        let body: serde_json::Value = serde_json::from_slice(
            &warp::hyper::body::to_bytes(response.into_body())
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(body["message"], "spawn refused");
        assert!(body.get("details").is_none());
    }

    #[tokio::test]
    async fn start_rejects_a_caller_supplied_core_argument() {
        let response = warp::test::request()
            .method("POST")
            .path("/start")
            .header("content-type", "application/json")
            .body(format!(
                r#"{{"address":{},"sessionId":"0123456789abcdef0123456789abcdef","path":"attacker.exe"}}"#,
                serde_json::to_string(ALLOWED_CORE_ADDRESS).unwrap()
            ))
            .reply(&routes())
            .await;

        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let body: serde_json::Value = serde_json::from_slice(response.body()).unwrap();
        assert_eq!(body["code"], "invalidRequest");
    }

    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn launch_releases_the_managed_core_before_rejecting_an_unverified_core() {
        let _state = lock_process_state();
        *lock_surviving_poison(&MANAGED_CORE) = Some(
            ManagedCore::adopt(
                "fedcba9876543210fedcba9876543210".to_string(),
                spawn_placeholder_core(),
            )
            .unwrap(),
        );

        let response = launch(StartParams {
            address: ALLOWED_CORE_ADDRESS.to_string(),
            session_id: "0123456789abcdef0123456789abcdef".to_string(),
        });

        assert_eq!(response.status(), StatusCode::CONFLICT);
        assert!(lock_surviving_poison(&MANAGED_CORE).is_none());
        let body: serde_json::Value = serde_json::from_slice(
            &warp::hyper::body::to_bytes(response.into_body())
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(body["code"], "coreVerificationFailed");
    }

    #[test]
    fn a_core_that_exits_on_its_own_is_reaped() {
        let _state = lock_process_state();
        let session_id = "0123456789abcdef0123456789abcdef";
        *lock_surviving_poison(&MANAGED_CORE) =
            Some(ManagedCore::adopt(session_id.to_string(), spawn_placeholder_core()).unwrap());

        reap_exited_core(session_id);

        assert!(lock_surviving_poison(&MANAGED_CORE).is_none());
    }

    #[test]
    fn reaping_leaves_a_running_or_newer_core_owned() {
        let _state = lock_process_state();
        let session_id = "0123456789abcdef0123456789abcdef";
        *lock_surviving_poison(&MANAGED_CORE) =
            Some(ManagedCore::adopt(session_id.to_string(), spawn_placeholder_core()).unwrap());

        reap_exited_core("fedcba9876543210fedcba9876543210");
        assert!(lock_surviving_poison(&MANAGED_CORE).is_some());

        adopt_core(session_id);
        reap_exited_core(session_id);

        let mut managed = lock_surviving_poison(&MANAGED_CORE);
        assert!(managed
            .as_mut()
            .unwrap()
            .child
            .try_wait()
            .unwrap()
            .is_none());
        release_managed_core(&mut managed).unwrap();
    }

    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn stop_confirms_the_exit_before_reporting_success() {
        let _state = lock_process_state();
        let session_id = "0123456789abcdef0123456789abcdef";
        adopt_core(session_id);

        let response = warp::test::request()
            .method("POST")
            .path("/stop")
            .json(&StopParams {
                session_id: session_id.to_string(),
            })
            .reply(&routes())
            .await;

        assert_eq!(response.status(), StatusCode::OK);
        let body: serde_json::Value = serde_json::from_slice(response.body()).unwrap();
        assert_eq!(body["stopped"], true);
        assert!(body.get("reason").is_none());
        assert!(lock_surviving_poison(&MANAGED_CORE).is_none());
    }

    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn stop_keeps_another_session_owned_and_running() {
        let _state = lock_process_state();
        adopt_core("fedcba9876543210fedcba9876543210");

        let response = warp::test::request()
            .method("POST")
            .path("/stop")
            .json(&StopParams {
                session_id: "0123456789abcdef0123456789abcdef".to_string(),
            })
            .reply(&routes())
            .await;

        assert_eq!(response.status(), StatusCode::CONFLICT);
        let body: serde_json::Value = serde_json::from_slice(response.body()).unwrap();
        assert_eq!(body["reason"], "sessionMismatch");

        let mut managed = lock_surviving_poison(&MANAGED_CORE);
        let core = managed.as_mut().expect("Core stays owned");
        assert_eq!(core.session_id, "fedcba9876543210fedcba9876543210");
        assert!(core.child.try_wait().unwrap().is_none());
        release_managed_core(&mut managed).unwrap();
    }

    #[cfg(target_os = "linux")]
    fn spawn_shell_core_once_ready(script: &str) -> Child {
        let mut child = Command::new("sh")
            .args(["-c", script])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn shell core");
        let mut ready = String::new();
        std::io::BufReader::new(child.stdout.take().expect("piped stdout"))
            .read_line(&mut ready)
            .expect("read readiness");
        assert_eq!(ready, "ready\n");
        child
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn terminate_lets_the_core_exit_on_its_own_before_killing_it() {
        use std::os::unix::process::ExitStatusExt;

        let mut core = ManagedCore::adopt(
            "0123456789abcdef0123456789abcdef".to_string(),
            spawn_shell_core_once_ready(
                "trap 'exit 0' TERM; echo ready; while :; do sleep 0.05; done",
            ),
        )
        .unwrap();

        core.terminate().unwrap();

        let status = core.child.try_wait().unwrap().expect("Core exited");
        assert_eq!(status.code(), Some(0));
        assert_eq!(status.signal(), None);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn terminate_kills_a_core_that_ignores_the_exit_request() {
        use std::os::unix::process::ExitStatusExt;

        let mut core = ManagedCore::adopt(
            "0123456789abcdef0123456789abcdef".to_string(),
            spawn_shell_core_once_ready("trap '' TERM; echo ready; exec sleep 30"),
        )
        .unwrap();

        core.terminate().unwrap();

        let status = core.child.try_wait().unwrap().expect("Core exited");
        assert_eq!(status.signal(), Some(libc::SIGKILL));
    }

    #[cfg(windows)]
    #[test]
    fn closing_the_job_takes_the_core_down_with_the_helper() {
        let core = ManagedCore::adopt(
            "0123456789abcdef0123456789abcdef".to_string(),
            spawn_running_core(),
        )
        .unwrap();
        let ManagedCore {
            mut child, _job, ..
        } = core;

        drop(_job);

        let deadline = Instant::now() + CORE_EXIT_TIMEOUT;
        while child.try_wait().unwrap().is_none() {
            assert!(Instant::now() < deadline, "Core outlived its job");
            thread::sleep(CORE_EXIT_POLL_INTERVAL);
        }
    }

    #[test]
    fn terminate_confirms_the_exit_of_a_running_core() {
        let mut managed = Some(
            ManagedCore::adopt(
                "0123456789abcdef0123456789abcdef".to_string(),
                spawn_running_core(),
            )
            .unwrap(),
        );

        release_managed_core(&mut managed).unwrap();

        assert!(managed.is_none());
        assert!(release_managed_core(&mut managed).is_ok());
    }

    #[tokio::test]
    async fn zapret_strategy_catalog_exposes_all_builtin_engine_families() {
        let response = warp::test::request()
            .method("GET")
            .path("/zapret/strategies")
            .reply(&routes())
            .await;

        assert_eq!(response.status(), StatusCode::OK);
        let strategies: Vec<serde_json::Value> = serde_json::from_slice(response.body()).unwrap();
        assert_eq!(strategies.len(), 41);
        assert_eq!(
            strategies
                .iter()
                .filter(|item| item["engine"] == "winws")
                .count(),
            5
        );
        assert_eq!(
            strategies
                .iter()
                .filter(|item| item["engine"] == "winws2")
                .count(),
            36
        );
        assert_eq!(
            strategies
                .iter()
                .filter(|item| item["id"].as_str().unwrap().starts_with("kinlay0-"))
                .count(),
            26
        );
    }

    #[tokio::test]
    async fn start_rejects_an_invalid_session_before_core_verification() {
        let response = warp::test::request()
            .method("POST")
            .path("/start")
            .json(&StartParams {
                address: ALLOWED_CORE_ADDRESS.to_string(),
                session_id: "ABCDEF0123456789abcdef0123456789".to_string(),
            })
            .reply(&routes())
            .await;

        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let body: serde_json::Value = serde_json::from_slice(response.body()).unwrap();
        assert_eq!(body["code"], "invalidRequest");
    }

    #[test]
    fn verifies_core_sha256_in_all_build_modes() {
        let path = std::env::temp_dir().join(format!(
            "flclashx-helper-core-sha256-{}",
            std::process::id()
        ));
        let mut file = File::create(&path).unwrap();
        file.write_all(b"test").unwrap();
        drop(file);

        assert!(open_verified_core(
            &path,
            "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        )
        .is_ok());
        assert_eq!(
            open_verified_core(&path, "invalid")
                .unwrap_err()
                .to_string(),
            "Core executable SHA256 mismatch"
        );
        std::fs::remove_file(path).unwrap();
    }

    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn stop_is_available_without_authentication() {
        let _state = lock_process_state();
        let response = warp::test::request()
            .method("POST")
            .path("/stop")
            .json(&StopParams {
                session_id: "0123456789abcdef0123456789abcdef".to_string(),
            })
            .reply(&routes())
            .await;

        assert_eq!(response.status(), StatusCode::OK);
        let body: serde_json::Value = serde_json::from_slice(response.body()).unwrap();
        assert_eq!(body["sessionId"], "0123456789abcdef0123456789abcdef");
        assert_eq!(body["stopped"], false);
        assert_eq!(body["reason"], "notRunning");
    }

    #[tokio::test]
    async fn stop_requires_a_session_json_body() {
        let response = warp::test::request()
            .method("POST")
            .path("/stop")
            .body("")
            .reply(&routes())
            .await;

        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let body: serde_json::Value = serde_json::from_slice(response.body()).unwrap();
        assert_eq!(body["code"], "invalidRequest");
    }

    #[tokio::test]
    async fn stop_rejects_unknown_fields() {
        let response = warp::test::request()
            .method("POST")
            .path("/stop")
            .header("content-type", "application/json")
            .body(r#"{"sessionId":"0123456789abcdef0123456789abcdef","force":true}"#)
            .reply(&routes())
            .await;

        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let body: serde_json::Value = serde_json::from_slice(response.body()).unwrap();
        assert_eq!(body["code"], "invalidRequest");
    }

    #[test]
    fn core_path_is_fixed_beside_the_helper() {
        assert_eq!(
            core_path().unwrap().file_name().unwrap(),
            std::ffi::OsStr::new(env!("CORE_NAME"))
        );
    }

    #[tokio::test]
    async fn browser_origins_and_rebound_hosts_cannot_reach_any_endpoint() {
        for (method, path) in [
            ("GET", "/ping"),
            ("GET", "/logs"),
            ("POST", "/start"),
            ("POST", "/stop"),
        ] {
            for (header, value) in [
                ("origin", "https://attacker.test"),
                ("origin", "null"),
                ("host", "attacker.test:47890"),
            ] {
                let response = warp::test::request()
                    .method(method)
                    .path(path)
                    .header(header, value)
                    .reply(&routes())
                    .await;
                assert_eq!(response.status(), StatusCode::FORBIDDEN);
                assert!(response
                    .headers()
                    .get("access-control-allow-origin")
                    .is_none());
            }
        }
        for host in [
            "127.0.0.1:47890",
            "localhost:47890",
            super::super::identity::helper_name(),
        ] {
            let response = warp::test::request()
                .path("/logs")
                .header("host", host)
                .reply(&routes())
                .await;
            assert_eq!(response.status(), StatusCode::OK);
        }
    }

    #[tokio::test]
    async fn state_changes_are_size_limited() {
        let oversized = " ".repeat(MAX_REQUEST_BODY_BYTES as usize + 1);
        for path in ["/start", "/stop"] {
            let response = warp::test::request()
                .method("POST")
                .path(path)
                .body(&oversized)
                .reply(&routes())
                .await;
            assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
            assert_eq!(response.headers()["connection"], "close");

            let response = warp::test::request()
                .method("POST")
                .path(path)
                .reply(&routes())
                .await;
            assert_eq!(response.status(), StatusCode::LENGTH_REQUIRED);
        }
    }

    #[cfg(not(target_os = "linux"))]
    #[test]
    fn only_accepts_random_core_pipe_namespace() {
        assert!(is_allowed_core_address(
            r"\\.\pipe\FlClashCore_0123456789abcdef0123456789abcdef"
        ));
        assert!(!is_allowed_core_address(r"\\.\pipe\FlClashCore"));
        assert!(!is_allowed_core_address(
            r"\\.\pipe\Other_0123456789abcdef0123456789abcdef"
        ));
        assert!(!is_allowed_core_address(
            r"\\.\pipe\FlClashCore_0123456789abcdef"
        ));
        assert!(!is_allowed_core_address(
            r"\\.\pipe\FlClashCore_0123456789abcdef0123456789abcdeg"
        ));
        assert!(!is_allowed_core_address(
            r"\\.\pipe\FlClashCore_ABCDEF0123456789abcdef0123456789"
        ));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn only_accepts_random_core_socket_namespace() {
        assert!(is_allowed_core_address("/tmp/FlClashSocket_4821.sock"));
        assert!(!is_allowed_core_address("/tmp/FlClashSocket_.sock"));
        assert!(!is_allowed_core_address("/tmp/FlClashSocket_4821"));
        assert!(!is_allowed_core_address("/tmp/Other_4821.sock"));
        assert!(!is_allowed_core_address("/tmp/FlClashSocket_../x.sock"));
        assert!(!is_allowed_core_address(
            "/tmp/FlClashSocket_12345678901.sock"
        ));
    }

    #[test]
    fn a_poisoned_lock_still_hands_out_the_guarded_value() {
        let mutex = Mutex::new(7);
        let _ = std::panic::catch_unwind(|| {
            let _guard = mutex.lock().unwrap();
            panic!("poison the lock");
        });

        assert!(mutex.lock().is_err());
        assert_eq!(*lock_surviving_poison(&mutex), 7);
    }

    #[test]
    fn logging_survives_a_panic_that_poisoned_the_log_buffer() {
        let _ = std::panic::catch_unwind(|| {
            let _guard = LOGS.lock().unwrap();
            panic!("poison the log buffer");
        });

        log_message("helper still logs after poisoning".to_string());

        assert!(lock_surviving_poison(&LOGS)
            .iter()
            .any(|entry| entry == "helper still logs after poisoning"));
    }

    #[tokio::test]
    async fn shutdown_stops_waiting_for_a_request_that_never_finishes() {
        let (shutdown, drain) = bounded_shutdown_within(async {}, Duration::from_millis(20));
        let server = async move {
            shutdown.await;
            pending::<()>().await;
        };

        tokio::time::timeout(Duration::from_secs(5), drain.serve(server))
            .await
            .expect("the drain outlived its deadline");
    }

    #[tokio::test]
    async fn the_drain_deadline_starts_with_shutdown() {
        let (_shutdown, drain) = bounded_shutdown_within(pending(), Duration::from_millis(20));

        let served = tokio::time::timeout(Duration::from_millis(200), drain.serve(pending())).await;

        assert!(served.is_err(), "the server ended before any shutdown");
    }
}

#[cfg(test)]
mod zapret_log_reason_tests {
    use super::{zapret_reason, ZapretStartRequest};

    #[test]
    fn shared_flutter_restart_request_deserializes() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../test/fixtures/zapret_restart_contract.json"
        ))
        .unwrap();
        let request: ZapretStartRequest =
            serde_json::from_value(fixture["request"].clone()).unwrap();
        assert_eq!(request.strategy_id, "flowseal-alt");
        assert_eq!(request.reason.as_deref(), Some("dashboard"));
        assert!(request.debug);
        assert_eq!(request.watchdog, Some(false));
    }

    #[test]
    fn reason_labels_are_bounded_and_legacy_clients_work() {
        assert_eq!(zapret_reason(Some("trial_screen"), true), "auto-tune screening");
        assert_eq!(zapret_reason(Some("infrastructure_changed"), true), "infrastructure changed");
        assert_eq!(zapret_reason(None, false), "start (unspecified)");
        assert_eq!(zapret_reason(Some("arbitrary\nmessage"), true), "restart (unspecified)");
    }
}
