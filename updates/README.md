# Zapret component catalog (schema 1)

The Windows client reads zapret-components-v1.json from the FlClashZ development branch over HTTPS. The repository is a trust root; the catalog is not independently signed. Only publish versions verified with the current Helper CLI and shared WinDivert runtime. Archive SHA256 values must be taken from the official release asset, and Git object hashes and exact lengths from the pinned source trees.

Zapret2 replaces winws2 and shared Windows runtime files. Flowseal replaces winws only, as the existing package uses the Zapret2 runtime. Do not publish a Flowseal release requiring incompatible dependencies. Lua files must come from the adapted FlClashZ tree, not blindly from the GUI upstream. Payloads come from the pinned GUI revision. All names are allowlisted in the client.

BAT imports are compiled into Rust argument templates; this schema does not replace or execute them. Updating those templates requires a Helper build. User lists and imported files are not overwritten.

Component update uses the application's current Windows user permissions. It does not add an elevated file-writing endpoint. Installed files must be writable. Updates stage before stopping Zapret, keep backups, and attempt rollback on failure. The current implementation does not automatically recover a transaction interrupted by power loss.

The catalog and client should be updated together when the allowlisted file layout or Helper ABI changes.
