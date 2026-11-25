//! Built-in Windows Zapret strategy catalog and launch argument builders.
//!
//! Strategy definitions and argument assembly are ported from
//! geliopat/zapret2-gui at 8dd17fcbcca405a50f497a6e2346ca263901d775. Keep Flowseal/winws profiles
//! separate from Lua/winws2 profiles: these engines do not share a CLI.

use serde::{Deserialize, Serialize};
use std::io::{Error, ErrorKind};
use std::path::Path;

mod imported_strategies;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TunnelMode {
    Full,
    Strict,
    GameMode,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ZapretLaunchMode {
    StrictSplit,
    FullBypass,
}

impl Default for ZapretLaunchMode {
    fn default() -> Self { Self::FullBypass }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct AutoLists {
    general: String,
    general_user: String,
    exclude: String,
    exclude_user: String,
    auto_path: String,
}

const FLOWSEAL: &[ZapretStrategy] = &[
    ZapretStrategy { id: "flowseal-alt", name: "Flowseal ALT (Fakedsplit) — Рекомендован для РФ", filename: "general (ALT).bat", description: "Основной рабочий режим для всех провайдеров РФ (Ростелеком, МТС, Дом.ру, Билайн, ТСПУ)", engine: "winws", category: "flowseal" },
    ZapretStrategy { id: "flowseal-alt11", name: "Flowseal ALT11 (Усиленный 4K)", filename: "general (ALT11).bat", description: "YouTube 4K 60FPS (seqovl=681, repeats=11) + Discord Голос", engine: "winws", category: "flowseal" },
    ZapretStrategy { id: "flowseal-general", name: "Flowseal General (Multisplit)", filename: "general.bat", description: "YouTube + Discord + Сайты (мягкий режим без поддельных пакетов)", engine: "winws", category: "flowseal" },
    ZapretStrategy { id: "flowseal-fake-tls-auto", name: "Flowseal FAKE TLS AUTO (Игровой)", filename: "general (FAKE TLS AUTO).bat", description: "Discord Голос + Минимальный пинг в онлайн-играх", engine: "winws", category: "flowseal" },
    ZapretStrategy { id: "flowseal-simple-fake", name: "Flowseal Simple Fake", filename: "general (SIMPLE FAKE).bat", description: "Простой режим для мобильных раздач и Wi-Fi роутеров", engine: "winws", category: "flowseal" },
];

const LUA_STRATEGIES: &[ZapretStrategy] = &[
    ZapretStrategy { id: "antidpi", name: "zapret2 Универсальный Lua", filename: "zapret-antidpi.lua", description: "Официальная базовая библиотека Lua-стратегий zapret2", engine: "winws2", category: "zapret2" },
    ZapretStrategy { id: "discord-light", name: "zapret2 Discord Лёгкий", filename: "zapret-discord-light.lua", description: "Лёгкий desync для Discord с минимальными задержками: TCP плюс голос по UDP.", engine: "winws2", category: "zapret2" },
    ZapretStrategy { id: "extsplit", name: "zapret2 SNI-граница", filename: "zapret-extsplit.lua", description: "Резка TLS по границе SNI-расширения: расширение с именем сайта уходит отдельным сегментом, плюс стандартный фейк.", engine: "winws2", category: "zapret2" },
    ZapretStrategy { id: "firstbyte", name: "zapret2 Первый байт", filename: "zapret-firstbyte.lua", description: "Первый байт ClientHello уходит отдельным сегментом, остальное целиком: минимальная резка при полном фейке.", engine: "winws2", category: "zapret2" },
    ZapretStrategy { id: "ipfrag", name: "zapret2 IP-фрагменты", filename: "zapret-ipfrag.lua", description: "Все пакеты обхода режутся на IP-фрагменты: fallback против жёсткого DPI, но часть сетей фрагменты не пропускает.", engine: "winws2", category: "zapret2" },
    ZapretStrategy { id: "sites-light", name: "zapret2 Только сайты", filename: "zapret-sites-light.lua", description: "Минимальное вмешательство для слабых машин и мобильных раздач: одна резка без фейков.", engine: "winws2", category: "zapret2" },
    ZapretStrategy { id: "syndata", name: "zapret2 SYN-данные", filename: "zapret-syndata.lua", description: "Фейковый ClientHello уезжает прямо в SYN-пакете, до основного трафика: DPI теряет начало потока.", engine: "winws2", category: "zapret2" },
    ZapretStrategy { id: "tspu-max", name: "zapret2 ТСПУ Макс", filename: "zapret-tspu-max.lua", description: "Жёсткий desync для сурового ТСПУ ценой скорости: переупорядочивание сегментов и тройные фейки.", engine: "winws2", category: "zapret2" },
    ZapretStrategy { id: "yt4k", name: "zapret2 YouTube 4K", filename: "zapret-yt4k.lua", description: "Агрессивный desync для YouTube 4K: тройные фейки и многоточечная резка по TCP, плюс фейк QUIC по UDP.", engine: "winws2", category: "zapret2" },
];

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ZapretStrategy {
    pub id: &'static str,
    pub name: &'static str,
    pub filename: &'static str,
    pub description: &'static str,
    pub engine: &'static str,
    pub category: &'static str,
}

#[derive(Debug)]
pub struct ZapretLaunch {
    pub strategy: ZapretStrategy,
    pub executable: &'static str,
    pub args: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ZapretStrategyInfo {
    pub id: &'static str,
    pub name: &'static str,
    pub filename: &'static str,
    pub description: &'static str,
    pub engine: &'static str,
    pub category: &'static str,
    pub supports_split_mode: bool,
}

pub fn strategy_info() -> Vec<ZapretStrategyInfo> {
    strategies().into_iter().map(|strategy| {
        let supports_split_mode = FLOWSEAL.iter().any(|item| item.id == strategy.id)
            || LUA_STRATEGIES.iter().any(|item| item.id == strategy.id);
        ZapretStrategyInfo {
            id: strategy.id,
            name: strategy.name,
            filename: strategy.filename,
            description: strategy.description,
            engine: strategy.engine,
            category: strategy.category,
            supports_split_mode,
        }
    }).collect()
}

pub fn strategies() -> Vec<ZapretStrategy> {
    let mut result = FLOWSEAL.to_vec();
    result.push(ZapretStrategy {
        id: "zapret2-ru-ultimate",
        name: "zapret2 РФ Ultimate (YouTube 4K + Discord)",
        filename: "zapret2-ru-ultimate.lua",
        description: "Флагманский профиль на ядре winws2 v2: Flowseal payload + Lua desync + seqovl=681 + conntrack 4K",
        engine: "winws2",
        category: "zapret2",
    });
    for item in imported_strategies::all() {
        result.push(ZapretStrategy {
            id: item.id,
            name: item.name,
            filename: item.filename,
            description: item.description,
            engine: "winws2",
            category: "zapret2",
        });
    }
    result.extend_from_slice(LUA_STRATEGIES);
    result
}

pub fn build_launch(bin_dir: &Path, strategy_id: &str, launch_mode: ZapretLaunchMode) -> Result<ZapretLaunch, Error> {
    let strategy = strategies()
        .into_iter()
        .find(|item| item.id == strategy_id)
        .ok_or_else(|| Error::new(ErrorKind::InvalidInput, format!("Unknown Zapret strategy: {strategy_id}")))?;
    let lists_dir = bin_dir.join("lists");
    // Split modes intentionally affect only Flowseal and built-in Lua presets.
    // Ultimate and imported/user strategies keep their own filters unchanged.
    let supports_split_mode = FLOWSEAL.iter().any(|item| item.id == strategy.id)
        || LUA_STRATEGIES.iter().any(|item| item.id == strategy.id);
    let tunnel_mode = if launch_mode == ZapretLaunchMode::StrictSplit && supports_split_mode {
        TunnelMode::Strict
    } else {
        TunnelMode::Full
    };
    for name in [
        "list-general.txt", "list-general-user.txt", "list-exclude.txt",
        "list-exclude-user.txt", "list-google.txt", "ipset-all.txt",
        "ipset-exclude.txt", "ipset-exclude-user.txt",
    ] {
        require_file(&lists_dir.join(name))?;
    }
    let (executable, mut args) = match strategy.engine {
        "winws" => (
            "winws.exe",
            StrategyBuilder::build_flowseal_args_inner(
                strategy.id, bin_dir, &lists_dir, tunnel_mode,
                "1024-65535", "1024-65535", None,
            ),
        ),
        "winws2" => {
            let args = if strategy.id == "zapret2-ru-ultimate" {
                StrategyBuilder::build_ultimate_args_with_auto(bin_dir, &lists_dir, None)
            } else if let Some(imported) = imported_strategies::find(strategy.id) {
                let list_path = |name: &str| format!("lists/{name}");
                StrategyBuilder::build_imported_args(imported, None, &list_path)
            } else {
                let script_path = bin_dir.join("strategies").join(strategy.filename);
                require_file(&script_path)?;
                StrategyBuilder::build_lua_preset_args(
                    tunnel_mode,
                    "1024-65535",
                    "1024-65535",
                    Some("--lua-init=@zapret-lib.lua"),
                    Some(&format!("--lua-init=@strategies/{}", strategy.filename)),
                    "lists/list-google.txt",
                    "lists/ipset-all.txt",
                    None,
                    strategy.id == "syndata",
                )
            };
            ("winws2.exe", args)
        }
        _ => return Err(Error::new(ErrorKind::InvalidInput, "Unsupported Zapret engine")),
    };
    args.insert(0, "--debug=0".to_string());
    validate_referenced_files(bin_dir, &args)?;
    Ok(ZapretLaunch { strategy, executable, args })
}

fn require_file(path: &Path) -> Result<(), Error> {
    if path.is_file() { Ok(()) } else {
        Err(Error::new(ErrorKind::NotFound, format!("Required Zapret file is missing: {}", path.display())))
    }
}

fn validate_referenced_files(bin_dir: &Path, args: &[String]) -> Result<(), Error> {
    for arg in args {
        let candidate = if let Some((_, value)) = arg.split_once("=@").or_else(|| arg.split_once(":@")) {
            Some(value)
        } else if let Some((_, value)) = arg.split_once('=') {
            if arg.starts_with("--hostlist=") || arg.starts_with("--hostlist-exclude=") ||
               arg.starts_with("--ipset=") || arg.starts_with("--ipset-exclude=") {
                Some(value)
            } else if arg.starts_with("--dpi-desync-fake-") || arg.starts_with("--dpi-desync-split-seqovl-pattern=") {
                Some(value)
            } else { None }
        } else { None };
        if let Some(value) = candidate {
            if value.starts_with("0x") || value == "!" || value.contains(',') { continue; }
            let path = bin_dir.join(value.replace('/', std::path::MAIN_SEPARATOR_STR));
            require_file(&path)?;
        }
    }
    Ok(())
}

impl ZapretLaunch {
    pub fn strategy_id(&self) -> &str { self.strategy.id }
}

impl ZapretStrategy {
    fn engine_is_winws1(&self) -> bool { self.engine == "winws" }
}

struct StrategyBuilder;

impl StrategyBuilder {
    const DISCORD_MEDIA_DOMAINS: &'static str =
        "discord.media,gateway.discord.gg,discord.com,discordapp.com,discordapp.net,discordcdn.com,discord.gg,dis.gd,discord.co,discord.app,tenor.com,tenor.co,giphy.com";

