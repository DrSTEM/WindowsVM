import AppKit
import Foundation

struct GuestResolution: Codable, Hashable {
    var width: Int
    var height: Int
    var label: String { "\(width) × \(height)" }
    static let presets = [GuestResolution(width: 1920, height: 1200),
                          GuestResolution(width: 2560, height: 1600),
                          GuestResolution(width: 3840, height: 2160)]
}

enum DisplayScaling: String, Codable, CaseIterable {
    // Keep reading the legacy setting. Both modes now preserve proportions.
    case fill, fit
    func imageRect(size: CGSize, bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                      width: width, height: height)
    }
}

@MainActor enum HostDisplay {
    static var currentScreen: NSScreen? { NSApp.keyWindow?.screen ?? NSScreen.main }

    private static func displayMode(for screen: NSScreen?) -> CGDisplayMode? {
        let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            ?? CGMainDisplayID()
        return CGDisplayCopyDisplayMode(id)
    }

    static func resolution(for screen: NSScreen?) -> GuestResolution {
        if let mode = displayMode(for: screen) {
            return supportedResolution(CGSize(width: mode.pixelWidth, height: mode.pixelHeight))
        }
        if let screen {
            return supportedResolution(screen.convertRectToBacking(screen.frame).size)
        }
        return GuestResolution(width: 1920, height: 1200)
    }

    static func fullScreenResolution(for screen: NSScreen?) -> GuestResolution {
        guard let screen else { return resolution(for: nil) }
        // AppKit full-screen spaces on a notched Mac start below the camera.
        // Use the backing pixels of that space as the guest's preferred mode.
        let insets = screen.safeAreaInsets
        let size = screen.frame.size
        let area = CGRect(x: 0, y: 0, width: size.width - insets.left - insets.right,
                          height: size.height - insets.top - insets.bottom)
        return supportedResolution(screen.convertRectToBacking(area).size)
    }

    static func refreshRate(for screen: NSScreen?) -> Double {
        let fixedRate = displayMode(for: screen)?.refreshRate ?? 0
        if fixedRate > 0 { return fixedRate }
        let maximum = screen?.maximumFramesPerSecond ?? 0
        return Double(maximum > 0 ? maximum : 60)
    }

    static func supportedResolution(_ pixels: CGSize) -> GuestResolution {
        // Bound unusually large backing stores with one scale on both axes.
        let scale = min(1, 7680 / max(1, pixels.width), 4320 / max(1, pixels.height))
        return GuestResolution(width: Int((pixels.width * scale).rounded()),
                               height: Int((pixels.height * scale).rounded()))
    }
}

/// A batch of changed tiles. Tile IDs are stable until the framebuffer resizes.
struct DisplayUpdate: @unchecked Sendable {
    static let tileSize = 256
    let resolution: GuestResolution
    let generation: Int
    var tiles: [Int: CGImage]

    var columns: Int { (resolution.width + Self.tileSize - 1) / Self.tileSize }
    func tileOrigin(_ id: Int) -> (x: Int, y: Int) {
        (id % columns * Self.tileSize, id / columns * Self.tileSize)
    }
}

/// Keep the latest pixels for each dirty tile while the UI is busy. Dropping a
/// whole batch would lose updates in tiles absent from the next batch.
final class DisplayMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: DisplayUpdate?
    func offer(_ update: DisplayUpdate) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let needsDelivery = pending == nil
        if pending?.generation == update.generation {
            pending?.tiles.merge(update.tiles) { _, newer in newer }
        } else {
            pending = update
        }
        return needsDelivery
    }
    func take() -> DisplayUpdate? {
        lock.lock(); defer { lock.unlock() }
        let result = pending
        pending = nil
        return result
    }
}

/// The decoder owns the pixel store. Only dirty tiles are copied to immutable
/// images for Core Animation, so a small update never copies the whole screen.
struct DisplayFramebuffer {
    private(set) var resolution: GuestResolution?
    private var generation = 0
    private var pixels = Data()
    private var dirty = Set<Int>()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    mutating func resize(width: Int, height: Int) throws {
        guard (1...7680).contains(width), (1...4320).contains(height) else {
            throw ConsoleError(message: "Unsupported display size \(width)×\(height)")
        }
        resolution = GuestResolution(width: width, height: height)
        generation += 1
        pixels = Data(count: width * height * 4)
        dirty.removeAll()
    }

    mutating func write(_ bytes: Data, x: Int, y: Int, width: Int, height: Int) throws {
        guard let resolution, x >= 0, y >= 0, width >= 0, height >= 0,
              x + width <= resolution.width, y + height <= resolution.height,
              bytes.count == width * height * 4 else {
            throw ConsoleError(message: "Invalid display rectangle")
        }
        guard width > 0, height > 0 else { return }
        let rowBytes = width * 4
        let stride = resolution.width * 4
        pixels.withUnsafeMutableBytes { destination in
            bytes.withUnsafeBytes { source in
                for row in 0..<height {
                    memcpy(destination.baseAddress!.advanced(by: (y + row) * stride + x * 4),
                           source.baseAddress!.advanced(by: row * rowBytes), rowBytes)
                }
            }
        }
        let side = DisplayUpdate.tileSize
        let columns = (resolution.width + side - 1) / side
        for row in y / side...(y + height - 1) / side {
            for column in x / side...(x + width - 1) / side {
                dirty.insert(row * columns + column)
            }
        }
    }

    mutating func takeUpdate() -> DisplayUpdate? {
        guard let resolution, !dirty.isEmpty else { return nil }
        var update = DisplayUpdate(resolution: resolution, generation: generation, tiles: [:])
        for id in dirty {
            let (x, y) = update.tileOrigin(id)
            let width = min(DisplayUpdate.tileSize, resolution.width - x)
            let height = min(DisplayUpdate.tileSize, resolution.height - y)
            let rowBytes = width * 4
            var tile = Data(count: rowBytes * height)
            tile.withUnsafeMutableBytes { destination in
                pixels.withUnsafeBytes { source in
                    for row in 0..<height {
                        memcpy(destination.baseAddress!.advanced(by: row * rowBytes),
                               source.baseAddress!.advanced(by: ((y + row) * resolution.width + x) * 4),
                               rowBytes)
                    }
                }
            }
            if let provider = CGDataProvider(data: tile as CFData) {
                update.tiles[id] = CGImage(width: width, height: height, bitsPerComponent: 8,
                    bitsPerPixel: 32, bytesPerRow: rowBytes, space: colorSpace,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue).union(.byteOrder32Little),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            }
        }
        dirty.removeAll(keepingCapacity: true)
        return update
    }
}
