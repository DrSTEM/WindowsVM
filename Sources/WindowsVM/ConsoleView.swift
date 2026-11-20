import AppKit
import SwiftUI

@MainActor final class ConsoleModel: ObservableObject {
    @Published var resolution: GuestResolution?
    @Published var status = "Connecting to the local display…"
    @Published var displayDetails = ""
    let client = RFBClient()
    private(set) var spice: SpiceConsoleClient?
    weak var window: NSWindow?
    private weak var display: GuestDisplay?
    private var generation: Int?
    private var tiles: [Int: CGImage] = [:]
    private var cursor: GuestCursor?

    init(session: VMSession) {
        if session.displayBackend?.usesSpice == true {
            let client = SpiceConsoleClient(session: session)
            spice = client
            client.statusChanged = { [weak self] message in self?.status = message }
            client.connect()
            return
        }
        let mailbox = DisplayMailbox()
        client.onFrame = { [weak self] update in
            if mailbox.offer(update) {
                DispatchQueue.main.async { [weak self] in
                    if let update = mailbox.take() { self?.apply(update) }
                }
            }
        }
        client.onCursor = { [weak self] cursor in
            DispatchQueue.main.async { [weak self] in
                self?.cursor = cursor
                self?.display?.setGuestCursor(cursor)
            }
        }
        client.onStatus = { [weak self] message in DispatchQueue.main.async { self?.status = message } }
        client.connect(port: session.displayPort, path: session.displayPort == nil ? session.displayPath : nil)
    }

    func attach(_ view: GuestDisplay) {
        guard display !== view else { return }
        display = view
        if let resolution, let generation {
            view.apply(DisplayUpdate(resolution: resolution, generation: generation, tiles: tiles))
        }
        if let cursor { view.setGuestCursor(cursor) }
    }

    private func apply(_ update: DisplayUpdate) {
        if generation != update.generation {
            generation = update.generation
            tiles.removeAll()
        }
        tiles.merge(update.tiles) { _, newer in newer }
        display?.apply(update)
        if resolution != update.resolution { resolution = update.resolution }
    }

    func close() {
        spice?.close()
        client.close()
    }

    deinit { client.close() }
}

struct ConsoleView: NSViewRepresentable {
    var model: ConsoleModel
    var scaling: DisplayScaling

    func makeNSView(context: Context) -> GuestDisplay {
        let view = GuestDisplay()
        view.wantsLayer = true
        view.client = model.client
        view.consoleModel = model
        view.scaling = scaling
        view.setAccessibilityLabel("Windows virtual machine display")
        model.attach(view)
        return view
    }

    func updateNSView(_ view: GuestDisplay, context: Context) {
        if view.client !== model.client {
            view.releaseInput()
            view.resetDisplay()
            view.client = model.client
        }
        view.consoleModel = model
        model.window = view.window
        view.scaling = scaling
        model.attach(view)
    }
}

