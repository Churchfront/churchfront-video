import SwiftUI
import CueATEM

/// PTZ control: pick a camera, drive it with the joystick, zoom, and recall presets.
struct CameraPanel: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: T.s4) {
            HStack {
                Text("Cameras").panelLabel()
                Spacer()
                Toggle("Follow next", isOn: $booth.followPreview)
                    .toggleStyle(.switch).controlSize(.mini).font(.sans(11))
                    .help("When a camera goes to Next on the switcher, select it here.")
            }
            if ptz.cameras.isEmpty {
                VStack(alignment: .leading, spacing: T.s3) {
                    Text("No PTZ cameras yet.").font(.sans(14, .semibold))
                    Text("Add each camera's IP address in settings. CueVideo uses VISCA over IP, which PTZOptics, BirdDog, Sony, Canon and most PTZ cameras support.")
                        .font(.sans(12)).foregroundStyle(T.inkMuted)
                    Button("Add cameras") { booth.showSettings = true }
                }
                Spacer()
            } else {
                cameraChips
                HStack(alignment: .center, spacing: T.s5) {
                    Joystick { x, y in ptz.drive(x: x, y: y) } onEnd: { ptz.stopDrive() }
                        .frame(width: 180, height: 180)
                    ZoomRocker { ptz.zoom($0) }.frame(width: 44, height: 180)
                }
                .frame(maxWidth: .infinity)
                HStack(spacing: T.s2) {
                    SmallButton("Auto focus") { ptz.autoFocus(true) }
                    SmallButton("Focus now") { ptz.focusOnce() }
                    SmallButton("Home") { ptz.home() }
                }
                HStack {
                    Text("Presets").panelLabel()
                    Spacer()
                    Button(saving ? "Done saving" : "Save shot") { saving.toggle() }
                        .buttonStyle(.plain).font(.sans(11, .bold))
                        .foregroundStyle(saving ? T.warning : T.accentStrong)
                        .help("Turn on, then tap a preset to save the camera's current shot to it.")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(70), spacing: T.s2), count: 4), spacing: T.s2) {
                    ForEach(1...8, id: \.self) { n in
                        PanelButton(title: "\(n)", subtitle: ptz.current?.presetNames[n], lit: saving ? T.warning : nil,
                                    width: 70, height: 46, titleSize: 15) {
                            if saving { ptz.store(n); saving = false } else { ptz.recall(n) }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(T.s4)
        .background(T.surface)
    }

    var cameraChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: T.s2) {
                ForEach(ptz.cameras) { c in
                    let tally = c.atemInput.flatMap { atem.state.tally[$0] } ?? 0
                    let ring: Color = tally & 1 != 0 ? T.program : (tally & 2 != 0 ? T.preview : T.line)
                    Button { ptz.selected = c.id } label: {
                        HStack(spacing: 6) {
                            Circle().fill(ptz.online.contains(c.id) ? T.success : T.lineStrong).frame(width: 6, height: 6)
                            Text(c.name).font(.sans(13, .semibold)).lineLimit(1)
                        }
                        .padding(.horizontal, 12).frame(height: 32)
                        .foregroundStyle(c.id == ptz.selected ? T.onAction : T.ink)
                        .background(RoundedRectangle(cornerRadius: T.rMD).fill(c.id == ptz.selected ? T.accent : T.surfaceRaised))
                        .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(ring, lineWidth: tally == 0 ? 1 : 2.5))
                    }
                    .buttonStyle(.plain)
                    .help(ptz.online.contains(c.id) ? "\(c.name) at \(c.host)" : "\(c.name) is not answering at \(c.host)")
                }
            }
        }
    }
}

struct SmallButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(title).font(.sans(12, .semibold)).frame(maxWidth: .infinity).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(T.line))
        }
        .buttonStyle(PressStyle())
    }
}

/// Drag anywhere in the circle; the camera moves faster the farther from the middle.
struct Joystick: View {
    let onMove: (Double, Double) -> Void
    let onEnd: () -> Void
    @State private var offset: CGSize = .zero

    var body: some View {
        GeometryReader { g in
            let r = min(g.size.width, g.size.height) / 2
            let knob: CGFloat = 54
            ZStack {
                Circle().fill(T.surfaceSunken).overlay(Circle().stroke(T.line))
                Circle().stroke(T.line, style: StrokeStyle(lineWidth: 1, dash: [3, 4])).padding(r * 0.45)
                ForEach(0..<4) { i in
                    Image(systemName: "chevron.up").font(.system(size: 11, weight: .bold)).foregroundStyle(T.inkSubtle)
                        .offset(y: -r + 14).rotationEffect(.degrees(Double(i) * 90))
                }
                Circle().fill(offset == .zero ? T.surfaceRaised : T.accent)
                    .overlay(Circle().stroke(Color.white.opacity(0.15)))
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                    .frame(width: knob, height: knob)
                    .offset(offset)
            }
            .frame(width: r * 2, height: r * 2)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                var dx = v.location.x - r, dy = v.location.y - r
                let limit = r - knob / 2
                let d = sqrt(dx * dx + dy * dy)
                if d > limit { dx *= limit / d; dy *= limit / d }
                offset = CGSize(width: dx, height: dy)
                onMove(Double(dx / limit), Double(-dy / limit))
            }.onEnded { _ in
                withAnimation(.spring(duration: 0.2)) { offset = .zero }
                onEnd()
            })
        }
    }
}

/// Spring-loaded zoom: push up to zoom in, down to zoom out, let go to stop.
struct ZoomRocker: View {
    let onZoom: (Double) -> Void
    @State private var y: CGFloat = 0
    @State private var last = 0.0

    var body: some View {
        GeometryReader { g in
            let half = g.size.height / 2 - 22
            ZStack {
                RoundedRectangle(cornerRadius: 22).fill(T.surfaceSunken).overlay(RoundedRectangle(cornerRadius: 22).stroke(T.line))
                VStack {
                    Image(systemName: "plus.magnifyingglass")
                    Spacer()
                    Image(systemName: "minus.magnifyingglass")
                }
                .font(.system(size: 12)).foregroundStyle(T.inkSubtle).padding(.vertical, 10)
                Capsule().fill(y == 0 ? T.surfaceRaised : T.accent).frame(width: 36, height: 30)
                    .overlay(Capsule().stroke(Color.white.opacity(0.15))).offset(y: y)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                y = min(half, max(-half, v.location.y - g.size.height / 2))
                let z = Double(-y / half)
                let q = (z * 7).rounded() / 7
                if q != last { last = q; onZoom(q) }
            }.onEnded { _ in
                withAnimation(.spring(duration: 0.2)) { y = 0 }
                last = 0
                onZoom(0)
            })
        }
    }
}
