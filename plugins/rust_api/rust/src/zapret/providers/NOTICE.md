# Vendored Flowseal provider

The Flowseal strategy provider in `flowseal.rs` is ported from
[geliopat/zapret-ui](https://github.com/geliopat/zapret-ui), file
`src-tauri/src/providers/flowseal.rs` (GPL-3.0).

The provider's parser, argument resolver, catalog format, migration, backup
recovery, custom strategy import, validation, and tests are retained. The
surrounding Tauri application layer is not copied; integration is being
adapted to FlClashX's Rust helper and Flutter UI.
