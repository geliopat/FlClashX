//! Direct, owned Flowseal process management for the interactive Windows user.
//!
//! This deliberately does not use the SYSTEM Helper service and never invokes
//! BAT/CMD, PowerShell, or a service manager. Only the verified winws.exe inside
//! the selected Flowseal installation is spawned, with parsed argv values.

use crate::zapret::core::{CoreProvider, GameFilterSettings};
use crate::zapret::providers::flowseal::FlowsealProvider;
use std::os::windows::{
    io::{AsRawHandle, FromRawHandle, OwnedHandle, RawHandle},
    process::CommandExt,
};
use std::{
    fs::{self, File, OpenOptions},
    io::{self, BufRead, BufReader, Read, Write},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex, MutexGuard, OnceLock},
    thread,
    time::{SystemTime, UNIX_EPOCH},
};
use windows_sys::Win32::{
    Foundation::{CloseHandle, HANDLE},
    Security::{GetTokenInformation, TokenElevation, TOKEN_ELEVATION, TOKEN_QUERY},
    System::{
        JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
            SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        },
        Threading::{GetCurrentProcess, OpenProcessToken},
    },
};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;

pub struct ProcessStatus {
    pub running: bool,
    pub pid: Option<u32>,
    pub strategy: Option<String>,
    pub log_path: String,
    pub elevated: bool,
}

struct RunningProcess {
    child: Child,
    pid: u32,
    // Closing the Job Object kills the process if FlClashX exits unexpectedly.
    _job: OwnedHandle,
    strategy: String,
    log_path: PathBuf,
}

fn process_slot() -> &'static Mutex<Option<RunningProcess>> {
    static PROCESS: OnceLock<Mutex<Option<RunningProcess>>> = OnceLock::new();
    PROCESS.get_or_init(|| Mutex::new(None))
}

fn lock_process() -> MutexGuard<'static, Option<RunningProcess>> {
    process_slot()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn process_is_running(running: &mut RunningProcess) -> io::Result<bool> {
    Ok(running.child.try_wait()?.is_none())
}

fn require_admin_token(elevated: bool) -> Result<(), &'static str> {
    if elevated {
        Ok(())
    } else {
        Err("Flowseal requires administrator privileges. Approve the UAC prompt to restart FlClashX, then start the strategy again.")
    }
}

pub fn is_elevated() -> bool {
    // Read the actual token elevation state; membership in the local
    // Administrators group alone is not enough under UAC.
    unsafe {
        let mut token: HANDLE = std::ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
            return false;
        }
        let mut elevation: TOKEN_ELEVATION = std::mem::zeroed();
        let mut returned = 0u32;
        let result = GetTokenInformation(
            token,
            TokenElevation,
            (&mut elevation as *mut TOKEN_ELEVATION).cast(),
            std::mem::size_of::<TOKEN_ELEVATION>() as u32,
            &mut returned,
        );
        CloseHandle(token);
        result != 0 && elevation.TokenIsElevated != 0
    }
}

fn is_valid_game_filter_range(value: &str) -> bool {
    if value.is_empty() || value.len() > 64 {
        return false;
    }
    value.split(',').all(|part| {
        let (start, end) = part.split_once('-').unwrap_or((part, part));
        if start.is_empty() || end.is_empty() || end.contains('-') {
            return false;
        }
        let Ok(start) = start.parse::<u16>() else {
            return false;
        };
        let Ok(end) = end.parse::<u16>() else {
            return false;
        };
        start > 0 && end > 0 && start <= end
    })
}

fn validate_game_filter_settings(settings: &GameFilterSettings) -> Result<(), String> {
    let validate_tcp = matches!(settings.mode.as_str(), "all" | "tcp");
    let validate_udp = matches!(settings.mode.as_str(), "all" | "udp");
    if !matches!(settings.mode.as_str(), "none" | "all" | "tcp" | "udp") {
        return Err("Unsupported Flowseal game filter mode".into());
    }
    if validate_tcp && !is_valid_game_filter_range(&settings.tcp_range) {
        return Err("Flowseal TCP game filter must contain valid ports or port ranges".into());
    }
    if validate_udp && !is_valid_game_filter_range(&settings.udp_range) {
        return Err("Flowseal UDP game filter must contain valid ports or port ranges".into());
    }
    Ok(())
}

