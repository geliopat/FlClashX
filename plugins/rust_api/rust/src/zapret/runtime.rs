//! Direct, owned Flowseal process management for the interactive Windows user.
//!
//! This deliberately does not use the SYSTEM Helper service and never invokes
//! BAT/CMD, PowerShell, or a service manager. Only the verified winws.exe inside
//! the selected Flowseal installation is spawned, with parsed argv values.

use crate::zapret::core::{CoreProvider, GameFilterSettings};
use crate::zapret::providers::flowseal::FlowsealProvider;
use std::ffi::OsStr;
use std::os::windows::{
    ffi::OsStrExt,
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
        Threading::{
            GetCurrentProcess, GetProcessId, OpenProcessToken, TerminateProcess,
            WaitForSingleObject,
        },
    },
    UI::{
        Shell::{ShellExecuteExW, SEE_MASK_NOASYNC, SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW},
        WindowsAndMessaging::SW_HIDE,
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
    child: Option<Child>,
    elevated_process: Option<OwnedHandle>,
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
    if let Some(child) = running.child.as_mut() {
        return Ok(child.try_wait()?.is_none());
    }
    let process = running
        .elevated_process
        .as_ref()
        .ok_or_else(|| io::Error::other("Flowseal process handle is missing"))?;
    match unsafe { WaitForSingleObject(process.as_raw_handle() as HANDLE, 0) } {
        0 => Ok(false),
        258 => Ok(true),
        _ => Err(io::Error::last_os_error()),
    }
}

fn stop_elevated(process: &OwnedHandle) -> io::Result<()> {
    let handle = process.as_raw_handle() as HANDLE;
    match unsafe { WaitForSingleObject(handle, 0) } {
        0 => return Ok(()),
        258 => {}
        _ => return Err(io::Error::last_os_error()),
    }
    if unsafe { TerminateProcess(handle, 1) } == 0 {
        if unsafe { WaitForSingleObject(handle, 0) } == 0 {
            return Ok(());
        }
        return Err(io::Error::last_os_error());
    }
    match unsafe { WaitForSingleObject(handle, 5000) } {
        0 => Ok(()),
        258 => Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "Timed out waiting for elevated winws.exe to exit",
        )),
        _ => Err(io::Error::last_os_error()),
    }
}

fn launch_elevated(
    executable: &Path,
    arguments: &[String],
    working_directory: &Path,
) -> io::Result<(OwnedHandle, u32)> {
    let verb = wide(OsStr::new("runas"));
    let file = wide(executable.as_os_str());
    let directory = wide(working_directory.as_os_str());
    let parameter_text = build_windows_command_line(arguments);
    let parameters = wide(OsStr::new(&parameter_text));

    let mut info: SHELLEXECUTEINFOW = unsafe { std::mem::zeroed() };
    info.cbSize = std::mem::size_of::<SHELLEXECUTEINFOW>() as u32;
    info.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
    info.lpVerb = verb.as_ptr();
    info.lpFile = file.as_ptr();
    info.lpParameters = parameters.as_ptr();
    info.lpDirectory = directory.as_ptr();
    info.nShow = SW_HIDE;

    if unsafe { ShellExecuteExW(&mut info) } == 0 {
        let error = io::Error::last_os_error();
        return if error.raw_os_error() == Some(1223) {
            Err(io::Error::new(
                io::ErrorKind::Interrupted,
                "The administrator approval request was cancelled",
            ))
        } else {
            Err(error)
        };
    }
    if info.hProcess.is_null() {
        return Err(io::Error::other(
            "Windows started Flowseal without returning a process handle",
        ));
    }

    let process = unsafe { OwnedHandle::from_raw_handle(info.hProcess as RawHandle) };
    let pid = unsafe { GetProcessId(info.hProcess) };
    if pid == 0 {
        let error = io::Error::last_os_error();
        let _ = stop_elevated(&process);
        return Err(error);
    }
    Ok((process, pid))
}

fn wide(value: &OsStr) -> Vec<u16> {
    value.encode_wide().chain(std::iter::once(0)).collect()
}

fn build_windows_command_line(arguments: &[String]) -> String {
    arguments
        .iter()
        .map(|argument| quote_windows_argument(argument))
        .collect::<Vec<_>>()
        .join(" ")
}

