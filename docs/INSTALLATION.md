# Install Windows VM

[← Home](../README.md) · [Using the app](USAGE.md) · [Troubleshooting](TROUBLESHOOTING.md)

## 1. Prepare your Mac

| Requirement | What to check |
| --- | --- |
| Processor | Apple Silicon (M-series). Intel Macs and running the build under Rosetta are unsupported. |
| macOS | A version supported by Xcode 26+ and Homebrew; macOS 15.6+ recommended. The app's deployment target is macOS 14, but that is not a tested end-to-end build configuration. |
| Development tools | [Xcode 26+](https://developer.apple.com/xcode/resources/). Open it once, finish setup, and select it under **Settings → Locations → Command Line Tools**. |
| Package manager | [Homebrew](https://brew.sh), including its printed `shellenv` instructions. |
| Memory | 16 GB recommended. Guests require at least 4 GB; leave enough for macOS. |
| Storage | At least 100 GB free recommended. The default virtual disk is 80 GB and grows as Windows writes to it. Downloads, Xcode, and build files need additional space. |
| Network | Required for dependencies, Windows media, and Windows first-run setup. |

Apple Developer membership and a paid UTM installation are not required for a local source build. Xcode and Homebrew have their own setup flows; the installer reports a missing prerequisite and stops rather than installing those for you.

## 2. Get the source and install

Open Terminal:

```bash
git clone https://github.com/DrSTEM/WindowsVM.git
cd WindowsVM
bash Install.command
```

The script performs these steps in order:

1. Checks Apple Silicon, Xcode, and the macOS SDK.
2. Installs missing Homebrew `python`, `qemu`, and `swtpm` tools. Homebrew may install or update their dependencies.
3. Downloads pinned **UTM v5.0.9-2** from its official GitHub release into `build/downloads/`.
4. Verifies its SHA-256, Apple notarisation ticket, app signature, signing team, and app version before copying runtime components. A failed verification stops setup.
5. Fetches the pinned CocoaSpice source, builds the app, and runs configuration/display/temporary-disk checks.
6. Installs to `~/Applications/Windows VM.app` and opens it. Any previous app is retained with a timestamped backup name.

No `sudo` is used by these project scripts. They do not install UTM into Applications, download Windows, create a VM, or change an existing guest. The first run downloads substantial dependencies and can take several minutes. Keep Terminal open until it finishes.

The app is ad hoc signed for local use. If macOS blocks launch, inspect the message and the [troubleshooting guide](TROUBLESHOOTING.md). Do not disable Gatekeeper system-wide.

## 3. Download Windows

Use Microsoft's official [Windows 11 ARM64 ISO page](https://www.microsoft.com/en-us/software-download/windows11arm64). Choose the language you want. An x64/AMD64 ISO is not suitable for this project.

Compare the ISO's checksum with the value Microsoft publishes for that exact version and language:

```bash
shasum -a 256 "/path/to/Windows11_ARM64.iso"
```

Keep the ISO somewhere stable until installation is complete. Windows has its own licence and activation requirements; the app does not include a licence or bypass Microsoft's requirements.

## 4. Create and boot a machine

1. Open **Windows VM**, choose **New**, and select the ARM64 ISO.
2. For a 16 GB Mac, start with **4 CPUs, 6 GB RAM, and an 80 GB disk**. On a lower-memory Mac, use 4 GB guest RAM and close other applications. The app validates allocations.
3. For the simplest initial setup, choose **SPICE / Metal (display only)** under **Settings → Devices** before starting. Use the experimental 3D mode only when you intend to install its matching driver.
4. Click **Start**, then click the guest display. Press Space at **Press any key to boot from CD or DVD**. If it times out, restart the VM and try again.
5. Follow Windows Setup. Choose only the VM's new virtual disk as the installation target. Accept Microsoft's terms and enter account or activation details directly in Windows.

## 5. Install network and display drivers

Download the official [UTM Windows Guest Tools ISO](https://getutm.app/downloads/utm-guest-tools-3d-latest.iso), also linked from [UTM's Windows guest support guide](https://docs.getutm.app/guest-support/windows/). This link tracks upstream updates; it is not a pinned project dependency. Read the current upstream driver instructions.

If Windows Setup cannot find a network adapter:

1. Reveal **VM Controls → Options → Media → Mount ISO** and select the tools ISO. If macOS mounted it in Finder, eject that host volume first.
2. In Windows, choose **Install driver** and browse to the disc's `Drivers/NetKVM` folder. Let Windows select its signed ARM64 driver.
3. Continue first-run setup. If Windows requests its installation disc again, remount the Windows ISO. There is one removable drive in this app.

Once on the desktop, mount the tools disc and run its guest-tools installer. For a display-only VM, keep the display-only graphics driver. Install the VirtIO serial driver and SPICE agent to enable automatic resolution changes. Restart Windows when prompted. See [UTM's driver instructions](https://docs.getutm.app/guest-support/windows/) for the experimental 3D driver and migration from an older driver.

## 6. Make it comfortable

Choose **Settings → Preferred resolution → Match Mac Retina**. If automatic resizing is unavailable, use **Windows Settings → System → Display** and select a supported resolution and comfortable scaling. Install drivers before expecting Retina modes.

Shut down Windows, eject the Windows installation ISO if still attached, then start again to check disk-only boot. You can now reopen the app and return to the same saved installation.

Your library defaults to:

```text
~/Library/Application Support/Windows VM/Machines/
```

Each machine is a `.wvm` package. Keep it intact. [Backups and updates →](UPDATING.md)

## Manual build

For individual steps or a custom app destination:

```bash
bash scripts/setup.sh
bash scripts/build-app.sh
bash scripts/test.sh
bash scripts/install-app.sh --destination "$HOME/Applications"
open "$HOME/Applications/Windows VM.app"
```

A local development DMG can be created with `bash scripts/package-local.sh`. It is for your local build, not a signed public installer. [Distribution status →](STATUS.md)