pub fn status(root: &Path) -> Result<ProcessStatus, String> {
    let mut slot = lock_process();
    let completed_log = if let Some(running) = slot.as_mut() {
        if process_is_running(running)
            .map_err(|error| format!("Cannot query winws.exe process: {error}"))?
        {
            return Ok(status_for_running(running));
        }
        Some(running.log_path.clone())
    } else {
        None
    };
    if completed_log.is_some() {
        slot.take();
    }
    Ok(status_stopped(
        completed_log.unwrap_or_else(|| root.join("logs").join("winws.log")),
    ))
}

pub fn start(
    requested_root: PathBuf,
    strategy: &str,
    game_filter: &GameFilterSettings,
) -> Result<ProcessStatus, String> {
    require_admin_token(is_elevated()).map_err(str::to_owned)?;
    validate_game_filter_settings(game_filter)?;

    let root = fs::canonicalize(&requested_root).map_err(|error| {
        format!(
            "Cannot resolve Flowseal installation directory {}: {error}",
            requested_root.display()
        )
    })?;
    if !root.is_dir() {
        return Err("Flowseal installation directory is not a directory".into());
    }

    let mut slot = lock_process();
    if let Some(running) = slot.as_mut() {
        if process_is_running(running)
            .map_err(|error| format!("Cannot query existing winws.exe process: {error}"))?
        {
            return Err(format!("flowseal_already_running:{}", running.pid));
        }
        slot.take();
    }

    let provider = FlowsealProvider::new(root.clone());
    provider
        .validate_installation()
        .map_err(|error| format!("Flowseal installation is invalid: {error}"))?;

    let executable = fs::canonicalize(provider.winws_executable())
        .map_err(|error| format!("Cannot resolve Flowseal winws.exe: {error}"))?;
    if !executable.starts_with(&root)
        || !executable
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.eq_ignore_ascii_case("winws.exe"))
    {
        return Err("Flowseal winws.exe resolves outside the installation directory".into());
    }
    for required in [
        root.join("bin").join("WinDivert.dll"),
        root.join("bin").join("WinDivert64.sys"),
    ] {
        let resolved = fs::canonicalize(&required).map_err(|error| {
            format!(
                "Cannot resolve required Flowseal file {}: {error}",
                required.display()
            )
        })?;
        if !resolved.starts_with(&root) {
            return Err(format!(
                "Required Flowseal file resolves outside the installation directory: {}",
                required.display()
            ));
        }
    }
    let bin_dir = fs::canonicalize(root.join("bin"))
        .map_err(|error| format!("Cannot resolve Flowseal bin directory: {error}"))?;
    if !bin_dir.starts_with(&root) {
        return Err("Flowseal bin directory resolves outside the installation directory".into());
    }

    let arguments = provider
        .parse_strategy(strategy, game_filter)
        .map_err(|error| format!("Cannot resolve Flowseal strategy: {error}"))?;
    let args = split_windows_arguments(&arguments)?;
    if args.is_empty() {
        return Err("Flowseal strategy contains no winws.exe arguments".into());
    }
    validate_argument_paths(&args, &root)?;

    let log_path = prepare_log_path(&root)?;
    let mut log_file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .map_err(|error| format!("Cannot open Flowseal log {}: {error}", log_path.display()))?;
    writeln!(
        log_file,
        "\n[{}][flowseal] Starting strategy: {}",
        unix_timestamp(),
        strategy.replace('\r', " ").replace('\n', " ")
    )
    .map_err(|error| format!("Cannot write Flowseal log: {error}"))?;

    let job = create_kill_on_close_job()
        .map_err(|error| format!("Cannot create Flowseal process job: {error}"))?;
    let working_directory = executable
        .parent()
        .ok_or_else(|| "Flowseal winws.exe has no parent directory".to_string())?;

    let mut command = Command::new(&executable);
    command
        .args(&args)
        .current_dir(working_directory)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .creation_flags(CREATE_NO_WINDOW);
    let mut child = command
        .spawn()
        .map_err(|error| format!("Cannot start Flowseal winws.exe: {error}"))?;
    let pid = child.id();
    let process_handle = child.as_raw_handle() as HANDLE;

    // The elevated FlClashX process owns the child handle and can safely put
    // this exact winws.exe instance into a kill-on-close Job Object.
    if unsafe { AssignProcessToJobObject(job.as_raw_handle() as HANDLE, process_handle) } == 0 {
        let error = io::Error::last_os_error();
        let _ = stop_child(&mut child);
        return Err(format!(
            "Cannot attach Flowseal process to its job: {error}"
        ));
    }

    let log = Arc::new(Mutex::new(log_file));
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "Flowseal stdout pipe was not created".to_string())?;
    if let Err(error) = spawn_log_reader("stdout", stdout, Arc::clone(&log)) {
        let _ = stop_child(&mut child);
        return Err(format!("Cannot start Flowseal stdout logger: {error}"));
    }
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| "Flowseal stderr pipe was not created".to_string())?;
    if let Err(error) = spawn_log_reader("stderr", stderr, Arc::clone(&log)) {
        let _ = stop_child(&mut child);
        return Err(format!("Cannot start Flowseal stderr logger: {error}"));
    }
    {
        let mut file = log.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let launch = "Started as a child of elevated FlClashX";
        let _ = writeln!(
            file,
            "[{}][flowseal] {launch}: winws.exe PID {pid}",
            unix_timestamp()
        );
        let _ = file.flush();
    }

    let running = RunningProcess {
        child,
        pid,
        _job: job,
        strategy: strategy.to_owned(),
        log_path: log_path.clone(),
    };
    let status = status_for_running(&running);
    *slot = Some(running);
    Ok(status)
}

