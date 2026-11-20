# Windows VM

- For the floating controls, start in `Sources/WindowsVM/VMConsoleScreen.swift`. For scaling, colour, or input, start in `SpiceConsoleView.swift` and `DisplaySupport.swift` in the same directory.
- Use `bash scripts/build-app.sh --frontend` for Swift-only iterations after a full build. Rebuild CocoaSpice and the engine only when those inputs change. Create a DMG when an installer is needed.
- The app can reconnect to a running VM after a frontend-only update. Keep the guest running when the engine and runtime are identical. Keep any checks focused on the behaviour that changed.
- Search tracked source first. `Machines/`, `Media/`, `Runtime/`, `build/`, and `dist/` contain local data or generated artifacts.
