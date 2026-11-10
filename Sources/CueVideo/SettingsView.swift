import SwiftUI
import AppKit
import CueATEM

// MARK: - Full switcher window

/// Every switcher control, for experienced operators. Kept out of the volunteer's window.
struct SwitcherWindow: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @State private var me = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: T.s4) {
                Text("Full Switcher").font(.sans(16, .bold))
                LinkPill()
                if !atem.state.product.isEmpty { Text(atem.state.product).font(.sans(13)).foregroundStyle(T.inkMuted) }
                Spacer()
                if atem.state.meCount > 1 {
                    Picker("", selection: $me) {
                        ForEach(0..<atem.state.meCount, id: \.self) { Text("M/E \($0 + 1)").tag($0) }
                    }
                    .pickerStyle(.segmented).frame(width: 70 * CGFloat(atem.state.meCount))
                }
            }
            .padding(.horizontal, T.s4).frame(height: 48).background(T.surface)
            Rectangle().fill(T.line).frame(height: 1)
            SurfaceView(me: me)
            Spacer(minLength: 0)
        }
        .background(T.bg)
        .foregroundStyle(T.ink)
        .onAppear { me = booth.me }
    }
}

// MARK: - Setup window

struct SetupWindow: View {
    var body: some View {
        TabView {
            SetupTab().tabItem { Text("Setup") }
            StatusTab().tabItem { Text("Status") }
        }
        .padding(T.s3)
        .frame(minWidth: 900, minHeight: 640)
        .background(T.bg)
        .foregroundStyle(T.ink)
    }
}

struct SetupSection<Content: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            Text(title).panelLabel()
            if let note { Text(note).font(.sans(12)).foregroundStyle(T.inkMuted).fixedSize(horizontal: false, vertical: true) }
            content
        }
        .padding(T.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: T.rLG).fill(T.surface))
    }
}