        fn sanitize_port_spec(raw: &str) -> String {
        let ok = !raw.is_empty()
            && raw.len() <= 64
            && raw.chars().all(|c| c.is_ascii_digit() || c == ',' || c == '-');
        if ok {
            raw.to_string()
        } else {
            "1024-65535".to_string()
        }
    }

    
        fn build_flowseal_args_inner(
        preset_id: &str,
        bin_dir: &Path,
        lists_dir: &Path,
        mode: TunnelMode,
        game_filter_tcp: &str,
        game_filter_udp: &str,
        auto: Option<&str>,
    ) -> Vec<String> {
        let is_game = mode == TunnelMode::GameMode;
        let is_strict = mode == TunnelMode::Strict;

        let game_tcp = StrategyBuilder::sanitize_port_spec(game_filter_tcp);
        let game_udp = StrategyBuilder::sanitize_port_spec(game_filter_udp);

        let wf_tcp = if is_game {
            format!("--wf-tcp=80,443,2053,2083,2087,2096,8443,{}", game_tcp)
        } else {
            "--wf-tcp=80,443,2053,2083,2087,2096,8443".into()
        };

        let wf_udp = if is_game {
            format!("--wf-udp=443,19294-19344,50000-65535,{}", game_udp)
        } else {
            "--wf-udp=443,19294-19344,50000-65535".into()
        };

        let b = |file: &str| {
            let p = bin_dir.join(file);
            if p.is_file() {
                file.to_string()
            } else {
                p.to_string_lossy().replace('\\', "/")
            }
        };
        let l = |file: &str| {
            if bin_dir.join("lists").join(file).is_file() {
                format!("lists/{}", file)
            } else {
                lists_dir.join(file).to_string_lossy().replace('\\', "/")
            }
        };

        let mut args = match preset_id {
            "flowseal-alt11" => vec![
                wf_tcp.clone(),
                wf_udp.clone(),
                "--filter-udp=443".into(),
                format!("--hostlist={}", l("list-general.txt")),
                format!("--hostlist={}", l("list-general-user.txt")),
                format!("--hostlist-exclude={}", l("list-exclude.txt")),
                format!("--hostlist-exclude={}", l("list-exclude-user.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude-user.txt")),
                "--dpi-desync=fake".into(),
                "--dpi-desync-repeats=11".into(),
                format!("--dpi-desync-fake-quic={}", b("quic_initial_www_google_com.bin")),
                "--new".into(),
                "--filter-udp=19294-19344,50000-65535".into(),
                "--dpi-desync=fake".into(),
                "--dpi-desync-any-protocol=1".into(),
                "--dpi-desync-cutoff=n4".into(),
                format!("--dpi-desync-fake-discord={}", b("ACTIVE_DISCORD_UDP.bin")),
                format!("--dpi-desync-fake-stun={}", b("ACTIVE_DISCORD_UDP.bin")),
                format!("--dpi-desync-fake-unknown-udp={}", b("ACTIVE_DISCORD_UDP.bin")),
                "--dpi-desync-repeats=6".into(),
                "--new".into(),
                "--filter-tcp=443,2053,2083,2087,2096,8443".into(),
                format!("--hostlist-domains={}", StrategyBuilder::DISCORD_MEDIA_DOMAINS),
                "--dpi-desync=fake,multisplit".into(),
                "--dpi-desync-split-seqovl=681".into(),
                "--dpi-desync-split-pos=1".into(),
                "--dpi-desync-fooling=ts".into(),
                "--dpi-desync-repeats=8".into(),
                format!("--dpi-desync-split-seqovl-pattern={}", b("tls_clienthello_www_google_com.bin")),
                format!("--dpi-desync-fake-tls={}", b("tls_clienthello_www_google_com.bin")),
                "--new".into(),
                "--filter-tcp=443".into(),
                format!("--hostlist={}", l("list-google.txt")),
                "--ip-id=zero".into(),
                "--dpi-desync=fake,multisplit".into(),
                "--dpi-desync-split-seqovl=681".into(),
                "--dpi-desync-split-pos=1".into(),
                "--dpi-desync-fooling=ts".into(),
                "--dpi-desync-repeats=8".into(),
                format!("--dpi-desync-split-seqovl-pattern={}", b("tls_clienthello_www_google_com.bin")),
                format!("--dpi-desync-fake-tls={}", b("tls_clienthello_www_google_com.bin")),
                "--new".into(),
                "--filter-tcp=80,443".into(),
                format!("--hostlist={}", l("list-general.txt")),
                format!("--hostlist={}", l("list-general-user.txt")),
                format!("--hostlist-exclude={}", l("list-exclude.txt")),
                format!("--hostlist-exclude={}", l("list-exclude-user.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude-user.txt")),
                "--dpi-desync=fake,multisplit".into(),
                "--dpi-desync-split-seqovl=664".into(),
                "--dpi-desync-split-pos=1".into(),
                "--dpi-desync-fooling=ts".into(),
                "--dpi-desync-repeats=8".into(),
                format!("--dpi-desync-split-seqovl-pattern={}", b("tls_clienthello_max_ru.bin")),
                format!("--dpi-desync-fake-tls={}", b("stun2.bin")),
                format!("--dpi-desync-fake-tls={}", b("tls_clienthello_max_ru.bin")),
                format!("--dpi-desync-fake-http={}", b("tls_clienthello_max_ru.bin")),
                "--new".into(),
                "--filter-udp=443".into(),
                format!("--ipset={}", l("ipset-all.txt")),
                format!("--hostlist-exclude={}", l("list-exclude.txt")),
                format!("--hostlist-exclude={}", l("list-exclude-user.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude-user.txt")),
                "--dpi-desync=fake".into(),
                "--dpi-desync-repeats=11".into(),
                format!("--dpi-desync-fake-quic={}", b("quic_initial_www_google_com.bin")),
                "--new".into(),
                "--filter-tcp=80,443,8443".into(),
                format!("--ipset={}", l("ipset-all.txt")),
                format!("--hostlist-exclude={}", l("list-exclude.txt")),
                format!("--hostlist-exclude={}", l("list-exclude-user.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude-user.txt")),
                "--dpi-desync=fake,multisplit".into(),
                "--dpi-desync-split-seqovl=664".into(),
                "--dpi-desync-split-pos=1".into(),
                "--dpi-desync-fooling=ts".into(),
                "--dpi-desync-repeats=8".into(),
                format!("--dpi-desync-split-seqovl-pattern={}", b("tls_clienthello_max_ru.bin")),
                format!("--dpi-desync-fake-tls={}", b("stun2.bin")),
                format!("--dpi-desync-fake-tls={}", b("tls_clienthello_max_ru.bin")),
                format!("--dpi-desync-fake-http={}", b("tls_clienthello_max_ru.bin")),
            ],
            "flowseal-alt" => vec![
                wf_tcp.clone(),
                wf_udp.clone(),
                "--filter-udp=443".into(),
                format!("--hostlist={}", l("list-general.txt")),
                format!("--hostlist={}", l("list-general-user.txt")),
                format!("--hostlist-exclude={}", l("list-exclude.txt")),
                format!("--hostlist-exclude={}", l("list-exclude-user.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude-user.txt")),
                "--dpi-desync=fake".into(),
                "--dpi-desync-repeats=6".into(),
                format!("--dpi-desync-fake-quic={}", b("quic_initial_www_google_com.bin")),
                "--new".into(),
                "--filter-udp=19294-19344,50000-65535".into(),
                "--dpi-desync=fake".into(),
                "--dpi-desync-any-protocol=1".into(),
                "--dpi-desync-cutoff=n4".into(),
                format!("--dpi-desync-fake-discord={}", b("ACTIVE_DISCORD_UDP.bin")),
                format!("--dpi-desync-fake-stun={}", b("ACTIVE_DISCORD_UDP.bin")),
                format!("--dpi-desync-fake-unknown-udp={}", b("ACTIVE_DISCORD_UDP.bin")),
                "--dpi-desync-repeats=6".into(),
                "--new".into(),
                "--filter-tcp=443,2053,2083,2087,2096,8443".into(),
                format!("--hostlist-domains={}", StrategyBuilder::DISCORD_MEDIA_DOMAINS),
                "--dpi-desync=fake,multisplit".into(),
                "--dpi-desync-split-pos=1".into(),
                "--dpi-desync-repeats=6".into(),
                "--dpi-desync-fooling=ts".into(),
                format!("--dpi-desync-fake-tls={}", b("tls_clienthello_www_google_com.bin")),
                "--new".into(),
                "--filter-tcp=443".into(),
                format!("--hostlist={}", l("list-google.txt")),
                "--ip-id=zero".into(),
                "--dpi-desync=fake,fakedsplit".into(),
                "--dpi-desync-repeats=6".into(),
                "--dpi-desync-fooling=ts".into(),
                "--dpi-desync-fakedsplit-pattern=0x00".into(),
                format!("--dpi-desync-fake-tls={}", b("tls_clienthello_www_google_com.bin")),
                "--new".into(),
                "--filter-tcp=80,443".into(),
                format!("--hostlist={}", l("list-general.txt")),
                format!("--hostlist={}", l("list-general-user.txt")),
                format!("--hostlist-exclude={}", l("list-exclude.txt")),
                format!("--hostlist-exclude={}", l("list-exclude-user.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude-user.txt")),
                "--dpi-desync=fake,fakedsplit".into(),
                "--dpi-desync-repeats=6".into(),
                "--dpi-desync-fooling=ts".into(),
                "--dpi-desync-fakedsplit-pattern=0x00".into(),
                format!("--dpi-desync-fake-tls={}", b("stun.bin")),
                format!("--dpi-desync-fake-tls={}", b("tls_clienthello_www_google_com.bin")),
                format!("--dpi-desync-fake-http={}", b("tls_clienthello_max_ru.bin")),
                "--new".into(),
                "--filter-udp=443".into(),
                format!("--ipset={}", l("ipset-all.txt")),
                format!("--hostlist-exclude={}", l("list-exclude.txt")),
                format!("--hostlist-exclude={}", l("list-exclude-user.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude-user.txt")),
                "--dpi-desync=fake".into(),
                "--dpi-desync-repeats=6".into(),
                format!("--dpi-desync-fake-quic={}", b("quic_initial_www_google_com.bin")),
                "--new".into(),
                "--filter-tcp=80,443,8443".into(),
                format!("--ipset={}", l("ipset-all.txt")),
                format!("--hostlist-exclude={}", l("list-exclude.txt")),
                format!("--hostlist-exclude={}", l("list-exclude-user.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude-user.txt")),
                "--dpi-desync=fake,fakedsplit".into(),
                "--dpi-desync-repeats=6".into(),
                "--dpi-desync-fooling=ts".into(),
                "--dpi-desync-fakedsplit-pattern=0x00".into(),
                format!("--dpi-desync-fake-tls={}", b("stun.bin")),
                format!("--dpi-desync-fake-tls={}", b("tls_clienthello_www_google_com.bin")),
                format!("--dpi-desync-fake-http={}", b("tls_clienthello_max_ru.bin")),
            ],
            "flowseal-fake-tls-auto" => vec![
                wf_tcp.clone(),
                wf_udp.clone(),
                "--filter-udp=443".into(),
                format!("--hostlist={}", l("list-general.txt")),
                format!("--hostlist={}", l("list-general-user.txt")),
                format!("--hostlist-exclude={}", l("list-exclude.txt")),
                format!("--hostlist-exclude={}", l("list-exclude-user.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude-user.txt")),
                "--dpi-desync=fake".into(),
                "--dpi-desync-repeats=11".into(),
                format!("--dpi-desync-fake-quic={}", b("quic_initial_www_google_com.bin")),
                "--new".into(),
                "--filter-udp=19294-19344,50000-65535".into(),
                "--dpi-desync=fake".into(),
                "--dpi-desync-any-protocol=1".into(),
                "--dpi-desync-cutoff=n4".into(),
                format!("--dpi-desync-fake-discord={}", b("ACTIVE_DISCORD_UDP.bin")),
                format!("--dpi-desync-fake-stun={}", b("ACTIVE_DISCORD_UDP.bin")),
                format!("--dpi-desync-fake-unknown-udp={}", b("ACTIVE_DISCORD_UDP.bin")),
                "--dpi-desync-repeats=6".into(),
                "--new".into(),
                "--filter-tcp=443,2053,2083,2087,2096,8443".into(),
                format!("--hostlist-domains={}", StrategyBuilder::DISCORD_MEDIA_DOMAINS),
                "--dpi-desync=fake,multidisorder".into(),
                "--dpi-desync-split-pos=1,midsld".into(),
                "--dpi-desync-repeats=11".into(),
                "--dpi-desync-fooling=badseq".into(),
                "--dpi-desync-fake-tls=0x00000000".into(),
                "--dpi-desync-fake-tls=!".into(),
                "--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com".into(),
                "--new".into(),
                "--filter-tcp=443".into(),
                format!("--hostlist={}", l("list-google.txt")),
                "--ip-id=zero".into(),
                "--dpi-desync=fake,multidisorder".into(),
                "--dpi-desync-split-pos=1,midsld".into(),
                "--dpi-desync-repeats=11".into(),
                "--dpi-desync-fooling=badseq".into(),
                "--dpi-desync-fake-tls=0x00000000".into(),
                "--dpi-desync-fake-tls=!".into(),
                "--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com".into(),
                "--new".into(),
                "--filter-tcp=80,443".into(),
                format!("--hostlist={}", l("list-general.txt")),
                format!("--hostlist={}", l("list-general-user.txt")),
                format!("--hostlist-exclude={}", l("list-exclude.txt")),
                format!("--hostlist-exclude={}", l("list-exclude-user.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude-user.txt")),
                "--dpi-desync=fake,multidisorder".into(),
                "--dpi-desync-split-pos=1,midsld".into(),
                "--dpi-desync-repeats=11".into(),
                "--dpi-desync-fooling=badseq".into(),
                "--dpi-desync-fake-tls=0x00000000".into(),
                "--dpi-desync-fake-tls=!".into(),
                "--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com".into(),
                format!("--dpi-desync-fake-http={}", b("tls_clienthello_max_ru.bin")),
                "--new".into(),
                "--filter-udp=443".into(),
                format!("--ipset={}", l("ipset-all.txt")),
                format!("--hostlist-exclude={}", l("list-exclude.txt")),
                format!("--hostlist-exclude={}", l("list-exclude-user.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude-user.txt")),
                "--dpi-desync=fake".into(),
                "--dpi-desync-repeats=11".into(),
                format!("--dpi-desync-fake-quic={}", b("quic_initial_www_google_com.bin")),
                "--new".into(),
                "--filter-tcp=80,443,8443".into(),
                format!("--ipset={}", l("ipset-all.txt")),
                format!("--hostlist-exclude={}", l("list-exclude.txt")),
                format!("--hostlist-exclude={}", l("list-exclude-user.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude-user.txt")),
                "--dpi-desync=fake,multidisorder".into(),
                "--dpi-desync-split-pos=1,midsld".into(),
                "--dpi-desync-repeats=11".into(),
                "--dpi-desync-fooling=badseq".into(),
                "--dpi-desync-fake-tls=0x00000000".into(),
                "--dpi-desync-fake-tls=!".into(),
                "--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com".into(),
                format!("--dpi-desync-fake-http={}", b("tls_clienthello_max_ru.bin")),
            ],
            "flowseal-simple-fake" => vec![
                wf_tcp.clone(),
                wf_udp.clone(),
                "--filter-udp=443".into(),
                format!("--hostlist={}", l("list-general.txt")),
                format!("--hostlist={}", l("list-general-user.txt")),
                format!("--hostlist-exclude={}", l("list-exclude.txt")),
                format!("--hostlist-exclude={}", l("list-exclude-user.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude-user.txt")),
                "--dpi-desync=fake".into(),
                "--dpi-desync-repeats=6".into(),
                format!("--dpi-desync-fake-quic={}", b("quic_initial_www_google_com.bin")),
                "--new".into(),
                "--filter-udp=19294-19344,50000-65535".into(),
                "--dpi-desync=fake".into(),
                "--dpi-desync-any-protocol=1".into(),
                "--dpi-desync-cutoff=n4".into(),
                format!("--dpi-desync-fake-discord={}", b("ACTIVE_DISCORD_UDP.bin")),
                format!("--dpi-desync-fake-stun={}", b("ACTIVE_DISCORD_UDP.bin")),
                format!("--dpi-desync-fake-unknown-udp={}", b("ACTIVE_DISCORD_UDP.bin")),
                "--dpi-desync-repeats=6".into(),
                "--new".into(),
                "--filter-tcp=443,2053,2083,2087,2096,8443".into(),
                format!("--hostlist-domains={}", StrategyBuilder::DISCORD_MEDIA_DOMAINS),
                "--dpi-desync=fake".into(),
                "--dpi-desync-repeats=6".into(),
                "--dpi-desync-fooling=ts".into(),
                format!("--dpi-desync-fake-tls={}", b("tls_clienthello_www_google_com.bin")),
                "--new".into(),
                "--filter-tcp=443".into(),
                format!("--hostlist={}", l("list-google.txt")),
                "--ip-id=zero".into(),
                "--dpi-desync=hostfakesplit".into(),
                "--dpi-desync-fooling=ts".into(),
                "--dpi-desync-hostfakesplit-mod=host=www.google.com".into(),
                "--new".into(),
                "--filter-tcp=80,443".into(),
                format!("--hostlist={}", l("list-general.txt")),
                format!("--hostlist={}", l("list-general-user.txt")),
                format!("--hostlist-exclude={}", l("list-exclude.txt")),
                format!("--hostlist-exclude={}", l("list-exclude-user.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude-user.txt")),
                "--dpi-desync=fake".into(),
                "--dpi-desync-repeats=6".into(),
                "--dpi-desync-fooling=ts".into(),
                format!("--dpi-desync-fake-tls={}", b("tls_clienthello_www_google_com.bin")),
                format!("--dpi-desync-fake-http={}", b("tls_clienthello_max_ru.bin")),
                "--new".into(),
                "--filter-udp=443".into(),
                format!("--ipset={}", l("ipset-all.txt")),
                format!("--hostlist-exclude={}", l("list-exclude.txt")),
                format!("--hostlist-exclude={}", l("list-exclude-user.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude-user.txt")),
                "--dpi-desync=fake".into(),
                "--dpi-desync-repeats=6".into(),
                format!("--dpi-desync-fake-quic={}", b("quic_initial_www_google_com.bin")),
                "--new".into(),
                "--filter-tcp=80,443,8443".into(),
                format!("--ipset={}", l("ipset-all.txt")),
                format!("--hostlist-exclude={}", l("list-exclude.txt")),
                format!("--hostlist-exclude={}", l("list-exclude-user.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude-user.txt")),
                "--dpi-desync=fake".into(),
                "--dpi-desync-repeats=6".into(),
                "--dpi-desync-fooling=ts".into(),
                format!("--dpi-desync-fake-tls={}", b("tls_clienthello_www_google_com.bin")),
                format!("--dpi-desync-fake-http={}", b("tls_clienthello_max_ru.bin")),
            ],
            _ /* flowseal-general: the only id reaching here; unknown flowseal-* ids are rejected in resolve_strategy_args */ => vec![
                wf_tcp.clone(),
                wf_udp.clone(),
                "--filter-udp=443".into(),
                format!("--hostlist={}", l("list-general.txt")),
                format!("--hostlist={}", l("list-general-user.txt")),
                format!("--hostlist-exclude={}", l("list-exclude.txt")),
                format!("--hostlist-exclude={}", l("list-exclude-user.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude-user.txt")),
                "--dpi-desync=fake".into(),
                "--dpi-desync-repeats=6".into(),
                format!("--dpi-desync-fake-quic={}", b("quic_initial_www_google_com.bin")),
                "--new".into(),
                "--filter-udp=19294-19344,50000-65535".into(),
                "--dpi-desync=fake".into(),
                "--dpi-desync-any-protocol=1".into(),
                "--dpi-desync-cutoff=n4".into(),
                format!("--dpi-desync-fake-discord={}", b("ACTIVE_DISCORD_UDP.bin")),
                format!("--dpi-desync-fake-stun={}", b("ACTIVE_DISCORD_UDP.bin")),
                format!("--dpi-desync-fake-unknown-udp={}", b("ACTIVE_DISCORD_UDP.bin")),
                "--dpi-desync-repeats=6".into(),
                "--new".into(),
                "--filter-tcp=443,2053,2083,2087,2096,8443".into(),
                format!("--hostlist-domains={}", StrategyBuilder::DISCORD_MEDIA_DOMAINS),
                "--dpi-desync=multisplit".into(),
                "--dpi-desync-split-seqovl=681".into(),
                "--dpi-desync-split-pos=1".into(),
                format!("--dpi-desync-split-seqovl-pattern={}", b("tls_clienthello_www_google_com.bin")),
                "--new".into(),
                "--filter-tcp=443".into(),
                format!("--hostlist={}", l("list-google.txt")),
                "--ip-id=zero".into(),
                "--dpi-desync=multisplit".into(),
                "--dpi-desync-split-seqovl=681".into(),
                "--dpi-desync-split-pos=1".into(),
                format!("--dpi-desync-split-seqovl-pattern={}", b("tls_clienthello_www_google_com.bin")),
                "--new".into(),
                "--filter-tcp=80,443".into(),
                format!("--hostlist={}", l("list-general.txt")),
                format!("--hostlist={}", l("list-general-user.txt")),
                format!("--hostlist-exclude={}", l("list-exclude.txt")),
                format!("--hostlist-exclude={}", l("list-exclude-user.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude-user.txt")),
                "--dpi-desync=multisplit".into(),
                "--dpi-desync-split-seqovl=568".into(),
                "--dpi-desync-split-pos=1".into(),
                format!("--dpi-desync-split-seqovl-pattern={}", b("tls_clienthello_4pda_to.bin")),
                "--new".into(),
                "--filter-udp=443".into(),
                format!("--ipset={}", l("ipset-all.txt")),
                format!("--hostlist-exclude={}", l("list-exclude.txt")),
                format!("--hostlist-exclude={}", l("list-exclude-user.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude-user.txt")),
                "--dpi-desync=fake".into(),
                "--dpi-desync-repeats=6".into(),
                format!("--dpi-desync-fake-quic={}", b("quic_initial_www_google_com.bin")),
                "--new".into(),
                "--filter-tcp=80,443,8443".into(),
                format!("--ipset={}", l("ipset-all.txt")),
                format!("--hostlist-exclude={}", l("list-exclude.txt")),
                format!("--hostlist-exclude={}", l("list-exclude-user.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude-user.txt")),
                "--dpi-desync=multisplit".into(),
                "--dpi-desync-split-seqovl=568".into(),
                "--dpi-desync-split-pos=1".into(),
            ],
        };

        // Auto-hostlist (design §3): into every TCP section gated
        // on list-general, after its exclude lines. Runs before the
        // game extension (its sections are ipset-based — out of
        // scope) and before the STRICT filter below, which drops
        // general blocks whole, auto lines included: STRICT stays
        // free of auto by construction, as the design requires.
        if let Some(auto_path) = auto {
            args = StrategyBuilder::inject_auto_hostlist(args, auto_path);
        }

        // 1. If Game Mode is active, attach game port filtering and ACTIVE_GAME_UDP desync
        // SECURITY (L-4): game port specs come from user settings — sanitize them
        // like everywhere else so a malformed value cannot break engine startup.
        let game_tcp = StrategyBuilder::sanitize_port_spec(game_filter_tcp);
        let game_udp = StrategyBuilder::sanitize_port_spec(game_filter_udp);
        if is_game {
            args.extend([
                "--new".into(),
                format!("--filter-tcp={}", game_tcp),
                format!("--ipset={}", l("ipset-all.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude-user.txt")),
                "--dpi-desync=fake,fakedsplit".into(),
                "--dpi-desync-repeats=6".into(),
                "--dpi-desync-any-protocol=1".into(),
                "--dpi-desync-cutoff=n4".into(),
                "--dpi-desync-fooling=ts".into(),
                "--dpi-desync-fakedsplit-pattern=0x00".into(),
                format!("--dpi-desync-fake-tls={}", b("stun.bin")),
                format!("--dpi-desync-fake-tls={}", b("tls_clienthello_www_google_com.bin")),
                format!("--dpi-desync-fake-http={}", b("tls_clienthello_max_ru.bin")),
                format!("--dpi-desync-fake-unknown={}", b("stun.bin")),
                format!("--dpi-desync-fake-unknown={}", b("tls_clienthello_www_google_com.bin")),
                "--new".into(),
                format!("--filter-udp={}", game_udp),
                format!("--ipset={}", l("ipset-all.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude.txt")),
                format!("--ipset-exclude={}", l("ipset-exclude-user.txt")),
                "--dpi-desync=fake".into(),
                "--dpi-desync-repeats=12".into(),
                "--dpi-desync-any-protocol=1".into(),
                format!("--dpi-desync-fake-unknown-udp={}", b("ACTIVE_GAME_UDP.bin")),
                "--dpi-desync-cutoff=n3".into(),
            ]);
        }

        // 2. If Strict Split-Tunneling is active, bypass all other websites and ipset-all
        if is_strict {
            let mut filtered = Vec::new();
            let mut current_block = Vec::new();
            for arg in args {
                if arg == "--new" {
                    let has_general = current_block.iter().any(|a: &String| a.contains("list-general") || a.contains("ipset-all.txt"));
                    if !has_general {
                        if !filtered.is_empty() {
                            filtered.push("--new".to_string());
                        }
                        filtered.extend(current_block);
                    }
                    current_block = Vec::new();
                } else if !arg.starts_with("--wf-tcp") && !arg.starts_with("--wf-udp") {
                    current_block.push(arg);
                }
            }
            if !current_block.is_empty() {
                let has_general = current_block.iter().any(|a: &String| a.contains("list-general") || a.contains("ipset-all.txt"));
                if !has_general {
                    if !filtered.is_empty() {
                        filtered.push("--new".to_string());
                    }
                    filtered.extend(current_block);
                }
            }
            let mut final_args = vec![wf_tcp.clone(), wf_udp.clone()];
            final_args.extend(filtered);
            args = final_args;
        }

        // 3. Ensure WinDivert root port filters are updated
        if let Some(first) = args.first_mut() {
            if first.starts_with("--wf-tcp") {
                *first = wf_tcp;
            }
        }
        if args.len() > 1 && args[1].starts_with("--wf-udp") {
            args[1] = wf_udp;
        }

        args
    }

