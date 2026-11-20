import AppKit
import CocoaSpiceNoUsb
import CocoaSpiceRenderer
import MetalKit
import SwiftUI

// CocoaSpice calls delegates on its GLib worker. All view state and input
// channel selection live on the main thread.
final class SpiceConsoleClient: NSObject, CSConnectionDelegate {
    private let session: VMSession
    private var connection: CSConnection?
    private(set) var display: CSDisplay?
    private var sizeObservation: NSKeyValueObservation?
    private(set) var input: CSInput?
    private(set) var canResizeGuest = false
    weak var view: SpiceGuestDisplay?
    var statusChanged: ((String) -> Void)?
    private var relativePointer = false
    private var selectingPointer = false
    private var lastPointerSelection: TimeInterval = -.infinity

    init(session: VMSession) { self.session = session }

    func connect() {
        guard CSMain.shared.spiceStart() else {
            statusChanged?("Could not start the SPICE client")
            return
        }
        let connection = CSConnection(unixSocketFile: URL(fileURLWithPath: session.displayPath))
        connection.delegate = self
        connection.session.shareClipboard = false
        self.connection = connection
        if !connection.connect() { statusChanged?("Could not connect to the local SPICE socket") }
    }

    func close() {
        canResizeGuest = false
        view?.releaseInput()
        view?.setDisplay(nil)
        sizeObservation = nil
        display = nil
        input = nil
        connection?.delegate = nil
        connection?.disconnect()
        connection = nil
    }

    deinit {
        connection?.delegate = nil
        connection?.disconnect()
    }

    func selectPointer(relative: Bool) {
        relativePointer = relative
        ensurePointerMode(force: true)
    }

    func ensurePointerMode(force: Bool = false) {
        guard let input, !selectingPointer else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || (input.serverModeCursor != relativePointer && now - lastPointerSelection >= 0.25) else { return }
        let relative = relativePointer
        let session = session
        lastPointerSelection = now
        selectingPointer = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let selected = (try? QMPClient(session: session).selectPointer(absolute: !relative)) ?? false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.selectingPointer = false
                guard self.input === input else {
                    self.ensurePointerMode(force: true)
                    return
                }
                if self.relativePointer == relative {
                    if selected { input.requestMouseMode(relative) }
                } else {
                    self.ensurePointerMode(force: true)
                }
            }
        }
    }

    private func deliver(_ connection: CSConnection, _ action: @escaping (SpiceConsoleClient) -> Void) {
        DispatchQueue.main.async { [weak self, weak connection] in
            guard let self, let connection, self.connection === connection else { return }
            action(self)
        }
    }

    func spiceConnected(_ connection: CSConnection) {
        deliver(connection) { $0.statusChanged?("Connected · SPICE / Metal") }
    }

    func spiceDisconnected(_ connection: CSConnection) {
        deliver(connection) {
            $0.canResizeGuest = false
            $0.view?.guestResizeCapabilityChanged()
            $0.view?.releaseInput()
            $0.view?.setDisplay(nil)
            $0.sizeObservation = nil
            $0.display = nil
            $0.input = nil
            $0.statusChanged?("Metal display disconnected")
        }
    }

    func spiceError(_ connection: CSConnection, code: CSConnectionError, message: String?) {
        deliver(connection) { $0.statusChanged?(message ?? "SPICE connection error (\(code.rawValue))") }
    }

    func spiceInputAvailable(_ connection: CSConnection, input: CSInput) {
        deliver(connection) {
            $0.input = input
            $0.ensurePointerMode(force: true)
        }
    }

    func spiceInputUnavailable(_ connection: CSConnection, input: CSInput) {
        deliver(connection) {
            guard $0.input === input else { return }
            $0.view?.releaseInput()
            $0.input = nil
        }
    }

    func spiceDisplayCreated(_ connection: CSConnection, display: CSDisplay) {
        spiceDisplayUpdated(connection, display: display)
    }

    func spiceDisplayUpdated(_ connection: CSConnection, display: CSDisplay) {
        deliver(connection) { client in
            guard display.isPrimaryDisplay else { return }
            if client.display !== display {
                client.sizeObservation = display.observe(\.displaySize, options: [.new]) { [weak client, weak observedConnection = connection] display, _ in
                    guard let observedConnection else { return }
                    client?.deliver(observedConnection) { client in
                        if client.display === display { client.view?.setDisplay(display) }
                    }
                }
            }
            client.display = display
            client.view?.setDisplay(display)
        }
    }

    func spiceDisplayDestroyed(_ connection: CSConnection, display: CSDisplay) {
        deliver(connection) {
            guard $0.display === display else { return }
            $0.sizeObservation = nil
            $0.display = nil
            $0.view?.setDisplay(nil)
        }
    }

    func spiceAgentConnected(_ connection: CSConnection, supportingFeatures features: CSConnectionAgentFeature) {
        deliver(connection) {
            $0.canResizeGuest = features.contains(.monitorsConfig)
            $0.view?.guestResizeCapabilityChanged()
        }
    }

    func spiceAgentDisconnected(_ connection: CSConnection) {
        deliver(connection) {
            $0.canResizeGuest = false
            $0.view?.guestResizeCapabilityChanged()
        }
    }
    func spiceForwardedPortOpened(_ connection: CSConnection, port: CSPort) {}
    func spiceForwardedPortClosed(_ connection: CSConnection, port: CSPort) {}
}

