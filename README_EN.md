<div align="center">

<img src="assets/images/icon.png" alt="FlClashZ" width="100">

# FlClashZ

**Mihomo + Zapret for Windows**

[![Windows x64](https://img.shields.io/badge/Windows-x64-0078D4?style=flat-square&logo=windows)](https://github.com/geliopat/FlClashZ/releases/latest)
[![Release](https://img.shields.io/github/v/release/geliopat/FlClashZ?style=flat-square)](https://github.com/geliopat/FlClashZ/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/geliopat/FlClashZ/total?style=flat-square)](https://github.com/geliopat/FlClashZ/releases)
[![License](https://img.shields.io/github/license/geliopat/FlClashZ?style=flat-square)](LICENSE)

[![Windows validation](https://github.com/geliopat/FlClashZ/actions/workflows/zapret-windows-validation.yml/badge.svg?branch=fix%2Fzapret2-stability)](https://github.com/geliopat/FlClashZ/actions/workflows/zapret-windows-validation.yml)

[Русский](README.md) · **English** · [中文](README_ZH.md)

</div>

FlClashZ is an independent fork of [FlClashX](https://github.com/pluralplay/FlClashX), combining a Mihomo-based proxy client with integrated Zapret2/Flowseal management. Its release target is Windows x64, with support for Remnawave subscriptions. It is not an official client of the upstream projects.

[Download](#download) · [Features](#features) · [Provider integration](#provider-integration) · [Updates](#updates) · [Build](#build-from-source)

## Download

Official packages are published on [GitHub Releases](https://github.com/geliopat/FlClashZ/releases). The asset links become available once the corresponding stable release is published.

| Edition | Format | Download |
| --- | --- | --- |
| Windows x64 installer | EXE | [FlClashZ-windows-amd64-setup.exe](https://github.com/geliopat/FlClashZ/releases/latest/download/FlClashZ-windows-amd64-setup.exe) |
| Windows x64 portable | ZIP | [FlClashZ-windows-amd64.zip](https://github.com/geliopat/FlClashZ/releases/latest/download/FlClashZ-windows-amd64.zip) |

Use the installer for normal use and built-in update installation. For portable use, extract the ZIP to its own directory and launch `FlClashZ.exe`; update it manually. Windows 10/11 x64 is the current target. Other inherited platforms are not current FlClashZ release targets.

## Features

| Mihomo | Zapret |
| --- | --- |
| Subscription and local profiles; YAML editor | Integrated Zapret2 and Flowseal management |
| TUN, system proxy and routing rules | Start, stop and restart controls |
| Proxy groups, DNS, connections and logs | Bundled Lua/BAT strategies and import |
| Automatic latency checks for nodes and groups | Automatic strategy selection, history and fallback |
| Overrides, scripts and backups | Availability diagnostics and list updates |

Mihomo handles proxy routing and DNS. Zapret follows the selected mode and the strategy's capabilities. STRICT SPLIT, FULL BYPASS, linked startup, automatic selection and recovery are configurable.

Windows interface: customizable dashboard, themes, glass cards and acrylic tray menu; separate Mihomo and Zapret controls, dedicated application data, Helper service and import protocols. The disclaimer acceptance is stored with application settings.

## Provider integration

Remnawave subscription headers, HWID and YAML fields `serverDescription`, `server-description` and `groupDescription` are supported when provided by the panel. The primary custom header prefix is `flclashz-`; inherited `flclashx-*` headers remain compatible, with the new names taking precedence.

```http
flclashz-view: app.theme:dark;app.glass:standard
flclashz-widgets: profiles,networkSpeed,networkTakeover,zapret
flclashz-zapret: autostart,mode:fullbypass,autofallback,autotune,tunemode:fast,tuneonfail
```

- [All subscription headers (Russian)](docs/headers.md)
- [Zapret configuration headers (Russian)](docs/flclashz-zapret-headers.md)

Installed-client import URI:

```text
flclashz://install-config?url=<URL-encoded subscription URL>
```

## Updates

Stable releases use tags such as `v1.0.1`. The default stable update source is the signed [latest manifest](https://github.com/geliopat/FlClashZ/releases/latest/download/manifest.json). It includes the version, asset URLs, SHA-256 hashes and an Ed25519 signature. Version-specific manifests are available under `releases/download/v<version>/manifest.json`.

The installer is designed to stop the running application before replacing files and preserve settings. Windows CI checks portable startup, installation, upgrade while running and FlClashX isolation before release publication.

## Build from source

Windows prerequisites: Flutter 3.47.6, Go 1.27.1, Rust (rustup), Visual Studio with Desktop development with C++, and Inno Setup 6.

```powershell
git clone --branch fix/zapret2-stability https://github.com/geliopat/FlClashZ.git
cd FlClashZ
flutter pub get
./scripts/setup_zapret.ps1
dart setup.dart windows --env stable --arch amd64 --targets zip,exe -v
```

Packages are written to `dist/`. Signed-update verification in local builds requires a trusted public key via `FLCLASHZ_UPDATE_PUBLIC_KEY`. The private signing key belongs in GitHub Actions secrets, never in the source tree.

[Windows validation](https://github.com/geliopat/FlClashZ/actions/workflows/zapret-windows-validation.yml) · [Release workflow](https://github.com/geliopat/FlClashZ/actions/workflows/flclashz-release.yml)

## Credits and license

Fork maintained by [geliopat](https://github.com/geliopat). Upstream authors and licenses remain credited:

- [FlClashX](https://github.com/pluralplay/FlClashX) — upstream client, pluralplay.
- [FlClash](https://github.com/chen08209/FlClash) — original client, chen08209.
- [Mihomo](https://github.com/MetaCubeX/mihomo)
- [Zapret2](https://github.com/bol-van/zapret2)
- [Flowseal](https://github.com/Flowseal/zapret-discord-youtube)
- [zapret2-gui](https://github.com/mqclass/zapret2-gui) / [strategy fork](https://github.com/geliopat/zapret2-gui)

[GPL-3.0](LICENSE). Third-party components retain their own licensing terms.

[Issues](https://github.com/geliopat/FlClashZ/issues) · [Release history](https://github.com/geliopat/FlClashZ/releases)

Star the repository if you find it useful.
