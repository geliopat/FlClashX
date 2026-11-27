# Third-party Go modules

## Mihomo

`mihomo` is a Git submodule pinned to the reviewed FlClashZ core commit. Initialize it with `git submodule update --init` after checkout. The root Go module selects it through a local replacement.

## sing-tun

Use the upstream Go module `github.com/metacubex/sing-tun` (currently v0.4.29, as required by Mihomo). No local copy or replacement is maintained. Its checksums are pinned in `core/go.sum`. The removed local change only reaped the macOS `dscacheutil` child process and is unnecessary for the Windows target. When updating Mihomo, reconcile the root indirect dependency and checksums with the new module graph.
