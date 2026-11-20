# Troubleshooting

[← Home](../README.md) · [Install](INSTALLATION.md) · [Report a bug](https://github.com/DrSTEM/WindowsVM/issues/new/choose)

## Setup and build

| Symptom | Next step |
| --- | --- |
| Apple Silicon check fails | Use an M-series Mac and run Terminal outside Rosetta. Intel is unsupported. |
| Xcode or SDK missing | Open Xcode 26+, finish its setup, and select it under **Settings → Locations → Command Line Tools**. `xcodebuild -version` and `xcrun --sdk macosx --show-sdk-version` should succeed. |
| `brew` not found | Install from [brew.sh](https://brew.sh), apply its `shellenv` instructions, and reopen Terminal. |
| Checksum or signing verification fails | Stop. Check connectivity and the pinned [official release](https://github.com/utmapp/UTM/releases/tag/v5.0.9-2). Do not bypass verification. Rerunning setup retries an invalid download. Report a repeatable failure. |
| Notarisation assessment fails offline | Connect to the internet and retry setup; Apple's assessment may require network access. |
| Runtime missing | Run `bash scripts/setup.sh`, then a full `bash scripts/build-app.sh`. |
| Frontend-only build asks for full build | Run the full build once, or after dependency/toolchain changes. |
| App missing or damaged | Rebuild, then run `codesign --verify --deep --strict "build/Windows VM.app"`. Preserve the exact error in a bug report. |
| macOS blocks opening a locally built app | Confirm you built the expected source and signature verification passes. If macOS offers an app-specific **Open Anyway** in Privacy & Security, review it yourself. Do not disable Gatekeeper or remove quarantine recursively. |
| Installer says the app or engine is running | Shut down Windows, then quit Windows VM. Reopen and reconnect if you had chosen Keep Running. The installer never terminates a guest for you. |

To force a clean runtime preparation, use `bash scripts/setup.sh --refresh`. Existing VM packages are not part of this operation. A failed preparation keeps the earlier runtime directory until the new preparation finishes.

## Windows will not boot

- Confirm the installer is **ARM64**, not x64/AMD64, and that its checksum matches Microsoft's value for that exact ISO.
- Click the display and press Space promptly at the CD/DVD boot prompt. If you missed it, restart and try again.
- If Windows is already installed, eject the installation media and start from the saved disk.
- Use the app's **Open Log** action. A failed VM package is preserved for inspection; do not delete it as a first troubleshooting step.

## No network in Windows Setup

Mount the official tools ISO through the app's Media controls, then use Windows' **Install driver** option and browse to `Drivers/NetKVM`. Choose the signed ARM64 driver. Eject any host Finder mount of the ISO first. [Full instructions](INSTALLATION.md#5-install-network-and-display-drivers).

## Small display, black picture, or resize trouble

First try **Reconnect Display**. Check the selected graphics mode and installed guest driver match. Display-only drivers and the experimental 3D driver are different. Follow [UTM's migration instructions](https://docs.getutm.app/guest-support/windows/#directx-graphics) when switching an existing guest to 3D.

Automatic resize needs the SPICE agent and VirtIO serial driver. For an older VM, completely shut down and start again to expose the channel. You can choose a supported mode manually in Windows Display settings. The full guest picture is fitted proportionally, so differing aspect ratios can produce borders.

For a black screen after a driver change, preserve the package and logs. Try the normal Windows recovery tools; do not repeatedly force-stop a guest that might still be writing. Changing graphics hardware without its matching driver can prevent display output.

## Pointer stuck or unexpected keys

Press **Control–Option** to release input. Click the display again to focus it. Turn off **Capture Mouse for Games** for normal desktop use. Command acts as the Windows key while focused. Reconnect the display if input stopped after a console reconnection.

## VM missing from the library

Check whether the app was launched with a custom `--library` path. The default is `~/Library/Application Support/Windows VM/Machines`. Keep each `.wvm` package together. A malformed config is reported and left intact. Do not recreate a machine over the only copy of an existing disk.

## Disk is larger in the app but not Windows

Expansion changes virtual capacity. Extend the Windows partition in Disk Management afterwards. The guest must be stopped for the host expansion. Shrinking is unsupported. Never run `qemu-img` repair or other write operations against a running guest.

## Send a useful bug report

Include your Mac chip, macOS and Xcode versions, app version, graphics mode, expected result, actual result, and steps to reproduce. Include only a short relevant log excerpt after checking it for usernames, local paths, IP addresses, guest content, or other private data. Do not upload a VM disk, installer ISO, account details, or recovery keys. See [security reporting](../SECURITY.md) for sensitive issues.
