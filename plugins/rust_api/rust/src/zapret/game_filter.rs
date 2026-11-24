use crate::zapret::core::GameFilterSettings;
use std::{
    fs,
    path::{Path, PathBuf},
};

const DEFAULT_GAME_FILTER_RANGE: &str = "1024-65535";

fn default_settings() -> GameFilterSettings {
    GameFilterSettings {
        mode: "none".into(),
        tcp_range: DEFAULT_GAME_FILTER_RANGE.into(),
        udp_range: DEFAULT_GAME_FILTER_RANGE.into(),
    }
}

fn settings_path(root: &Path) -> Result<PathBuf, String> {
    let root_metadata = fs::symlink_metadata(root)
        .map_err(|error| format!("Cannot inspect Flowseal directory: {error}"))?;
    if root_metadata.file_type().is_symlink() || !root_metadata.is_dir() {
        return Err("Flowseal installation directory must be a real directory".into());
    }
    let root = fs::canonicalize(root)
        .map_err(|error| format!("Cannot resolve Flowseal directory: {error}"))?;

    let utils = root.join("utils");
    let utils_metadata = fs::symlink_metadata(&utils)
        .map_err(|error| format!("Cannot inspect Flowseal utils directory: {error}"))?;
    if utils_metadata.file_type().is_symlink() || !utils_metadata.is_dir() {
        return Err("Flowseal utils path must be a real directory".into());
    }
    let utils = fs::canonicalize(&utils)
        .map_err(|error| format!("Cannot resolve Flowseal utils directory: {error}"))?;
    if !utils.starts_with(&root) {
        return Err("Flowseal utils directory resolves outside the installation".into());
    }

    let path = utils.join("game_filter.enabled");
    match fs::symlink_metadata(&path) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            Err("Flowseal game filter settings must not be a symbolic link".into())
        }
        Ok(metadata) if !metadata.is_file() => {
            Err("Flowseal game filter settings are not a regular file".into())
        }
        Ok(_) => {
            let canonical = fs::canonicalize(&path)
                .map_err(|error| format!("Cannot resolve Flowseal game filter settings: {error}"))?;
            if canonical.parent() != Some(utils.as_path()) {
                return Err("Flowseal game filter settings escape the utils directory".into());
            }
            Ok(canonical)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(path),
        Err(error) => Err(format!("Cannot inspect Flowseal game filter settings: {error}")),
    }
}

fn valid_range(value: &str) -> bool {
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

fn parse_settings(content: &str) -> GameFilterSettings {
    let content = content.trim_start_matches('\u{feff}').trim();
    if content.is_empty() {
        return default_settings();
    }

    // Flowseal <= 1.10.2 stored a single mode word. Keep it readable.
    if !content.contains('=') {
        return GameFilterSettings {
            mode: match content.to_ascii_lowercase().as_str() {
                "all" | "tcp" | "udp" => content.to_ascii_lowercase(),
                _ => "none".into(),
            },
            ..default_settings()
        };
    }

    let mut mode = None;
    let mut tcp_range = None;
    let mut udp_range = None;
    for line in content.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        match key.trim().to_ascii_lowercase().as_str() {
            "mode" => mode = Some(value.trim().to_ascii_lowercase()),
            "tcp" => tcp_range = Some(value.trim().to_owned()),
            "udp" => udp_range = Some(value.trim().to_owned()),
            _ => {}
        }
    }

    GameFilterSettings {
        mode: match mode.as_deref() {
            Some("all") => "all",
            Some("tcp") => "tcp",
            Some("udp") => "udp",
            _ => "none",
        }
        .into(),
        tcp_range: tcp_range
            .filter(|range| valid_range(range))
            .unwrap_or_else(|| DEFAULT_GAME_FILTER_RANGE.into()),
        udp_range: udp_range
            .filter(|range| valid_range(range))
            .unwrap_or_else(|| DEFAULT_GAME_FILTER_RANGE.into()),
    }
}

