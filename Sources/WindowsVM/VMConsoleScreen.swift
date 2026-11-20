import AppKit
import SwiftUI

struct VMConsoleScreen: View {
    @ObservedObject var machine: VMController
    @StateObject private var window = ConsoleWindowHandle()
    @State private var stopping = false
    @State private var relativeMouse = false
    @State private var controlsOpen = false
    @State private var controlsHovered = false
    @State private var optionsOpen = false
    @State private var hideControls: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .top) {
            display.ignoresSafeArea(.container)
            ZStack(alignment: .top) {
                controls
                    .padding(.top, 8)
                    .opacity(controlsOpen ? 1 : 0)
                    .allowsHitTesting(controlsOpen)
                    .accessibilityHidden(!controlsOpen)
                if !controlsOpen { revealControls }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .navigationTitle(machine.config.name)
        .confirmationDialog("Force stop \(machine.config.name)?", isPresented: $stopping, titleVisibility: .visible) {
            Button("Force Stop", role: .destructive) { Task { await machine.command("quit") } }
        } message: {
            Text("This disconnects power immediately. Unsaved Windows work may be lost.")
        }
        .alert("Virtual machine", isPresented: Binding(get: { machine.error != nil }, set: { if !$0 { machine.error = nil } })) {
            Button("OK") { machine.error = nil }
        } message: {
            Text(machine.error ?? "")
        }
        .onAppear { machine.showConsole() }
        .onChange(of: machine.state) {
            if machine.state == .running || machine.state == .paused { machine.showConsole() }
        }
        .onDisappear {
            hideControls?.cancel()
            machine.hideConsole()
        }
    }

    private var display: some View {
        ZStack {
            Color.black
            if let console = machine.console {
                if let spice = console.spice {
                    SpiceConsoleView(console: console, client: spice,
                                     followsWindow: machine.config.displayResolution == nil, relativeMouse: relativeMouse)
                        .id(ObjectIdentifier(spice))
                } else {
                    ConsoleView(model: console, scaling: .fit)
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "power").font(.system(size: 42))
                    Text(machine.state.rawValue).font(.title2)
                    Button("Start") { Task { await machine.start() } }.buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
            }
        }
    }

    private var revealControls: some View {
        Button {
            hideControls?.cancel()
            withAnimation(.easeOut(duration: 0.16)) { controlsOpen = true }
            scheduleHide()
        } label: {
            Group {
                if controlsHovered {
                    Label("VM Controls", systemImage: "chevron.down").font(.caption.weight(.semibold))
                } else {
                    Capsule().fill(.primary.opacity(0.6)).frame(width: 24, height: 2)
                }
            }
            .frame(width: 112, height: controlsHovered ? 26 : 8)
            .contentShape(Rectangle())
            .modifier(ConsoleGlass())
            .frame(height: 26, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show Windows VM Controls")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) { controlsHovered = hovering }
        }
    }

    private var controls: some View {
        HStack(spacing: 9) {
            ConsoleWindowGrip(handle: window, preferredResolution: machine.config.displayResolution)
                .frame(width: 42, height: 46)
                .overlay {
                    controlLabel("Move", icon: "line.3.horizontal").foregroundStyle(.secondary).allowsHitTesting(false)
                }
                .help("Drag to move the window")
            control(window.fullScreen ? "Exit Full Screen" : "Full Screen",
                    icon: window.fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                window.window?.toggleFullScreen(nil)
            }
            control("Minimize", icon: "minus") { window.window?.miniaturize(nil) }.disabled(window.fullScreen)
            Divider().frame(height: 27)
            control(machine.state == .paused ? "Resume" : "Pause", icon: machine.state == .paused ? "play.fill" : "pause.fill") {
                Task { await machine.command(machine.state == .paused ? "cont" : "stop") }
            }.disabled(!machine.active)
            Button {
                optionsOpen.toggle()
            } label: {
                controlLabel("Options", icon: "ellipsis")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Windows VM Options")
            .popover(isPresented: $optionsOpen, arrowEdge: .top) { options }
            control("Hide", icon: "chevron.up") { collapseControls() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .contentShape(Capsule())
        .modifier(ConsoleGlass())
        .onHover { hovering in
            hideControls?.cancel()
            if !hovering { scheduleHide() }
        }
        .onChange(of: optionsOpen) {
            if optionsOpen { hideControls?.cancel() } else { scheduleHide() }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(machine.config.name).font(.headline)
            Group {
                if let console = machine.console {
                    ConsoleMenuStatus(model: console)
                    Divider()
                    if console.spice != nil { Toggle("Capture Mouse for Games", isOn: $relativeMouse) }
                    Button("Reconnect Display") { machine.showConsole(reconnect: true) }
                }
                Button("Zoom Window") { window.window?.zoom(nil) }.disabled(window.fullScreen)
                Button("Mount ISO…") { DispatchQueue.main.async { chooseISO() } }
                Button("Eject ISO") { Task { await machine.mountISO(nil) } }.disabled(machine.config.installerPath == nil)
                Divider()
                Button("Shut Down Windows") { Task { await machine.command("system_powerdown") } }.disabled(!machine.active)
                Button("Restart Windows…") {
                    optionsOpen = false
                    DispatchQueue.main.async {
                        if confirm("Restart this virtual machine?", message: "Windows will restart immediately. Save your work first.", action: "Restart") {
                            Task { await machine.command("system_reset") }
                        }
                    }
                }.disabled(!machine.active)
                Button("Force Stop…", role: .destructive) { optionsOpen = false; stopping = true }.disabled(!machine.active)
                Button("Close Window") { window.window?.performClose(nil) }
            }.buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 245, alignment: .leading)
    }

    private func scheduleHide() {
        hideControls?.cancel()
        guard controlsOpen, !optionsOpen else { return }
        hideControls = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(1.6)) } catch { return }
            collapseControls()
        }
    }

    private func collapseControls() {
        hideControls?.cancel()
        controlsHovered = false
        withAnimation(.easeOut(duration: 0.16)) { controlsOpen = false }
    }

    private func controlLabel(_ title: String, icon: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold))
            Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 5)
        .frame(minWidth: 48, minHeight: 46)
        .contentShape(Rectangle())
    }

    private func control(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            controlLabel(title, icon: icon)
        }.buttonStyle(.plain).accessibilityLabel(title).help(title)
    }

    private func chooseISO() {
        let panel = NSOpenPanel()
        panel.title = "Mount ISO"
        if panel.runModal() == .OK, let url = panel.url { Task { await machine.mountISO(url) } }
    }
}

