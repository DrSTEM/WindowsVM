import SwiftUI
import AppKit

@main struct WindowsVMApp:App {
    @NSApplicationDelegateAdaptor(VMAppDelegate.self) private var delegate
    @StateObject private var library=VMLibrary()
    var body:some Scene {
        Window("Virtual Machines",id:"library") { LibraryView(library:library).onAppear{delegate.library=library} }
            .defaultSize(width:1050,height:720)
        WindowGroup("Windows",for:UUID.self) { $id in
            if let id,let machine=library.machines.first(where:{$0.id==id}) { VMConsoleScreen(machine:machine) }
            else { ContentUnavailableView("Virtual machine unavailable",systemImage:"desktopcomputer") }
        }.defaultSize(width:1100,height:820).windowStyle(.hiddenTitleBar)
    }
}

struct LibraryView:View {
    @ObservedObject var library:VMLibrary
    @Environment(\.openWindow) private var openWindow
    @State private var selected:UUID?
    @State private var creating=false
    @State private var editing=false
    @State private var importedDisk:URL?
    private var machine:VMController? { library.machines.first {$0.id==selected} }
    var body:some View {
        NavigationSplitView {
            List(selection:$selected) {
                Section("Virtual machines") {
                    ForEach(library.machines) { machine in VMRow(machine:machine).tag(machine.id) }
                }
            }.navigationSplitViewColumnWidth(min:220,ideal:260)
            .safeAreaInset(edge:.bottom) {
                HStack {
                    Button { importedDisk=nil;creating=true } label:{Label("New",systemImage:"plus")}.keyboardShortcut("n",modifiers:.command)
                    Spacer()
                    Button { importDisk() } label:{Image(systemName:"square.and.arrow.down")}.help("Import a self-contained virtual disk")
                }.padding(14)
            }
        } detail: {
            if let machine {
                MachineDetail(machine:machine,onOpen:{ openWindow(value:machine.id) },onEdit:{ editing=true },onDuplicate:{Task{await library.duplicate(machine)}},onRemove:{
                    DispatchQueue.main.async {
                        if confirm("Move \(machine.config.name) to the Trash?",message:"Its VM package, virtual disk and saved TPM state can be recovered from the Mac’s Trash.",action:"Move to Trash") {library.trash(machine)}
                    }
                })
            } else {
                VStack(spacing:18) {
                    Image(systemName:"desktopcomputer").font(.system(size:58)).foregroundStyle(.tint)
                    Text("Windows, on your Mac").font(.largeTitle.bold())
                    Text("Create a Windows 11 ARM64 virtual machine with hardware acceleration.").foregroundStyle(.secondary)
                    Button("Create Virtual Machine") { importedDisk=nil;creating=true }.buttonStyle(.borderedProminent)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        }
        .toolbar {
            ToolbarItem { Button { NSWorkspace.shared.open(library.directory) } label:{Label("VM Files",systemImage:"folder")}.help("Show the persistent VM library in Finder") }
        }
        .overlay { if library.busy { ProgressView("Preparing virtual machine…").padding(24).background(.regularMaterial,in:RoundedRectangle(cornerRadius:16)) } }
        .sheet(isPresented:$creating) {
            VMEditor(draft:VMConfiguration(),isNew:true,importDisk:importedDisk) { draft in
                let id=try await library.create(draft,importDisk:importedDisk);selected=id
            }
        }
        .sheet(isPresented:$editing) {
            if let machine { VMEditor(draft:machine.config,isNew:false,importDisk:nil) { try await machine.save($0) } }
        }
        .alert("Virtual machine",isPresented:Binding(get:{library.error != nil},set:{if !$0 {library.error=nil}})) {Button("OK"){library.error=nil}} message:{Text(library.error ?? "")}
        .onAppear {if selected==nil {selected=library.machines.first?.id}}
        .onChange(of:library.machines.count) { if machine==nil {selected=library.machines.first?.id} }
    }
    private func importDisk() {
        let panel=NSOpenPanel();panel.title="Import a self-contained Windows ARM64 virtual disk";panel.allowsMultipleSelection=false;panel.canChooseDirectories=false
        panel.allowedContentTypes=[]
        if panel.runModal() == .OK,let url=panel.url {importedDisk=url;creating=true}
    }
}

struct VMRow:View {
    @ObservedObject var machine:VMController
    var body:some View {
        HStack(spacing:10) {
            Image(systemName:"desktopcomputer").font(.title2).foregroundStyle(.tint)
            VStack(alignment:.leading,spacing:4) {Text(machine.config.name).font(.headline);Text(machine.state.rawValue).font(.caption).foregroundStyle(.secondary)}
        }.padding(.vertical,7)
    }
}

struct MachineDetail:View {
    @ObservedObject var machine:VMController
    let onOpen:()->Void,onEdit:()->Void,onDuplicate:()->Void,onRemove:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:28) {
            HStack(alignment:.top,spacing:20) {
                Image(systemName:"desktopcomputer").font(.system(size:54)).foregroundStyle(.tint).frame(width:100,height:100).background(.quaternary,in:RoundedRectangle(cornerRadius:24))
                VStack(alignment:.leading,spacing:8) {Text(machine.config.name).font(.largeTitle.bold());Text("Windows 11 · ARM64").foregroundStyle(.secondary);Label(machine.state.rawValue,systemImage:machine.active ? "circle.fill":"circle").font(.callout).foregroundStyle(machine.active ? .green:.secondary)}
                Spacer()
            }
            HStack(spacing:32) {
                resource("CPU",value:"\(machine.config.cpuCount) cores",icon:"cpu")
                resource("Memory",value:"\(machine.config.memoryMiB/1024) GB",icon:"memorychip")
                resource("Disk capacity",value:"\(machine.config.diskGiB) GB",icon:"internaldrive")
            }
            HStack {
                Button { Task {if !machine.active {await machine.start()};if machine.active {onOpen()}} } label:{Label(machine.active ? "Open Windows":"Start",systemImage:"play.fill")}.buttonStyle(.borderedProminent).controlSize(.large).disabled(machine.state == .starting || machine.operationInProgress)
                Button("Settings",action:onEdit).controlSize(.large).disabled(machine.active)
                Menu("More") {
                    Button("Show VM Files") {NSWorkspace.shared.open(machine.package)}
                    Button("Open Log") {machine.revealLog()}
                    Divider()
                    Button("Duplicate",action:onDuplicate).disabled(machine.active)
                    Button("Export Disk…") {DispatchQueue.main.async {exportDisk()}}.disabled(machine.active)
                    Button("Move to Trash…",role:.destructive,action:onRemove).disabled(machine.active)
                }.menuStyle(.borderlessButton).fixedSize()
            }
            GroupBox {
                VStack(alignment:.leading,spacing:12) {
                    Label(machine.config.networkEnabled ? "NAT networking enabled":"Network disconnected",systemImage:"network")
                    Label("UEFI Secure Boot firmware and persistent TPM 2.0",systemImage:"lock.shield")
                    Label(machine.config.installerPath.map{URL(fileURLWithPath:$0).lastPathComponent} ?? "Installer ejected",systemImage:"opticaldisc")
                }.font(.callout).frame(maxWidth:.infinity,alignment:.leading).padding(10)
            }
            if let error=machine.error {Text(error).foregroundStyle(.red).textSelection(.enabled)}
            Text("Windows activation and guest drivers are managed inside Windows. Hardware settings can be changed after shutdown.").font(.callout).foregroundStyle(.secondary)
            Spacer()
        }.padding(40).frame(maxWidth:850,alignment:.leading).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
    }
    private func resource(_ title:String,value:String,icon:String)->some View {VStack(alignment:.leading,spacing:6){Label(title,systemImage:icon).font(.caption).foregroundStyle(.secondary);Text(value).font(.title3.weight(.semibold))}}
    private func exportDisk() {
        let panel=NSSavePanel();panel.title="Export a standalone QCOW2 disk";panel.nameFieldStringValue=machine.config.name+".qcow2"
        guard panel.runModal() == .OK,let output=panel.url else {return}
        guard !FileManager.default.fileExists(atPath:output.path) else {machine.error="Choose a new filename; export does not overwrite existing disks.";return}
        let input=machine.package.appendingPathComponent("disk.qcow2"),tool=RuntimePaths.bundled.imageTool
        machine.operationInProgress=true
        Task {defer{machine.operationInProgress=false};do {_=try await Task.detached {try StorageManager.run(tool,["convert","-O","qcow2",input.path,output.path])}.value;NSWorkspace.shared.activateFileViewerSelecting([output])}catch{machine.error=error.localizedDescription}}
    }
}

