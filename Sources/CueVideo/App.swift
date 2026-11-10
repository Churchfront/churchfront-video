import SwiftUI
import AppKit
import CueATEM

/// What the whole app shares: the switcher, the cameras and the operator's settings.
final class Booth: ObservableObject {
    static let shared = Booth()
    let atem = ATEMClient()
    let ptz = PTZController(load: ProcessInfo.processInfo.environment["CUEVIDEO_FAKECAMS"] == nil)
    /// The setup, kept in a JSON file people and Claude can edit.
    let store = ConfigStore()
    @Published var simple = UserDefaults.standard.bool(forKey: "simple") { didSet { UserDefaults.standard.set(simple, forKey: "simple") } }
    @Published var followPreview = UserDefaults.standard.object(forKey: "followPreview") as? Bool ?? true {
        didSet { UserDefaults.standard.set(followPreview, forKey: "followPreview") }
    }
    @Published var me = 0
    @Published var showSettings = false
    private var heldArrows: Set<UInt16> = []

    var connectedOnce: Bool { !atem.state.inputs.isEmpty }

    /// Keyboard: 1 to 9 and 0 put that tile of the volunteer's source row on Next, shift
    /// puts it on Live, space cuts, return fades, arrows move the camera on Next.
    func key(_ e: NSEvent, down: Bool) -> Bool {
        if let r = NSApp.keyWindow?.firstResponder, r is NSTextView { return false }
        if e.modifierFlags.contains(.command) { return false }
        let arrows: [UInt16: (Double, Double)] = [123: (-0.6, 0), 124: (0.6, 0), 125: (0, -0.6), 126: (0, 0.6)]
        if let a = arrows[e.keyCode] {
            // Only the camera on Next moves, as with the joystick.
            let next = atem.state.preview[me]
            guard ptz.cameras.contains(where: { $0.atemInput == next && $0.id == ptz.selected }) else {
                heldArrows.removeAll(); ptz.stopDrive(); return true
            }
            if down { heldArrows.insert(e.keyCode) } else { heldArrows.remove(e.keyCode) }
            let x = heldArrows.compactMap { arrows[$0]?.0 }.reduce(0, +)
            let y = heldArrows.compactMap { arrows[$0]?.1 }.reduce(0, +)
            if heldArrows.isEmpty { ptz.stopDrive() } else { ptz.drive(x: x, y: y) }
            _ = a
            return true
        }
        guard down, !e.isARepeat else { return down }
        switch e.keyCode {
        case 49: atem.cut(me: me); return true
        case 36, 76: atem.auto(me: me); return true
        default: break
        }
        let digits: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8, 29: 9]
        if let i = digits[e.keyCode] {
            let src = store.volunteerSources(atem.state)
            guard i < src.count else { return true }
            if e.modifierFlags.contains(.shift) { atem.setProgram(src[i].input, me: me) } else { atem.setPreview(src[i].input, me: me) }
            return true
        }
        return false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let booth = Booth.shared
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { e in
            booth.key(e, down: e.type == .keyDown) ? nil : e
        }
        let env = ProcessInfo.processInfo.environment
        // Self-tests name their own switcher; otherwise the config file says where it is.
        if let host = env["CUEVIDEO_HOST"], !host.isEmpty { booth.atem.connect(host, port: env["CUEVIDEO_PORT"].flatMap(UInt16.init) ?? 9910) }
        if let fake = env["CUEVIDEO_FAKECAMS"] {
            var cams: [PTZCamera] = []
            for (i, name) in ["Center", "Left", "Right"].enumerated() {
                var c = PTZCamera(); c.name = name; c.host = fake; c.port = UInt16(52381 + i); c.atemInput = i + 1
                c.presetNames = [1: "Pulpit", 2: "Wide", 3: "Band"]
                cams.append(c)
            }
            booth.ptz.cameras = cams
        }
        booth.store.attach(booth)
        // Claude's way in (through the CueVideo MCP server). Not during self-tests, which
        // may run beside the real app.
        if !booth.store.readOnly { ControlServer.shared.start() }
        if let src = env["CUEVIDEO_NDI"] ?? UserDefaults.standard.string(forKey: "ndiSource") {
            NDIMonitor.shared.start(src)
        }
        NDIMonitor.shared.scan()
        if env["CUEVIDEO_FOLLOWTEST"] != nil { SelfTest.followTest() } else if let cams = env["CUEVIDEO_PTZTEST"] { SelfTest.ptzTest(cams) } else if env["CUEVIDEO_REALTEST"] != nil { SelfTest.realTest() } else if env["CUEVIDEO_PROBE"] != nil { SelfTest.probe() } else if env["CUEVIDEO_SELFTEST"] != nil { SelfTest.run() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct CueVideoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    init() { Fonts.register() }

    var body: some Scene {
        WindowGroup("CueVideo") {
            ContentView()
                .booth()
                .frame(minWidth: 1100, minHeight: 720)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands { BoothCommands() }

        // For the system owner: how CueVideo is set up and how it's talking to the gear.
        Window("CueVideo Setup", id: "setup") {
            SetupWindow().booth()
        }
        .defaultSize(width: 980, height: 760)

        // Every switcher control (keys, DSKs, aux, macros, T-bar), kept away from volunteers.
        Window("Full Switcher", id: "switcher") {
            SwitcherWindow().booth().frame(minWidth: 900, minHeight: 320)
        }
        .defaultSize(width: 1300, height: 420)
    }
}

struct BoothCommands: Commands {
    @Environment(\.openWindow) var openWindow
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Setup…") { openWindow(id: "setup") }.keyboardShortcut(",")
            Button("Full Switcher") { openWindow(id: "switcher") }.keyboardShortcut("k", modifiers: [.command, .shift])
        }
    }
}

extension View {
    /// Everything the app's windows share.
    func booth() -> some View {
        environmentObject(Booth.shared)
            .environmentObject(Booth.shared.atem)
            .environmentObject(Booth.shared.ptz)
            .environmentObject(Booth.shared.store)
            .environmentObject(NDIMonitor.shared)
    }
}