struct SetupTab: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @EnvironmentObject var store: ConfigStore
    @Environment(\.openWindow) var openWindow
    @State private var host = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: T.s4) {
                switcher
                sources
                keyButtons
                cameras
                configFile
            }
            .padding(T.s2)
        }
        .onAppear { host = store.config.atemHost }
        .onChange(of: store.config.atemHost) { _, h in host = h }
    }

    var switcher: some View {
        SetupSection(title: "ATEM switcher") {
            HStack(spacing: T.s2) {
                TextField("IP address", text: $host).textFieldStyle(.roundedBorder).frame(width: 200)
                    .onSubmit { store.update { $0.atemHost = host.trimmingCharacters(in: .whitespaces) } }
                Button("Connect") { store.update { $0.atemHost = host.trimmingCharacters(in: .whitespaces) } }
                LinkPill()
                if !atem.state.product.isEmpty {
                    Text("\(atem.state.product), protocol \(atem.state.version)").font(.sans(12)).foregroundStyle(T.inkMuted)
                }
                Spacer()
                Button("Open Full Switcher") { openWindow(id: "switcher") }
            }
            if atem.state.meCount > 1 {
                HStack {
                    Text("Volunteers run").font(.sans(13))
                    Picker("", selection: Binding(get: { store.config.me }, set: { v in store.update { $0.me = v } })) {
                        ForEach(1...atem.state.meCount, id: \.self) { Text("M/E \($0)").tag($0) }
                    }
                    .pickerStyle(.segmented).frame(width: 70 * CGFloat(atem.state.meCount))
                    Text("Program on M/E \(store.config.me): \(atem.state.inputs[atem.state.program[store.config.me - 1] ?? -1]?.long ?? "?")")
                        .font(.sans(12)).foregroundStyle(T.inkMuted)
                }
            }
        }
    }

    var sources: some View {
        let chosen = store.config.sources
        let available = atem.state.busSources.filter { s in !chosen.contains { $0.input == s.id } }
        return SetupSection(title: "Volunteer source row",
                            note: "The tiles a volunteer can put on Next, left to right. Keys 1 to 9 and 0 pick them in this order. Leave the name blank to use the camera's name or the switcher's. Until any are added, the row shows every camera.") {
            ForEach(Array(chosen.enumerated()), id: \.element.input) { i, s in
                HStack(spacing: T.s2) {
                    Text(i < 10 ? "\((i + 1) % 10)" : "").font(.sans(12, .bold)).foregroundStyle(T.inkSubtle).frame(width: 18)
                    Text(atem.state.inputs[s.input]?.long ?? "Input \(s.input)").font(.sans(13)).frame(width: 200, alignment: .leading)
                    TextField(store.label(s.input, atem.state), text: Binding(
                        get: { s.label ?? "" },
                        set: { v in store.update { c in
                            if let j = c.sources.firstIndex(where: { $0.input == s.input }) { c.sources[j].label = v.isEmpty ? nil : v }
                        } }
                    ))
                    .textFieldStyle(.roundedBorder).frame(width: 200)
                    if ptz.cameras.contains(where: { $0.atemInput == s.input }) {
                        Image(systemName: "video").foregroundStyle(T.inkSubtle).help("A PTZ camera")
                    }
                    Spacer()
                    Button { move(s.input, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
                    Button { move(s.input, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(i == chosen.count - 1)
                    Button { store.update { $0.sources.removeAll { $0.input == s.input } } } label: { Image(systemName: "minus.circle") }
                }
                .buttonStyle(.borderless)
            }
            Menu("Add a source") {
                ForEach(available) { s in
                    Button("\(s.long) (\(s.short))") { store.update { $0.sources.append(VolunteerSource(input: s.id)) } }
                }
            }
            .fixedSize()
            .disabled(available.isEmpty)
        }
    }

    var keyButtons: some View {
        let s = atem.state
        func name(_ i: Int?) -> String { i.map { s.inputs[$0]?.long ?? "input \($0)" } ?? "?" }
        return SetupSection(title: "Key buttons",
                            note: "On/off buttons under Fade and Cut, such as lower thirds. Upstream keys cut on and off; DSKs fade at their own rate.") {
            ForEach(store.config.keys) { k in
                HStack(spacing: T.s2) {
                    TextField("Label", text: Binding(get: { k.label }, set: { v in store.update { c in
                        if let i = c.keys.firstIndex(of: k) { c.keys[i].label = v }
                    } }))
                    .textFieldStyle(.roundedBorder).frame(width: 160)
                    Text(k.target).font(.sans(13)).frame(width: 110, alignment: .leading)
                    Text(k.dsk.map { "fill \(name(s.dskFill[$0 - 1])), key \(name(s.dskCut[$0 - 1]))" }
                         ?? "fill \(name(s.keyFill[(k.me ?? 1) - 1]?[(k.keyer ?? 1) - 1])), key \(name(s.keyCut[(k.me ?? 1) - 1]?[(k.keyer ?? 1) - 1]))")
                        .font(.sans(12)).foregroundStyle(T.inkMuted)
                    Spacer()
                    Button { store.update { $0.keys.removeAll { $0 == k } } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            Menu("Add a key button") {
                ForEach(s.keyFill.keys.sorted(), id: \.self) { me in
                    ForEach((s.keyFill[me] ?? [:]).keys.sorted(), id: \.self) { k in
                        Button("M/E \(me + 1) Key \(k + 1): \(name(s.keyFill[me]?[k]))") {
                            store.update { $0.keys.append(KeyButton(label: "Key \(k + 1)", me: me + 1, keyer: k + 1)) }
                        }
                    }
                }
                ForEach(s.dskFill.keys.sorted(), id: \.self) { d in
                    Button("DSK \(d + 1): \(name(s.dskFill[d]))") {
                        store.update { $0.keys.append(KeyButton(label: "DSK \(d + 1)", dsk: d + 1)) }
                    }
                }
            }
            .fixedSize()
        }
    }

    func move(_ input: Int, by d: Int) {
        store.update { c in
            guard let i = c.sources.firstIndex(where: { $0.input == input }) else { return }
            let j = i + d
            guard c.sources.indices.contains(j) else { return }
            c.sources.swapAt(i, j)
        }
    }

    var cameras: some View {
        SetupSection(title: "PTZ cameras",
                     note: "Canon (HTTP) works with no camera settings and shows the shots saved on the camera. Most other cameras speak VISCA over IP (UDP 52381); PTZOptics also takes VISCA over TCP (5678). Set the switcher input each camera is plugged into, so putting it on Next lets the volunteer move it.") {
            ForEach($ptz.cameras) { $c in
                VStack(alignment: .leading, spacing: T.s2) {
                    CameraRow(camera: $c) { ptz.cameras.removeAll { $0.id == c.id } }
                    if ptz.canSaveShots(c) { ShotEditor(camera: $c).padding(.leading, 16) }
                }
            }
            Button("Add camera") {
                var c = PTZCamera()
                c.name = "Cam \(ptz.cameras.count + 1)"
                c.proto = .canonXC; c.port = 80
                ptz.cameras.append(c)
            }
            CameraLoginRow().padding(.top, T.s2)
        }
    }

    var configFile: some View {
        SetupSection(title: "Configuration file",
                     note: "Everything on this page is saved in this file as plain JSON. You, the system owner or Claude can edit it directly; CueVideo picks up changes within a second.") {
            HStack(spacing: T.s2) {
                Text(store.url.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.url]) }
                Button("Copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.url.path, forType: .string)
                }
            }
            if let e = store.fileError {
                Text("The file has a problem, so CueVideo is still using the last good setup: \(e)")
                    .font(.sans(12, .semibold)).foregroundStyle(T.danger)
            }
            if store.readOnly {
                Text("A self-test is running, so changes aren't saved.").font(.sans(12)).foregroundStyle(T.warning)
            }
        }
    }
}

/// The Canon cameras' admin login, typed here by a person and kept in this Mac's Keychain.
/// Only changing presets stored on the cameras needs it.
struct CameraLoginRow: View {
    @State private var user = CameraLogin.savedUser ?? ""
    @State private var password = ""
    @State private var saved = CameraLogin.savedUser != nil
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            Text("Camera admin login").font(.sans(13, .semibold))
            Text("Only needed to delete or change presets stored on the cameras themselves. Saved in this Mac's Keychain, not in the configuration file. One login for every Canon camera.")
                .font(.sans(12)).foregroundStyle(T.inkMuted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: T.s2) {
                TextField("User name", text: $user).textFieldStyle(.roundedBorder).frame(width: 160)
                SecureField(saved ? "Saved (type to replace)" : "Password", text: $password).textFieldStyle(.roundedBorder).frame(width: 200)
                Button("Save") {
                    let u = user.trimmingCharacters(in: .whitespaces)
                    guard !u.isEmpty, !password.isEmpty else { note = "Enter both the user name and the password."; return }
                    if CameraLogin.save(user: u, password: password) {
                        password = ""; saved = true; note = "Saved in the Keychain."
                    } else {
                        note = "The Keychain didn't accept it. Try again."
                    }
                }
                if saved {
                    Button("Remove") { CameraLogin.clear(); saved = false; user = ""; password = ""; note = "Removed." }
                }
                if let note { Text(note).font(.sans(12)).foregroundStyle(T.inkMuted) }
            }
        }
    }
}

struct CameraRow: View {
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @Binding var camera: PTZCamera
    let remove: () -> Void

    var body: some View {
        HStack(spacing: T.s2) {
            Circle().fill(ptz.online.contains(camera.id) ? T.success : T.lineStrong).frame(width: 8, height: 8)
            TextField("Name", text: $camera.name).textFieldStyle(.roundedBorder).frame(width: 110)
            TextField("IP address", text: $camera.host).textFieldStyle(.roundedBorder).frame(width: 130)
            Picker("", selection: $camera.proto) {
                ForEach(VISCAProtocol.allCases) { Text($0.label).tag($0) }
            }
            .frame(width: 170)
            .onChange(of: camera.proto) { _, p in camera.port = p.defaultPort }
            TextField("Port", value: $camera.port, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 64)
            Picker("", selection: $camera.atemInput) {
                Text("No input").tag(Int?.none)
                ForEach(atem.state.busSources.filter(\.isExternal)) { Text($0.long).tag(Int?.some($0.id)) }
            }
            .frame(width: 160)
            .help("The switcher input this camera is plugged into")
            if camera.proto != .canonXC {
                Picker("", selection: $camera.firstPreset) {
                    Text("Presets from 0").tag(0)
                    Text("Presets from 1").tag(1)
                }
                .frame(width: 120)
            }
            Spacer()
            Button(action: remove) { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(T.inkSubtle)
        }
        .font(.sans(12))
    }
}

/// A camera's shots, editable by name and number, plus the presets stored on the camera.
/// Position: pan and tilt in hundredths of a degree, zoom in the camera's steps.
/// Exposure: gain in tenths of a dB, shutter as 1/x, iris as the f-number times 100.
struct ShotEditor: View {
    @EnvironmentObject var ptz: PTZController
    @Binding var camera: PTZCamera
    @State private var open = false
    @State private var deletingPreset: Int?
    @State private var problem: String?

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 6) {
                if camera.shots.isEmpty {
                    Text("No shots saved in CueVideo yet. Save one from the main window, or add one here from the camera as it is now.")
                        .font(.sans(12)).foregroundStyle(T.inkSubtle)
                }
                ForEach($camera.shots) { $s in
                    HStack(spacing: T.s2) {
                        Text(s.kind == .exposure ? "Exposure" : "Position").font(.sans(11, .semibold))
                            .foregroundStyle(s.kind == .exposure ? T.warning : T.accentStrong).frame(width: 60, alignment: .leading)
                        TextField("Name", text: $s.name).textFieldStyle(.roundedBorder).frame(width: 140)
                        if s.kind == .position {
                            number("Pan", $s.pan); number("Tilt", $s.tilt); number("Zoom", $s.zoom)
                        } else {
                            number("Gain", exposure($s, \.gain)); number("Shutter", exposure($s, \.shutter)); number("Iris", exposure($s, \.iris))
                        }
                        Button("Recall") { ptz.go(to: s, camera: camera.id) }
                            .help("Sends this to \(camera.name) now. Check it isn't live first.")
                        Button("Update to now") { ptz.saveShot("", camera: camera.id, kind: s.kind, replacing: s.id) }
                        Button { move(s.id, -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                        Button { move(s.id, 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                        Button { camera.shots.removeAll { $0.id == s.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                    .font(.sans(12))
                }
                HStack {
                    Button("Add position from the camera now") { ptz.saveShot("", camera: camera.id, kind: .position) }
                    Button("Add exposure from the camera now") { ptz.saveShot("", camera: camera.id, kind: .exposure) }
                }
                let presets = ptz.presetNames(camera)
                if !presets.isEmpty {
                    Text("Stored on the camera").font(.sans(11, .semibold)).foregroundStyle(T.inkSubtle).padding(.top, T.s2)
                    ForEach(presets.keys.sorted(), id: \.self) { n in
                        HStack(spacing: T.s2) {
                            Text("\(n)").font(.sans(12)).foregroundStyle(T.inkSubtle).frame(width: 24, alignment: .trailing)
                            Text(presets[n] ?? "").font(.sans(12)).frame(width: 160, alignment: .leading)
                            Text((ptz.exposurePresets[camera.id]?.contains(n) ?? false) ? "Exposure" : "Position")
                                .font(.sans(11)).foregroundStyle(T.inkMuted).frame(width: 70, alignment: .leading)
                            Button("Recall") { ptz.recall(n, camera: camera.id) }
                            Button("Delete from camera…") { deletingPreset = n }
                        }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Text("\(camera.shots.count) saved shot\(camera.shots.count == 1 ? "" : "s"), \(ptz.presetNames(camera).count) on the camera")
                .font(.sans(12, .semibold)).foregroundStyle(T.inkMuted)
        }
        .confirmationDialog("Delete \"\(deletingPreset.flatMap { ptz.presetNames(camera)[$0] } ?? "this preset")\" from \(camera.name)?",
                            isPresented: Binding(get: { deletingPreset != nil }, set: { if !$0 { deletingPreset = nil } })) {
            Button("Delete from camera", role: .destructive) {
                if let n = deletingPreset {
                    ptz.deleteCameraPreset(n, camera: camera.id) { why in
                        if let why { problem = "Couldn't delete that preset from \(camera.name). \(why)" }
                    }
                }
                deletingPreset = nil
            }
        } message: {
            Text("This removes it from the camera itself, for every controller that uses it. It can't be undone.")
        }
        .alert(problem ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    func number(_ label: String, _ v: Binding<Int>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.sans(11)).foregroundStyle(T.inkSubtle)
            TextField("", value: v, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 64)
        }
    }

    /// One exposure value as a plain number for editing (0 when the shot doesn't set it).
    func exposure(_ s: Binding<PTZShot>, _ k: WritableKeyPath<PTZExposure, Int?>) -> Binding<Int> {
        Binding(get: { s.wrappedValue.exposure?[keyPath: k] ?? 0 },
                set: { v in var e = s.wrappedValue.exposure ?? PTZExposure(); e[keyPath: k] = v; s.wrappedValue.exposure = e })
    }

    func move(_ id: UUID, _ d: Int) {
        guard let i = camera.shots.firstIndex(where: { $0.id == id }), camera.shots.indices.contains(i + d) else { return }
        camera.shots.swapAt(i, i + d)
    }
}

// MARK: - Status

/// What CueVideo knows and what it has sent, for whoever is looking after the system.
struct StatusTab: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: T.s4) {
                HStack {
                    Text("Live view of how CueVideo is talking to the switcher and cameras.").font(.sans(13)).foregroundStyle(T.inkMuted)
                    Spacer()
                    Button("Copy report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(StatusReport.text(booth), forType: .string)
                    }
                    .help("Copies everything on this page as text, ready to paste to Claude or the system owner")
                }
                SetupSection(title: "Switcher") {
                    grid(StatusReport.switcherRows(booth))
                }
                SetupSection(title: "Cameras") {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        VStack(alignment: .leading, spacing: T.s2) {
                            ForEach(ptz.cameras) { c in
                                grid(StatusReport.cameraRows(c, booth))
                                if c.id != ptz.cameras.last?.id { Rectangle().fill(T.line).frame(height: 1) }
                            }
                        }
                    }
                }
                SetupSection(title: "Commands sent to the switcher", note: "Newest first. Only commands from this Mac show here; the switcher's own panel and other software aren't listed.") {
                    if atem.sentLog.isEmpty {
                        Text("Nothing sent yet.").font(.sans(12)).foregroundStyle(T.inkSubtle)
                    }
                    ForEach(atem.sentLog.reversed()) { e in
                        HStack(spacing: T.s3) {
                            Text(StatusReport.time(e.time)).font(.system(size: 12, design: .monospaced)).foregroundStyle(T.inkSubtle)
                            Text(e.command).font(.system(size: 12, design: .monospaced)).foregroundStyle(T.inkMuted).frame(width: 44, alignment: .leading)
                            Text(e.describe(atem.state)).font(.sans(12))
                            if !e.sent { Text("not sent, switcher offline").font(.sans(11, .semibold)).foregroundStyle(T.warning) }
                        }
                    }
                }
                SetupSection(title: "Configuration file") {
                    grid(StatusReport.configRows(store))
                }
            }
            .padding(T.s2)
        }
    }

    func grid(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: T.s4, verticalSpacing: 6) {
            ForEach(rows.indices, id: \.self) { i in
                GridRow {
                    Text(rows[i].0).font(.sans(12)).foregroundStyle(T.inkSubtle)
                    Text(rows[i].1).font(.sans(12)).textSelection(.enabled)
                }
            }
        }
    }
}

enum StatusReport {
    static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: d)
    }

    static func switcherRows(_ b: Booth) -> [(String, String)] {
        let s = b.atem.state
        let link: String = {
            switch b.atem.link {
            case .online: return "Online"
            case .connecting: return "Connecting"
            case .offline(let why): return "Offline: \(why)"
            case .idle: return "Not set up"
            }
        }()
        var rows: [(String, String)] = [
            ("Connection", "\(link), \(b.atem.host.isEmpty ? "no address" : "\(b.atem.host) UDP 9910")"),
            ("Model", s.product.isEmpty ? "Unknown until connected" : "\(s.product), protocol \(s.version)"),
            ("Size", "\(s.meCount) M/E, \(s.keyerCount) keys, \(s.dskCount) DSKs, \(s.auxCount) aux, \(s.inputs.count) sources"),
            ("Volunteers run", "M/E \(b.me + 1)"),
        ]
        for me in 0..<s.meCount {
            rows.append(("M/E \(me + 1)", "Live \(s.inputs[s.program[me] ?? -1]?.long ?? "?"), Next \(s.inputs[s.preview[me] ?? -1]?.long ?? "?")"
                         + ((s.ftbBlack[me] ?? false) ? ", faded to black" : "")))
        }
        func name(_ i: Int?) -> String { i.map { s.inputs[$0]?.long ?? "input \($0)" } ?? "?" }
        for me in s.keyFill.keys.sorted() {
            for k in (s.keyFill[me] ?? [:]).keys.sorted() {
                rows.append(("M/E \(me + 1) Key \(k + 1)", "fill \(name(s.keyFill[me]?[k])), key \(name(s.keyCut[me]?[k]))"
                             + ((s.keyOnAir[me]?[k] ?? false) ? ", ON AIR" : "")))
            }
        }
        for d in s.dskFill.keys.sorted() {
            rows.append(("DSK \(d + 1)", "fill \(name(s.dskFill[d])), key \(name(s.dskCut[d]))" + ((s.dskOnAir[d] ?? false) ? ", ON AIR" : "")))
        }
        if s.hasStreaming || s.hasRecording {
            rows.append(("Stream and record", "\(s.hasStreaming ? (s.streaming ? "streaming" : "not streaming") : "no streaming"), \(s.hasRecording ? (s.recording ? "recording" : "not recording") : "no recording")"))
        }
        return rows
    }

    static func cameraRows(_ c: PTZCamera, _ b: Booth) -> [(String, String)] {
        let s = b.atem.state
        let input = c.atemInput.map { "\(s.inputs[$0]?.long ?? "input \($0)") (input \($0))" } ?? "not set"
        let picture: String = {
            guard c.proto == .canonXC else { return "Not available for VISCA cameras" }
            switch CanonFeedHub.shared.isLive(c) {
            case .some(true): return "Coming in (Canon video.cgi, motion JPEG)"
            case .some(false): return "Connecting or stopped"
            case .none: return "Not showing on screen right now"
            }
        }()
        let presets = b.ptz.presetNames(c)
        return [
            ("Camera", c.name),
            ("Address", "\(c.host):\(c.port), \(c.proto.label)"),
            ("Control", b.ptz.online.contains(c.id) ? "Answering\(b.ptz.models[c.id].map { ", \($0)" } ?? "")" : "Not answering"),
            ("Switcher input", input),
            ("Picture", picture),
            ("Saved shots", presets.isEmpty ? "None named" : presets.keys.sorted().map { "\($0) \(presets[$0]!)" }.joined(separator: ", ")),
        ]
    }

    static func configRows(_ store: ConfigStore) -> [(String, String)] {
        [
            ("File", store.url.path),
            ("Last read", store.loadedAt.map { time($0) } ?? "Not read this session"),
            ("Problem", store.fileError ?? "None"),
        ]
    }

    /// Everything above as text.
    static func text(_ b: Booth) -> String {
        var out = "CueVideo status, \(Date().formatted(date: .abbreviated, time: .standard))\n\nSWITCHER\n"
        out += switcherRows(b).map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        out += "\n\nCAMERAS\n"
        out += b.ptz.cameras.map { c in cameraRows(c, b).map { "\($0.0): \($0.1)" }.joined(separator: "\n") }.joined(separator: "\n\n")
        out += "\n\nCOMMANDS SENT (newest first)\n"
        out += b.atem.sentLog.reversed().map { "\(time($0.time)) \($0.command) \($0.describe(b.atem.state))\($0.sent ? "" : " [not sent]")" }.joined(separator: "\n")
        out += "\n\nCONFIG\n" + configRows(b.store).map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        if let data = try? Data(contentsOf: b.store.url), let json = String(data: data, encoding: .utf8) { out += "\n\n" + json }
        return out
    }
}
