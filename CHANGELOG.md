# Changelog

## 0.6.0 — 20 November 2026

First public source release of Windows VM.

- Native SwiftUI/AppKit library and console for Windows 11 ARM64 on Apple Silicon.
- QEMU/HVF engine, persistent QCOW2 storage, UEFI firmware, and virtual TPM 2.0.
- SPICE console with Metal presentation, Retina-aware sizing, relative pointer capture, and a VNC compatibility path.
- Floating VM controls, power/media actions, reconnect, full screen, settings, disk expansion, import/export, and duplication.
- Experimental Direct3D 11 runtime path through DXMT and a separate rendering worker.
- Guided local installer, verified runtime preparation, update helper, app backups, and public setup/use/architecture/troubleshooting documentation.

This release provides source and local build tooling. There are no public app/DMG assets. See [status](docs/STATUS.md) for tested behaviour and limitations.