struct SpiceConsoleView: NSViewRepresentable {
    var console: ConsoleModel
    var client: SpiceConsoleClient
    var followsWindow: Bool
    var relativeMouse: Bool

    func makeNSView(context: Context) -> SpiceGuestDisplay {
        let view = SpiceGuestDisplay(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.setAccessibilityLabel("Windows virtual machine display (Metal)")
        view.console = console
        view.client = client
        view.followsWindow = followsWindow
        view.relativeMouse = relativeMouse
        client.view = view
        view.prepareRenderer()
        view.setDisplay(client.display)
        return view
    }

    func updateNSView(_ view: SpiceGuestDisplay, context: Context) {
        console.window = view.window
        view.followsWindow = followsWindow
        view.relativeMouse = relativeMouse
    }

    static func dismantleNSView(_ view: SpiceGuestDisplay, coordinator: ()) {
        view.releaseInput()
        view.setDisplay(nil)
        view.client?.view = nil
    }
}

final class SpiceGuestDisplay: MTKView {
    weak var console: ConsoleModel?
    weak var client: SpiceConsoleClient?
    private var renderer: CSMetalRenderer?
    private var guestDisplay: CSDisplay?
    private var guestSize: CGSize = .zero
    private var tracking: NSTrackingArea?
    private var buttons: CSInputButton = []
    private var heldKeys: Set<UInt16> = []
    private var captured = false
    private var wheelRemainder: CGFloat = 0
    private var resizeTask: Task<Void, Never>?
    private var pendingResolution: GuestResolution?
    private var requestedResolution: GuestResolution?
    private var usesNearestSampling = false
    var followsWindow = false {
        didSet { if oldValue != followsWindow { guestResizeCapabilityChanged() } }
    }
    var relativeMouse = false {
        didSet {
            guard oldValue != relativeMouse else { return }
            if !relativeMouse { releaseInput() }
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    func prepareRenderer() {
        autoResizeDrawable = false
        colorPixelFormat = device?.supportsFamily(.apple7) == true ? .bgr10a2Unorm : .bgra8Unorm
        // Guest SDR bytes are sRGB. The drawable retains those values and
        // WindowServer handles the conversion to the destination display profile.
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        isPaused = true
        guard device != nil else { return }
        var pipeline = CSMetalRenderer(metalKitView: self)
        if pipeline == nil, colorPixelFormat == .bgr10a2Unorm {
            colorPixelFormat = .bgra8Unorm
            pipeline = CSMetalRenderer(metalKitView: self)
        }
        guard let renderer = pipeline else {
            DispatchQueue.main.async { [weak self] in self?.console?.status = "Metal renderer unavailable" }
            return
        }
        self.renderer = renderer
        delegate = renderer
        publishDisplayDetails()
    }

    func setDisplay(_ incoming: CSDisplay?) {
        let displayChanged = guestDisplay !== incoming
        if displayChanged, let renderer {
            guestDisplay?.removeRenderer(renderer)
            incoming?.addRenderer(renderer)
        }
        guestDisplay = incoming
        if displayChanged { guestResizeCapabilityChanged() }
        let size = incoming?.displaySize ?? .zero
        guard size != guestSize else {
            updateRefreshRate()
            return
        }
        guestSize = size
        let resolution: GuestResolution? = guestSize.width > 0 && guestSize.height > 0
            ? GuestResolution(width: Int(guestSize.width), height: Int(guestSize.height)) : nil
        // Views can attach while SwiftUI is reconciling its hierarchy.
        DispatchQueue.main.async { [weak self] in self?.console?.resolution = resolution }
        needsLayout = true
        updateRefreshRate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        console?.window = window
        NotificationCenter.default.removeObserver(self)
        if let window {
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(windowResigned), name: NSWindow.didResignKeyNotification, object: window)
            center.addObserver(self, selector: #selector(windowChanged), name: NSWindow.didChangeScreenNotification, object: window)
            center.addObserver(self, selector: #selector(windowChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
            center.addObserver(self, selector: #selector(windowChanged), name: NSWindow.didEnterFullScreenNotification, object: window)
            center.addObserver(self, selector: #selector(windowChanged), name: NSWindow.didExitFullScreenNotification, object: window)
            center.addObserver(self, selector: #selector(windowChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        } else {
            releaseInput()
            resizeTask?.cancel()
            pendingResolution = nil
        }
        updateRefreshRate()
    }

    deinit {
        resizeTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        windowChanged()
    }

    @objc private func windowResigned() { releaseInput() }
    @objc private func windowChanged() {
        needsLayout = true
        updateRefreshRate()
    }

    private func updateRefreshRate() {
        let fps = max(1, Int(HostDisplay.refreshRate(for: window?.screen).rounded()))
        if preferredFramesPerSecond != fps { preferredFramesPerSecond = fps }
        isPaused = window?.occlusionState.contains(.visible) != true || renderer == nil || guestDisplay == nil
    }

    override func layout() {
        super.layout()
        let backingSize = convertToBacking(bounds).size
        let pixels = CGSize(width: backingSize.width.rounded(), height: backingSize.height.rounded())
        guard pixels.width > 1, pixels.height > 1 else { return }
        if drawableSize != pixels { drawableSize = pixels }
        scheduleGuestResize()
        publishDisplayDetails()
        guard guestSize.width > 0, guestSize.height > 0 else { return }
        let rect = pixelViewport(in: pixels)
        let scale = rect.width / guestSize.width
        renderer?.viewportOrigin = CGPoint(x: rect.midX - pixels.width / 2, y: rect.midY - pixels.height / 2)
        renderer?.viewportScale = scale
        let nearest = scale >= 1 && abs(scale - scale.rounded()) < 0.0001
        if nearest != usesNearestSampling {
            usesNearestSampling = nearest
            renderer?.changeUpscaler(nearest ? .nearest : .linear, downscaler: .linear)
        }
    }

    private func pixelViewport(in pixels: CGSize) -> CGRect {
        let rect = DisplayScaling.fit.imageRect(size: guestSize, bounds: CGRect(origin: .zero, size: pixels))
        return CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(), width: rect.width, height: rect.height)
    }

    func guestResizeCapabilityChanged() {
        resizeTask?.cancel()
        pendingResolution = nil
        requestedResolution = nil
        scheduleGuestResize()
        publishDisplayDetails()
    }

    private func publishDisplayDetails() {
        let bits = colorPixelFormat == .bgr10a2Unorm ? 10 : 8
        let colour = "\(bits)-bit Metal · guest SDR"
        let sizing: String
        if !followsWindow {
            sizing = "Fixed guest resolution"
        } else if client?.canResizeGuest != true {
            sizing = "Auto resize needs SPICE Guest Tools"
        } else {
            let target = HostDisplay.supportedResolution(drawableSize)
            sizing = CGSize(width: target.width, height: target.height) == guestSize
                ? "Matches window at \(target.label)" : "Window target \(target.label)"
        }
        let details = "\(colour)\n\(sizing)"
        guard console?.displayDetails != details else { return }
        DispatchQueue.main.async { [weak self] in self?.console?.displayDetails = details }
    }

    private func scheduleGuestResize() {
        guard followsWindow, window != nil, client?.canResizeGuest == true, let display = guestDisplay else { return }
        let target = HostDisplay.supportedResolution(drawableSize)
        guard target != pendingResolution else { return }
        resizeTask?.cancel()
        pendingResolution = nil
        guard target.width >= 800, target.height >= 600, target != requestedResolution,
              CGSize(width: target.width, height: target.height) != guestSize else { return }
        pendingResolution = target
        resizeTask = Task { @MainActor [weak self, weak display] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, let display, self.guestDisplay === display, self.pendingResolution == target else { return }
            self.pendingResolution = nil
            self.requestedResolution = target
            display.requestResolution(CGRect(x: 0, y: 0, width: target.width, height: target.height))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow,.mouseMoved,.inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
    }

    private var imageRect: CGRect {
        let pixels = drawableSize
        guard pixels.width > 1, pixels.height > 1 else { return bounds }
        let rect = pixelViewport(in: pixels)
        let xScale = bounds.width / pixels.width, yScale = bounds.height / pixels.height
        return CGRect(x: bounds.minX + rect.minX * xScale, y: bounds.minY + rect.minY * yScale,
                      width: rect.width * xScale, height: rect.height * yScale)
    }

    private func move(_ event: NSEvent) {
        guard let input = client?.input, guestSize.width > 0, guestSize.height > 0 else { return }
        client?.ensurePointerMode()
        if input.serverModeCursor {
            if captured { input.sendMouseMotion(buttons, relativePoint: CGPoint(x: event.deltaX, y: event.deltaY)) }
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let image = imageRect
        guard image.width > 0, image.height > 0 else { return }
        let x = min(guestSize.width - 1, max(0, (point.x - image.minX) * guestSize.width / image.width))
        let y = min(guestSize.height - 1, max(0, (point.y - image.minY) * guestSize.height / image.height))
        let mapped = CGPoint(x: x, y: y)
        guestDisplay?.cursor?.move(to: mapped)
        input.sendMousePosition(buttons, absolutePoint: mapped)
    }

    private func button(_ event: NSEvent, _ button: CSInputButton, down: Bool) {
        if down {
            window?.makeFirstResponder(self)
            if relativeMouse, !captured, client?.input != nil, CGAssociateMouseAndMouseCursorPosition(0) == .success {
                captured = true
                NSCursor.hide()
                client?.selectPointer(relative: true)
            }
        }
        move(event)
        if down { buttons.insert(button) } else { buttons.remove(button) }
        client?.input?.sendMouseButton(button, mask: buttons, pressed: down)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { button(event, .left, down: true) }
    override func mouseUp(with event: NSEvent) { button(event, .left, down: false) }
    override func rightMouseDown(with event: NSEvent) { button(event, .right, down: true) }
    override func rightMouseUp(with event: NSEvent) { button(event, .right, down: false) }
    override func otherMouseDown(with event: NSEvent) { button(event, otherButton(event), down: true) }
    override func otherMouseUp(with event: NSEvent) { button(event, otherButton(event), down: false) }
    override func mouseMoved(with event: NSEvent) { move(event) }
    override func mouseDragged(with event: NSEvent) { move(event) }
    override func rightMouseDragged(with event: NSEvent) { move(event) }
    override func otherMouseDragged(with event: NSEvent) { move(event) }

    private func otherButton(_ event: NSEvent) -> CSInputButton {
        switch event.buttonNumber {
        case 3: return .side
        case 4: return .extra
        default: return .middle
        }
    }

    override func scrollWheel(with event: NSEvent) {
        wheelRemainder += event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? 20 : 1)
        let steps = min(10, max(-10, Int(wheelRemainder)))
        for _ in 0..<abs(steps) {
            client?.input?.sendMouseScroll(steps > 0 ? .up : .down, buttonMask: buttons, dy: 0)
        }
        wheelRemainder -= CGFloat(steps)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    private func releaseShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains([.control, .option]) else { return false }
        releaseInput()
        window?.makeFirstResponder(nil)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard !releaseShortcut(event), let code = Self.scanCodes[event.keyCode] else { return }
        heldKeys.insert(event.keyCode)
        client?.input?.send(.press, code: code)
    }

    override func keyUp(with event: NSEvent) {
        if heldKeys.remove(event.keyCode) != nil, let code = Self.scanCodes[event.keyCode] {
            client?.input?.send(.release, code: code)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard !releaseShortcut(event), let code = Self.scanCodes[event.keyCode] else { return }
        if event.keyCode == 57 {
            client?.input?.send(.press, code: code)
            client?.input?.send(.release, code: code)
        } else if heldKeys.remove(event.keyCode) != nil {
            client?.input?.send(.release, code: code)
        } else {
            heldKeys.insert(event.keyCode)
            client?.input?.send(.press, code: code)
        }
    }

    func releaseInput() {
        client?.input?.releaseKeys()
        heldKeys.removeAll()
        for button in [CSInputButton.left, .middle, .right, .side, .extra] where buttons.contains(button) {
            buttons.remove(button)
            client?.input?.sendMouseButton(button, mask: buttons, pressed: false)
        }
        if captured {
            captured = false
            _ = CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
            client?.selectPointer(relative: false)
        }
    }

    override func resignFirstResponder() -> Bool {
        releaseInput()
        return super.resignFirstResponder()
    }

    // Apple virtual key codes to PC XT set 1. 0x100 represents an E0 prefix.
    private static let scanCodes: [UInt16: Int32] = [
        0:0x1e,1:0x1f,2:0x20,3:0x21,4:0x23,5:0x22,6:0x2c,7:0x2d,8:0x2e,9:0x2f,10:0x56,11:0x30,
        12:0x10,13:0x11,14:0x12,15:0x13,16:0x15,17:0x14,18:0x02,19:0x03,20:0x04,21:0x05,22:0x07,
        23:0x06,24:0x0d,25:0x0a,26:0x08,27:0x0c,28:0x09,29:0x0b,30:0x1b,31:0x18,32:0x16,
        33:0x1a,34:0x17,35:0x19,36:0x1c,37:0x26,38:0x24,39:0x28,40:0x25,41:0x27,42:0x2b,
        43:0x33,44:0x35,45:0x31,46:0x32,47:0x34,48:0x0f,49:0x39,50:0x29,51:0x0e,53:0x01,
        54:0x15c,55:0x15b,56:0x2a,57:0x3a,58:0x38,59:0x1d,60:0x36,61:0x138,62:0x11d,
        65:0x53,67:0x37,69:0x4e,71:0x45,75:0x135,76:0x11c,78:0x4a,82:0x52,83:0x4f,84:0x50,
        85:0x51,86:0x4b,87:0x4c,88:0x4d,89:0x47,91:0x48,92:0x49,96:0x3f,97:0x40,
        98:0x41,99:0x3d,100:0x42,101:0x43,103:0x57,109:0x44,111:0x58,114:0x152,
        115:0x147,116:0x149,117:0x153,118:0x3e,119:0x14f,120:0x3c,121:0x151,122:0x3b,
        123:0x14b,124:0x14d,125:0x150,126:0x148,
    ]
}