    /// Builds winws2 arguments for an imported kinlay0 strategy.
    /// Pure: the caller resolves the filesystem-shaped inputs (the
    /// auto-hostlist path and the list resolver, same shape as
    /// branch 4's l()) so tests can pin the output.
    ///
    /// Layout mirrors the flagship: our standard root capture
    /// filters, the three stock lua-init libraries the collection
    /// loads (minus its blobs.lua — blobs are registered our way,
    /// only the ones this strategy references), then the strategy's
    /// profiles in the .bat's own order as --new=<slug> sections.
    ///
    /// Honest scope limits, same as the flagship: the split-tunnel
    /// Lua modes do not reshape these lists (start_locked reports
    /// the mode as not applied for imported ids), and the .bat
    /// gamefilter sections are not carried over — the GUI's own
    /// game sections belong to the Flowseal/Lua-preset builders.
    ///
    /// Auto-hostlist (design §3): with the setting on, the
    /// domain_tls section — the TCP section gated on list-general —
    /// gains --hostlist-auto after its exclude lines, like the
    /// flagship's general sections. The QUIC section stays out:
    /// the UDP failure detector is out of phase-1 scope there too.

        fn build_imported_args(
        imported: &imported_strategies::ImportedStrategy,
        auto: Option<&str>,
        list_path: &dyn Fn(&str) -> String,
    ) -> Vec<String> {
        let mut args: Vec<String> = vec![
            "--wf-tcp-out=80,443,2053,2083,2087,2096,8443".into(),
            "--wf-udp-out=443,19294-19344,50000-65535".into(),
            "--lua-init=@zapret-lib.lua".into(),
            "--lua-init=@zapret-antidpi.lua".into(),
            "--lua-init=@zapret-auto.lua".into(),
        ];
        for name in imported.blobs {
            if let Some(file) = imported_strategies::blob_file(name) {
                args.push(format!("--blob={}:@{}", name, file));
            }
        }
        for (slug, profile_args) in imported.profiles {
            args.push(format!("--new={}", slug));
            for arg in *profile_args {
                if let Some(pos) = arg.find("{L}") {
                    let file = &arg[pos + 3..];
                    args.push(format!("{}{}", &arg[..pos], list_path(file)));
                } else {
                    args.push(arg.to_string());
                }
            }
        }
        if let Some(auto_path) = auto {
            let anchor = format!(
                "--hostlist-exclude={}",
                list_path("list-exclude-user.txt")
            );
            StrategyBuilder::insert_after_in_section(
                &mut args,
                "domain_tls",
                &anchor,
                &[format!("--hostlist-auto={}", auto_path)],
            );
        }
        args
    }

