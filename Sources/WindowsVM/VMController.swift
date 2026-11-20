import Foundation
import AppKit
import Darwin

@MainActor final class VMController: ObservableObject, Identifiable {
    nonisolated let id:UUID
    let package:URL
    @Published var config:VMConfiguration
    @Published var state:VMState = .stopped
    @Published var error:String?
    @Published var console:ConsoleModel?
    @Published var operationInProgress=false
    private(set) var session:VMSession?
    private var qemuProcess:Process?
    private var tpmProcess:Process?
    private var pollTimer:Timer?
    private var polling=false
    private let runtime=RuntimePaths.bundled
    var active:Bool { operationInProgress || state == .running || state == .paused || state == .starting || state == .unreachable }
    init(package:URL,config:VMConfiguration) {
        self.package=package;self.config=config;self.id=config.id;session=VMSession.load(package)
        pollTimer=Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in Task { @MainActor in await self?.refresh() } }
        Task { await refresh() }
    }
    deinit { pollTimer?.invalidate() }
    func refresh() async {
        guard let session,!polling,state != .starting else { return }
        polling=true;defer { polling=false }
        let status=await Task.detached { try? QMPClient(session:session).command("query-status") as? [String:Any] }.value
        if let name=status?["status"] as? String {
            let next:VMState = name == "paused" ? .paused:.running
            if state != next {state=next}
        } else {
            let exited:Bool
            if let process=qemuProcess {exited = !process.isRunning}
            else if let pid=session.processID {exited = kill(pid,0) == -1 && errno == ESRCH}
            else {exited=false}
            if exited {state = .stopped;console=nil}
            else if active || state == .stopped {state = .unreachable}
        }
    }
    func showConsole(reconnect:Bool=false) {
        guard let session,active else { return }
        if reconnect {console?.close();console=nil}
        if console == nil { console=ConsoleModel(session:session) }
    }
    func hideConsole() {
        console?.close()
        console = nil
    }
    func start() async {
        guard !active else { showConsole();return }
        let screen = HostDisplay.currentScreen
        let displayResolution = HostDisplay.fullScreenResolution(for: screen)
        let refreshRate = HostDisplay.refreshRate(for: screen)
        await refresh()
        if active { showConsole();return }
        state = .starting;error=nil
        do {
            try config.validate(requireMedia:false);try runtime.validate()
            if let iso=config.installerPath,!FileManager.default.isReadableFile(atPath:iso) {
                config.installerPath=nil;try config.save(to:package)
            }
            let disk=package.appendingPathComponent("disk.qcow2")
            let tool=runtime.imageTool
            let _=try await Task.detached { try StorageManager.run(tool,["info","--output=json",disk.path]) }.value
            let folder="/private/tmp/wvm-\(getuid())-\(UUID().uuidString)"
            guard mkdir(folder,0o700)==0 else { throw ConsoleError(message:"Cannot create a private VM runtime directory") }
            let session=VMSession(directory:folder,expectedName:"wvm-\(id.uuidString)",displayBackend:config.displayBackend)
            self.session=session;try session.save(package)
            let log=package.appendingPathComponent("qemu.log")
            if !FileManager.default.fileExists(atPath:log.path) { FileManager.default.createFile(atPath:log.path,contents:nil) }
            let logHandle=try FileHandle(forWritingTo:log);try logHandle.seekToEnd()
            let tpm=Process();tpm.executableURL=runtime.tpm
            tpm.arguments=["socket","--tpm2","--tpmstate","dir=\(QEMUArguments.escape(package.appendingPathComponent("tpm").path)),mode=0600,lock","--ctrl","type=unixio,path=\(session.tpmPath),mode=0600,terminate","--flags","not-need-init","--terminate"]
            tpm.standardOutput=logHandle;tpm.standardError=logHandle;try tpm.run();tpmProcess=tpm
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath:session.tpmPath) { break }
                guard tpm.isRunning else { throw ConsoleError(message:"TPM failed to start. Open the VM log for details.") }
                try await Task.sleep(nanoseconds:50_000_000)
            }
            guard FileManager.default.fileExists(atPath:session.tpmPath) else { throw ConsoleError(message:"TPM startup timed out") }
            let qemu=Process();qemu.executableURL=runtime.engine
            qemu.arguments=QEMUArguments.make(config:config,package:package,session:session,runtime:runtime,
                                             hostResolution:displayResolution,hostRefreshRate:refreshRate)
            if session.displayBackend == .metal {
                guard FileManager.default.isReadableFile(atPath: runtime.dxmt.path),
                      FileManager.default.isExecutableFile(atPath: runtime.renderServer.path) else {
                    throw ConsoleError(message: "The Metal graphics runtime is incomplete. Rebuild using scripts/prepare-runtime.py.")
                }
                let cache = package.appendingPathComponent("graphics-cache", isDirectory: true)
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                qemu.environment = QEMUArguments.graphicsEnvironment(session:session,runtime:runtime,cache:cache)
            }
            qemu.standardOutput=logHandle;qemu.standardError=logHandle
            qemu.terminationHandler={ [weak self,weak tpm] process in
                if tpm?.isRunning == true { tpm?.terminate() }
                Task { @MainActor in
                    self?.state=process.terminationStatus==0 ? .stopped : .failed
                    if process.terminationStatus != 0 { self?.error="QEMU exited with code \(process.terminationStatus). Open the VM log for details." }
                    self?.console=nil
                }
            }
            try qemu.run();qemuProcess=qemu
            var recorded=session;recorded.processID=qemu.processIdentifier
            self.session=recorded;try recorded.save(package)
            try logHandle.close()
            var ready=false
            for _ in 0..<100 {
                guard qemu.isRunning else { throw ConsoleError(message:"QEMU could not start. Open the VM log for details.") }
                if FileManager.default.fileExists(atPath:session.qmpPath) {
                    ready = await Task.detached { (try? QMPClient(session:session).command("query-status")) != nil }.value
                    if ready { break }
                }
                try await Task.sleep(nanoseconds:100_000_000)
            }
            guard ready else { throw ConsoleError(message:"VM startup timed out. Its disk remains intact; check the log before retrying.") }
            state = .running;showConsole()
        } catch {
            if qemuProcess?.isRunning != true,tpmProcess?.isRunning == true { tpmProcess?.terminate() }
            state = qemuProcess?.isRunning == true ? .unreachable:.failed;self.error=error.localizedDescription
        }
    }
    func command(_ name:String,arguments:[String:Any]=[:]) async {
        guard let session else { return }
        do { _=try await Task.detached { try QMPClient(session:session).command(name,arguments:arguments) }.value;await refresh() }
        catch { self.error=error.localizedDescription }
    }
    func save(_ updated:VMConfiguration) async throws {
        guard !active else { throw ConsoleError(message:"Shut down this VM before changing hardware") }
        operationInProgress=true;defer{operationInProgress=false}
        try updated.validate(requireMedia:false)
        if updated.diskGiB < config.diskGiB { throw ConsoleError(message:"Disk shrinking is not supported") }
        if updated.diskGiB > config.diskGiB {
            let storage=StorageManager(runtime:runtime),pkg=package,size=updated.diskGiB
            try await Task.detached { try storage.expand(pkg,to:size) }.value
        }
        try updated.save(to:package,requireMedia:false);config=updated
    }
    func mountISO(_ url:URL?) async {
        do {
            if let url { guard url.pathExtension.lowercased()=="iso",FileManager.default.isReadableFile(atPath:url.path) else {throw ConsoleError(message:"Choose a readable ISO image")} }
            if active {
                guard let session else { return }
                _=try await Task.detached {
                    let client=QMPClient(session:session)
                    let blocks=try client.command("query-block") as? [[String:Any]]
                    guard let device=blocks?.first(where:{$0["device"] as? String == "installer"})?["qdev"] as? String else {throw ConsoleError(message:"The removable ISO drive is unavailable")}
                    let args:[String:Any] = url.map { ["id":device,"filename":$0.path,"format":"raw","read-only-mode":"read-only"] } ?? ["id":device,"force":false]
                    return try client.command(url == nil ? "eject":"blockdev-change-medium",arguments:args)
                }.value
            }
            var updated=config;updated.installerPath=url?.path
            try updated.save(to:package);config=updated
        } catch { self.error=error.localizedDescription }
    }
    func revealLog() { NSWorkspace.shared.open(package.appendingPathComponent("qemu.log")) }
}

