# Windows CI build modes

Use **Zapret Windows validation** → Run workflow on the development branch. Choose:
- fast (default): tool/dependency caches, bounded local sccache and verified native outputs.
- full: run native build commands again; Flutter/Go/Cargo dependency and pinned archive caches remain available.
- clean: no GitHub Actions cache restore/save in validation; no sccache. Stable release always uses clean and keeps its existing explicit publication gate.

The existing setup build hook builds Mihomo first; Helper embeds the Core SHA-256. Separate exact cache keys include runner image, toolchain, source, build config and hook code; Helper additionally depends on Core identity. The hook still independently checks its own fingerprint and output SHA-256 before reuse. Tests, analyzer, ZIP/EXE packaging, installer and portable smoke checks remain mandatory. No Flutter build tree, signed manifest, secrets or release package is cached.

Zapret/Flowseal archives are verified against their existing pinned SHA-256 on every use; raw files from the pinned strategy commit are still downloaded and staged each run. MSVC uses the preinstalled Windows runner toolchain; C++ compiler caching is not enabled for the Visual Studio generator. Rust incremental mode is disabled with sccache; its local store is capped at 1 GiB. Cargo registry is cached separately to avoid redundant target caches.

Review Actions → Caches for storage usage; GitHub eviction and branch scope apply. Do not increase the paid cache quota. Cache-hit output is not proof of native reuse: check the setup hook log for Cache hit / Rebuilding. Compare cold and warm runs on the same branch, then modify only UI, Helper, and Core in separate validation runs. Never publish a release from these tests.
