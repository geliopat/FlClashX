# Independent Windows core releases

The core executable is **FlClashCore.exe**, built from the host adapter at
`core/cmd/core` in a pinned FlClashZ source commit and a pinned Mihomo gitlink.
The stock Mihomo CLI cannot replace it. Keep one Go module graph and the
existing core build flags; do not introduce a second copy of the adapter.

## Release identity and compatibility

Use an independent version `v<major>.<minor>.<patch>-z.<revision>`, where the
first three numbers identify the upstream Mihomo version and the final number
is a positive core release revision. Use release tags `flclashz-core-<version>`
to avoid triggering the upstream Mihomo v* release workflow. Version and SHA
are independent of the Flutter application version.

`FlClashCore.exe --core-info` prints a single JSON object and exits without
starting the IPC server. It reports product, version, mihomoVersion,
engineRevision, hostRevision, ipcRevision, os and arch. Standalone release
builds inject version and both SHAs at link time. IPC revision 1 is the
candidate baseline, not evidence of verified backwards compatibility.
Increment it for breaking changes; additive changes require contract tests.

## Update trust and transaction

Use a distinct signed core manifest domain; sign version, engine and host
SHAs, IPC revision, target, asset name, size and SHA-256. Pin the signing public
key in the trusted client/Helper; a manual HTTPS manifest URL can mirror the
same signed artifacts, not bypass trust. Local import also requires an
authenticated manifest. Reject unsigned or incompatible executables before
execution, including before probing --core-info. Refuse downgrade unless a
previous trusted local version is explicitly restored.

A core updater must coordinate exclusively with the existing lifecycle owner.
Verify bytes before stopping the active core, stage safely, retain the last
verified binary and manifest, replace both as a journaled transaction, and
check initialization/config/listeners/IPC on restart. Restore both on failure.
The privileged Helper must verify the signed identity and hash itself before
launch, restrict paths and reject reparse points; a user-writable hash file
alone must never authorize a privileged executable. Recover interrupted
transactions at startup. Preserve existing bundled manifest fallback.

Default source: https://github.com/geliopat/Clash.Meta/releases/latest/download/core-manifest.json
(actual availability begins only after the first independently approved release).
Custom manifest URLs and local packages use the same trust rules. No automatic
installation; manual check and confirmation. No arbitrary URL executable.

## Progress

- Core metadata command and contract test implemented; not compiled.
- Independent workflow, signer and guarded patch replay are implemented in the core repository (`FlClashZ` branch). The default branch still needs explicit configuration before workflow_dispatch. No build was dispatched.
- Client-side signed manifest parsing, compatibility checks, numeric version ordering and staged binary hashing are implemented with regression fixtures. Not yet wired to downloads or lifecycle. The signing key must be provisioned before publication.
- Trusted-key provisioning, transaction, privileged Helper verification and update integration
  remain open; do not mark independent updates ready until implemented and
  accepted.