private struct ConsoleMenuStatus: View {
    @ObservedObject var model: ConsoleModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.status)
            if let resolution = model.resolution { Text(resolution.label) }
            if model.spice != nil { Text(model.displayDetails) }
            Text("Control–Option releases input")
        }.font(.caption).foregroundStyle(.secondary)
    }
}

private struct ConsoleGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}

private final class ConsoleWindowHandle: ObservableObject {
    weak var window: NSWindow?
    @Published var fullScreen = false
}

private struct ConsoleWindowGrip: NSViewRepresentable {
    let handle: ConsoleWindowHandle
    let preferredResolution: GuestResolution?

    func makeNSView(context: Context) -> WindowGrip {
        let view = WindowGrip()
        view.handle = handle
        view.preferredResolution = preferredResolution
        return view
    }

    func updateNSView(_ view: WindowGrip, context: Context) {
        if view.preferredResolution != preferredResolution {
            view.preferredResolution = preferredResolution
            view.updateAspectRatio()
        }
    }
}

private final class WindowGrip: NSView {
    weak var handle: ConsoleWindowHandle?
    var preferredResolution: GuestResolution?

    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        handle?.window = window
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(screenChanged), name: NSWindow.didChangeScreenNotification, object: window)
        center.addObserver(self, selector: #selector(willEnterFullScreen), name: NSWindow.willEnterFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(fullScreenChanged), name: NSWindow.didEnterFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(fullScreenChanged), name: NSWindow.didExitFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DispatchQueue.main.async { [weak self] in self?.fullScreenChanged() }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func screenChanged() { updateAspectRatio() }
    @objc private func willEnterFullScreen() { window?.aspectRatio = .zero }
    @objc private func fullScreenChanged() {
        guard let window else { return }
        handle?.fullScreen = window.styleMask.contains(.fullScreen)
        updateAspectRatio()
    }

    func updateAspectRatio() {
        guard let window, let screen = window.screen, !window.styleMask.contains(.fullScreen) else { return }
        let resolution = preferredResolution ?? HostDisplay.fullScreenResolution(for: screen)
        let aspect = CGFloat(resolution.width) / CGFloat(resolution.height)
        window.aspectRatio = CGSize(width: resolution.width, height: resolution.height)
        let current = window.frame
        let available = screen.visibleFrame
        let width = min(current.width, current.height * aspect, available.width, available.height * aspect)
        let height = width / aspect
        // Keep the window under the pointer as closely as the new screen allows.
        let x = min(max(current.midX - width / 2, available.minX), available.maxX - width)
        let y = min(max(current.maxY - height, available.minY), available.maxY - height)
        let frame = CGRect(x: x, y: y, width: width, height: height)
        if abs(current.width - frame.width) > 1 || abs(current.height - frame.height) > 1 {
            window.setFrame(frame, display: true)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.zoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }
}
