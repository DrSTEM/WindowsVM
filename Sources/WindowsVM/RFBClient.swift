import AppKit
import Foundation
import Darwin

struct ConsoleError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct RFBInputBatch {
    private(set) var bytes = Data()
    private var lastMotionOffset: Int?

    mutating func append(_ packet: Data, replaceableMotion: Bool) {
        if replaceableMotion, let offset = lastMotionOffset {
            bytes.replaceSubrange(offset..<bytes.count, with: packet)
        } else {
            lastMotionOffset = replaceableMotion ? bytes.count : nil
            bytes.append(packet)
        }
    }
}

struct GuestCursor: @unchecked Sendable {
    let image: CGImage?
    let hotSpot: CGPoint
}

/// RFB 3.8 over a private local connection with lossless pixel updates.
final class RFBClient: @unchecked Sendable {
    private var fd: Int32 = -1
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var stopped = false
    private var inputReady = false
    private var input = RFBInputBatch()
    private var inputScheduled = false
    private let inputQueue = DispatchQueue(label: "Windows VM input", qos: .userInteractive)
    private var framebuffer = DisplayFramebuffer()
    var onFrame: ((DisplayUpdate) -> Void)?
    var onCursor: ((GuestCursor) -> Void)?
    var onStatus: ((String) -> Void)?

