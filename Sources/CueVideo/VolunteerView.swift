import SwiftUI
import CueATEM

/// The volunteer's screen, built around three steps: pick what's next, frame it, take it live.
/// Top half: the Next and Live monitors and the source row. Bottom half: saved shots, camera
/// control (center, under the tiles) and the take buttons. Everything else lives in Setup and the Full Switcher window.
struct VolunteerView: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: T.s3) {
                HStack(spacing: T.s3) {
                    BusMonitor(title: "Next", input: atem.state.preview[booth.me], color: T.preview)
                    BusMonitor(title: "Live", input: atem.state.program[booth.me], color: T.program)
                }
                .frame(maxHeight: .infinity)
                SourceRow()
            }
            .padding(T.s4)
            Rectangle().fill(T.line).frame(height: 1)
            // Camera control sits bottom center, right under the source tiles, so the mouse
            // travels as little as possible: pick a tile, drop straight down to frame it.
            // Left to right: exposure, saved shots, the joystick (center), then take right beside it.
            HStack(alignment: .top, spacing: T.s6) {
                VStack(alignment: .leading, spacing: T.s2) {
                    NextCameraHeader()
                    HStack(alignment: .top, spacing: T.s5) {
                        ExposurePanel()
                        ShotsPanel().frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                FramePanel().fixedSize()
                TakePanel().frame(width: 250).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(T.s4)
            .frame(height: 290)
            .background(T.surface)
        }
        // The camera controls always drive whatever camera is on Next, so the Live
        // camera can't be moved by accident.
        .onAppear { ptz.follow(atemInput: atem.state.preview[booth.me]) }
        .onChange(of: atem.state.preview[booth.me]) { _, v in ptz.follow(atemInput: v) }
    }
}

/// A numbered step label: 1 Pick, 2 Frame, 3 Take.
struct StepLabel: View {
    let n: Int
    let text: String
    var body: some View {
        HStack(spacing: T.s2) {
            Text("\(n)").font(.sans(12, .bold)).foregroundStyle(T.onAction)
                .frame(width: 20, height: 20).background(Circle().fill(T.accent))
            Text(text).panelLabel()
        }
    }
}

/// The Next or Live picture: the camera's own preview when a Canon camera is on that bus,
/// otherwise the source's name written large.
struct BusMonitor: View {
    @EnvironmentObject var booth: Booth
    let title: String
    let input: Int?
    let color: Color
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @EnvironmentObject var store: ConfigStore
    @ObservedObject var tracker = AutoTracker.shared

    var camera: PTZCamera? {
        guard let input else { return nil }
        return ptz.cameras.first { $0.atemInput == input && $0.proto == .canonXC && !$0.host.isEmpty }
    }

    var keyOverlays: [String] {
        let s = atem.state
        let keys = store.config.keys.filter { k in
            guard let n = k.ndi, !n.isEmpty, n != store.ndi(input) else { return false }
            guard k.dsk != nil || (k.me ?? 1) - 1 == booth.me else { return false }
            return title == "Live" ? k.isOn(s) : k.onNext(s)
        }
        var seen = Set<String>()
        return keys.compactMap(\.ndi).filter { seen.insert($0).inserted }
    }

    /// Clicking a person on Next follows them. On Live, a click only switches who an
    /// already-tracking camera follows, so a stray click can't start moving the live shot.
    func pick(_ camera: PTZCamera) -> ((CGPoint) -> Void)? {
        guard title == "Next" || tracker.isTracking(camera.id) else { return nil }
        return { p in tracker.start(camera, at: p) }
    }

