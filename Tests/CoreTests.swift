import Foundation
import CoreGraphics

@main struct CoreTests {
    static func main() throws {
        var checks=0
        func check(_ condition:@autoclosure () -> Bool,_ message:String) throws {
            guard condition() else {throw ConsoleError(message:"FAIL: \(message)")};checks+=1;print("PASS: \(message)")
        }
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("wvm-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:temporary)}
        var config=VMConfiguration();config.installerPath=nil
        config.cpuCount=min(4,ProcessInfo.processInfo.processorCount)
        let package=temporary.appendingPathComponent("A, B.wvm")
        try FileManager.default.createDirectory(at:package,withIntermediateDirectories:false)
        try config.save(to:package)
        let roundtrip=try VMConfiguration.load(from:package)
        try check(roundtrip==config,"configuration preserves identity and all resources")
        try check(roundtrip.displayResolution == nil && roundtrip.displayScaling == nil,"existing VM configurations load with automatic display defaults")
        var retina=config
        retina.displayResolution=GuestResolution(width:3024,height:1964);retina.displayScaling = .fill
        try retina.save(to:package)
        let retinaRoundtrip=try VMConfiguration.load(from:package)
        try check(retinaRoundtrip==retina,"Retina resolution and scaling persist with VM identity")
        let bounds=CGRect(x:0,y:0,width:800,height:600),imageSize=CGSize(width:1920,height:1080)
        try check(DisplayScaling.fill.imageRect(size:imageSize,bounds:bounds)==DisplayScaling.fit.imageRect(size:imageSize,bounds:bounds),"legacy fill preserves the guest aspect ratio")
        try check(DisplayScaling.fit.imageRect(size:imageSize,bounds:bounds)==CGRect(x:0,y:75,width:800,height:450),"fit mode preserves aspect ratio and pointer offsets")
        var framebuffer = DisplayFramebuffer()
        try framebuffer.resize(width: 3024, height: 1964)
        let fullBytes = Data(count: 3024 * 1964 * 4)
        try framebuffer.write(fullBytes, x: 0, y: 0, width: 3024, height: 1964)
        let initial = framebuffer.takeUpdate()!
        try check(initial.tiles.count == 96 && initial.tiles[95]?.width == 208
                  && initial.tiles[95]?.height == 172, "Retina scanout includes clipped tiles at the right and bottom edges")
        try framebuffer.write(Data([2, 4, 6, 0]), x: 3023, y: 1963, width: 1, height: 1)
        let edge = framebuffer.takeUpdate()!
        let bytes = edge.tiles[95]?.dataProvider?.data as Data?
        try check(edge.tiles.count == 1 && bytes?.suffix(4) == Data([2, 4, 6, 0]),
                  "a one-pixel desktop update copies only its tile and keeps the pixel at the correct offset")
        try framebuffer.write(Data([8, 7, 6, 0]), x: 0, y: 0, width: 1, height: 1)
        let corner = framebuffer.takeUpdate()!
        let mailbox = DisplayMailbox()
        let scheduled = mailbox.offer(edge)
        let rescheduled = mailbox.offer(corner)
        let merged = mailbox.take()
        try check(scheduled && !rescheduled && merged?.tiles.count == 2 && mailbox.take() == nil,
                  "pending partial updates preserve pixels in different tiles")
        let oldScheduled = mailbox.offer(edge)
        try framebuffer.resize(width: 1280, height: 720)
        try framebuffer.write(Data([1, 2, 3, 0]), x: 0, y: 0, width: 1, height: 1)
        let resized = framebuffer.takeUpdate()!
        let newScheduled = mailbox.offer(resized)
        let delivered = mailbox.take()
        try check(oldScheduled && !newScheduled && delivered?.resolution.width == 1280 && delivered?.tiles[95] == nil,
                  "resizing discards pending tiles from the old scanout")
        var input = RFBInputBatch()
        input.append(Data([1]), replaceableMotion: true)
        input.append(Data([2]), replaceableMotion: true)
        input.append(Data([3]), replaceableMotion: false)
        input.append(Data([4]), replaceableMotion: true)
        input.append(Data([5]), replaceableMotion: true)
        input.append(Data([6]), replaceableMotion: false)
        try check(input.bytes == Data([2, 3, 5, 6]), "stale motion is coalesced without moving it across ordered button and keyboard events")
        var bad=config;bad.schemaVersion=99
        do {try bad.validate();throw ConsoleError(message:"FAIL: unsupported schema accepted")}catch let e as ConsoleError {try check(e.message != "FAIL: unsupported schema accepted","unsupported configuration versions rejected")}
        bad=config;bad.memoryMiB=Int(ProcessInfo.processInfo.physicalMemory/1_048_576)
        do {try bad.validate();throw ConsoleError(message:"FAIL: unsafe RAM accepted")}catch let e as ConsoleError {try check(e.message != "FAIL: unsafe RAM accepted","host memory reserve enforced")}
        let session=VMSession(directory:"/private/tmp/wvm-test",expectedName:"test")
        let runtime=RuntimePaths(root:root.appendingPathComponent("Runtime"))
        let args=QEMUArguments.make(config:config,package:package,session:session,runtime:runtime)
        let retinaArgs=QEMUArguments.make(config:config,package:package,session:session,runtime:runtime,hostResolution:GuestResolution(width:3024,height:1964))
        try check(retinaArgs.contains("virtio-ramfb,xres=3024,yres=1964"),"automatic display advertises the Mac's physical pixels through EDID")
        var metalSession = session
        metalSession.displayBackend = .metal
        let metalArgs = QEMUArguments.make(config:config,package:package,session:metalSession,
                                          runtime:runtime,hostResolution:GuestResolution(width:3024,height:1964))
        try check(metalArgs.contains("virtio-ramfb-gl,blob=true,hostmem=8G,neptune=true,xres=3024,yres=1964,refresh_rate=120000")
                  && !metalArgs.contains("-vnc"), "Metal uses a Retina VirtIO 3D device without a VNC listener")
        try check(metalArgs.contains("hvf,ipa-granule-size=0x1000"),
                  "HVF maps Windows GPU command rings at their 4 KiB page boundaries")
        try check(metalArgs.contains(where: { $0.hasPrefix("unix=on,addr=/private/tmp/wvm-test/display.sock,")
                  && $0.contains("disable-copy-paste=on") && $0.contains("disable-agent-file-xfer=on") }),
                  "Metal uses the private socket without clipboard or file transfer")
        let graphicsCache = package.appendingPathComponent("graphics-cache")
        let graphicsEnvironment = QEMUArguments.graphicsEnvironment(session:metalSession,runtime:runtime,cache:graphicsCache)
        try check(graphicsEnvironment?["NPT_D3D11_LIBRARY_PATH"] == runtime.dxmt.path
                  && graphicsEnvironment?["RENDER_SERVER_EXEC_PATH"] == runtime.renderServer.path
                  && graphicsEnvironment?["XDG_CACHE_HOME"] == graphicsCache.path
                  && QEMUArguments.graphicsEnvironment(session:session,runtime:runtime,cache:graphicsCache) == nil,
                  "DXMT and the per-VM cache are configured only for Metal")
        var spiceSession = session
        spiceSession.displayBackend = .spice
        let spiceArgs = QEMUArguments.make(config:config,package:package,session:spiceSession,runtime:runtime)
        try check(spiceArgs.contains("virtio-ramfb,xres=1920,yres=1200")
                  && spiceArgs.contains("-spice") && spiceArgs.contains(where: { $0.contains(",gl=off,") })
                  && !spiceArgs.contains("-vnc"),
                  "display-only SPICE keeps the existing VirtIO adapter and uses the Metal console")
        let legacySession = try JSONDecoder().decode(VMSession.self,from:Data(
            #"{"directory":"/private/tmp/wvm-test","expectedName":"test"}"#.utf8))
        try check(legacySession.displayBackend == nil && args.contains("-vnc"),"existing sessions still use VNC")
        var withMedia=config;withMedia.installerPath="/private/tmp/tools.iso"
        let mediaArgs=QEMUArguments.make(config:withMedia,package:package,session:session,runtime:runtime)
        try check(!mediaArgs.contains("-boot") && mediaArgs.contains(where:{$0.contains("id=cdrom") && $0.contains("bootindex=1")}),"ARM ISO boot uses firmware device priorities without an unsupported boot-order command")
        try check(args.contains("hvf") && !args.contains("tcg"),"HVF required with no silent emulation fallback")
        try check(args.contains("unix:/private/tmp/wvm-test/display.sock"),"normal display transport is a Unix socket")
        try check(!args.contains(where:{$0.contains("hostfwd") || $0.contains("virtfs")}),"no automatic port forwarding or host directory sharing")
        try check(args.contains(where:{$0.contains("A,, B.wvm/disk.qcow2")}),"QEMU filename commas escaped")
        try check(args.contains("tpm-crb-device,tpmdev=tpm0"),"ARM TPM CRB configured")
        let tools=root.appendingPathComponent("Runtime/bin/qemu-img")
        let disk=temporary.appendingPathComponent("disk.qcow2")
        _=try StorageManager.run(tools,["create","-f","qcow2",disk.path,"64G"])
        let storage=StorageManager(runtime:runtime)
        let diskPackage=temporary.appendingPathComponent("disk-package")
        try FileManager.default.createDirectory(at:diskPackage,withIntermediateDirectories:false)
        try FileManager.default.moveItem(at:disk,to:diskPackage.appendingPathComponent("disk.qcow2"))
        try storage.expand(diskPackage,to:80)
        let info=try storage.diskInfo(diskPackage.appendingPathComponent("disk.qcow2"))
        try check(info["virtual-size"] as? UInt64 == 80*1024*1024*1024,"real QCOW2 expansion reaches requested capacity")
        do {try storage.expand(diskPackage,to:64);throw ConsoleError(message:"FAIL: shrink permitted")}catch let e as ConsoleError {try check(e.message != "FAIL: shrink permitted","disk shrinking is rejected")}
        _=try StorageManager.run(tools,["check",diskPackage.appendingPathComponent("disk.qcow2").path])
        try check(true,"expanded QCOW2 passes qemu-img integrity check")
        if let path=ProcessInfo.processInfo.environment["WVM_TEST_QMP_DIRECTORY"],let name=ProcessInfo.processInfo.environment["WVM_TEST_QMP_NAME"] {
            let session=VMSession(directory:path,expectedName:name)
            let result=try QMPClient(session:session).command("query-status") as? [String:Any]
            try check(result?["status"] != nil,"real QMP handshake, identity and command response")
            for _ in 0..<10 {_=try QMPClient(session:session).command("query-status")}
            try check(true,"rapid QMP transactions tolerate monitor reconnect timing")
            do {_=try QMPClient(session:VMSession(directory:path,expectedName:"wrong-vm")).command("query-status");throw ConsoleError(message:"FAIL: wrong VM accepted")}catch let e as ConsoleError {try check(e.message != "FAIL: wrong VM accepted","wrong VM identity rejected before mutation")}
        }
        print("\(checks) checks passed")
    }
}
