// vmhost — native VM runner for vmforge, built on Apple's Virtualization.framework.
// Runs ARM64 Linux guests (EFI boot) and macOS guests at near-native speed.
import Foundation
import Virtualization
import AppKit

struct Config: Codable {
    var name: String
    var kind: String          // "linux" | "macos"
    var cpus: Int
    var memoryMB: Int
    var diskGB: Int
    var iso: String?
    var width: Int?
    var height: Int?
}

func say(_ m: String) { print(m); fflush(stdout) }
func die(_ m: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + m + "\n").utf8))
    exit(1)
}

func loadConfig(_ dir: URL) -> Config {
    do {
        let d = try Data(contentsOf: dir.appendingPathComponent("vm.json"))
        return try JSONDecoder().decode(Config.self, from: d)
    } catch { die("cannot read vm.json in \(dir.path): \(error)") }
}

func ensureDisk(_ url: URL, gb: Int) throws {
    if FileManager.default.fileExists(atPath: url.path) { return }
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let h = try FileHandle(forWritingTo: url)
    try h.truncate(atOffset: UInt64(gb) * 1024 * 1024 * 1024)   // sparse
    try h.close()
}

func baseConfig(_ cfg: Config, _ dir: URL) throws -> VZVirtualMachineConfiguration {
    let c = VZVirtualMachineConfiguration()
    c.cpuCount = min(max(cfg.cpus, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
                     VZVirtualMachineConfiguration.maximumAllowedCPUCount)
    c.memorySize = min(max(UInt64(cfg.memoryMB) << 20, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                       VZVirtualMachineConfiguration.maximumAllowedMemorySize)

    let disk = dir.appendingPathComponent("disk.img")
    try ensureDisk(disk, gb: cfg.diskGB)
    let att = try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false)
    c.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: att)]

    let net = VZVirtioNetworkDeviceConfiguration()
    net.attachment = VZNATNetworkDeviceAttachment()
    c.networkDevices = [net]

    c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    c.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

    let snd = VZVirtioSoundDeviceConfiguration()
    let out = VZVirtioSoundDeviceOutputStreamConfiguration()
    out.sink = VZHostAudioOutputStreamSink()
    snd.streams = [out]
    c.audioDevices = [snd]
    return c
}

func linuxConfig(_ cfg: Config, _ dir: URL) throws -> VZVirtualMachineConfiguration {
    let c = try baseConfig(cfg, dir)

    let platform = VZGenericPlatformConfiguration()
    let midURL = dir.appendingPathComponent("machine.bin")
    if let d = try? Data(contentsOf: midURL), let mid = VZGenericMachineIdentifier(dataRepresentation: d) {
        platform.machineIdentifier = mid
    } else {
        let mid = VZGenericMachineIdentifier()
        try mid.dataRepresentation.write(to: midURL)
        platform.machineIdentifier = mid
    }
    c.platform = platform

    let boot = VZEFIBootLoader()
    let nvram = dir.appendingPathComponent("efi.nvram")
    boot.variableStore = FileManager.default.fileExists(atPath: nvram.path)
        ? VZEFIVariableStore(url: nvram)
        : try VZEFIVariableStore(creatingVariableStoreAt: nvram)
    c.bootLoader = boot

    if let iso = cfg.iso, !iso.isEmpty {
        guard FileManager.default.fileExists(atPath: iso) else { die("ISO not found: \(iso)") }
        let a = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: iso), readOnly: true)
        c.storageDevices.append(VZUSBMassStorageDeviceConfiguration(attachment: a))
    }

    let gpu = VZVirtioGraphicsDeviceConfiguration()
    gpu.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: cfg.width ?? 1440, heightInPixels: cfg.height ?? 900)]
    c.graphicsDevices = [gpu]
    c.keyboards = [VZUSBKeyboardConfiguration()]
    c.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    return c
}

func macConfig(_ cfg: Config, _ dir: URL) throws -> VZVirtualMachineConfiguration {
    let c = try baseConfig(cfg, dir)
    guard let hwData = try? Data(contentsOf: dir.appendingPathComponent("hardware.bin")),
          let hw = VZMacHardwareModel(dataRepresentation: hwData),
          let midData = try? Data(contentsOf: dir.appendingPathComponent("machine.bin")),
          let mid = VZMacMachineIdentifier(dataRepresentation: midData)
    else { die("macOS VM is not installed yet (missing hardware.bin / machine.bin)") }

    let p = VZMacPlatformConfiguration()
    p.hardwareModel = hw
    p.machineIdentifier = mid
    p.auxiliaryStorage = VZMacAuxiliaryStorage(url: dir.appendingPathComponent("aux.img"))
    c.platform = p
    c.bootLoader = VZMacOSBootLoader()

    let gpu = VZMacGraphicsDeviceConfiguration()
    gpu.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: cfg.width ?? 1920,
                                                     heightInPixels: cfg.height ?? 1200,
                                                     pixelsPerInch: 144)]
    c.graphicsDevices = [gpu]
    c.keyboards = [VZMacKeyboardConfiguration()]
    c.pointingDevices = [VZMacTrackpadConfiguration()]
    return c
}