    var body: some View {
        ZStack {
            Color.black
            if let camera {
                CameraVideo(camera: camera, onPick: pick(camera)).id(camera.id)
            } else if let n = store.ndi(input) {
                NDIVideo(source: n).id(n)
            } else {
                Text(store.label(input, atem.state))
                    .font(.sans(34, .bold)).foregroundStyle(T.inkMuted)
                    .lineLimit(2).minimumScaleFactor(0.4).multilineTextAlignment(.center).padding(T.s6)
            }
            // Lower thirds and other keys with an NDI picture, laid over the shot when the
            // key is on it: on Live when it's on air, on Next when it will be after the take.
            ForEach(keyOverlays, id: \.self) { n in NDIVideo(source: n, overlay: true).id("key-" + n) }
        }
        .clipShape(RoundedRectangle(cornerRadius: T.rLG))
        .overlay(RoundedRectangle(cornerRadius: T.rLG).stroke(color, lineWidth: 3))
        .overlay(alignment: .topLeading) {
            Text(title.uppercased()).font(.sans(13, .bold)).tracking(1.2)
                .foregroundStyle(title == "Next" ? T.onAction : .white)
                .padding(.horizontal, 10).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: T.rSM).fill(color))
                .padding(T.s3)
        }
        .overlay(alignment: .topTrailing) {
            if let camera, let s = tracker.sessions[camera.id] {
                TrackingBadge(phase: s.phase) { tracker.stop(camera.id) }.padding(T.s3)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if camera != nil || store.ndi(input) != nil {
                Text(store.label(input, atem.state)).font(.sans(15, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .padding(T.s3)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Step 1: the sources a volunteer needs, as big tiles. Tap one to put it on Next.
struct SourceRow: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        let sources = store.volunteerSources(atem.state)
        // Centered, so the camera control below sits right under the tiles.
        VStack(alignment: .center, spacing: T.s2) {
            StepLabel(n: 1, text: "Pick what's next")
            if sources.isEmpty {
                Text("No sources set up yet. Add them in Setup (⌘,).").font(.sans(13)).foregroundStyle(T.inkMuted)
                    .frame(height: 96)
            } else {
                HStack(spacing: T.s2) {
                    ForEach(sources) { s in SourceTile(source: s) }
                }
                .frame(height: 96)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct SourceTile: View {
    let source: VolunteerSource
    @ObservedObject var tracker = AutoTracker.shared
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @EnvironmentObject var store: ConfigStore

    var camera: PTZCamera? {
        ptz.cameras.first { $0.atemInput == source.input && $0.proto == .canonXC && !$0.host.isEmpty }
    }
    var isLive: Bool { atem.state.program[booth.me] == source.input }
    var isNext: Bool { atem.state.preview[booth.me] == source.input }

    var body: some View {
        Button { atem.setPreview(source.input, me: booth.me) } label: {
            ZStack(alignment: .bottomLeading) {
                if let camera {
                    CameraVideo(camera: camera).id(camera.id)
                } else if let n = source.ndi, !n.isEmpty {
                    NDIVideo(source: n).id(n)
                } else {
                    T.surfaceRaised
                }
                HStack(spacing: 6) {
                    Text(store.label(source.input, atem.state)).font(.sans(14, .semibold)).lineLimit(1)
                    if isLive { badge("LIVE", T.program) } else if isNext { badge("NEXT", T.preview) }
                    if let camera, AutoTracker.shared.isTracking(camera.id) {
                        Image(systemName: "figure.walk").font(.system(size: 11, weight: .bold)).foregroundStyle(T.accent)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8).frame(height: 26)
                .background(Capsule().fill(Color.black.opacity(camera == nil && (source.ndi ?? "").isEmpty ? 0 : 0.6)))
                .padding(6)
            }
            .frame(maxWidth: 220, maxHeight: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: T.rMD))
            .overlay(RoundedRectangle(cornerRadius: T.rMD)
                .stroke(isLive ? T.program : (isNext ? T.preview : T.line), lineWidth: isLive || isNext ? 3 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help("Put \(store.label(source.input, atem.state)) on Next")
    }

    func badge(_ s: String, _ c: Color) -> some View {
        Text(s).font(.sans(10, .bold)).foregroundStyle(c == T.preview ? T.onAction : .white)
            .padding(.horizontal, 5).frame(height: 16)
            .background(RoundedRectangle(cornerRadius: T.rSM).fill(c))
    }
}

/// Step 2: frame the camera that's on Next.
struct FramePanel: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @EnvironmentObject var store: ConfigStore

    /// The camera on Next, if Next is a camera.
    var target: PTZCamera? {
        guard let i = atem.state.preview[booth.me] else { return nil }
        return ptz.cameras.first { $0.atemInput == i && !$0.host.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            StepLabel(n: 2, text: target.map { "Frame \($0.name)" } ?? "Frame the shot")
            HStack(alignment: .center, spacing: T.s4) {
                Joystick { x, y in ptz.drive(x: x, y: y) } onEnd: { ptz.stopDrive() }
                    .frame(width: 170, height: 170)
                ZoomRocker { ptz.zoom($0) }.frame(width: 44, height: 170)
                VStack(alignment: .leading, spacing: T.s2) {
                    SmallButton("Focus") { ptz.focusOnce() }.frame(width: 140)
                    if let t = target { TrackButton(camera: t).frame(width: 140) }
                    if let t = target, !ptz.online.contains(t.id) {
                        Text("Not answering").font(.sans(11, .semibold)).foregroundStyle(T.warning)
                    } else if let t = target, !ptz.hasControl(t) {
                        Text("Waiting for control. Another controller has \(t.name), maybe its web page. Close it and this takes over.")
                            .font(.sans(11, .semibold)).foregroundStyle(T.warning).frame(width: 140, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .opacity(target == nil ? 0.35 : 1)
            .allowsHitTesting(target != nil)
            .overlay {
                if target == nil {
                    Text("Put a camera on Next to frame it")
                        .font(.sans(13, .semibold)).foregroundStyle(T.ink)
                        .padding(.horizontal, T.s3).padding(.vertical, T.s2)
                        .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.surfaceRaised))
                }
            }
        }
        .onAppear { if let t = target { ptz.selected = t.id } }
        .onChange(of: target?.id) { _, id in if let id { ptz.selected = id } }
    }
}

/// Names the camera that exposure and saved shots act on: always the one on Next.
struct NextCameraHeader: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        let next = atem.state.preview[booth.me]
        let cam = ptz.cameras.first { $0.atemInput == next && !$0.host.isEmpty }
        HStack(spacing: T.s2) {
            Image(systemName: cam == nil ? "video.slash" : "video.fill").font(.system(size: 13, weight: .semibold))
            Text(cam?.name ?? "No camera on Next").font(.sans(16, .bold))
            if cam != nil {
                Text("ON NEXT").font(.sans(10, .bold)).tracking(1).foregroundStyle(T.onAction)
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: T.rSM).fill(T.preview))
            } else {
                Text(store.label(next, atem.state)).font(.sans(13)).foregroundStyle(T.inkSubtle)
            }
        }
        .foregroundStyle(cam == nil ? T.inkMuted : T.ink)
        .padding(.horizontal, T.s3).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.surfaceSunken))
        .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(cam == nil ? T.line : T.preview, lineWidth: cam == nil ? 1 : 2))
        .help("Exposure and saved shots below act on the camera that's on Next.")
    }
}

/// Bottom left: exposure for the camera on Next.
struct ExposurePanel: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController

    var target: PTZCamera? {
        guard let i = atem.state.preview[booth.me] else { return nil }
        return ptz.cameras.first { $0.atemInput == i && !$0.host.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            Text("Exposure").panelLabel().frame(height: 20)
            if let t = target, ptz.canSaveShots(t) {
                ExposureControls(camera: t)
            } else {
                Text(target == nil ? "Put a camera on Next" : "Not available for this camera")
                    .font(.sans(12)).foregroundStyle(T.inkSubtle).frame(width: 200, alignment: .leading)
            }
        }
        .frame(width: 200, alignment: .leading)
    }
}

/// Gain, shutter and iris for the camera on Next. Each row steps through the values the
/// camera accepts, with darker and brighter buttons rather than raw numbers to reason about.
struct ExposureControls: View {
    let camera: PTZCamera
    @EnvironmentObject var ptz: PTZController

    var body: some View {
        let e = ptz.exposure[camera.id] ?? CameraExposure()
        VStack(spacing: 6) {
            row("Gain", CameraExposure.gainText(e.value.gain), auto: e.gainAuto, list: e.gainList, value: e.value.gain,
                brighterIsUp: true) { ptz.setExposure(PTZExposure(gain: $0), camera: camera.id) }
            row("Shutter", CameraExposure.shutterText(e.value.shutter), auto: e.shutterAuto, list: e.shutterList, value: e.value.shutter,
                brighterIsUp: false) { ptz.setExposure(PTZExposure(shutter: $0), camera: camera.id) }
            row("Iris", CameraExposure.irisText(e.value.iris), auto: e.irisAuto, list: e.irisList, value: e.value.iris,
                brighterIsUp: false) { ptz.setExposure(PTZExposure(iris: $0), camera: camera.id) }
        }
        .frame(width: 200)
        .onAppear { ptz.refreshExposure(camera: camera.id) }
    }

    /// `brighterIsUp`: whether a bigger number makes the picture brighter (gain) or darker
    /// (shutter speed and f-number).
    func row(_ label: String, _ text: String, auto: Bool, list: [Int], value: Int?, brighterIsUp: Bool,
             set: @escaping (Int) -> Void) -> some View {
        let i = value.flatMap { v in list.firstIndex(of: v) ?? list.firstIndex { $0 >= v } }
        func step(_ brighter: Bool) {
            guard !list.isEmpty else { return }
            let up = brighter == brighterIsUp
            let j = max(0, min(list.count - 1, (i ?? 0) + (up ? 1 : -1)))
            set(list[j])
        }
        return HStack(spacing: 4) {
            Text(label).font(.sans(11, .semibold)).foregroundStyle(T.inkSubtle).frame(width: 46, alignment: .leading)
            stepButton("sun.min", "Darker") { step(false) }
            Text(auto ? "Auto" : text).font(.sans(13, .semibold)).monospacedDigit()
                .frame(maxWidth: .infinity).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: T.rSM).fill(T.surfaceSunken))
            stepButton("sun.max", "Brighter") { step(true) }
        }
        .disabled(list.isEmpty)
    }

    func stepButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: T.rSM).fill(T.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: T.rSM).stroke(T.line))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(help)
    }
}