    /// Builds zapret2 Ultimate configuration for Russia on winws2 v2.
    /// Thin wrapper: reads the auto-hostlist setting and resolves
    /// the absolute auto path from the user lists directory; the
    /// argument list itself is built by the pure inner function so
    /// tests can pin both states. bin_dir is passed through for the
    /// list-path resolver (relative "lists/..." when the files sit
    /// next to the engine, absolute lists_dir otherwise).

        fn build_ultimate_args_with_auto(
        bin_dir: &Path,
        lists_dir: &Path,
        auto: Option<&str>,
    ) -> Vec<String> {
        // Same resolver as the other builders: prefer the relative
        // "lists/..." path when the file sits next to the engine
        // (stock mode), otherwise the absolute lists_dir path. The
        // relative form MUST NOT be assumed: in Monkey mode the engine
        // spawns with cwd=bin/monkey/, where lists/ is deliberately
        // not mirrored (both modes share the stock bin/lists/), and
        // a missing hostlist file makes the engine silently run with
        // an empty list — a quiet no-op, not an error.
        let l = |file: &str| {
            if bin_dir.join("lists").join(file).is_file() {
                format!("lists/{}", file)
            } else {
                lists_dir.join(file).to_string_lossy().replace('\\', "/")
            }
        };
        let mut args = vec![
            "--wf-tcp-out=80,443,2053,2083,2087,2096,8443".into(),
            "--wf-udp-out=443,19294-19344,50000-65535".into(),

            // Lua library initialization (relative to bin_dir)
            "--lua-init=@zapret-lib.lua".into(),
            "--lua-init=@zapret-antidpi.lua".into(),

            // Load pre-crafted binary packet payloads
            "--blob=quic_google:@quic_initial_www_google_com.bin".into(),
            "--blob=discord_udp:@ACTIVE_DISCORD_UDP.bin".into(),
            "--blob=tls_google:@tls_clienthello_www_google_com.bin".into(),
            "--blob=tls_max_ru:@tls_clienthello_max_ru.bin".into(),
            "--blob=stun2:@stun2.bin".into(),

            // 1. YouTube QUIC Handshake Bypass (UDP 443)
            "--new=quic_youtube".into(),
            "--filter-udp=443".into(),
            format!("--hostlist={}", l("list-general.txt")),
            format!("--hostlist={}", l("list-general-user.txt")),
            format!("--hostlist-exclude={}", l("list-exclude.txt")),
            "--payload=quic_initial".into(),
            "--lua-desync=fake:blob=quic_google:repeats=11".into(),

            // 2. Discord Voice UDP & STUN Media (19294-19344, 50000-65535)
            "--new=discord_voice".into(),
            "--filter-udp=19294-19344,50000-65535".into(),
            "--payload=all".into(),
            "--out-range=n1-n4".into(),
            "--lua-desync=fake:blob=discord_udp:repeats=6".into(),

            // 3. Discord Media & Voice Gateway TCP (443, 2053, 2083, 2087, 2096, 8443)
            "--new=discord_media".into(),
            "--filter-tcp=443,2053,2083,2087,2096,8443".into(),
            format!("--hostlist-domains={}", StrategyBuilder::DISCORD_MEDIA_DOMAINS),
            "--payload=tls_client_hello".into(),
            "--out-range=n1-n4".into(),
            "--lua-desync=fake:blob=tls_google:repeats=8:tcp_ts=1000".into(),
            "--lua-desync=multisplit:pos=2:seqovl=681:seqovl_pattern=tls_google:tcp_ts=1000".into(),

            // 4. YouTube 4K Google TCP (443) - seqovl=681 + TLS Fake Google + out-range=n1-n4 for 60FPS
            "--new=youtube_4k".into(),
            "--filter-tcp=443".into(),
            format!("--hostlist={}", l("list-google.txt")),
            "--payload=tls_client_hello".into(),
            "--out-range=n1-n4".into(),
            "--lua-desync=fake:blob=tls_google:repeats=8:tcp_ts=1000:ip_id=zero".into(),
            "--lua-desync=multisplit:pos=2:seqovl=681:seqovl_pattern=tls_google:tcp_ts=1000:ip_id=zero".into(),

            // 5. General Blocked Websites HTTPS (80,443) - seqovl=664 + TLS Fake max_ru
            "--new=general_https".into(),
            "--filter-tcp=80,443".into(),
            format!("--hostlist={}", l("list-general.txt")),
            format!("--hostlist={}", l("list-general-user.txt")),
            format!("--hostlist-exclude={}", l("list-exclude.txt")),
            "--payload=tls_client_hello".into(),
            "--out-range=n1-n4".into(),
            "--lua-desync=fake:blob=tls_max_ru:repeats=8:tcp_ts=1000".into(),
            "--lua-desync=multisplit:pos=2:seqovl=664:seqovl_pattern=tls_max_ru:tcp_ts=1000".into(),

            // 6. General HTTP (80)
            "--new=general_http".into(),
            "--filter-tcp=80".into(),
            format!("--hostlist={}", l("list-general.txt")),
            "--payload=http_req".into(),
            "--lua-desync=fake:blob=tls_max_ru:tcp_ts=1000".into(),
            "--lua-desync=multisplit:pos=2:seqovl=664:seqovl_pattern=tls_max_ru:tcp_ts=1000".into(),

            // 7. IPSet All Fallback
            "--new=ipset_fallback".into(),
            "--filter-tcp=80,443,8443".into(),
            format!("--ipset={}", l("ipset-all.txt")),
            format!("--hostlist-exclude={}", l("list-exclude.txt")),
            "--payload=tls_client_hello".into(),
            "--out-range=n1-n4".into(),
            "--lua-desync=fake:blob=tls_max_ru:repeats=8:tcp_ts=1000".into(),
            "--lua-desync=multisplit:pos=2:seqovl=664:seqovl_pattern=tls_max_ru:tcp_ts=1000".into(),
        ];

        if let Some(auto_path) = auto {
            // Auto-hostlist (design §3): only the two general
            // sections learn — youtube_4k/discord_media are gated on
            // their own narrow sets and must not apply their
            // specialized handling to random learned domains, and
            // ipset_fallback is an IP filter, not a domain one. The
            // auto path is absolute (the engine WRITES to this file,
            // so it must land in the user lists directory); every
            // other list path goes through the same l() resolver as
            // the vec above — including the insert anchors, which
            // must match the resolved lines exactly, or the insert
            // silently does nothing. At the same time — and only
            // with the setting on — the general sections gain the
            // exclude pairs they historically lacked, because the
            // invariant "exclude always wins" must hold in every
            // section that carries auto: general_https gets the user
            // exclude next to its static one; general_http gets the
            // whole pair (its include side is NOT extended —
            // list-general-user stays out of this section, as
            // before). With the setting off and stock lists present
            // the argument list above is byte for byte the
            // historical one.
            StrategyBuilder::insert_after_in_section(
                &mut args,
                "general_https",
                &format!("--hostlist-exclude={}", l("list-exclude.txt")),
                &[
                    format!("--hostlist-exclude={}", l("list-exclude-user.txt")),
                    format!("--hostlist-auto={}", auto_path),
                ],
            );
            StrategyBuilder::insert_after_in_section(
                &mut args,
                "general_http",
                &format!("--hostlist={}", l("list-general.txt")),
                &[
                    format!("--hostlist-exclude={}", l("list-exclude.txt")),
                    format!("--hostlist-exclude={}", l("list-exclude-user.txt")),
                    format!("--hostlist-auto={}", auto_path),
                ],
            );
        }

        args
    }

