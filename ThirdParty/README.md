# Third-party components

The MIT license at the repository root applies to original Windows VM code and documentation. Dependencies keep their upstream licences. This source repository contains notices and build adaptations, not prepared runtime binaries, Windows media, guest tools, or VM disks.

## Build inputs

| Component | Source / role | Licensing information |
| --- | --- | --- |
| UTM runtime selection | [UTM v5.0.9-2](https://github.com/utmapp/UTM/tree/v5.0.9-2): QEMU ARM64 framework, rendering worker, dependency frameworks, firmware | Multiple upstream licences; UTM's Apache-2.0 UI licence does not replace component licences |
| QEMU | [UTM QEMU v10.0.12-utm](https://github.com/utmapp/qemu/releases/tag/v10.0.12-utm) | GPL and per-component notices; see `QEMU-COPYING.txt` and upstream source |
| CocoaSpice | [Pinned revision](https://github.com/utmapp/CocoaSpice/tree/e239fab0828ebafc3a5a973fa84039400d7ac703) | Apache-2.0; fetched and built locally, upstream LICENSE copied into the app |
| DXMT | [UTM fork](https://github.com/utmapp/dxmt/tree/1fe2e752c98207518a99c9322482f63ebb9f0232) | Consult its upstream licence and dependencies |
| SPICE, GLib, ANGLE, graphics dependencies | Framework dependency closure from the pinned UTM release | Separate upstream licences, including LGPL and permissive components |
| EDK2 / firmware | Firmware resources from UTM | Preserved `edk2-licenses.txt` and upstream notices |
| qemu-img, swtpm, libraries | Official Homebrew formulae and their installed dependency closure | GPL/BSD/LGPL/permissive components; see the recorded manifest and upstream formulae |

`utm-source-manifest.sh` preserves UTM's source-version inventory. `HomebrewNotices/` and `homebrew-notice-inventory.json` preserve the notices available during the initial development build. That inventory is historical, not a complete statement about whatever Homebrew installs today. `Runtime/manifest.json` records the files used by a particular local preparation.

`scripts/build-spice.py` records the source adaptations for early firmware display, display reconnection, idle rendering, shader compilation, and module layout. It extracts the pinned upstream source on every full build and preserves the upstream LICENSE. `scripts/prepare-runtime.py` copies runtime components, rewrites the render-worker rpath and Homebrew library load paths, and ad hoc signs modified helpers. It does not copy UTM's interface or artwork. Proprietary D3DMetal components are excluded by the runtime dependency traversal.

## Public binary release work remains

A locally built app/DMG is a development artifact. The repository does not yet contain the complete set of component notices, corresponding-source archives, and rebuild/relink materials required for redistributing all bundled dependencies. A public binary release must complete those materials for the exact shipped versions and establish Developer ID signing and notarisation. No prebuilt app or runtime is attached to the public source release.

Windows and the guest-tools ISO are downloaded separately from Microsoft and UTM. Windows requires its own licence and activation. No trademark licence or affiliation is implied.