/// Shots for the camera that's on Next: the ones saved in CueVideo (tap to recall,
/// right-click to update, rename or delete), then the presets stored on the camera itself
/// (tap to recall, right-click to delete). A shot holds a position or an exposure.
struct ShotsPanel: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController

    @State private var saving = false
    @State private var saveKind: ShotKind = .position
    @State private var newName = ""
    @State private var renaming: PTZShot?
    @State private var deleting: PTZShot?
    @State private var deletingPreset: Int?
    @State private var problem: String?
    @State private var storing = false

    var target: PTZCamera? {
        guard let i = atem.state.preview[booth.me] else { return nil }
        return ptz.cameras.first { $0.atemInput == i && !$0.host.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            HStack {
                Text("Saved shots").panelLabel()
                Spacer()
                if let t = target {
                    if ptz.canSaveShots(t) {
                        Button("Save current shot") { newName = ""; saveKind = .position; saving = true }
                            .buttonStyle(.plain).font(.sans(12, .bold)).foregroundStyle(T.accentStrong)
                            .help("Saves \(t.name)'s position (or exposure) as a new shot")
                            .popover(isPresented: $saving, arrowEdge: .top) { savePopover(t) }
                    } else {
                        Button(storing ? "Done saving" : "Save to preset") { storing.toggle() }
                            .buttonStyle(.plain).font(.sans(12, .bold)).foregroundStyle(storing ? T.warning : T.accentStrong)
                            .help("Turn on, then tap a preset to save the camera's current shot to it.")
                    }
                }
            }
            .frame(height: 20)
            if let t = target {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: T.s2)], spacing: T.s2) {
                        ForEach(t.shots) { s in
                            PanelButton(title: s.name, subtitle: s.kind == .exposure ? "EXPOSURE" : nil,
                                        width: 130, height: 48, titleSize: 15) { ptz.go(to: s) }
                                .contextMenu {
                                    Button(s.kind == .exposure ? "Update to the camera's exposure now" : "Update to where the camera is now") {
                                        ptz.saveShot("", camera: t.id, kind: s.kind, replacing: s.id) { if !$0 { problem = Self.noReading } }
                                    }
                                    Button("Rename…") { newName = s.name; renaming = s }
                                    Divider()
                                    Button("Delete…") { deleting = s }
                                }
                        }
                        ForEach(cameraPresets(t), id: \.self) { n in
                            let exp = ptz.exposurePresets[t.id]?.contains(n) ?? false
                            PanelButton(title: ptz.presetNames(t)[n] ?? "Preset \(n)", subtitle: exp ? "ON CAMERA · EXPOSURE" : "ON CAMERA",
                                        lit: storing ? T.warning : nil, width: 130, height: 48, titleSize: 15) {
                                if storing { ptz.store(n); storing = false } else { ptz.recall(n) }
                            }
                            .contextMenu {
                                if ptz.canSaveShots(t) { Button("Delete from camera…") { deletingPreset = n } }
                            }
                        }
                    }
                }
                if t.shots.isEmpty && cameraPresets(t).isEmpty {
                    Text("No shots yet. Frame the camera, then press Save current shot.")
                        .font(.sans(12)).foregroundStyle(T.inkSubtle)
                }
            } else {
                Spacer()
            }
        }
        .alert("Rename shot", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Pulpit", text: $newName)
            Button("Save") { rename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete \(deleting?.name ?? "this shot")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let d = deleting, let t = target, let i = ptz.cameras.firstIndex(where: { $0.id == t.id }) {
                    ptz.cameras[i].shots.removeAll { $0.id == d.id }
                }
                deleting = nil
            }
        }
        .confirmationDialog(presetQuestion, isPresented: Binding(get: { deletingPreset != nil }, set: { if !$0 { deletingPreset = nil } })) {
            Button("Delete from camera", role: .destructive) {
                if let n = deletingPreset, let t = target {
                    ptz.deleteCameraPreset(n, camera: t.id) { why in
                        if let why { problem = "Couldn't delete that preset. \(why)" }
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

    static let noReading = "The camera didn't report its settings, so the shot wasn't saved. Check that it's answering and try again."

    var presetQuestion: String {
        guard let n = deletingPreset, let t = target else { return "Delete this preset?" }
        return "Delete \"\(ptz.presetNames(t)[n] ?? "Preset \(n)")\" from \(t.name)?"
    }

    func savePopover(_ t: PTZCamera) -> some View {
        VStack(alignment: .leading, spacing: T.s3) {
            Text("Save a shot on \(t.name)").font(.sans(14, .bold))
            Picker("", selection: $saveKind) {
                Text("Position").tag(ShotKind.position)
                Text("Exposure").tag(ShotKind.exposure)
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(saveKind == .position ? "Pan, tilt and zoom, where the camera is pointing now."
                                       : "Gain, shutter and iris, the camera's exposure now.")
                .font(.sans(12)).foregroundStyle(T.inkMuted)
            TextField(saveKind == .position ? "Pulpit" : "Bright stage", text: $newName)
                .textFieldStyle(.roundedBorder).onSubmit { save(t) }
            HStack {
                Spacer()
                Button("Cancel") { saving = false }.keyboardShortcut(.cancelAction)
                Button("Save") { save(t) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(T.s4)
        .frame(width: 300)
    }

    func save(_ t: PTZCamera) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        ptz.saveShot(name, camera: t.id, kind: saveKind) { if !$0 { problem = Self.noReading } }
        saving = false
        saveKind = .position  // always back to position for next time
    }

    func rename() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        if let r = renaming, let t = target, !name.isEmpty,
           let i = ptz.cameras.firstIndex(where: { $0.id == t.id }), let j = ptz.cameras[i].shots.firstIndex(where: { $0.id == r.id }) {
            ptz.cameras[i].shots[j].name = name
        }
        renaming = nil
    }

    /// Presets stored on the camera. For VISCA cameras, which can't report names, the first eight numbers.
    func cameraPresets(_ t: PTZCamera) -> [Int] {
        let names = ptz.presetNames(t)
        if ptz.canSaveShots(t) { return names.keys.sorted() }
        return names.isEmpty ? Array(1...8) : names.keys.sorted()
    }
}

/// Step 3: take it live.
struct TakePanel: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        let me = booth.me
        let fading = atem.state.inTransition[me] ?? false
        let black = atem.state.ftbBlack[me] ?? false
        VStack(alignment: .leading, spacing: T.s3) {
            StepLabel(n: 3, text: "Take it live")
            Button { atem.auto(me: me) } label: {
                Text(fading ? "FADING" : "FADE").font(.sans(24, .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 84)
                    .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.program.opacity(fading ? 0.6 : 1)))
                    .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(Color.white.opacity(0.25)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .help("Fade from Live to Next (Return)")
            HStack(spacing: T.s2) {
                PanelButton(title: "CUT", width: 121, height: 52, titleSize: 16) { atem.cut(me: me) }
                    .help("Switch to Next instantly (Space)")
                PanelButton(title: "BLACK", lit: black || (atem.state.ftbInTransition[me] ?? false) ? T.program : nil,
                            width: 121, height: 52, titleSize: 16, blink: black) { atem.fadeToBlack(me: me) }
                    .help(black ? "Fade back up from black" : "Fade everything to black")
            }
            // Keys such as lower thirds: lit while on air, press to turn on or off.
            if !store.config.keys.isEmpty {
                HStack(spacing: T.s2) {
                    ForEach(store.config.keys) { k in
                        let on = k.isOn(atem.state)
                        PanelButton(title: k.label.uppercased(), subtitle: on ? "ON AIR" : "OFF", lit: on ? T.program : nil,
                                    width: store.config.keys.count == 1 ? 250 : 121, height: 44, titleSize: 13) { k.toggle(atem) }
                            .help(on ? "Take \(k.label) off (\(k.target))" : "Put \(k.label) on (\(k.target))")
                    }
                }
            }
        }
    }
}

/// Turns auto tracking on and off for the camera on Next. On, it follows the person nearest
/// the middle; clicking someone on the Next picture follows them instead.
struct TrackButton: View {
    let camera: PTZCamera
    @ObservedObject var tracker = AutoTracker.shared

    var body: some View {
        let s = tracker.sessions[camera.id]
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if s != nil { tracker.stop(camera.id) } else { tracker.start(camera) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "figure.walk").font(.system(size: 12, weight: .bold))
                    Text(s == nil ? "Track" : "Tracking").font(.sans(12, .semibold))
                }
                .foregroundStyle(s == nil ? T.ink : T.onAction)
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: T.rMD).fill(s == nil ? T.surfaceRaised : T.accent))
                .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(s == nil ? T.line : T.accent))
            }
            .buttonStyle(PressStyle())
            .disabled(camera.proto != .canonXC)
            .help(s == nil ? "Follow the person in the middle of the shot. Or click someone on the Next picture. Moving the joystick stops tracking."
                           : "Stop following. Moving the joystick or recalling a shot also stops it.")
            if let s {
                // The follow shot: tap to reframe. The highlighted one is what it's framing to.
                HStack(spacing: 2) {
                    ForEach(ShotSize.allCases) { z in
                        Button { tracker.setSize(camera.id, z) } label: {
                            Text(z.short).font(.sans(11, .semibold))
                                .foregroundStyle(s.size == z ? T.onAction : T.inkMuted)
                                .frame(maxWidth: .infinity).frame(height: 24)
                                .background(RoundedRectangle(cornerRadius: T.rSM).fill(s.size == z ? T.accent : T.surfaceSunken))
                        }
                        .buttonStyle(PressStyle())
                        .help("Frame \(z.name.lowercased())")
                    }
                }
                Text([TrackingBadge.words(s.phase), s.phase == .following ? s.size.name : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.sans(11, .semibold))
                    .foregroundStyle(s.phase == .following ? T.accent : T.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Or click a person on Next").font(.sans(11)).foregroundStyle(T.inkSubtle)
            }
        }
    }
}

/// Shown on a monitor whose camera is tracking, with a button to stop it.
struct TrackingBadge: View {
    let phase: AutoTracker.Phase
    let stop: () -> Void

    static func words(_ p: AutoTracker.Phase?) -> String? {
        switch p {
        case .starting: return "Looking for someone"
        case .following: return "Following"
        case .searching: return "Lost sight, holding"
        case .lost: return "Lost them, looking"
        case nil: return nil
        }
    }

    var body: some View {
        Button(action: stop) {
            HStack(spacing: 6) {
                Image(systemName: "figure.walk").font(.system(size: 11, weight: .bold))
                Text(Self.words(phase)?.uppercased() ?? "").font(.sans(11, .bold)).tracking(0.8)
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(phase == .following ? T.onAction : .black)
            .padding(.horizontal, 8).frame(height: 24)
            .background(Capsule().fill(phase == .following ? T.accent : T.warning))
        }
        .buttonStyle(PressStyle())
        .help("Stop auto tracking")
    }
}