    /// Inserts `new_lines` right after `anchor` inside the named
    /// `--new=<section>` span of an argument list. A missing section
    /// or anchor leaves the list untouched (the builders' tests pin
    /// the shapes this is used with).

        fn build_lua_preset_args(
        mode: TunnelMode,
        game_tcp: &str,
        game_udp: &str,
        lib_init: Option<&str>,
        preset_init: Option<&str>,
        google_list: &str,
        ipset_all: &str,
        auto: Option<&AutoLists>,
        syndata: bool,
    ) -> Vec<String> {
        let is_strict = mode == TunnelMode::Strict;
        let is_game = mode == TunnelMode::GameMode;

        let mut args: Vec<String> = Vec::new();

        // Root WinDivert capture filters. STRICT never narrows them
        // (capture without desync is harmless; parity with Flowseal);
        // GAME widens them by the game port specs.
        if is_game {
            args.push(format!(
                "--wf-tcp-out=80,443,2053,2083,2087,2096,8443,{}",
                game_tcp
            ));
            args.push(format!(
                "--wf-udp-out=443,19294-19344,50000-65535,{}",
                game_udp
            ));
        } else {
            args.push("--wf-tcp-out=80,443,2053,2083,2087,2096,8443".into());
            args.push("--wf-udp-out=443,19294-19344,50000-65535".into());
        }

        // UDP fake payloads, mirrored from the flagship's sections. Without
        // them the UDP sections below would have no blob to send; the
        // files live in bin/ next to the engine, same as the flagship.
        args.push("--blob=discord_udp:@ACTIVE_DISCORD_UDP.bin".into());
        args.push("--blob=quic_google:@quic_initial_www_google_com.bin".into());
        if is_game {
            args.push("--blob=game_udp:@ACTIVE_GAME_UDP.bin".into());
        }

        // The preset's TLS desync pair: identical parameters in the
        // FULL section and in both STRICT gated sections. The mode
        // changes WHERE desync applies, never HOW it desyncs.
        let fake_tls =
            "--lua-desync=fake:blob=fake_default_tls:tcp_md5:tls_mod=rnd,rndsni,dupsid";
        let multisplit =
            "--lua-desync=multisplit:pos=2:seqovl=5:seqovl_pattern=0x1603030000";
        // The syndata preset's extra instance: same fake blob and
        // mutation as fake_tls, but delivered inside the SYN packet.
        // Placed before the section's payload lines (see below), so
        // no --payload restriction applies to it.
        let syndata_spec =
            "--lua-desync=syndata:blob=fake_default_tls:tcp_md5:tls_mod=rnd,rndsni,dupsid";

        if is_strict {
            // STRICT (design variant A): the ungated TCP section is
            // replaced by two gated sections on port 443 only, so
            // desync touches YouTube/Discord traffic and nothing
            // else. No port 80, no http_req pair, no Cloudflare
            // ports. The lua-init lines move in front of the sections:
            // their FULL position was inside the unnamed first
            // section, which STRICT does not have; the flagship
            // places --lua-init before all sections, so this follows
            // its proven layout.
            if let Some(init) = lib_init {
                args.push(init.into());
            }
            if let Some(init) = preset_init {
                args.push(init.into());
            }
            args.push("--new=discord_tcp".into());
            args.push("--filter-tcp=443".into());
            args.push(format!(
                "--hostlist-domains={}",
                StrategyBuilder::DISCORD_MEDIA_DOMAINS
            ));
            if syndata {
                args.push(syndata_spec.into());
            }
            args.push("--payload=tls_client_hello".into());
            args.push(fake_tls.into());
            args.push("--payload=tls_client_hello".into());
            args.push(multisplit.into());
            args.push("--new=google_tcp".into());
            args.push("--filter-tcp=443".into());
            args.push(format!("--hostlist={}", google_list));
            if syndata {
                args.push(syndata_spec.into());
            }
            args.push("--payload=tls_client_hello".into());
            args.push(fake_tls.into());
            args.push("--payload=tls_client_hello".into());
            args.push(multisplit.into());
        } else {
            // FULL (and the GAME base): the historical ungated TCP
            // section, byte for byte when auto is None.
            args.push("--filter-tcp=80,443,2053,2083,2087,2096,8443".into());
            if let Some(auto) = auto {
                // Auto-hostlist gating (design §3), right after the
                // filter, before the payload lines: listed hosts get
                // desync immediately, unlisted ones go through the
                // engine's failure detector and are learned into the
                // auto file. list-google is part of the gate on
                // purpose, not an option: youtube/googlevideo live
                // only in list-google, and without it a YouTube
                // preset would route its own traffic through the
                // failure detector (and the auto-tune probes with
                // it) instead of the immediate include.
                args.push(format!("--hostlist={}", auto.general));
                args.push(format!("--hostlist={}", auto.general_user));
                args.push(format!("--hostlist={}", google_list));
                args.push(format!("--hostlist-exclude={}", auto.exclude));
                args.push(format!("--hostlist-exclude={}", auto.exclude_user));
                args.push(format!("--hostlist-auto={}", auto.auto_path));
            }
            if let Some(init) = lib_init {
                args.push(init.into());
            }
            if let Some(init) = preset_init {
                args.push(init.into());
            }
            if syndata {
                args.push(syndata_spec.into());
            }
            args.push("--payload=tls_client_hello".into());
            args.push(fake_tls.into());
            args.push("--payload=http_req".into());
            args.push("--lua-desync=fake:blob=fake_default_http:tcp_md5".into());
            args.push("--payload=tls_client_hello,http_req".into());
            args.push(multisplit.into());
        }

        // UDP sections. Previously branch 4 captured voice/QUIC UDP via
        // --wf-udp-out but defined no --filter-udp section, so Discord
        // voice and YouTube QUIC passed through untouched: voice did
        // not work on any discovered preset. These two sections mirror
        // the flagship's discord_voice and quic_youtube sections (same
        // blobs, same repeats); the QUIC section is intentionally
        // ungated like branch 4's TCP section. Caveat: presets whose
        // fake() loops (yt4k, tspu-max) triple the UDP fakes too
        // (voice: up to 72 in a burst at flow start, out-range
        // n1-n4 x 18, ~86 KB; QUIC: 33 per Initial, vs the
        // flagship's 6/11), and sites-light's pass-through fake()
        // leaves UDP unprotected by design.
        args.push("--new=discord_voice".into());
        args.push("--filter-udp=19294-19344,50000-65535".into());
        args.push("--payload=all".into());
        args.push("--out-range=n1-n4".into());
        args.push("--lua-desync=fake:blob=discord_udp:repeats=6".into());
        if !is_strict {
            // STRICT drops the quic section entirely (parity with
            // Flowseal STRICT): YouTube over QUIC gets no desync and
            // the browser is expected to fall back to TCP. The voice
            // section above stays: voice is Discord.
            args.push("--new=quic".into());
            args.push("--filter-udp=443".into());
            args.push("--payload=quic_initial".into());
            args.push("--lua-desync=fake:blob=quic_google:repeats=11".into());
        }

        if is_game {
            // GAME sections go after the base sections (same order
            // as Flowseal). The game range overlaps base ports
            // (2053, 2083, 2087, 2096, 8443); which section the
            // engine picks on overlap is an upstream assumption
            // (first fully matching section), not a verified fact —
            // see the design draft's open checks. Both sections call
            // the neutral fake_plain() from zapret-lib.lua, never the
            // preset's fake(): game behaviour stays identical on
            // every preset (no yt4k triple send, no sites-light
            // pass-through).
            args.push("--new=game_tcp".into());
            args.push(format!("--filter-tcp={}", game_tcp));
            args.push(format!("--ipset={}", ipset_all));
            args.push("--payload=tls_client_hello,http_req".into());
            args.push("--lua-desync=fake_plain:blob=fake_default_tls".into());
            args.push("--new=game_udp".into());
            args.push(format!("--filter-udp={}", game_udp));
            args.push(format!("--ipset={}", ipset_all));
            args.push("--payload=all".into());
            args.push("--out-range=n1-n3".into());
            args.push("--lua-desync=fake_plain:blob=game_udp:repeats=12".into());
        }

        args
    }