struct VMEditor:View {
    @Environment(\.dismiss) private var dismiss
    @State var draft:VMConfiguration
    let isNew:Bool
    let importDisk:URL?
    let save:(VMConfiguration) async throws -> Void
    @State private var busy=false
    @State private var error:String?
    private var maxMemory:Int { Int(ProcessInfo.processInfo.physicalMemory / 1_048_576) * 3 / 4 }
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text(isNew ? "Create a Windows virtual machine":"Virtual Machine Settings").font(.title2.bold())
            Form {
                Section("Windows 11 ARM64") {
                    TextField("Name",text:$draft.name)
                    LabeledContent("Installer") {
                        Text(draft.installerPath.map{URL(fileURLWithPath:$0).lastPathComponent} ?? "No ISO selected").lineLimit(1).truncationMode(.middle)
                        Button("Choose…"){let p=NSOpenPanel();p.canChooseDirectories=false;p.allowedContentTypes=[];if p.runModal() == .OK{draft.installerPath=p.url?.path}}
                    }
                    HStack{Button("Download Windows from Microsoft"){NSWorkspace.shared.open(URL(string:"https://www.microsoft.com/en-us/software-download/windows11arm64")!)};Spacer();if draft.installerPath != nil{Button("Eject"){draft.installerPath=nil}}}
                    if let importDisk{Text("Import: \(importDisk.lastPathComponent)").font(.caption)}
                }
                Section("Hardware") {
                    Stepper("CPU cores: \(draft.cpuCount)",value:$draft.cpuCount,in:2...min(8,ProcessInfo.processInfo.processorCount))
                    Stepper("Memory: \(draft.memoryMiB/1024) GB",value:$draft.memoryMiB,in:4096...maxMemory,step:1024)
                    Stepper("Disk capacity: \(draft.diskGiB) GB",value:$draft.diskGiB,in:64...2048,step:16)
                    Text(isNew ? "Disk space is allocated as Windows writes data.":"Increasing capacity expands the virtual disk. Extend the Windows partition in Disk Management afterward. Shrinking is unavailable.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Devices") {
                    Picker("Graphics",selection:Binding(get:{draft.displayBackend ?? .compatibility},
                                                        set:{draft.displayBackend = $0})) {
                        ForEach(DisplayBackend.allCases,id:\.self) { backend in
                            Text(backend.label).tag(backend)
                        }
                    }
                    if draft.displayBackend == .metal {
                        Text("For Direct3D 11, install the ARM64 VirtIO GPU 3D driver from the UTM Guest Tools ISO. Change graphics modes with Windows shut down.").font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Preferred resolution",selection:$draft.displayResolution) {
                        Text("Match Mac Retina (\(HostDisplay.fullScreenResolution(for: HostDisplay.currentScreen).label))").tag(GuestResolution?.none)
                        ForEach(GuestResolution.presets,id:\.self) {resolution in Text(resolution.label).tag(Optional(resolution))}
                        if let resolution=draft.displayResolution,!GuestResolution.presets.contains(resolution) {Text(resolution.label).tag(Optional(resolution))}
                    }
                    Text("With the SPICE guest agent, Match Mac Retina also follows the window’s size. Fixed resolutions take effect on the next start.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Enable NAT networking",isOn:$draft.networkEnabled)
                    Picker("Keyboard",selection:$draft.keyboardLayout){Text("United Kingdom").tag("en-gb");Text("United States").tag("en-us")}
                    Text("Apple Silicon · HVF · NVMe · USB keyboard and tablet · Secure Boot UEFI · TPM 2.0").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            if let error{Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)}
            HStack{Button("Cancel"){dismiss()}.keyboardShortcut(.cancelAction);Spacer();if busy{ProgressView().controlSize(.small)};Button(isNew ? "Create":"Save"){Task{busy=true;defer{busy=false};do{try await save(draft);dismiss()}catch{self.error=error.localizedDescription}}}.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(busy)}
        }.padding(24).frame(width:620,height:650).interactiveDismissDisabled(busy)
    }
}

@MainActor func confirm(_ title:String,message:String,action:String)->Bool {
    let alert=NSAlert();alert.messageText=title;alert.informativeText=message;alert.addButton(withTitle:action);alert.addButton(withTitle:"Cancel");return alert.runModal() == .alertFirstButtonReturn
}

@MainActor final class VMAppDelegate:NSObject,NSApplicationDelegate {
    weak var library:VMLibrary?
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        guard library?.machines.contains(where:{$0.active}) == true else{return .terminateNow}
        return confirm("Keep virtual machines running?",message:"Closing Windows VM leaves active machines running. Reopen the app to reconnect, or cancel and shut down Windows from the Power menu first.",action:"Keep Running and Quit") ? .terminateNow:.terminateCancel
    }
}
