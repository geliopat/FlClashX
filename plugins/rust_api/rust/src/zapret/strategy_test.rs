//! Flowseal strategy auto-test, ported from geliopat/zapret-ui.
//! Each strategy is started as a short-lived winws.exe process. The app refuses
//! to test while its normal Flowseal process is running and always reaps the
//! temporary test process before moving to the next strategy.

use crate::{
    api::zapret::{FlowsealStrategyTestProgress, FlowsealStrategyTestResult},
    zapret::{
        core::{CoreProvider, GameFilterSettings},
        providers::flowseal::FlowsealProvider,
        runtime,
    },
};
use futures_util::{stream, StreamExt};
use reqwest::{header::RANGE, tls::Version, Client};
use serde::Deserialize;
use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        atomic::{AtomicBool, AtomicU32, Ordering},
        Mutex,
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use flutter_rust_bridge::for_generated::SseCodec;
use crate::frb_generated::StreamSink;
use std::os::windows::process::CommandExt;

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
static TEST_RUNNING: AtomicBool = AtomicBool::new(false);
static TEST_CANCELLED: AtomicBool = AtomicBool::new(false);
static TEST_PROCESS_PID: AtomicU32 = AtomicU32::new(0);
static TEST_EVENT_SINK: Mutex<Option<StreamSink<FlowsealStrategyTestProgress, SseCodec>>> =
    Mutex::new(None);

const DEFAULT_TARGETS: [(&str, &str); 17] = [
    ("Discord Main", "https://discord.com"),
    ("Discord Gateway", "https://gateway.discord.gg"),
    ("Discord CDN", "https://cdn.discordapp.com"),
    ("Discord Updates", "https://updates.discord.com"),
    ("YouTube Web", "https://www.youtube.com"),
    ("YouTube Short", "https://youtu.be"),
    ("YouTube Image", "https://i.ytimg.com"),
    ("YouTube Video", "https://redirector.googlevideo.com"),
    ("Google Main", "https://www.google.com"),
    ("Google Gstatic", "https://www.gstatic.com"),
    ("Cloudflare Web", "https://www.cloudflare.com"),
    ("Cloudflare CDN", "https://cdnjs.cloudflare.com"),
    ("Cloudflare DNS 1.1.1.1", "PING:1.1.1.1"),
    ("Cloudflare DNS 1.0.0.1", "PING:1.0.0.1"),
    ("Google DNS 8.8.8.8", "PING:8.8.8.8"),
    ("Google DNS 8.8.4.4", "PING:8.8.4.4"),
    ("Quad9 DNS 9.9.9.9", "PING:9.9.9.9"),
];

struct Target {
    name: String,
    url: Option<String>,
    host: String,
}

#[derive(Clone, Copy)]
enum ProbeKind {
    Http1,
    Tls12,
    Tls13,
}

#[derive(Clone, Copy, PartialEq)]
enum TestKind {
    Standard,
    Dpi,
    Combined,
}

struct TestGuard;

impl TestGuard {
    fn acquire() -> Result<Self, String> {
        TEST_RUNNING
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .map_err(|_| "Проверка стратегий уже выполняется.".to_string())?;
        TEST_CANCELLED.store(false, Ordering::Release);
        Ok(Self)
    }
}

impl Drop for TestGuard {
    fn drop(&mut self) {
        TEST_CANCELLED.store(false, Ordering::Release);
        TEST_PROCESS_PID.store(0, Ordering::Release);
        TEST_RUNNING.store(false, Ordering::Release);
    }
}

struct RunningStrategy {
    child: Child,
}

impl Drop for RunningStrategy {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        TEST_PROCESS_PID.store(0, Ordering::Release);
    }
}

struct TestIpsetOverride {
    path: PathBuf,
    original: PathBuf,
    temporary: PathBuf,
}

