# Contributing

Thanks for helping improve Windows VM. Small, focused changes are easiest to review. For a substantial feature or driver/runtime change, open an issue describing the behaviour first.

## Build and check

Use an Apple Silicon Mac with Xcode 26+ and Homebrew. From a fresh checkout:

```bash
bash scripts/setup.sh
bash scripts/build-app.sh
bash scripts/test.sh
python3 scripts/check-repo.py
```

The tests use temporary disks and remove their own temporary files. Optional `WVM_TEST_QMP_DIRECTORY` and `WVM_TEST_QMP_NAME` variables enable read-only checks of a specific running VM. They are unnecessary for routine checks. Never point a write or repair operation at a live disk.

For Swift-only iterations after the full build, use `bash scripts/build-app.sh --frontend`. Keep the guest running when the bundled engine and runtime are identical; reconnect the console after the frontend update. Rebuild the engine/CocoaSpice/runtime only when those inputs change. Build a DMG with `bash scripts/package-local.sh` only when you need a local installer.

## Find the right source

See the [source map](docs/ARCHITECTURE.md#source-map). Start in `VMConsoleScreen.swift` for floating controls, and `SpiceConsoleView.swift` / `DisplaySupport.swift` for rendering, scaling, colour, or input. Search tracked source first. `Machines/`, `Media/`, `Runtime/`, `build/`, and `dist/` contain local or generated data.

## Send a change

1. Branch from `main` and keep the change focused.
2. Explain the user-visible problem and the resulting behaviour in the pull request.
3. Run checks appropriate to the change. Include manual steps for UI, input, storage, or lifecycle changes. State anything you could not verify.
4. Update the relevant guide and changelog if behaviour or requirements change.
5. Keep VM disks, ISOs, runtime binaries, credentials, personal screenshots, and private logs out of Git.

No code signing credentials are needed for local builds or contributions. The CI workflow checks source hygiene and core behaviour; it does not establish a real Windows boot, graphics-driver compatibility, or a cleared public binary release.

## Dependencies and releases

The UTM digest, version, signing team, and CocoaSpice revision live in `scripts/runtime-lock.json`. Verify any change against upstream release metadata. Changes to runtime preparation or CocoaSpice require a full build and targeted end-to-end validation.

Homebrew tools are not locked to a bottle revision. A public binary release additionally needs complete dependency notices, corresponding-source and relinking materials where required, and a signing/notarisation process. Do not attach locally prepared app bundles to public releases until those requirements are completed. See [ThirdParty/README.md](ThirdParty/README.md).

By contributing original code, you agree that it can be distributed under the repository's MIT license. Third-party contributions must preserve their own license and attribution.