pub fn stop(root: &Path) -> Result<ProcessStatus, String> {
    let mut slot = lock_process();
    let log_path = if let Some(running) = slot.as_mut() {
        stop_child(&mut running.child)
            .map_err(|error| format!("Cannot stop owned Flowseal winws.exe process: {error}"))?;
        running.log_path.clone()
    } else {
        root.join("logs").join("winws.log")
    };
    slot.take();
    Ok(status_stopped(log_path))
}

fn status_for_running(running: &RunningProcess) -> ProcessStatus {
    ProcessStatus {
        running: true,
        pid: Some(running.pid),
        strategy: Some(running.strategy.clone()),
        log_path: running.log_path.to_string_lossy().into_owned(),
        elevated: is_elevated(),
    }
}

fn status_stopped(log_path: PathBuf) -> ProcessStatus {
    ProcessStatus {
        running: false,
        pid: None,
        strategy: None,
        log_path: log_path.to_string_lossy().into_owned(),
        elevated: is_elevated(),
    }
}

fn stop_child(child: &mut Child) -> io::Result<()> {
    if child.try_wait()?.is_some() {
        return Ok(());
    }
    if let Err(error) = child.kill() {
        return if child.try_wait()?.is_some() {
            Ok(())
        } else {
            Err(error)
        };
    }
    child.wait()?;
    Ok(())
}

