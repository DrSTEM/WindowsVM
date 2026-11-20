# Update, back up, and roll back

[← Home](../README.md) · [Install](INSTALLATION.md) · [Troubleshooting](TROUBLESHOOTING.md)

## Before updating

1. Save work and **shut down Windows**. A paused guest is still running.
2. Quit Windows VM. If you previously chose **Keep Running**, reopen the app and shut down the guest first.
3. Copy each whole `.wvm` package to a backup location while it is stopped. The default library is `~/Library/Application Support/Windows VM/Machines/`; a custom `--library` location takes precedence.
4. Read the [changelog](../CHANGELOG.md) for any migration or driver requirements.

The installer and update helper stop if a WindowsVM frontend or VMEngine process is running. They do not force-stop guests. Application backups are not backups of Windows.

## Update a standard checkout

In the source folder you cloned:

```bash
bash scripts/update.sh
```

This requires the `main` branch and a clean tracked working tree. It runs `git pull --ff-only`, prepares dependencies, performs a full build, runs the checks, and installs the app to `~/Applications`. Uncommitted source changes are preserved by stopping before the pull. If the branch has diverged, Git stops for you to resolve it.

The setup helper reuses a completed runtime when its lock file matches. A changed runtime lock triggers a newly verified preparation. Homebrew tool versions are those available when preparation happens; they are recorded in `Runtime/manifest.json` and are not fully reproducible across dates. To intentionally refresh the same pinned runtime with current installed tools:

```bash
bash scripts/setup.sh --refresh
```

Then run the full build, tests, and installer. **Windows Update** inside the guest and **guest-tools updates** are separate from app updates. Back up before changing graphics drivers.

## Manual update or custom destination

```bash
git pull --ff-only
bash scripts/setup.sh
bash scripts/build-app.sh
bash scripts/test.sh
bash scripts/install-app.sh --destination "$HOME/Applications"
```

These commands do not edit your VM library. Reopen the app and start Windows afterwards.

## Roll back the app

Installation keeps an existing app beside the new one as `Windows VM.backup-<timestamp>-<process>.app`. With Windows shut down and both app instances quit, move the new app aside in Finder and rename the chosen backup to **Windows VM.app**. Keep your VM backup until the update is working.

To rebuild a particular source release, use a separate checkout so your normal `main` checkout remains available:

```bash
git clone --branch v0.6.0 https://github.com/DrSTEM/WindowsVM.git WindowsVM-0.6.0
cd WindowsVM-0.6.0
bash Install.command
```

Older apps may not understand future configuration formats. If a release changes the VM format, restore its matching whole-package backup as well. Never replace a disk or TPM state while a guest is running.

## Developer iterations

After a full build, `bash scripts/build-app.sh --frontend` rebuilds Swift and reuses CocoaSpice, the engine, and runtime. A running VM can be reconnected when those bundled components are identical. Use a full build when the runtime lock, CocoaSpice build inputs, engine, or toolchain changes. The normal installer deliberately requires a shutdown; managing a live development replacement is a separate workflow.

## Remove the app

Shut down your guests and quit the app. Move the app and any app backups from `~/Applications` to Trash. Your VM library remains separate; copy anything you want to keep before removing it. Homebrew tools may be used by other software, so app removal does not uninstall them.