    func connect(port: UInt16? = nil, path: String? = nil) {
        DispatchQueue.global(qos: .userInteractive).async { [self] in
            let socketFD = socket(path == nil ? AF_INET:AF_UNIX, SOCK_STREAM, 0)
            guard socketFD >= 0 else {
                if !isStopped { onStatus?("Could not open the display socket") }
                return
            }
            defer { finishSocket(socketFD) }
            do {
                var noSignal: Int32 = 1
                setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 1, tv_usec: 0)
                setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                let result: Int32
                if let path {
                    var address = sockaddr_un()
                    address.sun_family = sa_family_t(AF_UNIX)
                    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
                    let bytes = Array(path.utf8)+[0]
                    guard bytes.count <= MemoryLayout.size(ofValue:address.sun_path) else { throw ConsoleError(message:"Display socket path is too long") }
                    withUnsafeMutableBytes(of:&address.sun_path) { $0.copyBytes(from:bytes) }
                    result = withUnsafePointer(to:&address) { p in p.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.connect(socketFD,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
                } else {
                    var address = sockaddr_in()
                    address.sin_family = sa_family_t(AF_INET)
                    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    address.sin_port = (port ?? 5909).bigEndian
                    address.sin_addr.s_addr = inet_addr("127.0.0.1")
                    result = withUnsafePointer(to: &address) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                    }
                }
                guard result == 0 else { throw ConsoleError(message: "Cannot connect to the local display: \(String(cString: strerror(errno)))") }
                stateLock.lock()
                if stopped { stateLock.unlock(); return }
                fd = socketFD
                stateLock.unlock()
                try handshake()
                stateLock.lock()
                inputReady = !stopped
                stateLock.unlock()
                onStatus?("Connected")
                while !isStopped { try receiveMessage() }
            } catch { if !isStopped { onStatus?(error.localizedDescription) } }
        }
    }
    private var isStopped: Bool { stateLock.lock(); defer { stateLock.unlock() }; return stopped }
    func close() {
        stateLock.lock()
        stopped = true
        inputReady = false
        input = RFBInputBatch()
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        stateLock.unlock()
    }
    private func finishSocket(_ socketFD: Int32) {
        close()
        // Only the reader closes the descriptor, after any writer has left it.
        writeLock.lock()
        stateLock.lock()
        fd = -1
        stateLock.unlock()
        Darwin.close(socketFD)
        writeLock.unlock()
    }
    private func read(_ count: Int) throws -> Data {
        guard count >= 0 && count <= 128 * 1024 * 1024 else { throw ConsoleError(message: "Display message exceeds the safety limit") }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ConsoleError(message: "Display disconnected") }
                offset += n
            }
        }
        return data
    }
    private func write(_ bytes: Data, requiresReady: Bool = false) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        stateLock.lock()
        let socketFD = stopped || (requiresReady && !inputReady) ? -1 : fd
        stateLock.unlock()
        guard socketFD >= 0 else { throw ConsoleError(message: "Display disconnected") }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(socketFD, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ConsoleError(message: "Display input disconnected") }
                offset += n
            }
        }
    }
    private func handshake() throws {
        let version = try read(12)
        guard String(data: version, encoding: .ascii)?.hasPrefix("RFB 003.") == true else { throw ConsoleError(message: "Unexpected local display protocol") }
        try write(Data("RFB 003.008\n".utf8))
        let count = Int(try read(1)[0])
        guard count > 0 else { throw ConsoleError(message: "QEMU refused the display connection") }
        let methods = try read(count)
        guard methods.contains(1) else { throw ConsoleError(message: "Local display requires unsupported authentication") }
        try write(Data([1]))
        guard try read(4).u32(0) == 0 else { throw ConsoleError(message: "Display authentication failed") }
        try write(Data([1])) // shared connection
        let header = try read(24)
        try framebuffer.resize(width: Int(header.u16(0)), height: Int(header.u16(2)))
        _ = try read(Int(header.u32(20)))
        // 32bpp, 24 depth, little endian, RGB888 => B,G,R,padding bytes.
        try write(Data([0,0,0,0, 32,24,0,1, 0,255,0,255,0,255,16,8,0,0,0,0]))
        var encodings = Data([2,0,0,3])
        for encoding: Int32 in [0, -223, -239] { encodings.appendBE(UInt32(bitPattern: encoding)) }
        try write(encodings)
        try requestUpdate(incremental: false)
    }
    private func requestUpdate(incremental: Bool) throws {
        guard let size = framebuffer.resolution else { return }
        var packet = Data([3,incremental ? 1 : 0,0,0,0,0]); packet.appendBE(UInt16(size.width)); packet.appendBE(UInt16(size.height)); try write(packet)
    }
    private func receiveMessage() throws {
        switch try read(1)[0] {
        case 0:
            let update = try read(3)
            var resized = false
            var receivedPixels = false
            for _ in 0..<Int(update.u16(1)) {
                let rectangle = try read(12)
                let x = Int(rectangle.u16(0)), y = Int(rectangle.u16(2))
                let w = Int(rectangle.u16(4)), h = Int(rectangle.u16(6))
                let encoding = Int32(bitPattern: rectangle.u32(8))
                if encoding == -223 {
                    try framebuffer.resize(width: w, height: h)
                    resized = true
                    continue
                }
                if encoding == -239 {
                    try receiveCursor(x: x, y: y, width: w, height: h)
                    continue
                }
                guard encoding == 0, let size = framebuffer.resolution,
                      x+w <= size.width, y+h <= size.height else { throw ConsoleError(message: "Invalid display rectangle or encoding \(encoding)") }
                let bytes = try read(w*h*4)
                try framebuffer.write(bytes, x: x, y: y, width: w, height: h)
                receivedPixels = true
            }
            // Re-arm the server before preparing images for the compositor.
            if resized || receivedPixels || update.u16(1) == 0 { try requestUpdate(incremental: !resized) }
            if let update = framebuffer.takeUpdate() { onFrame?(update) }
        case 2: break // bell
        case 3:
            let header = try read(7); _ = try read(Int(header.u32(3))) // deliberately don't import clipboard
        default: throw ConsoleError(message: "Unsupported server display message")
        }
    }

    private func receiveCursor(x: Int, y: Int, width: Int, height: Int) throws {
        guard width <= 512, height <= 512 else { throw ConsoleError(message: "Unsupported cursor size") }
        guard width > 0, height > 0 else {
            onCursor?(GuestCursor(image: nil, hotSpot: .zero))
            return
        }
        var pixels = try read(width * height * 4)
        let maskStride = (width + 7) / 8
        let mask = try read(maskStride * height)
        pixels.withUnsafeMutableBytes { bytes in
            let colors = bytes.bindMemory(to: UInt8.self)
            for row in 0..<height {
                for column in 0..<width {
                    let offset = (row * width + column) * 4
                    if mask[row * maskStride + column / 8] & (0x80 >> (column % 8)) == 0 {
                        colors[offset] = 0; colors[offset + 1] = 0; colors[offset + 2] = 0
                        colors[offset + 3] = 0
                    } else {
                        colors[offset + 3] = 255
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return }
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        onCursor?(GuestCursor(image: image, hotSpot: CGPoint(x: min(x, width - 1), y: min(y, height - 1))))
    }

    private func enqueue(_ packet: Data, replaceableMotion: Bool = false) {
        stateLock.lock()
        guard inputReady else { stateLock.unlock(); return }
        input.append(packet, replaceableMotion: replaceableMotion)
        if input.bytes.count > 16_384 {
            stateLock.unlock()
            onStatus?("Input stalled. Reconnect the display.")
            close()
            return
        }
        let schedule = !inputScheduled
        inputScheduled = true
        stateLock.unlock()
        if schedule { inputQueue.async { self.drainInput() } }
    }

    private func drainInput() {
        while true {
            stateLock.lock()
            let bytes = input.bytes
            input = RFBInputBatch()
            if bytes.isEmpty { inputScheduled = false }
            stateLock.unlock()
            guard !bytes.isEmpty else { return }
            do { try write(bytes, requiresReady: true) }
            catch {
                if !isStopped { onStatus?(error.localizedDescription) }
                close()
                return
            }
        }
    }

    func key(_ symbol: UInt32, down: Bool) {
        var packet = Data([4, down ? 1 : 0, 0, 0])
        packet.appendBE(symbol)
        enqueue(packet)
    }
    func pointer(x: UInt16, y: UInt16, buttons: UInt8, motion: Bool = false) {
        var packet = Data([5, buttons])
        packet.appendBE(x)
        packet.appendBE(y)
        enqueue(packet, replaceableMotion: motion)
    }
}

extension Data {
    func u16(_ i: Int) -> UInt16 { UInt16(self[i]) << 8 | UInt16(self[i+1]) }
    func u32(_ i: Int) -> UInt32 { UInt32(self[i]) << 24 | UInt32(self[i+1]) << 16 | UInt32(self[i+2]) << 8 | UInt32(self[i+3]) }
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) { var n = value.bigEndian; Swift.withUnsafeBytes(of: &n) { append(contentsOf: $0) } }
}
