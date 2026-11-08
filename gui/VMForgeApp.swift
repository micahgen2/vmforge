import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CatalogEntry: Codable, Identifiable, Hashable { let id: String; let name: String; let arch: [String] }
struct VM: Codable, Identifiable, Hashable {
    var name: String; var kind: String; var arch: String
    var cpus: Int; var memoryMB: Int; var diskGB: Int; var iso: String?
    var id: String { name }
}

final class Backend: ObservableObject {
    @Published var vms: [VM] = []
    @Published var catalog: [CatalogEntry] = []
    @Published var running: Set<String> = []
    @Published var busy = false
    @Published var progress: Double? = nil
    @Published var log = ""
    @Published var failed = false

    private var current: Process?
    private var procs: [String: Process] = [:]
    let script = (Bundle.main.resourcePath ?? ".") + "/vmforge"
    let home = ProcessInfo.processInfo.environment["VMFORGE_HOME"] ?? (NSHomeDirectory() + "/VMForge")

    var hasDevTools: Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select"); p.arguments = ["-p"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit(); return p.terminationStatus == 0
    }

    var hasQemu: Bool {
        ["/opt/homebrew/bin", "/usr/local/bin"].contains { FileManager.default.fileExists(atPath: $0 + "/qemu-system-x86_64") }
    }

    private func makeProcess(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script] + args
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        return p
    }

    private func json<T: Decodable>(_ args: [String], as: T.Type) -> T? {
        let p = makeProcess(args); let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return try? JSONDecoder().decode(T.self, from: d)
    }

    func reload() {
        DispatchQueue.global().async {
            let c = self.json(["catalog", "--json"], as: [CatalogEntry].self) ?? []
            let v = self.json(["ls", "--json"], as: [VM].self) ?? []
            DispatchQueue.main.async { self.catalog = c; self.vms = v }
        }
    }

    private static let barOnly = try! NSRegularExpression(pattern: "^[#=\\d.% ]+$")
    private static let pct = try! NSRegularExpression(pattern: "(\\d{1,3}(?:\\.\\d)?)%")

    private func consume(_ s: String) {
        for seg in s.components(separatedBy: CharacterSet(charactersIn: "\r\n")) {
            let t = seg.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            let r = NSRange(t.startIndex..., in: t)
            if let m = Backend.pct.firstMatch(in: t, range: r), let rr = Range(m.range(at: 1), in: t), let v = Double(t[rr]) {
                progress = min(v / 100, 1)
                if Backend.barOnly.firstMatch(in: t, range: r) != nil || t.hasPrefix("Installing") { continue }
            } else if Backend.barOnly.firstMatch(in: t, range: r) != nil { continue }
            log += t + "\n"
        }
    }

    func stream(_ args: [String], done: @escaping (Bool) -> Void) {
        guard !busy else { return }
        busy = true; failed = false; progress = nil; log = ""
        let p = makeProcess(args); let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData; guard !d.isEmpty else { return }
            let s = String(decoding: d, as: UTF8.self)
            DispatchQueue.main.async { self?.consume(s) }
        }
        p.terminationHandler = { [weak self] pr in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.consume(rest)
                let ok = pr.terminationStatus == 0
                self.busy = false; self.progress = nil; self.current = nil; self.failed = !ok
                done(ok); self.reload()
            }
        }
        do { try p.run(); current = p } catch { busy = false; log = "Could not run python3: \(error)"; failed = true }
    }

    func cancel() { current?.terminate() }

    func create(name: String, image: String?, iso: String?, arch: String, cpus: Int, mem: Int, disk: Int, done: @escaping (Bool) -> Void) {
        var a = ["create", name]
        if let iso = iso { a += ["--iso", iso] } else if let image = image { a.append(image) }
        a += ["--arch", arch, "--cpus", String(cpus), "--mem", String(mem), "--disk", String(disk)]
        stream(a, done: done)
    }

    func start(_ vm: VM) {
        guard procs[vm.name] == nil else { return }
        let p = makeProcess(["run", vm.name])
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        p.terminationHandler = { [weak self] pr in
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async {
                self?.procs[vm.name] = nil; self?.running.remove(vm.name)
                if pr.terminationStatus != 0 { self?.failed = true; self?.log = out }
            }
        }
        if (try? p.run()) != nil { procs[vm.name] = p; running.insert(vm.name) }
    }

    func stop(_ vm: VM) { procs[vm.name]?.terminate() }

    func eject(_ vm: VM) {
        let p = makeProcess(["eject", vm.name]); try? p.run(); p.waitUntilExit(); reload()
    }

    func delete(_ vm: VM) {
        stop(vm)
        let p = makeProcess(["rm", vm.name, "--yes"]); try? p.run(); p.waitUntilExit(); reload()
    }
}