final class GuestDisplay: NSView {
    var client: RFBClient?
    weak var consoleModel: ConsoleModel?
    private let surface = CALayer()
    private var tiles: [Int: CALayer] = [:]
    private var generation: Int?
    private var resolution: GuestResolution?
    private var guestCursor = NSCursor.arrow
    var scaling: DisplayScaling = .fill {
        didSet { if oldValue != scaling { needsLayout = true } }
    }
    private var buttons: UInt8 = 0
    private var lastPointer: (UInt16, UInt16) = (0, 0)
    private var keys: [UInt16: UInt32] = [:]
    private var modifiers: NSEvent.ModifierFlags = []
    private var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        consoleModel?.window = window
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
                name: NSWindow.didResignKeyNotification, object: window)
        }
    }

    @objc private func windowResignedKey() { releaseInput() }
    deinit { NotificationCenter.default.removeObserver(self) }

    func resetDisplay() {
        surface.sublayers = nil
        tiles.removeAll()
        generation = nil
        resolution = nil
        guestCursor = .arrow
        window?.invalidateCursorRects(for: self)
    }

    func apply(_ update: DisplayUpdate) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if surface.superlayer == nil {
            layer?.backgroundColor = NSColor.black.cgColor
            surface.isGeometryFlipped = true
            layer?.addSublayer(surface)
        }
        if generation != update.generation {
            surface.sublayers = nil
            tiles.removeAll()
            generation = update.generation
            resolution = update.resolution
            positionSurface()
        }
        for (id, image) in update.tiles {
            let tile: CALayer
            if let existing = tiles[id] {
                tile = existing
            } else {
                let (x, y) = update.tileOrigin(id)
                tile = CALayer()
                // RFB counts rows down from the top. Sublayer positions here
                // count up from the bottom, including the short bottom row.
                let layerY = update.resolution.height - y - image.height
                tile.frame = CGRect(x: x, y: layerY, width: image.width, height: image.height)
                tile.edgeAntialiasingMask = []
                tile.magnificationFilter = .linear
                tile.minificationFilter = .linear
                surface.addSublayer(tile)
                tiles[id] = tile
            }
            tile.contents = image
        }
    }

    private var imageRect: CGRect {
        guard let resolution else { return bounds }
        return scaling.imageRect(size: CGSize(width: resolution.width, height: resolution.height), bounds: bounds)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        positionSurface()
        CATransaction.commit()
    }

    private func positionSurface() {
        guard let resolution else { return }
        let rect = imageRect
        surface.bounds = CGRect(x: 0, y: 0, width: resolution.width, height: resolution.height)
        surface.position = CGPoint(x: rect.midX, y: rect.midY)
        surface.setAffineTransform(CGAffineTransform(scaleX: rect.width / CGFloat(resolution.width),
                                                    y: rect.height / CGFloat(resolution.height)))
        window?.invalidateCursorRects(for: self)
    }

    func setGuestCursor(_ cursor: GuestCursor) {
        let scale = window?.backingScaleFactor ?? 1
        let image = cursor.image.map {
            NSImage(cgImage: $0, size: NSSize(width: CGFloat($0.width) / scale, height: CGFloat($0.height) / scale))
        } ?? NSImage(size: NSSize(width: 1, height: 1))
        guestCursor = NSCursor(image: image, hotSpot: NSPoint(x: cursor.hotSpot.x / scale, y: cursor.hotSpot.y / scale))
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(imageRect, cursor: guestCursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow,.mouseMoved,.inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    private func mouse(_ event: NSEvent, motion: Bool = false) {
        guard let size = resolution else { return }
        let p = convert(event.locationInWindow, from: nil), r = imageRect
        guard r.width > 0, r.height > 0 else { return }
        let x = max(0,min(size.width-1,Int((p.x-r.minX)/r.width*CGFloat(size.width))))
        let y = max(0,min(size.height-1,Int((p.y-r.minY)/r.height*CGFloat(size.height))))
        lastPointer=(UInt16(x),UInt16(y))
        client?.pointer(x: lastPointer.0, y: lastPointer.1, buttons: buttons, motion: motion)
    }
    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); buttons |= 1; mouse(e) }
    override func mouseUp(with e: NSEvent) { buttons &= ~1; mouse(e) }
    override func rightMouseDown(with e: NSEvent) { buttons |= 4; mouse(e) }
    override func rightMouseUp(with e: NSEvent) { buttons &= ~4; mouse(e) }
    override func otherMouseDown(with e: NSEvent) { buttons |= 2; mouse(e) }
    override func otherMouseUp(with e: NSEvent) { buttons &= ~2; mouse(e) }
    override func mouseMoved(with e: NSEvent) { mouse(e, motion: true) }
    override func mouseDragged(with e: NSEvent) { mouse(e, motion: true) }
    override func rightMouseDragged(with e: NSEvent) { mouse(e, motion: true) }
    override func otherMouseDragged(with e: NSEvent) { mouse(e, motion: true) }
    override func scrollWheel(with e: NSEvent) {
        let bit: UInt8 = e.scrollingDeltaY > 0 ? 8 : 16
        if e.scrollingDeltaY != 0 { buttons |= bit; mouse(e); buttons &= ~bit; mouse(e) }
    }
    private func symbol(_ e: NSEvent) -> UInt32? {
        let special: [UInt16:UInt32] = [36:0xff0d,48:0xff09,49:0x20,51:0xff08,53:0xff1b,117:0xffff,123:0xff51,124:0xff53,125:0xff54,126:0xff52,115:0xff50,119:0xff57,116:0xff55,121:0xff56,122:0xffbe,120:0xffbf,99:0xffc0,118:0xffc1,96:0xffc2,97:0xffc3,98:0xffc4,100:0xffc5,101:0xffc6,109:0xffc7,103:0xffc8,111:0xffc9]
        if let key = special[e.keyCode] { return key }
        guard let scalar = e.charactersIgnoringModifiers?.unicodeScalars.first else { return nil }
        return scalar.value < 256 ? scalar.value : 0x01000000 | scalar.value
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.type == .keyDown { keyDown(with:event); return true }
        return super.performKeyEquivalent(with:event)
    }
    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.contains([.control,.option]) { releaseInput(); window?.makeFirstResponder(nil); return }
        if let code = keys[e.keyCode] ?? symbol(e) {
            keys[e.keyCode] = code
            client?.key(code, down: true)
        }
    }
    override func keyUp(with e: NSEvent) {
        if let code = keys.removeValue(forKey: e.keyCode) { client?.key(code, down: false) }
    }
    override func flagsChanged(with e: NSEvent) {
        if e.modifierFlags.contains([.control,.option]) {releaseInput();window?.makeFirstResponder(nil);return}
        for (flag,key): (NSEvent.ModifierFlags,UInt32) in [(.shift,0xffe1),(.control,0xffe3),(.option,0xffe9),(.command,0xffeb)] {
            if modifiers.contains(flag) != e.modifierFlags.contains(flag) { client?.key(key,down:e.modifierFlags.contains(flag)) }
        }
        modifiers = e.modifierFlags
    }
    func releaseInput() {
        for key in keys.values { client?.key(key,down:false) }; keys.removeAll()
        for key: UInt32 in [0xffe1,0xffe3,0xffe9,0xffeb] { client?.key(key,down:false) }
        buttons = 0; modifiers = []
        client?.pointer(x:lastPointer.0,y:lastPointer.1,buttons:0)
    }
    override func resignFirstResponder() -> Bool { releaseInput(); return super.resignFirstResponder() }
}
