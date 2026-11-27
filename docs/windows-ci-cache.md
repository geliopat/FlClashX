# Windows CI build modes

Use **Zapret Windows validation** → Run workflow on the development branch. Choose:
- fast (default): tool/dependency caches, bounded local sccache and verified native outputs.
- full: run native build commands again; Flutter/Go/Cargo dependency and pinned archive caches remain available.
- clean: no GitHub Actions cache restore/save in validation; no sccache. Stable release always uses clean and keeps its existing explicit publication gate.

A distinct candidate SHA checked out by the workflow uses Clean to avoid populating shared caches from another revision.

The existing setup build hook builds Mihomo first; Helper embeds the Core SHA-256. Separate exact cache keys include runner image, toolchain, source, build config and hook code; Helper additionally depends on Core identity. The hook still independently checks its own fingerprint and output SHA-256 before reuse. Tests, analyzer, ZIP/EXE packaging, installer and portable smoke checks remain mandatory. No Flutter build tree, signed manifest, secrets or release package is cached.

Zapret/Flowseal archives are verified against their existing pinned SHA-256 on every use; raw files are cached by Git blob identity obtained independently from the pinned commit's tree. If the tree cannot be queried, raw files are downloaded without using that cache. Assets are staged anew every run. MSVC uses the preinstalled Windows runner toolchain; C++ compiler caching is not enabled for the Visual Studio generator. Rust incremental mode is disabled with sccache; its local store is capped at 1 GiB. Cargo registry is cached separately to avoid redundant target caches.

Review Actions → Caches for storage usage; GitHub eviction and branch scope apply. Do not increase the paid cache quota. Cache-hit output is not proof of native reuse: check the setup hook log for Cache hit / Rebuilding. Compare cold and warm runs on the same branch, then modify only UI, Helper, and Core in separate validation runs. Never publish a release from these tests.

## Measured validation (2026-11-27)

- Fast cold: 21:00, [run 45977767390 attempt 1](https://github.com/geliopat/FlClashZ/actions/runs/45977767390/attempts/1).
- Fast warm: 12:30, [attempt 2](https://github.com/geliopat/FlClashZ/actions/runs/45977767390/attempts/2), 110/124 cacheable Rust requests hit; all four custom caches restored.
- Clean: 20:02, [run 45983064821](https://github.com/geliopat/FlClashZ/actions/runs/45983064821); all custom cache restore/save steps skipped. The temporary test branch selected Clean on push; application sources were unchanged.

All three runs passed tests, packaging and installer/portable smoke checks. Full and component-specific invalidation experiments remain to be run independently. Caches are branch-scoped; the first run on the integration branch may be cold.
