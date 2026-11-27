# Native Mihomo integration: v1.1.5

Status: staged core candidate, client integration pending. No build or validation workflow may run until agreed implementation and static review are complete.

Checkpoint: `archive/v1.1.5-before-core-integration` at `64b3a6a1f8285f32822eceb5eac192eb0e9a381f`. Keep this branch unchanged for rollback.

Core repository: https://github.com/geliopat/Clash.Meta
- Clean Mihomo v1.19.34: `mihomo-upstream`, `0455d0d28c4526937380505153e65a843d8612e8`
- Original FlClash fork reference: `FlClash`, `fea29264f541cba170bb8b7dda84697aa1dbcc3b`
- FlClashZ candidate: `FlClashZ`, `5a55a1bb96d9b62a73c5463f333c5afb1f8b3762`
- Provenance and replay guide: https://github.com/geliopat/Clash.Meta/blob/5a55a1bb96d9b62a73c5463f333c5afb1f8b3762/docs/flclashz-patch-stack.md

## Implementation order

1. Review candidate patch dependencies and compile compatibility statically; complete remaining selected core fixes. Do not copy unrelated platform, TLS or listener changes.
2. Pin a core revision by commit, preserving root module's local sing-tun replacement. Prefer a pinned Git submodule/local Go module replacement; update only the checkout/build inputs that need it. Do not update production releases.
3. Replace host-side duplicate accounting with native counters and request events, preserving early inbound closure and probe-route settlement. Move DNS and URL-test notifications into hooks, with the same bounded queues and inactive-host behavior. Use native route resolution and network resets, preserve route epoch checks and held picks. Do not count bytes twice or run two health/geo schedulers. Keep existing IPC messages compatible; version new fields explicitly and preserve unknown ones. Add contract regressions.
4. Adapt the FlClash connection log, typed numeric samples, incremental rows and filters to the existing FlClashZ UI. One lifecycle-aware publisher for traffic and active connection statistics; controls, sidebar, dashboard and details use projections from the same state.
5. Merge optional general overrides with the existing per-key ownership, inheritance, explicit values, resource URLs/paths, protected TUN settings and managed Remnawave locks. Retain old migration and recovery compatibility.
6. Complete the rest of docs/next-release-acceptance.md, static review, and only then user-authorized Windows testing. No stable release without explicit approval.

Preserve all existing FlClashZ features, UI, Helper security, Zapret2 strategy and recovery behavior. Source-code work is not equivalent to acceptance. No client dependency change has been made yet.
