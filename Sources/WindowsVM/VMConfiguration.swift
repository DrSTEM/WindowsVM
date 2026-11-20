import Foundation

enum DisplayBackend: String, Codable, CaseIterable {
    case compatibility, spice, metal

    var usesSpice: Bool { self != .compatibility }

    var label: String {
        switch self {
        case .compatibility: return "Compatibility (VNC)"
        case .spice: return "SPICE / Metal (display only)"
        case .metal: return "Metal and Direct3D 11 (experimental)"
        }
    }
}

struct VMConfiguration: Codable, Identifiable, Equatable {
    var schemaVersion = 1
    var id = UUID()
    var name = "Windows 11"
    var cpuCount = 4
    var memoryMiB = 6144
    var diskGiB = 80
    var installerPath: String?
    var networkEnabled = true
    var keyboardLayout = "en-gb"
    var displayResolution: GuestResolution?
    var displayScaling: DisplayScaling?
    var displayBackend: DisplayBackend?
    var createdAt = Date()

    func validate(requireMedia:Bool=true) throws {
        guard schemaVersion == 1 else { throw ConsoleError(message: "This VM configuration version is unsupported") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 100 else { throw ConsoleError(message: "Enter a VM name of 1–100 characters") }
        guard (2...min(8,ProcessInfo.processInfo.processorCount)).contains(cpuCount) else { throw ConsoleError(message: "Use 2–8 CPU cores, within the host’s available cores") }
        let maxMemory = Int(ProcessInfo.processInfo.physicalMemory / 1024 / 1024 * 3 / 4)
        guard (4096...maxMemory).contains(memoryMiB) else { throw ConsoleError(message: "Allocate at least 4 GB RAM and leave at least a quarter for macOS") }
        guard (64...2048).contains(diskGiB) else { throw ConsoleError(message: "Virtual disk capacity must be 64–2048 GB") }
        guard ["en-gb","en-us"].contains(keyboardLayout) else { throw ConsoleError(message: "Unsupported keyboard layout") }
        if let resolution = displayResolution {
            guard (800...7680).contains(resolution.width), (600...4320).contains(resolution.height) else { throw ConsoleError(message: "Display resolution must be within 800–7680 × 600–4320") }
        }
        if let path = installerPath, !path.isEmpty {
            guard path.hasPrefix("/"), URL(fileURLWithPath:path).pathExtension.lowercased()=="iso", (!requireMedia || FileManager.default.isReadableFile(atPath:path)) else { throw ConsoleError(message:"Choose a readable Windows ARM64 ISO") }
        }
    }
    static func load(from package: URL) throws -> Self {
        let data = try Data(contentsOf: package.appendingPathComponent("config.json"))
        guard data.count < 65536 else { throw ConsoleError(message: "Configuration file is too large") }
        let value = try JSONDecoder().decode(Self.self,from:data); try value.validate(requireMedia:false); return value
    }
    func save(to package: URL,requireMedia:Bool=true) throws {
        try validate(requireMedia:requireMedia)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(self).write(to:package.appendingPathComponent("config.json"),options:.atomic)
    }
}

struct VMSession: Codable {
    var directory: String
    var processID:Int32?=nil
    var displayPort: UInt16? // only the initial, adopted backend proof uses TCP
    var expectedName: String
    var displayBackend: DisplayBackend?
    var qmpPath: String { directory + "/qmp.sock" }
    var displayPath: String { directory + "/display.sock" }
    var tpmPath: String { directory + "/tpm.sock" }
    static func load(_ package: URL) -> Self? { try? JSONDecoder().decode(Self.self,from:Data(contentsOf:package.appendingPathComponent("session.json"))) }
    func save(_ package: URL) throws { try JSONEncoder().encode(self).write(to:package.appendingPathComponent("session.json"),options:.atomic) }
}

enum VMState: String { case stopped = "Stopped", starting = "Starting", running = "Running", paused = "Paused", unreachable = "Control unavailable", failed = "Needs attention" }

struct RuntimePaths {
    let root: URL
    var engine: URL { Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("VMEngine") }
    var qemu: URL { root.appendingPathComponent("Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu") }
    var firmware: URL { root.appendingPathComponent("qemu/edk2-aarch64-secure-code.fd") }
    var variables: URL { root.appendingPathComponent("qemu/edk2-arm-secure-vars.fd") }
    var imageTool: URL { root.appendingPathComponent("bin/qemu-img") }
    var tpm: URL { root.appendingPathComponent("bin/swtpm") }
    var dxmt: URL { root.appendingPathComponent("Frameworks/dxmt-native.framework/dxmt-native") }
    var renderServer: URL { root.appendingPathComponent("bin/VMRenderServer") }
    static var bundled: Self { Self(root: Bundle.main.resourceURL!.appendingPathComponent("Runtime")) }
    func validate(requireMedia:Bool=true) throws {
        for file in [engine,qemu,firmware,variables,imageTool,tpm] where !FileManager.default.isReadableFile(atPath:file.path) { throw ConsoleError(message:"Missing VM runtime component: \(file.lastPathComponent). Rebuild using scripts/build-app.sh.") }
    }
}

struct QEMUArguments {
    static func escape(_ path: String) -> String { path.replacingOccurrences(of:",",with:",,") }
    static func make(config: VMConfiguration, package: URL, session: VMSession, runtime: RuntimePaths, hostResolution: GuestResolution? = nil, hostRefreshRate: Double = 120) -> [String] {
        let p: (String)->String = { escape(package.appendingPathComponent($0).path) }
        let resolution = config.displayResolution ?? hostResolution ?? GuestResolution(width: 1920, height: 1200)
        // Windows allocates shared VirtIO GPU command rings on 4 KiB boundaries.
        // Select that HVF granule so every ring can be mapped into the guest.
        let accelerator = session.displayBackend == .metal ? "hvf,ipa-granule-size=0x1000" : "hvf"
        var args = [runtime.qemu.path,"-L",runtime.root.appendingPathComponent("qemu").path,
            "-name",session.expectedName,"-machine","virt-10.0,gic-version=3","-accel",accelerator,"-cpu","host",
            "-smp",String(config.cpuCount),"-m",String(config.memoryMiB),
            "-drive","if=pflash,format=raw,unit=0,readonly=on,file=\(escape(runtime.firmware.path))",
            "-drive","if=pflash,format=qcow2,unit=1,file=\(p("efi-vars.qcow2"))",
            "-drive","if=none,id=osdisk,format=qcow2,file=\(p("disk.qcow2"))",
            "-device","nvme,drive=osdisk,serial=\(config.id.uuidString.prefix(20)),bootindex=0",
            "-device","qemu-xhci,id=usb","-device","usb-kbd",
            "-chardev","socket,id=chrtpm,path=\(session.tpmPath)","-tpmdev","emulator,id=tpm0,chardev=chrtpm",
            "-device","tpm-crb-device,tpmdev=tpm0","-qmp","unix:\(session.qmpPath),server=on,wait=off",
            "-k",config.keyboardLayout,
            "-serial","file:\(package.appendingPathComponent("serial.log").path)"]
        let size = "xres=\(resolution.width),yres=\(resolution.height)"
        if let backend = session.displayBackend, backend.usesSpice {
            let gpu = backend == .metal
                ? "virtio-ramfb-gl,blob=true,hostmem=8G,neptune=true,\(size),refresh_rate=\(Int((hostRefreshRate * 1000).rounded()))"
                : "virtio-ramfb,\(size)"
            let gl = backend == .metal ? "es" : "off"
            args += ["-nodefaults","-vga","none","-device","usb-mouse",
                     "-device",gpu,
                     "-spice","unix=on,addr=\(escape(session.displayPath)),disable-ticketing=on,disable-copy-paste=on,disable-agent-file-xfer=on,gl=\(gl),image-compression=off,streaming-video=off"]
        } else {
            args += ["-device","virtio-ramfb,\(size)", "-vnc","unix:\(session.displayPath)", "-display","none"]
        }
        args += ["-device","usb-tablet"]
        if let iso = config.installerPath, !iso.isEmpty {
            args += ["-drive","if=none,id=installer,media=cdrom,format=raw,readonly=on,file=\(escape(iso))",
                     "-device","usb-storage,id=cdrom,drive=installer,removable=on,bootindex=1"]
        } else { args += ["-drive","if=none,id=installer,media=cdrom","-device","usb-storage,id=cdrom,drive=installer,removable=on"] }
        args += config.networkEnabled ? ["-netdev","user,id=net0","-device","virtio-net-pci,netdev=net0"] : ["-nic","none"]
        if session.displayBackend?.usesSpice == true {
            // Append the agent controller after the existing PCI devices so saved
            // guests keep the addresses of their graphics, network and boot disks.
            args += ["-device","virtio-serial-pci,id=spice-agent-bus",
                     "-chardev","spicevmc,id=spice-agent,name=vdagent",
                     "-device","virtserialport,bus=spice-agent-bus.0,chardev=spice-agent,name=com.redhat.spice.0"]
        }
        return args
    }

    static func graphicsEnvironment(session: VMSession, runtime: RuntimePaths, cache: URL) -> [String: String]? {
        guard session.displayBackend == .metal else { return nil }
        var environment = ProcessInfo.processInfo.environment
        environment["ANGLE_DEFAULT_PLATFORM"] = "metal"
        environment["RENDER_SERVER_EXEC_PATH"] = runtime.renderServer.path
        environment["NPT_BACKEND"] = "dxmt"
        for api in ["D3D11", "D3D12", "DXGI"] {
            environment["NPT_\(api)_LIBRARY_PATH"] = runtime.dxmt.path
        }
        environment["XDG_RUNTIME_DIR"] = session.directory
        // Isolate driver cache files from other apps and persist them between boots.
        environment["XDG_CACHE_HOME"] = cache.path
        return environment
    }
}