@main
struct VMForgeApp: App {
    @StateObject var be = Backend()
    var body: some Scene {
        WindowGroup("VMForge") {
            ContentView().environmentObject(be).frame(minWidth: 820, minHeight: 540)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var be: Backend
    @State private var selection: String?
    @State private var showNew = false
    @State private var devTools = true

    var body: some View {
        VStack(spacing: 0) {
            if !devTools {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Xcode Command Line Tools are required to run VMs. Open Terminal and run:  xcode-select --install")
                        .font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("Re-check") { devTools = be.hasDevTools }
                }.padding(10).background(.orange.opacity(0.15))
            }
            mainView
        }
        .onAppear { devTools = be.hasDevTools }
    }

    var mainView: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(be.vms) { vm in
                    HStack {
                        Image(systemName: vm.kind == "macos" ? "apple.logo" : "terminal")
                        Text(vm.name)
                        Spacer()
                        if be.running.contains(vm.name) { Circle().fill(.green).frame(width: 8, height: 8) }
                    }.tag(vm.name)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            .toolbar {
                ToolbarItem { Button { showNew = true } label: { Label("New VM", systemImage: "plus") } }
            }
        } detail: {
            if let vm = be.vms.first(where: { $0.name == selection }) {
                DetailView(vm: vm)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.plus").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text(be.vms.isEmpty ? "No virtual machines yet" : "Select a virtual machine").font(.title3)
                    Button("New VM…") { showNew = true }.buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showNew) { NewVMSheet(selection: $selection) }
        .onAppear { be.reload() }
    }
}

struct DetailView: View {
    @EnvironmentObject var be: Backend
    let vm: VM
    @State private var confirmDelete = false

    var body: some View {
        let on = be.running.contains(vm.name)
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(vm.name).font(.largeTitle.bold())
                if on { Text("Running").font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.green.opacity(0.25), in: Capsule()) }
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow { Text("Type").foregroundStyle(.secondary); Text(vm.kind == "macos" ? "macOS (native)" : vm.kind == "qemu" ? "x86_64 (emulated via QEMU)" : "Linux ARM64 (native)") }
                GridRow { Text("CPUs").foregroundStyle(.secondary); Text("\(vm.cpus)") }
                GridRow { Text("Memory").foregroundStyle(.secondary); Text("\(vm.memoryMB / 1024) GB") }
                GridRow { Text("Disk").foregroundStyle(.secondary); Text("\(vm.diskGB) GB (grows as used)") }
                GridRow { Text("Installer ISO").foregroundStyle(.secondary); Text(vm.iso.map { ($0 as NSString).lastPathComponent } ?? "none — boots from disk") }
            }
            HStack {
                if on { Button { be.stop(vm) } label: { Label("Stop", systemImage: "stop.fill") }.controlSize(.large) }
                else { Button { be.start(vm) } label: { Label("Start", systemImage: "play.fill") }.buttonStyle(.borderedProminent).controlSize(.large) }
                if vm.iso != nil && vm.kind != "macos" {
                    Button("Eject installer ISO") { be.eject(vm) }.disabled(on)
                        .help("Do this after the OS is installed so it boots from its disk")
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: be.home + "/vms/" + vm.name))
                }
                Spacer()
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            }
            if on { Text("Shut the guest down from inside its OS when you can — closing the window or Stop is like pulling the power.")
                .font(.footnote).foregroundStyle(.secondary) }
            if !be.log.isEmpty && !be.busy {
                ScrollView { Text(be.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 140).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer()
        }
        .padding(28)
        .confirmationDialog("Delete “\(vm.name)” and its disk?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { be.delete(vm) }
        } message: { Text("This permanently removes the VM and everything inside it.") }
    }
}