        fn insert_after_in_section(
        args: &mut Vec<String>,
        section: &str,
        anchor: &str,
        new_lines: &[String],
    ) {
        let marker = format!("--new={}", section);
        let Some(start) = args.iter().position(|a| a == &marker) else {
            return;
        };
        let end = args
            .iter()
            .skip(start + 1)
            .position(|a| a.starts_with("--new="))
            .map(|p| start + 1 + p)
            .unwrap_or(args.len());
        if let Some(rel) = args[start..end].iter().position(|a| a == anchor) {
            let at = start + rel + 1;
            for (i, line) in new_lines.iter().enumerate() {
                args.insert(at + i, line.clone());
            }
        }
    }

    /// Inserts `--hostlist-auto=<auto_path>` into every section of
    /// a Flowseal argument list that is (a) TCP (`--filter-tcp`)
    /// and (b) gated on list-general.txt, right after the section's
    /// last `--hostlist-exclude` line (design §3). UDP sections
    /// carrying list-general (the QUIC sections at the head of each
    /// preset) are deliberately skipped: the UDP failure detector
    /// is out of phase-1 scope, and google-only / ipset-only /
    /// domains-only sections are not general sections.
        fn inject_auto_hostlist(args: Vec<String>, auto_path: &str) -> Vec<String> {
        let auto_arg = format!("--hostlist-auto={}", auto_path);
        let mut out: Vec<String> = Vec::with_capacity(args.len() + 4);
        let mut block: Vec<String> = Vec::new();
        for arg in args {
            if arg == "--new" {
                StrategyBuilder::inject_auto_into_block(&mut block, &auto_arg);
                out.append(&mut block);
                out.push(arg);
            } else {
                block.push(arg);
            }
        }
        StrategyBuilder::inject_auto_into_block(&mut block, &auto_arg);
        out.append(&mut block);
        out
    }

}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_contains_all_builtin_gui_profiles() {
        let items = strategies();
        assert_eq!(items.len(), 41);
        assert_eq!(items.iter().filter(|s| s.engine == "winws").count(), 5);
        assert_eq!(items.iter().filter(|s| s.id.starts_with("kinlay0-")).count(), 26);
        assert_eq!(items.iter().filter(|s| s.engine == "winws2" && !s.id.starts_with("kinlay0-")).count(), 10);
    }

