pub mod channel;
pub mod core;
pub mod game_filter;
pub mod installer;
pub mod ipset;
pub mod providers;
pub mod runtime;
pub mod user_lists;

pub(crate) fn ipset_mode(content: &str) -> &'static str {
    let mut lines = content
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .peekable();

    if lines.peek().is_none() {
        "any"
    } else if lines.any(|line| line == "203.0.113.113/32") {
        "none"
    } else {
        "loaded"
    }
}