struct NewVMSheet: View {
    @EnvironmentObject var be: Backend
    @Environment(\.dismiss) var dismiss
    @Binding var selection: String?
    @State private var imageID = "alpine"
    @State private var arch = "arm64"
    @State private var name = ""
    @State private var cpus = 4
    @State private var mem = 4096
    @State private var disk = 40
    @State private var ownISO = false
    @State private var isoPath: String?
    @State private var picking = false

    var entry: CatalogEntry? { be.catalog.first { $0.id == imageID } }
    var finalName: String { name.isEmpty ? imageID : name }
    var nameOK: Bool {
        finalName.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil && !be.vms.contains { $0.name == finalName }
    }
    var canCreate: Bool { nameOK && (!ownISO || isoPath != nil) && !be.busy && (arch == "arm64" || be.hasQemu) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Virtual Machine").font(.title2.bold())
            Form {
                Toggle("Use my own ISO file", isOn: $ownISO)
                if ownISO {
                    HStack {
                        Text(isoPath.map { ($0 as NSString).lastPathComponent } ?? "No file chosen").foregroundStyle(.secondary)
                        Spacer(); Button("Choose…") { picking = true }
                    }
                } else {
                    Picker("Operating system", selection: $imageID) {
                        ForEach(be.catalog) { Text($0.name).tag($0.id) }
                    }
                }
                Picker("Architecture", selection: $arch) {
                    Text("Apple Silicon (fast)").tag("arm64")
                    if !ownISO, entry?.arch.contains("x86_64") ?? true { Text("Intel x86_64 (emulated, slow)").tag("x86_64") }
                }.pickerStyle(.segmented)
                if arch == "x86_64" && !be.hasQemu {
                    Text("Intel emulation needs QEMU: install Homebrew, then run  brew install qemu").font(.footnote).foregroundStyle(.orange)
                }
                TextField("Name", text: $name, prompt: Text(imageID))
                Stepper("CPUs: \(cpus)", value: $cpus, in: 1...16)
                Picker("Memory", selection: $mem) {
                    ForEach([2048, 4096, 8192, 16384], id: \.self) { Text("\($0 / 1024) GB").tag($0) }
                }
                Stepper("Disk: \(disk) GB", value: $disk, in: 8...500, step: 8)
                if !nameOK { Text("Name must be unique and use letters, numbers, . _ -").font(.footnote).foregroundStyle(.red) }
                if imageID == "macos" && !ownISO { Text("Downloads about 15 GB, then installs macOS. This takes a while.").font(.footnote).foregroundStyle(.secondary) }
            }.formStyle(.grouped).disabled(be.busy)

            if be.busy || !be.log.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if be.busy { if let p = be.progress { ProgressView(value: p) } else { ProgressView().progressViewStyle(.linear) } }
                    ScrollView { Text(be.log).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(height: 80).padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            HStack {
                Spacer()
                Button(be.busy ? "Cancel download" : "Close") { if be.busy { be.cancel() } else { dismiss() } }
                Button("Create") {
                    be.create(name: finalName, image: ownISO ? nil : imageID, iso: ownISO ? isoPath : nil, arch: arch,
                              cpus: cpus, mem: mem, disk: disk) { ok in
                        if ok { selection = finalName; dismiss() }
                    }
                }.buttonStyle(.borderedProminent).disabled(!canCreate).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 520)
        .onChange(of: imageID) { _ in if imageID == "macos" { arch = "arm64"; mem = max(mem, 8192); disk = max(disk, 80) } }
        .onChange(of: ownISO) { _ in if ownISO { arch = "arm64" } }
        .fileImporter(isPresented: $picking, allowedContentTypes: [UTType(filenameExtension: "iso") ?? .data]) { r in
            if case .success(let u) = r { isoPath = u.path }
        }
        .onAppear { be.log = ""; be.failed = false }
    }
}