fn create_kill_on_close_job() -> io::Result<OwnedHandle> {
    let raw = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
    if raw.is_null() {
        return Err(io::Error::last_os_error());
    }
    let job = unsafe { OwnedHandle::from_raw_handle(raw as RawHandle) };
    let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if unsafe {
        SetInformationJobObject(
            job.as_raw_handle() as HANDLE,
            JobObjectExtendedLimitInformation,
            (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
            std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        )
    } == 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(job)
}

fn prepare_log_path(root: &Path) -> Result<PathBuf, String> {
    let requested = root.join("logs");
    fs::create_dir_all(&requested)
        .map_err(|error| format!("Cannot create Flowseal log directory: {error}"))?;
    let directory = fs::canonicalize(&requested)
        .map_err(|error| format!("Cannot resolve Flowseal log directory: {error}"))?;
    if !directory.starts_with(root) {
        return Err("Flowseal log directory resolves outside the installation directory".into());
    }
    let path = directory.join("winws.log");
    if let Ok(metadata) = fs::symlink_metadata(&path) {
        if metadata.file_type().is_symlink() {
            return Err("Flowseal log path must not be a symbolic link".into());
        }
        if !metadata.is_file() {
            return Err("Flowseal log path is not a regular file".into());
        }
    }
    Ok(path)
}

fn spawn_log_reader<R>(stream: &'static str, reader: R, log: Arc<Mutex<File>>) -> io::Result<()>
where
    R: Read + Send + 'static,
{
    thread::Builder::new()
        .name(format!("flowseal-{stream}-log"))
        .spawn(move || {
            let mut reader = BufReader::new(reader);
            let mut line = Vec::new();
            loop {
                line.clear();
                match reader.read_until(b'\n', &mut line) {
                    Ok(0) => break,
                    Ok(_) => {
                        let mut file = log.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
                        let _ = write!(file, "[{}][{stream}] ", unix_timestamp());
                        let _ = file.write_all(&line);
                        if !line.ends_with(b"\n") {
                            let _ = file.write_all(b"\n");
                        }
                        let _ = file.flush();
                    }
                    Err(error) => {
                        let mut file = log.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
                        let _ = writeln!(
                            file,
                            "[{}][{stream}] log read error: {error}",
                            unix_timestamp()
                        );
                        break;
                    }
                }
            }
        })
        .map(|_| ())
}

fn unix_timestamp() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or_default()
}

fn split_windows_arguments(input: &str) -> Result<Vec<String>, String> {
    if input.chars().any(|character| character.is_control()) {
        return Err("Flowseal strategy arguments contain control characters".into());
    }

    let mut arguments = Vec::new();
    let mut current = String::new();
    let mut characters = input.chars().peekable();
    let mut quoted = false;
    let mut started = false;

    while characters.peek().is_some() {
        if characters
            .peek()
            .is_some_and(|character| character.is_whitespace())
            && !quoted
        {
            characters.next();
            if started {
                arguments.push(std::mem::take(&mut current));
                started = false;
            }
            continue;
        }

        let mut backslashes = 0usize;
        while characters.peek() == Some(&'\\') {
            characters.next();
            backslashes += 1;
        }

        match characters.peek().copied() {
            Some('"') => {
                characters.next();
                current.extend(std::iter::repeat_n('\\', backslashes / 2));
                if backslashes % 2 == 1 {
                    current.push('"');
                } else {
                    quoted = !quoted;
                }
                started = true;
            }
            Some(character) => {
                current.extend(std::iter::repeat_n('\\', backslashes));
                if character.is_control() {
                    return Err("Flowseal strategy arguments contain control characters".into());
                }
                current.push(character);
                characters.next();
                started = true;
            }
            None => {
                current.extend(std::iter::repeat_n('\\', backslashes));
            }
        }
    }

    if quoted {
        return Err("Flowseal strategy contains an unmatched quote".into());
    }
    if started {
        arguments.push(current);
    }
    if arguments.iter().any(|argument| argument.contains('\0')) {
        return Err("Flowseal strategy arguments contain NUL".into());
    }
    Ok(arguments)
}

fn validate_argument_paths(arguments: &[String], root: &Path) -> Result<(), String> {
    let mut index = 0usize;
    while index < arguments.len() {
        let argument = &arguments[index];
        if let Some((flag, value)) = argument.split_once('=') {
            if is_required_path_option(flag) {
                validate_path_value(value, root)?;
            } else if flag.starts_with("--dpi-desync-fake-") && is_path_value(value) {
                validate_path_value(value, root)?;
            } else if is_path_value(argument) {
                validate_path_value(argument, root)?;
            }
        } else if is_required_path_option(argument) {
            let value = arguments
                .get(index + 1)
                .ok_or_else(|| format!("Flowseal path option has no value: {argument}"))?;
            validate_path_value(value, root)?;
            index += 1;
        } else if is_path_value(argument) {
            validate_path_value(argument, root)?;
        }
        index += 1;
    }
    Ok(())
}

fn is_required_path_option(flag: &str) -> bool {
    matches!(
        flag,
        "--hostlist"
            | "--hostlist-exclude"
            | "--hostlist-auto"
            | "--hostlist-auto-fallback"
            | "--ipset"
            | "--ipset-exclude"
    )
}

fn is_path_value(value: &str) -> bool {
    let value = value.trim_matches('"');
    value.starts_with('@') || (!value.is_empty() && Path::new(value).is_absolute())
}

fn validate_path_value(value: &str, root: &Path) -> Result<(), String> {
    let value = value.trim_matches('"').trim_start_matches('@');
    if value.is_empty() {
        return Err("Flowseal strategy contains an empty file path".into());
    }
    let path = PathBuf::from(value);
    if !path.is_absolute() {
        return Err(format!(
            "Flowseal strategy contains a relative file path: {value}"
        ));
    }
    let resolved = canonicalize_with_missing_tail(&path)?;
    if !resolved.starts_with(root) {
        return Err(format!(
            "Flowseal strategy file path resolves outside the installation directory: {value}"
        ));
    }
    Ok(())
}

fn canonicalize_with_missing_tail(path: &Path) -> Result<PathBuf, String> {
    let mut cursor = path;
    let mut missing = Vec::new();
    loop {
        match fs::symlink_metadata(cursor) {
            Ok(_) => {
                let mut resolved = fs::canonicalize(cursor).map_err(|error| {
                    format!(
                        "Cannot resolve Flowseal strategy path {}: {error}",
                        cursor.display()
                    )
                })?;
                for component in missing.iter().rev() {
                    resolved.push(component);
                }
                return Ok(resolved);
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                let name = cursor.file_name().ok_or_else(|| {
                    format!("Cannot resolve Flowseal strategy path {}", path.display())
                })?;
                missing.push(name.to_os_string());
                cursor = cursor.parent().ok_or_else(|| {
                    format!("Cannot resolve Flowseal strategy path {}", path.display())
                })?;
            }
            Err(error) => {
                return Err(format!(
                    "Cannot inspect Flowseal strategy path {}: {error}",
                    cursor.display()
                ))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refuses_to_start_winws_without_an_elevated_token() {
        assert!(require_admin_token(false).is_err());
    }

    #[test]
    fn allows_winws_start_with_an_elevated_token() {
        assert!(require_admin_token(true).is_ok());
    }

    #[test]
    fn validates_only_the_game_filter_ranges_selected_by_mode() {
        let disabled = GameFilterSettings {
            mode: "none".into(),
            tcp_range: String::new(),
            udp_range: String::new(),
        };
        assert!(validate_game_filter_settings(&disabled).is_ok());

        let tcp_only = GameFilterSettings {
            mode: "tcp".into(),
            tcp_range: "80,443,1024-65535".into(),
            udp_range: "not-used".into(),
        };
        assert!(validate_game_filter_settings(&tcp_only).is_ok());

        let udp_only = GameFilterSettings {
            mode: "udp".into(),
            tcp_range: "not-used".into(),
            udp_range: "2000-3000".into(),
        };
        assert!(validate_game_filter_settings(&udp_only).is_ok());

        let all = GameFilterSettings {
            mode: "all".into(),
            tcp_range: "80,443".into(),
            udp_range: "2000-3000".into(),
        };
        assert!(validate_game_filter_settings(&all).is_ok());
    }

    #[test]
    fn rejects_injected_and_invalid_game_filter_ranges() {
        for value in [
            "",
            "0",
            "65536",
            "100-50",
            "1-",
            "-80",
            "80,",
            "80 --hostlist=C:\\outside.txt",
            "80\n--fake",
        ] {
            assert!(!is_valid_game_filter_range(value), "accepted {value:?}");
        }
        let injected = GameFilterSettings {
            mode: "tcp".into(),
            tcp_range: "80 --hostlist=C:\\outside.txt".into(),
            udp_range: "12".into(),
        };
        assert!(validate_game_filter_settings(&injected).is_err());
    }

    #[test]
    fn rejects_unknown_game_filter_modes() {
        let settings = GameFilterSettings {
            mode: "powershell".into(),
            tcp_range: "12".into(),
            udp_range: "12".into(),
        };
        assert!(validate_game_filter_settings(&settings).is_err());
    }

    #[test]
    fn splits_quoted_arguments_with_spaces_and_windows_escapes() {
        assert_eq!(
            split_windows_arguments(
                r#"--hostlist="C:\Program Files\Flowseal\lists\all.txt" --fake="a b" --literal=^!"#
            )
            .unwrap(),
            [
                r#"--hostlist=C:\Program Files\Flowseal\lists\all.txt"#,
                "--fake=a b",
                "--literal=^!",
            ]
        );
    }

    #[test]
    fn rejects_unmatched_quotes_and_control_characters() {
        assert!(split_windows_arguments(r#"--hostlist="unterminated"#).is_err());
        assert!(split_windows_arguments("--hostlist=one\ntwo").is_err());
    }

    #[test]
    fn accepts_hostlist_domains_as_domain_values_not_file_paths() {
        let root = std::env::temp_dir().join(format!(
            "flowseal-runtime-domains-{}-{}",
            std::process::id(),
            unix_timestamp()
        ));
        fs::create_dir_all(&root).unwrap();
        let args = vec![
            "--hostlist-domains=discord.media,discord.com".to_string(),
            "--hostlist-exclude-domains=example.com".to_string(),
        ];
        assert!(validate_argument_paths(&args, &root).is_ok());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn rejects_strategy_paths_outside_the_flowseal_root() {
        let root = std::env::temp_dir().join(format!(
            "flowseal-runtime-root-{}-{}",
            std::process::id(),
            unix_timestamp()
        ));
        let outside = root.with_file_name("flowseal-runtime-outside.txt");
        fs::create_dir_all(&root).unwrap();
        fs::write(&outside, "test").unwrap();
        let args = vec![format!("--hostlist={}", outside.display())];
        assert!(validate_argument_paths(&args, &root).is_err());
        let _ = fs::remove_dir_all(&root);
        let _ = fs::remove_file(outside);
    }
}