    #[test]
    fn flowseal_and_lua_profiles_use_their_own_engine_cli() {
        let bin = Path::new("C:/FlClashX/zapret");
        let _ = bin;
        let flowseal = StrategyBuilder::build_flowseal_args_inner(
            "flowseal-alt", Path::new("."), Path::new("./lists"),
            TunnelMode::Full, "1024-65535", "1024-65535", None
        );
        assert!(flowseal.iter().any(|a| a.starts_with("--dpi-desync=")));
        assert!(!flowseal.iter().any(|a| a.starts_with("--lua-desync=")));
        let lua = StrategyBuilder::build_lua_preset_args(
            TunnelMode::Full, "1024-65535", "1024-65535",
            Some("--lua-init=@zapret-lib.lua"),
            Some("--lua-init=@strategies/zapret-yt4k.lua"),
            "lists/list-google.txt", "lists/ipset-all.txt", None, false
        );
        assert!(lua.iter().any(|a| a.starts_with("--lua-desync=")));
        assert!(!lua.iter().any(|a| a.starts_with("--dpi-desync=")));
    }

    #[test]
    fn strict_split_flowseal_keeps_only_specialized_list_sections() {
        let args = StrategyBuilder::build_flowseal_args_inner(
            "flowseal-alt",
            Path::new("."),
            Path::new("./lists"),
            TunnelMode::Strict,
            "1024-65535",
            "1024-65535",
            None,
        );

        assert!(args.iter().any(|arg| arg.contains("list-google.txt")));
        assert!(args.iter().any(|arg| arg.contains("--hostlist-domains=")));
        assert!(!args.iter().any(|arg| arg.contains("list-general")));
        assert!(!args.iter().any(|arg| arg.contains("ipset-all.txt")));
        assert!(!args.iter().any(|arg| arg == "--filter-udp=443"));
        assert!(args.iter().any(|arg| arg == "--filter-udp=19294-19344,50000-65535"));
    }

