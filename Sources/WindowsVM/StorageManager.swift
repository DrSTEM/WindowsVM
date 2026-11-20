import Foundation

struct StorageManager {
    let runtime: RuntimePaths
    static func run(_ executable:URL,_ arguments:[String]) throws -> String {
        let process=Process();process.executableURL=executable;process.arguments=arguments
        let pipe=Pipe();process.standardOutput=pipe;process.standardError=pipe
        try process.run()
        let output=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        let text=String(data:output,encoding:.utf8) ?? ""
        guard process.terminationStatus==0 else { throw ConsoleError(message:text.isEmpty ? "Storage tool failed (\(process.terminationStatus))" : text) }
        return text
    }
    func create(_ config:VMConfiguration,in library:URL,importDisk:URL?=nil) throws -> URL {
        try config.validate();try runtime.validate()
        let destination=library.appendingPathComponent(config.id.uuidString).appendingPathExtension("wvm")
        let package=library.appendingPathComponent(".creating-"+config.id.uuidString)
        var stored=config
        guard !FileManager.default.fileExists(atPath:destination.path) && !FileManager.default.fileExists(atPath:package.path) else { throw ConsoleError(message:"This VM already exists") }
        try FileManager.default.createDirectory(at:package,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        // Failures retain the partial package for diagnostics; never delete an existing disk.
        if let disk=importDisk {
            let info=try diskInfo(disk)
            let specific=(info["format-specific"] as? [String:Any])?["data"] as? [String:Any]
            guard info["backing-filename"]==nil && info["data-file"]==nil && specific?["data-file"]==nil else { throw ConsoleError(message:"Import requires a self-contained disk without external backing files") }
            _=try Self.run(runtime.imageTool,["convert","-p","-O","qcow2",disk.path,package.appendingPathComponent("disk.qcow2").path])
            if let size=info["virtual-size"] as? UInt64 {
                stored.diskGiB=max(config.diskGiB,Int((size+1_073_741_823)/1_073_741_824))
                if UInt64(stored.diskGiB)*1_073_741_824 > size {
                    _=try Self.run(runtime.imageTool,["resize",package.appendingPathComponent("disk.qcow2").path,"\(stored.diskGiB)G"])
                }
            }
        } else { _=try Self.run(runtime.imageTool,["create","-f","qcow2",package.appendingPathComponent("disk.qcow2").path,"\(config.diskGiB)G"]) }
        try FileManager.default.copyItem(at:runtime.variables,to:package.appendingPathComponent("efi-vars.qcow2"))
        try FileManager.default.createDirectory(at:package.appendingPathComponent("tpm"),withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        try stored.save(to:package)
        try FileManager.default.moveItem(at:package,to:destination)
        return destination
    }
    func diskInfo(_ disk:URL) throws -> [String:Any] {
        let text=try Self.run(runtime.imageTool,["info","--output=json",disk.path])
        guard let data=text.data(using:.utf8),let json=try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw ConsoleError(message:"Cannot inspect virtual disk") };return json
    }
    func expand(_ package:URL,to gib:Int) throws {
        let path=package.appendingPathComponent("disk.qcow2")
        let info=try diskInfo(path)
        guard let size=info["virtual-size"] as? UInt64,UInt64(gib)*1024*1024*1024>size else { throw ConsoleError(message:"Expansion must increase the current capacity") }
        _=try Self.run(runtime.imageTool,["resize",path.path,"\(gib)G"])
    }
}
