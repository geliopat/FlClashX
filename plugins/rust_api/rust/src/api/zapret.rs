use crate::zapret::core::{CoreProvider, GameFilterSettings};
use crate::zapret::providers::flowseal::FlowsealProvider;
use crate::zapret::runtime;
use flutter_rust_bridge::frb;
use std::path::PathBuf;

pub struct FlowsealStatus {
    pub installed: bool,
    pub version: String,
    pub executable: String,
}

pub struct FlowsealRuntimeStatus {
    pub running: bool,
    pub pid: Option<u32>,
    pub strategy: Option<String>,
    pub log_path: String,
    pub elevated: bool,
}

pub struct FlowsealGameFilterSettings {
    pub mode: String,
    pub tcp_range: String,
    pub udp_range: String,
}

fn provider(root: String) -> FlowsealProvider {
    FlowsealProvider::new(PathBuf::from(root))
}

fn runtime_status(status: runtime::ProcessStatus) -> FlowsealRuntimeStatus {
    FlowsealRuntimeStatus {
        running: status.running,
        pid: status.pid,
        strategy: status.strategy,
        log_path: status.log_path,
        elevated: status.elevated,
    }
}

#[frb]
pub async fn flowseal_install_or_update(root: String) -> Result<String, String> {
    crate::zapret::installer::install_or_update(PathBuf::from(root)).await
}

#[frb]
pub fn flowseal_status(root: String) -> FlowsealStatus {
    let provider = provider(root);
    FlowsealStatus {
        installed: provider.is_installed(),
        version: provider.local_version(),
        executable: provider.winws_executable().to_string_lossy().into_owned(),
    }
}

#[frb]
pub fn flowseal_list_strategies(root: String) -> Result<Vec<String>, String> {
    provider(root).strategies_readonly()
}

#[frb]
pub fn flowseal_parse_strategy(
    root: String,
    strategy: String,
    game_filter_mode: String,
    game_filter_tcp: String,
    game_filter_udp: String,
) -> Result<String, String> {
    let provider = provider(root);
    let filter = GameFilterSettings {
        mode: game_filter_mode,
        tcp_range: game_filter_tcp,
        udp_range: game_filter_udp,
    };
    provider.parse_strategy(&strategy, &filter)
}

#[frb]
pub fn flowseal_import_strategy(root: String, name: String, content: String) -> Result<(), String> {
    provider(root).import_custom_strategy(&name, &content)
}

#[frb]
pub fn flowseal_validate_installation(root: String) -> Result<String, String> {
    let provider = provider(root);
    let (version, count) = provider.validate_installation()?;
    Ok(format!("{version} ({count} Flowseal strategies)"))
}

#[frb]
pub fn flowseal_is_elevated() -> bool {
    runtime::is_elevated()
}

#[frb]
pub fn flowseal_process_status(root: String) -> Result<FlowsealRuntimeStatus, String> {
    runtime::status(&PathBuf::from(root)).map(runtime_status)
}

#[frb]
pub fn flowseal_start(
    root: String,
    strategy: String,
    game_filter_mode: String,
    game_filter_tcp: String,
    game_filter_udp: String,
) -> Result<FlowsealRuntimeStatus, String> {
    let filter = GameFilterSettings {
        mode: game_filter_mode,
        tcp_range: game_filter_tcp,
        udp_range: game_filter_udp,
    };
    let root = PathBuf::from(root);
    crate::zapret::game_filter::save(&root, &filter)?;
    runtime::start(root, &strategy, &filter).map(runtime_status)
}

#[frb]
pub fn flowseal_stop(root: String) -> Result<FlowsealRuntimeStatus, String> {
    runtime::stop(&PathBuf::from(root)).map(runtime_status)
}

#[frb]
pub fn flowseal_read_user_list(root: String, filename: String) -> Result<Vec<String>, String> {
    crate::zapret::user_lists::read(&PathBuf::from(root), &filename)
}

#[frb]
pub fn flowseal_add_user_list_entry(
    root: String,
    filename: String,
    entry: String,
) -> Result<Vec<String>, String> {
    crate::zapret::user_lists::add(&PathBuf::from(root), &filename, &entry)
}

#[frb]
pub fn flowseal_remove_user_list_entry(
    root: String,
    filename: String,
    entry: String,
) -> Result<Vec<String>, String> {
    crate::zapret::user_lists::remove(&PathBuf::from(root), &filename, &entry)
}

#[frb]
pub fn flowseal_replace_user_list(
    root: String,
    filename: String,
    entries: Vec<String>,
) -> Result<Vec<String>, String> {
    crate::zapret::user_lists::replace(&PathBuf::from(root), &filename, &entries)
}

#[frb]
pub fn flowseal_get_game_filter(root: String) -> Result<FlowsealGameFilterSettings, String> {
    let settings = crate::zapret::game_filter::read(&PathBuf::from(root))?;
    Ok(FlowsealGameFilterSettings {
        mode: settings.mode,
        tcp_range: settings.tcp_range,
        udp_range: settings.udp_range,
    })
}

#[frb]
pub fn flowseal_save_game_filter(
    root: String,
    mode: String,
    tcp_range: String,
    udp_range: String,
) -> Result<(), String> {
    let settings = GameFilterSettings {
        mode,
        tcp_range,
        udp_range,
    };
    crate::zapret::game_filter::save(&PathBuf::from(root), &settings)
}

pub struct FlowsealIpSetUpdateResult {
    pub changed: bool,
    pub count: u64,
}

#[frb]
pub fn flowseal_ipset_status(root: String) -> Result<String, String> {
    crate::zapret::ipset_control::status(&PathBuf::from(root))
}

#[frb]
pub fn flowseal_set_ipset_filter(root: String, mode: String) -> Result<String, String> {
    crate::zapret::ipset_control::set_mode(&PathBuf::from(root), &mode)
}

#[frb]
pub async fn flowseal_update_ipset(root: String) -> Result<FlowsealIpSetUpdateResult, String> {
    let result = crate::zapret::ipset_control::update(&PathBuf::from(root)).await?;
    Ok(FlowsealIpSetUpdateResult {
        changed: result.changed,
        count: result.count as u64,
    })
}

pub struct FlowsealUserListsSnapshot {
    pub include: Vec<String>,
    pub exclude: Vec<String>,
    pub ips: Vec<String>,
}

#[frb]
pub fn flowseal_export_user_list(root: String, filename: String) -> Result<String, String> {
    let entries = crate::zapret::user_lists::read(&PathBuf::from(root), &filename)?;
    Ok(entries.join("\r\n"))
}

#[frb]
pub fn flowseal_export_user_lists_backup(root: String) -> Result<String, String> {
    crate::zapret::user_lists::export_backup(&PathBuf::from(root))
}

#[frb]
pub fn flowseal_import_user_lists_backup(
    root: String,
    content: String,
) -> Result<FlowsealUserListsSnapshot, String> {
    let backup = crate::zapret::user_lists::import_backup(&PathBuf::from(root), &content)?;
    Ok(FlowsealUserListsSnapshot {
        include: backup.include,
        exclude: backup.exclude,
        ips: backup.ips,
    })
}