    #[test]
    fn strict_split_lua_keeps_discord_and_google_but_drops_youtube_quic() {
        let args = StrategyBuilder::build_lua_preset_args(
            TunnelMode::Strict,
            "1024-65535",
            "1024-65535",
            Some("--lua-init=@zapret-lib.lua"),
            Some("--lua-init=@strategies/zapret-yt4k.lua"),
            "lists/list-google.txt",
            "lists/ipset-all.txt",
            None,
            false,
        );

        assert!(args.iter().any(|arg| arg == "--new=discord_tcp"));
        assert!(args.iter().any(|arg| arg == "--new=discord_voice"));
        assert!(args.iter().any(|arg| arg == "--new=google_tcp"));
        assert!(!args.iter().any(|arg| arg == "--new=quic"));
        assert!(!args.iter().any(|arg| arg.contains("list-general")));
        assert!(args.iter().any(|arg| arg.contains("list-google.txt")));
    }

    #[test]
    fn full_bypass_lua_keeps_general_and_youtube_quic_sections() {
        let args = StrategyBuilder::build_lua_preset_args(
            TunnelMode::Full,
            "1024-65535",
            "1024-65535",
            Some("--lua-init=@zapret-lib.lua"),
            Some("--lua-init=@strategies/zapret-yt4k.lua"),
            "lists/list-google.txt",
            "lists/ipset-all.txt",
            None,
            false,
        );

        assert!(args.iter().any(|arg| arg == "--new=quic"));
        assert!(args.iter().any(|arg| arg.contains("list-general.txt")));
    }

    #[test]
    fn every_imported_strategy_has_a_registered_blob_mapping() {
        for item in imported_strategies::all() {
            for name in item.blobs {
                assert!(
                    imported_strategies::blob_file(name).is_some()
                        || imported_strategies::is_runtime_blob(name),
                    "{} has no blob mapping for {name}",
                    item.id
                );
            }
        }
    }
}