// MARK: - GUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, VZVirtualMachineDelegate {
    let vm: VZVirtualMachine
    let cfg: Config
    var window: NSWindow!

    init(vm: VZVirtualMachine, cfg: Config) { self.vm = vm; self.cfg = cfg }

    func applicationDidFinishLaunching(_ n: Notification) {
        vm.delegate = self
        let isMac = cfg.kind == "macos"
        let w = CGFloat(cfg.width ?? (isMac ? 1920 : 1440)) / (isMac ? 2 : 1)
        let h = CGFloat(cfg.height ?? (isMac ? 1200 : 900)) / (isMac ? 2 : 1)

        let view = VZVirtualMachineView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        if #available(macOS 14.0, *) { view.automaticallyReconfiguresDisplay = true }

        window = NSWindow(contentRect: view.frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "vmforge — \(cfg.name)"
        window.contentView = view
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)

        vm.start { result in
            if case .failure(let e) = result { die("failed to start VM: \(e)") }
            say("VM started.")
        }
    }

    func windowWillClose(_ n: Notification) {
        if vm.canStop { vm.stop { _ in exit(0) } } else { exit(0) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func guestDidStop(_ vm: VZVirtualMachine) { say("Guest stopped."); exit(0) }
    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) { die("VM stopped: \(error)") }
}

func installMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem(); main.addItem(appItem)
    let sub = NSMenu()
    sub.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = sub
    NSApp.mainMenu = main
}

func runVM(_ dir: URL) {
    let cfg = loadConfig(dir)
    let conf: VZVirtualMachineConfiguration
    do {
        conf = cfg.kind == "macos" ? try macConfig(cfg, dir) : try linuxConfig(cfg, dir)
        try conf.validate()
    } catch { die("invalid VM configuration: \(error)") }

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    installMenu()
    let vm = VZVirtualMachine(configuration: conf)
    let delegate = AppDelegate(vm: vm, cfg: cfg)
    app.delegate = delegate
    app.run()
}

// MARK: - macOS guest install

func macInstall(_ dir: URL, ipsw: URL) {
    let cfg = loadConfig(dir)
    VZMacOSRestoreImage.load(from: ipsw) { result in
        DispatchQueue.main.async {
            switch result {
            case .failure(let e): die("cannot read restore image: \(e)")
            case .success(let image):
                guard let req = image.mostFeaturefulSupportedConfiguration else {
                    die("this restore image is not supported on this Mac")
                }
                do {
                    try req.hardwareModel.dataRepresentation.write(to: dir.appendingPathComponent("hardware.bin"))
                    try VZMacMachineIdentifier().dataRepresentation.write(to: dir.appendingPathComponent("machine.bin"))
                    _ = try VZMacAuxiliaryStorage(creatingStorageAt: dir.appendingPathComponent("aux.img"),
                                                  hardwareModel: req.hardwareModel, options: [.allowOverwrite])
                    var c = cfg
                    c.cpus = max(cfg.cpus, req.minimumSupportedCPUCount)
                    c.memoryMB = max(cfg.memoryMB, Int(req.minimumSupportedMemorySize >> 20))
                    let conf = try macConfig(c, dir)
                    try conf.validate()
                    let vm = VZVirtualMachine(configuration: conf)
                    let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
                    let obs = installer.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
                        let pct = Int(p.fractionCompleted * 100)
                        print("\rInstalling macOS… \(pct)%", terminator: ""); fflush(stdout)
                    }
                    _ = obs
                    installer.install { r in
                        switch r {
                        case .success: say("\nmacOS installed. Start it with: vmforge run \(cfg.name)"); exit(0)
                        case .failure(let e): die("\ninstall failed: \(e)")
                        }
                    }
                } catch { die("install setup failed: \(error)") }
            }
        }
    }
}

func macLatest() {
    VZMacOSRestoreImage.fetchLatestSupported { result in
        switch result {
        case .success(let img): say(img.url.absoluteString); exit(0)
        case .failure(let e): die("cannot query latest macOS: \(e)")
        }
    }
}

// MARK: - entry

let args = CommandLine.arguments
func usage() -> Never {
    die("usage: vmhost run <vmdir> | macos-latest | macos-install <vmdir> <ipsw>")
}
guard args.count >= 2 else { usage() }
switch args[1] {
case "run":
    guard args.count >= 3 else { usage() }
    runVM(URL(fileURLWithPath: args[2]))
case "macos-latest":
    macLatest(); dispatchMain()
case "macos-install":
    guard args.count >= 4 else { usage() }
    macInstall(URL(fileURLWithPath: args[2]), ipsw: URL(fileURLWithPath: args[3])); dispatchMain()
default: usage()
}