@MainActor final class VMLibrary:ObservableObject {
    @Published var machines:[VMController]=[]
    @Published var error:String?
    @Published var busy=false
    let directory:URL
    init() {
        let args=ProcessInfo.processInfo.arguments
        if let index=args.firstIndex(of:"--library"),index+1<args.count { UserDefaults.standard.set(args[index+1],forKey:"VMLibraryPath") }
        if let path=UserDefaults.standard.string(forKey:"VMLibraryPath") { directory=URL(fileURLWithPath:path) }
        else { directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Windows VM/Machines") }
        do { try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);reload() }
        catch { self.error=error.localizedDescription }
    }
    func reload() {
        do {
            let urls=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).filter { $0.pathExtension=="wvm" }
            var next:[VMController]=[]
            for url in urls {
                do {
                    let config=try VMConfiguration.load(from:url)
                    if let existing=machines.first(where:{$0.package==url}) { next.append(existing) }
                    else { next.append(VMController(package:url,config:config)) }
                } catch { self.error="Could not load \(url.lastPathComponent): \(error.localizedDescription). Its files are preserved." }
            }
            machines=next.sorted {$0.config.createdAt < $1.config.createdAt}
        } catch { self.error=error.localizedDescription }
    }
    func create(_ config:VMConfiguration,importDisk:URL?=nil) async throws -> UUID {
        busy=true;defer {busy=false}
        let storage=StorageManager(runtime:.bundled),dir=directory
        _=try await Task.detached { try storage.create(config,in:dir,importDisk:importDisk) }.value
        reload();return config.id
    }
    func duplicate(_ machine:VMController) async {
        guard !machine.active else { return };busy=true;machine.operationInProgress=true;defer {busy=false;machine.operationInProgress=false}
        do {
            var config=machine.config;config.id=UUID();config.name+=" copy";config.createdAt=Date()
            let destination=directory.appendingPathComponent(config.id.uuidString).appendingPathExtension("wvm")
            let source=machine.package
            let staging=directory.appendingPathComponent(".duplicate-"+UUID().uuidString)
            try await Task.detached { try FileManager.default.copyItem(at:source,to:staging) }.value
            try config.save(to:staging,requireMedia:false)
            try? FileManager.default.removeItem(at:staging.appendingPathComponent("session.json"))
            try FileManager.default.moveItem(at:staging,to:destination)
            reload()
        } catch {self.error=error.localizedDescription}
    }
    func trash(_ machine:VMController) {
        guard !machine.active else { return }
        do { try FileManager.default.trashItem(at:machine.package,resultingItemURL:nil);reload() } catch { self.error=error.localizedDescription }
    }
}
