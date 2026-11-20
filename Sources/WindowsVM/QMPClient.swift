import Foundation
import Darwin

/// A bounded QMP transaction. Each operation authenticates the expected VM name.
/// Private parent directory permissions protect the Unix socket from other users.
struct QMPClient {
    private static let transactionLock=NSLock()
    let session: VMSession
    func command(_ name: String, arguments: [String:Any] = [:]) throws -> Any {
        try withMonitor { try transact($0, name, arguments) }
    }

    func selectPointer(absolute: Bool) throws -> Bool {
        try withMonitor { channel in
            let devices = try transact(channel, "query-mice", [:]) as? [[String: Any]]
            guard let pointer = devices?.first(where: { ($0["absolute"] as? Bool) == absolute }),
                  let index = pointer["index"] as? Int else { return false }
            if pointer["current"] as? Bool != true {
                _ = try transact(channel, "human-monitor-command", ["command-line": "mouse_set \(index)"])
            }
            return true
        }
    }

    private func withMonitor<T>(_ action: (UnixChannel) throws -> T) throws -> T {
        Self.transactionLock.lock();defer{Self.transactionLock.unlock()}
        // QEMU's monitor accepts one connection. A just-closed connection may
        // not yet have been reaped by its event loop; retry only connection
        // establishment, never a command whose delivery is uncertain.
        var connected:UnixChannel?
        var lastError:Error?
        for _ in 0..<20 {
            do {connected=try UnixChannel(path:session.qmpPath);break}
            catch {lastError=error;Thread.sleep(forTimeInterval:0.05)}
        }
        guard let channel=connected else {throw lastError ?? ConsoleError(message:"VM control unavailable") }
        defer { channel.close() }
        let greeting = try channel.jsonLine()
        guard greeting["QMP"] != nil else { throw ConsoleError(message:"Unexpected VM control service") }
        _ = try transact(channel,"qmp_capabilities",[:])
        let identity = try transact(channel,"query-name",[:]) as? [String:Any]
        guard identity?["name"] as? String == session.expectedName else { throw ConsoleError(message:"VM control identity does not match this machine") }
        return try action(channel)
    }
    private func transact(_ channel: UnixChannel,_ name:String,_ args:[String:Any]) throws -> Any {
        let id = UUID().uuidString
        var data = try JSONSerialization.data(withJSONObject:["execute":name,"arguments":args,"id":id]);data.append(contentsOf:[13,10])
        try channel.write(data)
        for _ in 0..<128 {
            let reply = try channel.jsonLine()
            guard reply["id"] as? String == id else { continue }
            if let error = reply["error"] as? [String:Any] { throw ConsoleError(message:error["desc"] as? String ?? "VM command failed") }
            guard let result = reply["return"] else { throw ConsoleError(message:"Invalid VM control reply") }
            return result
        }
        throw ConsoleError(message:"VM sent too many unrelated control events")
    }
}

final class UnixChannel {
    private var fd:Int32
    init(path:String) throws {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)+[0]
        guard bytes.count <= MemoryLayout.size(ofValue:address.sun_path) else { throw ConsoleError(message:"VM socket path is too long") }
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of:&address.sun_path) { buffer in buffer.copyBytes(from:bytes) }
        fd = socket(AF_UNIX,SOCK_STREAM,0)
        guard fd >= 0 else { throw ConsoleError(message:"Cannot create local VM control socket") }
        var timeout = timeval(tv_sec:3,tv_usec:0), one:Int32=1
        setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size));setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to:&address) { p in p.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { let message = String(cString:strerror(errno));Darwin.close(fd);fd = -1;throw ConsoleError(message:"VM control unavailable: \(message)") }
    }
    func close() { if fd >= 0 { Darwin.close(fd);fd = -1 } }
    deinit { close() }
    func write(_ data:Data) throws {
        try data.withUnsafeBytes { b in
            var count=0
            while count<data.count {
                let n=Darwin.write(fd,b.baseAddress!.advanced(by:count),data.count-count)
                if n<0 && errno==EINTR { continue };guard n>0 else { throw ConsoleError(message:"Could not send VM command") };count+=n
            }
        }
    }
    func jsonLine() throws -> [String:Any] {
        var data=Data(),byte:UInt8=0
        while data.count<1_048_576 {
            let n=Darwin.read(fd,&byte,1)
            if n<0 && errno==EINTR { continue };guard n==1 else { throw ConsoleError(message:"VM control disconnected or timed out") }
            if byte==10 { guard let json=try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw ConsoleError(message:"Invalid VM control message") };return json }
            data.append(byte)
        }
        throw ConsoleError(message:"VM control message exceeds the safety limit")
    }
}
