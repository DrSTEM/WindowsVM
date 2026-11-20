# Status and verification

[← Home](../README.md) · [Changelog](../CHANGELOG.md) · [Third-party release work](../ThirdParty/README.md)

## Release model

**0.6.0 is an early-access source release.** Clone the repository and build on your Mac. There is no prebuilt public app or DMG. Local builds are ad hoc signed; this project has not established Developer ID signing, notarisation, or a complete redistribution package for every bundled dependency.

The source build requires Apple Silicon, Xcode 26+ and Homebrew. The app has a macOS 14 deployment target, but end-to-end testing has been on a newer M-series Mac. Earlier macOS versions, other M-series chips, and low-memory hosts are not yet covered by a compatibility test matrix.

## Earlier manual app validation

During development on an Apple M5 with 16 GB RAM, macOS 27.2.1 and Xcode 27.2, the following were observed in the native application:

- A genuine Windows 11 ARM64 installer booted with HVF, UEFI, and virtual TPM, and Windows installed to a persistent virtual disk.
- The saved installation booted again from disk and reached a signed-in desktop. Keyboard and pointer input worked; Calculator, a browser HTTPS page, and a downloaded file were exercised.
- Normal shutdown/start, pause/resume, media mounting/ejecting, display reconnect, native full screen, and reconnecting after keeping the guest running were exercised.
- A 3024 × 1964 guest desktop was displayed. Later SPICE/Metal and experimental 3D driver work reached the Windows lock screen and desktop; Windows reported Direct3D acceleration and an active 120 Hz display mode.

These are observations on one development machine, not a broad compatibility or performance claim. A 120 Hz mode does not establish 120 FPS rendering. Game installation, gameplay compatibility, and input-to-photon latency were not benchmarked.

## Public checkout verification — 20 November 2026

A separate, empty checkout was used to exercise the public build route, without using the development `Runtime/` or build products:

- Downloaded the pinned official UTM DMG; verified its published SHA-256, notarisation ticket, app signature, expected signing team, and version.
- Prepared the runtime framework closure, firmware, render worker, and Homebrew tools locally.
- Fetched the pinned CocoaSpice revision and built the native app from source.
- Verified the ad hoc signed bundle with `codesign --verify --deep --strict`.

The validation deliberately leaves the existing installed app and running guest alone. It does not repeat a Windows installation or claim a fresh-machine manual acceptance run. All **28 core and temporary-disk checks passed**. No live guest control or storage mutation was part of this publication run.

## Automated coverage

`bash scripts/test.sh` checks configuration persistence and validation, display geometry and partial frame delivery, input ordering, QEMU device arguments and private transports, and real temporary QCOW2 creation, growth, and integrity. Optional live QMP checks verify a named running VM read-only and are not required by CI.

`python3 scripts/check-repo.py` checks tracked publication boundaries, common credential patterns, personal absolute paths, unexpected binaries, and relative documentation links. It is a useful guard, not a complete secret scanner or security audit.

GitHub Actions is configured to run source/documentation checks and core tests on temporary disks. At publication, its runners could not start due to an account-level restriction; the successful results above are local verification. Hosted CI does not boot Windows or validate experimental graphics. Build warnings inherited from the pinned CocoaSpice headers/implementation are not treated as successful graphics tests.

## Current limitations

| Area | Current position |
| --- | --- |
| Hosts and guests | Apple Silicon host, Windows ARM64 guest |
| Graphics | SDR output; experimental Direct3D 11 with matching guest driver; no measured game compatibility or FPS |
| Integration | No shared clipboard, shared folders, drag and drop, guest audio, or separate Windows application windows |
| Lifecycle | No snapshots or saved suspend/resume state; pause/resume is in memory |
| Virtualisation | No nested virtualisation support |
| Distribution | Local source builds only; public signed binary release work remains |
| Reproducibility | UTM/CocoaSpice pinned; Homebrew dependency versions depend on preparation date |

If you hit a problem, use the [troubleshooting guide](TROUBLESHOOTING.md) and include a minimal reproduction in an issue. Keep private data out of reports.