fn quote_windows_argument(argument: &str) -> String {
    if !argument.is_empty()
        && !argument
            .chars()
            .any(|character| character.is_whitespace() || character == '"')
    {
        return argument.to_owned();
    }

    let mut quoted = String::from("\"");
    let mut backslashes = 0usize;
    for character in argument.chars() {
        match character {
            '\\' => backslashes += 1,
            '"' => {
                quoted.extend(std::iter::repeat_n('\\', backslashes * 2 + 1));
                quoted.push('"');
                backslashes = 0;
            }
            _ => {
                quoted.extend(std::iter::repeat_n('\\', backslashes));
                backslashes = 0;
                quoted.push(character);
            }
        }
    }
    quoted.extend(std::iter::repeat_n('\\', backslashes * 2));
    quoted.push('"');
    quoted
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

    let (mut child, elevated_process, pid) = if is_elevated() {
        let mut command = Command::new(&executable);
        command
            .args(&args)
            .current_dir(working_directory)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .creation_flags(CREATE_NO_WINDOW);
        let child = command
            .spawn()
            .map_err(|error| format!("Cannot start Flowseal winws.exe: {error}"))?;
        let pid = child.id();
        (Some(child), None, pid)
    } else {
        let (process, pid) = launch_elevated(&executable, &args, working_directory)
            .map_err(|error| format!("Cannot start elevated Flowseal winws.exe: {error}"))?;
        (None, Some(process), pid)
    };

    let process_handle = child
        .as_ref()
        .map(|process| process.as_raw_handle() as HANDLE)
        .or_else(|| {
            elevated_process
                .as_ref()
                .map(|process| process.as_raw_handle() as HANDLE)
        })
        .ok_or_else(|| "Flowseal process handle is missing".to_string())?;

    // The process is never considered managed unless it is inside the
    // kill-on-close job. If assignment fails, terminate this exact child.
    if unsafe { AssignProcessToJobObject(job.as_raw_handle() as HANDLE, process_handle) } == 0 {
        let error = io::Error::last_os_error();
        if let Some(process) = child.as_mut() {
            let _ = stop_child(process);
        }
        if let Some(process) = elevated_process.as_ref() {
            let _ = stop_elevated(process);
        }
        return Err(format!(
            "Cannot attach Flowseal process to its job: {error}"
        ));
    }

    let log = Arc::new(Mutex::new(log_file));
    if let Some(process) = child.as_mut() {
        let stdout = process
            .stdout
            .take()
            .ok_or_else(|| "Flowseal stdout pipe was not created".to_string())?;
        if let Err(error) = spawn_log_reader("stdout", stdout, Arc::clone(&log)) {
            let _ = stop_child(process);
            return Err(format!("Cannot start Flowseal stdout logger: {error}"));
        }
        let stderr = process
            .stderr
            .take()
            .ok_or_else(|| "Flowseal stderr pipe was not created".to_string())?;
        if let Err(error) = spawn_log_reader("stderr", stderr, Arc::clone(&log)) {
            let _ = stop_child(process);
            return Err(format!("Cannot start Flowseal stderr logger: {error}"));
        }
    }
    {
        let mut file = log.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let launch = if elevated_process.is_some() {
            "Started through UAC"
        } else {
            "Started in current elevated session"
        };
        let _ = writeln!(
            file,
            "[{}][flowseal] {launch}: winws.exe PID {pid}",
            unix_timestamp()
        );
        let _ = file.flush();
    }

    let running = RunningProcess {
        child,
        elevated_process,
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
        if let Some(process) = running.child.as_mut() {
            stop_child(process).map_err(|error| {
                format!("Cannot stop owned Flowseal winws.exe process: {error}")
            })?;
        } else if let Some(process) = running.elevated_process.as_ref() {
            stop_elevated(process).map_err(|error| {
                format!("Cannot stop elevated Flowseal winws.exe process: {error}")
            })?;
        }
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
        elevated: running.elevated_process.is_some() || is_elevated(),
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
            | "--hostlist-domains"
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
    fn elevated_command_line_round_trips_windows_quoting() {
        let arguments = vec![
            r#"--hostlist=C:\Program Files\Flowseal\lists\all.txt"#.to_owned(),
            "--fake=a b".to_owned(),
            String::new(),
            r#"--quoted=a\"b"#.to_owned(),
            r#"--trailing=C:\path with spaces\\"#.to_owned(),
        ];
        let command_line = build_windows_command_line(&arguments);
        assert_eq!(split_windows_arguments(&command_line).unwrap(), arguments);
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
