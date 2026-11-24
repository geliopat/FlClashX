# Source attribution: geliopat/zapret-ui

Parts of the Windows Zapret / Flowseal integration are adapted from
[`geliopat/zapret-ui`](https://github.com/geliopat/zapret-ui), which is
licensed under the MIT License.

Adapted source areas include:

- `src-tauri/src/providers/flowseal.rs`: Flowseal strategy provider,
  BAT parsing, argument resolution, strategy catalog, migrations,
  custom-strategy import and validation.
- `src-tauri/src/core/channel.rs`, `src-tauri/src/core/installation.rs`
  and related core modules: signed stable-channel resolution, artifact
  verification, safe extraction, transactional installation and rollback.
- `src-tauri/src/lib.rs`: Game Filter settings compatibility and persistence,
  IPSet mode handling and update validation, user-list validation,
  import/export and backup/restore behavior.
- `src-tauri/src/ipset.rs`: IPSet list comparison and install-if-changed logic.
- `src/features/filters.js` and `src/features/user-lists.js`: corresponding
  filter and user-list workflows adapted to FlClashX's Flutter UI.

The FlClashX integration replaces the source application's Tauri commands,
window lifecycle and service layer with FlClashX's Flutter/Rust bridge and
Windows process ownership model. The source repository's unrelated application
features are not included.

## MIT License

Copyright (c) 2026 larrriiin

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