pub fn read(root: &Path) -> Result<GameFilterSettings, String> {
    let path = settings_path(root)?;
    match fs::read_to_string(&path) {
        Ok(content) => Ok(parse_settings(&content)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(default_settings()),
        Err(error) => Err(format!("Cannot read Flowseal game filter settings: {error}")),
    }
}

pub fn save(root: &Path, settings: &GameFilterSettings) -> Result<(), String> {
    if !matches!(settings.mode.as_str(), "none" | "all" | "tcp" | "udp") {
        return Err("Unsupported Flowseal game filter mode".into());
    }
    if !valid_range(&settings.tcp_range) || !valid_range(&settings.udp_range) {
        return Err("Flowseal game filter must contain valid TCP and UDP port ranges".into());
    }

    let path = settings_path(root)?;
    let mode = if settings.mode == "none" {
        "disabled"
    } else {
        settings.mode.as_str()
    };
    let content = format!(
        "mode={mode}\r\ntcp={}\r\nudp={}\r\n",
        settings.tcp_range, settings.udp_range
    );
    fs::write(path, content)
        .map_err(|error| format!("Cannot save Flowseal game filter settings: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static NEXT_DIRECTORY: AtomicUsize = AtomicUsize::new(0);

    struct TestRoot(PathBuf);

    impl TestRoot {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "flowseal-game-filter-{}-{}",
                std::process::id(),
                NEXT_DIRECTORY.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(root.join("utils")).unwrap();
            Self(root)
        }
    }

    impl Drop for TestRoot {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn missing_settings_use_flowseal_defaults() {
        let root = TestRoot::new();
        assert_eq!(
            read(&root.0).unwrap(),
            GameFilterSettings {
                mode: "none".into(),
                tcp_range: "1024-65535".into(),
                udp_range: "1024-65535".into(),
            }
        );
    }

    #[test]
    fn reads_legacy_mode_and_current_settings_formats() {
        assert_eq!(
            parse_settings("tcp"),
            GameFilterSettings {
                mode: "tcp".into(),
                tcp_range: "1024-65535".into(),
                udp_range: "1024-65535".into(),
            }
        );
        assert_eq!(
            parse_settings("\u{feff}mode=disabled\r\ntcp=80,443\r\nudp=443\r\n"),
            GameFilterSettings {
                mode: "none".into(),
                tcp_range: "80,443".into(),
                udp_range: "443".into(),
            }
        );
        assert_eq!(
            parse_settings("mode=udp\ntcp=invalid\nudp=40000-50000"),
            GameFilterSettings {
                mode: "udp".into(),
                tcp_range: "1024-65535".into(),
                udp_range: "40000-50000".into(),
            }
        );
    }

    #[test]
    fn saves_disabled_mode_without_losing_port_ranges() {
        let root = TestRoot::new();
        let settings = GameFilterSettings {
            mode: "none".into(),
            tcp_range: "80,443".into(),
            udp_range: "20000-30000".into(),
        };
        save(&root.0, &settings).unwrap();
        assert_eq!(read(&root.0).unwrap(), settings);
        assert_eq!(
            fs::read_to_string(root.0.join("utils/game_filter.enabled")).unwrap(),
            "mode=disabled\r\ntcp=80,443\r\nudp=20000-30000\r\n"
        );
    }

    #[test]
    fn rejects_invalid_modes_and_port_ranges() {
        let root = TestRoot::new();
        for mode in ["disabled", "all;format c:", "unknown"] {
            let settings = GameFilterSettings {
                mode: mode.into(),
                tcp_range: "1024-65535".into(),
                udp_range: "1024-65535".into(),
            };
            assert!(save(&root.0, &settings).is_err());
        }
        for range in ["0", "65536", "443-", "-443", "443-80", "80,,443", "80;exit"] {
            let settings = GameFilterSettings {
                mode: "all".into(),
                tcp_range: range.into(),
                udp_range: "443".into(),
            };
            assert!(save(&root.0, &settings).is_err(), "{range}");
        }
    }
}
