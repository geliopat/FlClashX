use crate::zapret::core::{CoreProvider, GameFilterSettings};
use crate::zapret::providers::flowseal::FlowsealProvider;
use flutter_rust_bridge::frb;
use std::path::PathBuf;

pub struct FlowsealStatus {
    pub installed: bool,
    pub version: String,
    pub executable: String,
}

fn provider(root: String) -> FlowsealProvider {
    FlowsealProvider::new(PathBuf::from(root))
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