impl Drop for TestIpsetOverride {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

#[derive(Deserialize)]
struct DpiSuiteEntry {
    #[serde(default)]
    id: String,
    host: String,
}

pub fn listen(sink: StreamSink<FlowsealStrategyTestProgress, SseCodec>) -> Result<(), String> {
    *TEST_EVENT_SINK
        .lock()
        .map_err(|error| format!("Не удалось подключить события тестирования: {error}"))? =
        Some(sink);
    Ok(())
}

fn emit_progress(
    message: impl Into<String>,
    kind: &str,
    current: usize,
    total: usize,
    strategy: Option<&str>,
) {
    let event = FlowsealStrategyTestProgress {
        message: message.into(),
        kind: kind.to_string(),
        current: current as u64,
        total: total as u64,
        strategy: strategy.unwrap_or_default().to_string(),
    };
    if let Ok(sink) = TEST_EVENT_SINK.lock() {
        if let Some(sink) = sink.as_ref() {
            let _ = sink.add(event);
        }
    }
}

fn system_tool(name: &str) -> PathBuf {
    std::env::var_os("SystemRoot")
        .or_else(|| std::env::var_os("WINDIR"))
        .map(PathBuf::from)
        .map(|root| root.join("System32").join(name))
        .unwrap_or_else(|| PathBuf::from(name))
}

pub fn cancel() {
    TEST_CANCELLED.store(true, Ordering::Release);
    let pid = TEST_PROCESS_PID.load(Ordering::Acquire);
    if pid != 0 {
        let _ = Command::new(system_tool("taskkill.exe"))
            .args(["/F", "/T", "/PID", &pid.to_string()])
            .creation_flags(CREATE_NO_WINDOW)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
}

fn target_from_value(name: impl Into<String>, value: &str) -> Option<Target> {
    let name = name.into();
    if let Some(host) = value.strip_prefix("PING:") {
        let host = host.trim();
        if host.is_empty() {
            return None;
        }
        return Some(Target {
            name,
            url: None,
            host: host.to_string(),
        });
    }
    let url = reqwest::Url::parse(value).ok()?;
    if url.scheme() != "https" {
        return None;
    }
    let host = url.host_str()?.to_string();
    Some(Target {
        name,
        url: Some(url.to_string()),
        host,
    })
}

fn parse_target_line(line: &str) -> Option<Target> {
    let line = line.trim().trim_start_matches('\u{feff}');
    if line.is_empty() || line.starts_with('#') {
        return None;
    }
    let (name, value) = line.split_once('=')?;
    let name = name.trim();
    let value = value.trim().trim_matches('"');
    if name.is_empty() || value.is_empty() {
        return None;
    }
    target_from_value(name, value)
}

fn load_standard_targets(root: &Path) -> Vec<Target> {
    let path = root.join("utils").join("targets.txt");
    let configured = fs::read_to_string(path)
        .ok()
        .map(|content| {
            content
                .lines()
                .filter_map(parse_target_line)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    if !configured.is_empty() {
        return configured;
    }
    DEFAULT_TARGETS
        .iter()
        .filter_map(|(name, value)| target_from_value(*name, value))
        .collect()
}

fn build_client(kind: ProbeKind, timeout: Duration) -> Result<Client, String> {
    let mut builder = Client::builder()
        .timeout(timeout)
        .connect_timeout(Duration::from_secs(3))
        .redirect(reqwest::redirect::Policy::limited(5))
        .http1_only();
    builder = match kind {
        ProbeKind::Http1 => builder,
        ProbeKind::Tls12 => builder
            .min_tls_version(Version::TLS_1_2)
            .max_tls_version(Version::TLS_1_2),
        ProbeKind::Tls13 => builder
            .min_tls_version(Version::TLS_1_3)
            .max_tls_version(Version::TLS_1_3),
    };
    builder
        .build()
        .map_err(|error| format!("Не удалось создать HTTP-клиент проверки: {error}"))
}

async fn tcp_latency(host: &str) -> Option<i32> {
    let started = Instant::now();
    let connected = tokio::time::timeout(
        Duration::from_secs(2),
        tokio::net::TcpStream::connect((host, 443)),
    )
    .await
    .ok()?
    .ok()?;
    drop(connected);
    Some(started.elapsed().as_millis().min(i32::MAX as u128) as i32)
}

async fn standard_target(
    target: Target,
    clients: [(ProbeKind, Option<Client>); 3],
) -> (String, i32, i32, Option<i32>) {
    let latency = tcp_latency(&target.host).await;
    let mut ok = 0;
    let mut error = 0;
    if let Some(url) = target.url.as_deref() {
        for (_, client) in clients {
            let Some(client) = client else { continue };
            match client.get(url).header(RANGE, "bytes=0-0").send().await {
                Ok(_) => ok += 1,
                Err(_) => error += 1,
            }
        }
    }
    (target.name, ok, error, latency)
}

async fn load_dpi_targets() -> Vec<Target> {
    if let Ok(host) = std::env::var("MONITOR_HOST") {
        let host = host
            .trim()
            .trim_start_matches("https://")
            .trim_end_matches('/');
        if let Some(target) = target_from_value("Custom", &format!("https://{host}")) {
            return vec![target];
        }
    }

    if let Ok(client) = Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
    {
        if let Ok(response) = client
            .get("https://hyperion-cs.github.io/dpi-checkers/ru/tcp-16-20/suite.v2.json")
            .send()
            .await
        {
            if let Ok(entries) = response.json::<Vec<DpiSuiteEntry>>().await {
                let targets = entries
                    .into_iter()
                    .filter_map(|entry| {
                        target_from_value(
                            if entry.id.is_empty() { &entry.host } else { &entry.id },
                            &format!("https://{}", entry.host),
                        )
                    })
                    .collect::<Vec<_>>();
                if !targets.is_empty() {
                    return targets;
                }
            }
        }
    }

    [
        ("Discord", "https://discord.com"),
        ("YouTube", "https://www.youtube.com"),
        ("Google Video", "https://redirector.googlevideo.com"),
        ("Cloudflare", "https://www.cloudflare.com"),
    ]
    .into_iter()
    .filter_map(|(name, value)| target_from_value(name, value))
    .collect()
}

fn dpi_payload() -> Vec<u8> {
    let mut value = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or(0x9e3779b97f4a7c15);
    let mut payload = vec![0u8; 64 * 1024];
    for byte in &mut payload {
        value ^= value << 13;
        value ^= value >> 7;
        value ^= value << 17;
        *byte = value as u8;
    }
    payload
}

async fn dpi_target(
    target: Target,
    clients: [(ProbeKind, Option<Client>); 3],
    payload: Vec<u8>,
) -> (String, i32, i32) {
    let mut ok = 0;
    let mut error = 0;
    let Some(url) = target.url.as_deref() else {
        return (target.name, ok, error);
    };
    for (_, client) in clients {
        let Some(client) = client else { continue };
        match client
            .post(url)
            .header(RANGE, "bytes=0-65535")
            .body(payload.clone())
            .send()
            .await
        {
            Ok(_) => ok += 1,
            Err(_) => error += 1,
        }
    }
    (target.name, ok, error)
}

fn test_ipset_override(root: &Path) -> Result<TestIpsetOverride, String> {
    let canonical_root = fs::canonicalize(root)
        .map_err(|error| format!("Не удалось разрешить каталог Flowseal: {error}"))?;
    let lists = fs::canonicalize(canonical_root.join("lists"))
        .map_err(|error| format!("Не удалось разрешить каталог списков Flowseal: {error}"))?;
    if !lists.starts_with(&canonical_root) {
        return Err("Каталог списков Flowseal выходит за пределы установки.".into());
    }
    let original = lists.join("ipset-all.txt");
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    let temporary = lists.join(format!(
        "ipset-test-{}-{nonce}.txt",
        std::process::id()
    ));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)
        .map_err(|error| format!("Не удалось подготовить временный IPSet: {error}"))?;
    file.write_all(b"")
        .map_err(|error| format!("Не удалось записать временный IPSet: {error}"))?;
    file.flush()
        .map_err(|error| format!("Не удалось сохранить временный IPSet: {error}"))?;
    Ok(TestIpsetOverride {
        path: temporary.clone(),
        original,
        temporary,
    })
}

fn prepare_test_arguments(
    provider: &FlowsealProvider,
    root: &Path,
    strategy: &str,
    filter: &GameFilterSettings,
    ipset: Option<&TestIpsetOverride>,
) -> Result<String, String> {
    let mut arguments = provider.parse_strategy(strategy, filter)?;
    if let Some(ipset) = ipset {
        let original = ipset.original.to_string_lossy();
        let temporary = ipset.temporary.to_string_lossy();
        arguments = arguments.replace(original.as_ref(), temporary.as_ref());

        // Do not let the personal IP list affect the common strategy comparison.
        let user_ipset = root.join("lists").join(crate::zapret::ipset::USER_INCLUDE_FILE);
        for form in [
            format!("--ipset=\"{}\"", user_ipset.display()),
            format!("--ipset={}", user_ipset.display()),
        ] {
            arguments = arguments.replace(&form, "");
        }
    }
    Ok(arguments)
}

fn start_strategy(
    executable: &Path,
    arguments: &str,
    requested_root: &Path,
) -> Result<RunningStrategy, String> {
    let root = fs::canonicalize(requested_root).map_err(|error| {
        format!("Не удалось разрешить каталог Flowseal для теста: {error}")
    })?;
    let executable = fs::canonicalize(executable)
        .map_err(|error| format!("Не удалось разрешить winws.exe для теста: {error}"))?;
    if !executable.starts_with(&root)
        || !executable
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.eq_ignore_ascii_case("winws.exe"))
    {
        return Err("Путь к winws.exe выходит за пределы каталога Flowseal.".into());
    }

    let bin_dir = fs::canonicalize(root.join("bin"))
        .map_err(|error| format!("Не удалось разрешить каталог bin Flowseal: {error}"))?;
    if !bin_dir.starts_with(&root) || !executable.starts_with(&bin_dir) {
        return Err("Каталог bin Flowseal ссылается за пределы установки.".into());
    }
    for required in [
        root.join("bin").join("WinDivert.dll"),
        root.join("bin").join("WinDivert64.sys"),
    ] {
        let resolved = fs::canonicalize(&required).map_err(|error| {
            format!("Не удалось разрешить файл Flowseal {}: {error}", required.display())
        })?;
        if !resolved.starts_with(&root) {
            return Err(format!(
                "Файл Flowseal выходит за пределы установки: {}",
                required.display()
            ));
        }
    }

    let args = runtime::split_windows_arguments(arguments)?;
    if args.is_empty() {
        return Err("В стратегии нет аргументов winws.exe.".into());
    }
    runtime::validate_argument_paths(&args, &root)?;
    let working_directory = executable
        .parent()
        .ok_or_else(|| "Не удалось определить рабочий каталог winws.exe.".to_string())?;
    let child = Command::new(&executable)
        .args(args)
        .current_dir(working_directory)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
        .map_err(|error| format!("Не удалось запустить winws.exe: {error}"))?;
    TEST_PROCESS_PID.store(child.id(), Ordering::Release);
    Ok(RunningStrategy { child })
}

fn ensure_no_external_winws() -> Result<(), String> {
    let output = Command::new(system_tool("tasklist.exe"))
        .args(["/FI", "IMAGENAME eq winws.exe", "/FO", "CSV", "/NH"])
        .creation_flags(CREATE_NO_WINDOW)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .map_err(|error| format!("Не удалось проверить сторонние процессы winws.exe: {error}"))?;
    if !output.status.success() {
        return Err("Не удалось проверить, запущен ли другой winws.exe.".into());
    }
    let listing = String::from_utf8_lossy(&output.stdout).to_ascii_lowercase();
    if listing.contains("winws.exe") {
        return Err(
            "Обнаружен уже запущенный winws.exe. Остановите его вручную перед автотестом."
                .into(),
        );
    }
    Ok(())
}

#[derive(Clone)]
struct TestResult {
    config: String,
    status: String,
    http_ok: i32,
    http_error: i32,
    ping_ok: i32,
    ping_fail: i32,
    avg_ping_ms: i32,
    score: i32,
}

impl TestResult {
    fn failed(config: String) -> Self {
        Self::from_counts(config, 0, 1, 0, 1, 0)
    }

    fn from_counts(
        config: String,
        http_ok: i32,
        http_error: i32,
        ping_ok: i32,
        ping_fail: i32,
        avg_ping_ms: i32,
    ) -> Self {
        let status = if http_error == 0 && ping_fail == 0 {
            "success"
        } else if http_ok > http_error {
            "partial"
        } else {
            "failed"
        };
        let score = http_ok * 10 + ping_ok - http_error * 20 - ping_fail * 2;
        Self {
            config,
            status: status.to_string(),
            http_ok,
            http_error,
            ping_ok,
            ping_fail,
            avg_ping_ms,
            score,
        }
    }

    fn from_combined(standard: Self, dpi: Self) -> Self {
        let config = standard.config.clone();
        let mut result = Self::from_counts(
            config,
            standard.http_ok + dpi.http_ok,
            standard.http_error + dpi.http_error,
            standard.ping_ok,
            standard.ping_fail,
            standard.avg_ping_ms,
        );
        let rate = |ok: i32, error: i32| {
            let total = ok + error;
            if total > 0 { ok * 100 / total } else { 0 }
        };
        let standard_http = rate(standard.http_ok, standard.http_error);
        let dpi_http = rate(dpi.http_ok, dpi.http_error);
        let ping = rate(standard.ping_ok, standard.ping_fail);
        result.score = standard_http * 6 + dpi_http * 3 + ping;
        result
    }

    fn to_api(&self) -> FlowsealStrategyTestResult {
        FlowsealStrategyTestResult {
            strategy: self.config.clone(),
            status: self.status.clone(),
            http_ok: self.http_ok,
            http_error: self.http_error,
            ping_ok: self.ping_ok,
            ping_fail: self.ping_fail,
            avg_ping_ms: self.avg_ping_ms,
            score: self.score,
        }
    }
}

fn emit_target_result(
    current: usize,
    total: usize,
    strategy: &str,
    target: &str,
    ok: i32,
    error: i32,
    latency: Option<i32>,
) {
    let message = if ok + error == 0 {
        match latency {
            Some(ms) => format!("{target}: TCP {ms} мс"),
            None => format!("{target}: недоступен"),
        }
    } else {
        format!("{target}: HTTP {ok}/{}", ok + error)
    };
    let kind = if error == 0 && latency.is_some() {
        "success"
    } else if error == 0 && ok > 0 {
        "success"
    } else {
        "warning"
    };
    emit_progress(message, kind, current, total, Some(strategy));
}

pub async fn run(
    root: PathBuf,
    test_type: &str,
    game_filter: &GameFilterSettings,
) -> Result<Vec<FlowsealStrategyTestResult>, String> {
    let _guard = TestGuard::acquire()?;
    if !runtime::is_elevated() {
        return Err("Для автоматического тестирования стратегий нужны права администратора. Перезапустите FlClashX от имени администратора.".into());
    }
    runtime::validate_game_filter_settings(game_filter)?;
    let root = fs::canonicalize(&root)
        .map_err(|error| format!("Не удалось разрешить каталог Flowseal: {error}"))?;
    if runtime::status(&root)?.running {
        return Err("Сначала остановите запущенный winws.exe. Во время проверки стратегии запускаются по очереди.".into());
    }
    ensure_no_external_winws()?;

    let kind = match test_type {
        "standard" => TestKind::Standard,
        "dpi" => TestKind::Dpi,
        "combined" => TestKind::Combined,
        _ => return Err("Неизвестный тип проверки стратегий.".into()),
    };
    let provider = FlowsealProvider::new(root.clone());
    if !provider.is_installed() {
        return Err("Установка Flowseal не обнаружена или не завершена.".into());
    }
    let strategies = provider.strategies_readonly()?;
    if strategies.is_empty() {
        return Err("В каталоге Flowseal нет готовых стратегий для проверки.".into());
    }

    let runs_dpi = kind != TestKind::Standard;
    let runs_standard = kind != TestKind::Dpi;
    let timeout = if runs_dpi {
        Duration::from_secs(5)
    } else {
        Duration::from_secs(4)
    };
    let clients = [
        ProbeKind::Http1,
        ProbeKind::Tls12,
        ProbeKind::Tls13,
    ]
    .map(|probe| (probe, build_client(probe, timeout).ok()));
    if clients.iter().all(|(_, client)| client.is_none()) {
        return Err("Не удалось создать HTTP-клиенты для тестирования.".into());
    }

    let standard_targets = runs_standard.then(|| load_standard_targets(&root));
    let dpi_targets = if runs_dpi {
        Some(load_dpi_targets().await)
    } else {
        None
    };
    let ipset_override = runs_dpi.then(|| test_ipset_override(&root)).transpose()?;
    let mut results = Vec::with_capacity(strategies.len());

    emit_progress(
        format!("Начата проверка стратегий: {}", strategies.len()),
        "info",
        0,
        strategies.len(),
        None,
    );

    for (index, name) in strategies.iter().enumerate() {
        if TEST_CANCELLED.load(Ordering::Acquire) {
            break;
        }
        let current = index + 1;
        emit_progress(
            format!("Проверка стратегии {current}/{}: {name}", strategies.len()),
            "config",
            current,
            strategies.len(),
            Some(name),
        );

        let arguments = prepare_test_arguments(
            &provider,
            &root,
            name,
            game_filter,
            ipset_override.as_ref(),
        )?;
        let executable = provider.winws_executable();
        let mut process = match start_strategy(&executable, &arguments, &root) {
            Ok(process) => process,
            Err(error) => {
                emit_progress(
                    format!("{name}: не удалось запустить ({error})"),
                    "error",
                    current,
                    strategies.len(),
                    Some(name),
                );
                results.push(TestResult::failed(name.clone()));
                continue;
            }
        };

        tokio::time::sleep(Duration::from_millis(700)).await;
        if process.child.try_wait().map_err(|error| error.to_string())?.is_some() {
            emit_progress(
                format!("{name}: winws.exe завершился сразу после запуска"),
                "error",
                current,
                strategies.len(),
                Some(name),
            );
            results.push(TestResult::failed(name.clone()));
            continue;
        }

        let result = match kind {
            TestKind::Standard => {
                run_standard(
                    name,
                    current,
                    strategies.len(),
                    standard_targets.clone().unwrap_or_default(),
                    clients.clone(),
                )
                .await
            }
            TestKind::Dpi => {
                run_dpi(
                    name,
                    current,
                    strategies.len(),
                    dpi_targets.clone().unwrap_or_default(),
                    clients.clone(),
                )
                .await
            }
            TestKind::Combined => {
                let standard = run_standard(
                    name,
                    current,
                    strategies.len(),
                    standard_targets.clone().unwrap_or_default(),
                    clients.clone(),
                )
                .await;
                if TEST_CANCELLED.load(Ordering::Acquire) {
                    standard
                } else {
                    let dpi = run_dpi(
                        name,
                        current,
                        strategies.len(),
                        dpi_targets.clone().unwrap_or_default(),
                        clients.clone(),
                    )
                    .await;
                    TestResult::from_combined(standard, dpi)
                }
            }
        };
        drop(process);
        emit_progress(
            format!(
                "{name}: проверка завершена, результат {}",
                result.score
            ),
            match result.status.as_str() {
                "success" => "success",
                "partial" => "warning",
                _ => "error",
            },
            current,
            strategies.len(),
            Some(name),
        );
        results.push(result);

        if TEST_CANCELLED.load(Ordering::Acquire) {
            break;
        }
    }

    if TEST_CANCELLED.load(Ordering::Acquire) {
        emit_progress(
            "Проверка остановлена пользователем.",
            "warning",
            results.len(),
            strategies.len(),
            None,
        );
    } else {
        emit_progress(
            format!("Проверка завершена. Обработано стратегий: {}", results.len()),
            "success",
            strategies.len(),
            strategies.len(),
            None,
        );
    }

    let mut results = results;
    results.sort_by(|a, b| b.score.cmp(&a.score));
    Ok(results.iter().map(TestResult::to_api).collect())
}

async fn run_standard(
    strategy: &str,
    current: usize,
    total: usize,
    targets: Vec<Target>,
    clients: [(ProbeKind, Option<Client>); 3],
) -> TestResult {
    let probes = stream::iter(targets.into_iter().map(|target| {
        let clients = clients.clone();
        async move { standard_target(target, clients).await }
    }))
    .buffer_unordered(8);
    tokio::pin!(probes);
    let (mut http_ok, mut http_error, mut ping_ok, mut ping_fail) = (0, 0, 0, 0);
    let (mut ping_sum, mut ping_count) = (0i64, 0i64);
    while let Some((target, ok, error, latency)) = probes.next().await {
        http_ok += ok;
        http_error += error;
        if let Some(ms) = latency {
            ping_ok += 1;
            ping_sum += i64::from(ms);
            ping_count += 1;
        } else {
            ping_fail += 1;
        }
        emit_target_result(current, total, strategy, &target, ok, error, latency);
        if TEST_CANCELLED.load(Ordering::Acquire) {
            break;
        }
    }
    let average = if ping_count > 0 {
        ((ping_sum + ping_count / 2) / ping_count) as i32
    } else {
        0
    };
    TestResult::from_counts(
        strategy.to_string(),
        http_ok,
        http_error,
        ping_ok,
        ping_fail,
        average,
    )
}

async fn run_dpi(
    strategy: &str,
    current: usize,
    total: usize,
    targets: Vec<Target>,
    clients: [(ProbeKind, Option<Client>); 3],
) -> TestResult {
    let payload = dpi_payload();
    let probes = stream::iter(targets.into_iter().map(|target| {
        let clients = clients.clone();
        let payload = payload.clone();
        async move { dpi_target(target, clients, payload).await }
    }))
    .buffer_unordered(8);
    tokio::pin!(probes);
    let (mut http_ok, mut http_error) = (0, 0);
    while let Some((target, ok, error)) = probes.next().await {
        http_ok += ok;
        http_error += error;
        emit_progress(
            format!("{target}: DPI HTTP {ok}/{}", ok + error),
            if error == 0 { "success" } else { "warning" },
            current,
            total,
            Some(strategy),
        );
        if TEST_CANCELLED.load(Ordering::Acquire) {
            break;
        }
    }
    TestResult::from_counts(strategy.to_string(), http_ok, http_error, 0, 0, 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_configured_targets_and_rejects_unsafe_schemes() {
        let target = parse_target_line("YouTube = \"https://youtube.com/path\"").unwrap();
        assert_eq!(target.name, "YouTube");
        assert_eq!(target.host, "youtube.com");
        assert!(parse_target_line("Bad = \"http://example.com\"").is_none());
        assert!(parse_target_line("# comment").is_none());
    }

    #[test]
    fn creates_64_kib_dpi_payload() {
        let payload = dpi_payload();
        assert_eq!(payload.len(), 65_536);
        assert!(payload.windows(2).any(|pair| pair[0] != pair[1]));
    }

    #[test]
    fn combined_score_weights_each_suite_independently() {
        let standard = TestResult::from_counts("test".into(), 3, 0, 2, 0, 15);
        let dpi = TestResult::from_counts("test".into(), 12, 0, 0, 0, 0);
        let result = TestResult::from_combined(standard, dpi);
        assert_eq!(result.score, 1_000);
        assert_eq!(result.avg_ping_ms, 15);
    }
}
