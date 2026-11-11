import SwiftUI
import CueATEM

/// A source's live picture, for anywhere one is shown small: the camera's own preview, the
/// NDI picture set for it, or its name. A mix output shows whatever is live on that mix.
struct SourcePicture: View {
    let input: Int?
    /// Write the source's name when it has no picture. Off where a label already says it.
    var named = true
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @EnvironmentObject var store: ConfigStore

    private var resolved: Int? {
        guard let input, (10000..<11000).contains(input), input % 10 == 0 else { return input }
        return atem.state.program[(input - 10000) / 10 - 1] ?? input
    }

    var body: some View {
        let id = resolved
        ZStack {
            Color.black
            if let id, let cam = ptz.cameras.first(where: { $0.atemInput == id && $0.proto == .canonXC && !$0.host.isEmpty }) {
                CameraVideo(camera: cam).id(cam.id)
            } else if let n = store.ndi(id) {
                NDIVideo(source: n).id(n)
            } else {
                T.surfaceRaised
                if named { Text(store.routeLabel(id, atem.state)).font(.sans(15, .bold)).foregroundStyle(T.inkMuted)
                    .lineLimit(2).minimumScaleFactor(0.5).multilineTextAlignment(.center).padding(T.s2) }
            }
        }
    }
}

/// Routing as a picture: the sources down the left, the room's screens down the right, each
/// screen showing what's on it, and a wire from every screen back to its source. Drag a
/// source onto a screen (or click the source, then the screen) to change it right away.
struct PatchView: View {
    let screens: [ScreenOutput]
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var store: ConfigStore
    @State private var selected: Int?
    @State private var drag: (source: Int, at: CGPoint)?
    @State private var undo: [(screen: String, was: [(aux: Int, source: Int)])] = []
    @State private var message = ""

    private let sw: CGFloat = 168, sh: CGFloat = 94.5, sGap: CGFloat = 12
    private let dw: CGFloat = 248, dh: CGFloat = 139.5, dLabel: CGFloat = 30, dGap: CGFloat = 12

    /// One color per source, so a screen, its wire and its source read as a set. None is
    /// tally red or green.
    private static let palette: [Color] = [0x7CC2EE, 0xF2B84B, 0xB39DF5, 0x4FD8C4, 0xF58FB8, 0xFF9E6B, 0xD9DE6A, 0xABABAB].map(T.hex)

    /// The mixes, then the operator's sources, then anything else a screen shows now.
    private var sources: [Int] {
        let s = atem.state
        let ok = Set(s.auxSources.map(\.id))
        func can(_ id: Int) -> Bool { ok.isEmpty || ok.contains(id) }
        var ids = s.program.keys.sorted().map { 10010 + $0 * 10 }.filter(can)
        for v in store.volunteerSources(s).map(\.input) where can(v) && !ids.contains(v) { ids.append(v) }
        for sc in screens { for a in sc.aux { if let v = s.aux[a - 1], !ids.contains(v) { ids.append(v) } } }
        return ids
    }

    private func color(_ source: Int?, _ ids: [Int]) -> Color {
        guard let source, let i = ids.firstIndex(of: source) else { return T.lineStrong }
        return Self.palette[i % Self.palette.count]
    }

    /// What a screen shows, when all its outputs agree.
    private func showing(_ sc: ScreenOutput) -> Int? {
        let now = Set(sc.aux.map { atem.state.aux[$0 - 1] })
        return now.count == 1 ? now.first ?? nil : nil
    }

    private func sFrame(_ i: Int) -> CGRect { CGRect(x: 0, y: CGFloat(i) * (sh + sGap), width: sw, height: sh) }
    private func dFrame(_ i: Int, _ w: CGFloat) -> CGRect { CGRect(x: w - dw, y: CGFloat(i) * (dh + dLabel + dGap), width: dw, height: dh) }
    private func screenAt(_ p: CGPoint, _ w: CGFloat) -> Int? {
        screens.indices.first { dFrame($0, w).insetBy(dx: -24, dy: -6).contains(p) }
    }

    var body: some View {
        let ids = sources
        let focus = drag?.source ?? selected
        let height = max(CGFloat(ids.count) * (sh + sGap) - sGap, CGFloat(screens.count) * (dh + dLabel + dGap) - dGap)
        VStack(alignment: .leading, spacing: T.s2) {
            HStack(spacing: T.s2) {
                Text("Pictures").panelLabel()
                Spacer()
                Text("Screens in the room").panelLabel()
            }
            GeometryReader { g in
                let w = g.size.width
                let over = drag.flatMap { screenAt($0.at, w) }
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in
                        func wire(_ a: CGPoint, _ b: CGPoint) -> Path {
                            var p = Path(); let m = (a.x + b.x) / 2
                            p.move(to: a); p.addCurve(to: b, control1: CGPoint(x: m, y: a.y), control2: CGPoint(x: m, y: b.y))
                            return p
                        }
                        for (i, sc) in screens.enumerated() {
                            guard let src = showing(sc), let si = ids.firstIndex(of: src) else { continue }
                            let dim = focus != nil && focus != src
                            ctx.stroke(wire(CGPoint(x: sw + 5, y: sFrame(si).midY), CGPoint(x: w - dw - 5, y: dFrame(i, w).midY)),
                                       with: .color(color(src, ids).opacity(dim ? 0.18 : 1)),
                                       style: StrokeStyle(lineWidth: focus == src ? 5 : 4, lineCap: .round))
                        }
                        if let drag, let si = ids.firstIndex(of: drag.source) {
                            ctx.stroke(wire(CGPoint(x: sw + 5, y: sFrame(si).midY), drag.at), with: .color(T.accent),
                                       style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [8, 7]))
                        }
                    }
                    .allowsHitTesting(false)
                    ForEach(Array(ids.enumerated()), id: \.element) { i, id in
                        sourceTile(id, color(id, ids), on: focus == id, width: w)
                            .position(x: sFrame(i).midX, y: sFrame(i).midY)
                    }
                    ForEach(Array(screens.enumerated()), id: \.element.id) { i, sc in
                        screenTile(sc, color(showing(sc), ids), target: over == i || (drag == nil && selected != nil))
                            .position(x: dFrame(i, w).midX, y: dFrame(i, w).midY + dLabel / 2)
                    }
                    // The picture being carried.
                    if let drag {
                        SourcePicture(input: drag.source).frame(width: 96, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: T.rSM))
                            .overlay(RoundedRectangle(cornerRadius: T.rSM).stroke(T.accent, lineWidth: 2))
                            .opacity(0.9).position(drag.at).allowsHitTesting(false)
                    }
                }
                .coordinateSpace(name: "patch")
            }
            .frame(height: height)
            HStack(spacing: T.s3) {
                Text(selected.map { "Now click the screen that should show \(store.routeLabel($0, atem.state))." }
                     ?? (message.isEmpty ? "Drag a picture onto a screen, or click a picture and then a screen. It changes right away." : message))
                    .font(.sans(12, message.isEmpty || selected != nil ? .regular : .semibold))
                    .foregroundStyle(selected != nil ? T.accent : (message.isEmpty ? T.inkSubtle : T.success))
                Spacer()
                Button("Undo") { undoLast() }.buttonStyle(CueButton()).disabled(undo.isEmpty)
                    .help("Put the last screen you changed back to what it showed")
            }
        }
        .frame(maxWidth: 780, alignment: .leading)
        .padding(T.s4)
        .background(RoundedRectangle(cornerRadius: T.rLG).fill(T.surface))
        .overlay(RoundedRectangle(cornerRadius: T.rLG).stroke(T.line))
    }

    private func sourceTile(_ id: Int, _ c: Color, on: Bool, width w: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            SourcePicture(input: id, named: false)
            Text(store.routeLabel(id, atem.state)).font(.sans(12, .semibold)).foregroundStyle(.white).lineLimit(1)
                .padding(.horizontal, 7).frame(height: 22)
                .background(Capsule().fill(Color.black.opacity(0.65))).padding(5)
        }
        .frame(width: sw, height: sh)
        .clipShape(RoundedRectangle(cornerRadius: T.rMD))
        .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(c, lineWidth: on ? 4 : 2))
        .contentShape(Rectangle())
        .onTapGesture { selected = selected == id ? nil : id }
        .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("patch"))
            .onChanged { drag = (id, $0.location); selected = nil }
            .onEnded { v in
                if let k = screenAt(v.location, w) { route(id, screens[k]) }
                drag = nil
            })
        .help("Drag onto a screen, or click this and then click a screen")
    }

    private func screenTile(_ sc: ScreenOutput, _ c: Color, target: Bool) -> some View {
        let src = showing(sc)
        // Outputs that disagree are "mixed"; a switcher that hasn't said yet is neither.
        let mixed = Set(sc.aux.map { atem.state.aux[$0 - 1] }).count > 1
        return VStack(alignment: .leading, spacing: 4) {
            ZStack {
                if src != nil { SourcePicture(input: src) } else {
                    T.surfaceRaised
                    Text(mixed ? "Mixed" : "Not reported yet").font(.sans(15, .bold)).foregroundStyle(T.inkMuted)
                }
            }
            .frame(width: dw, height: dh)
            .clipShape(RoundedRectangle(cornerRadius: T.rMD))
            .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(target ? T.accent : c, lineWidth: target ? 4 : 3))
            HStack(spacing: 6) {
                Text(sc.name).font(.sans(14, .bold)).lineLimit(1)
                Text(src != nil ? store.routeLabel(src, atem.state) : (mixed ? "Its outputs show different pictures" : ""))
                    .font(.sans(12)).foregroundStyle(T.inkMuted).lineLimit(1)
            }
            .frame(width: dw, height: dLabel - 4, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { if let s = selected { route(s, sc) } }
        .help(selected == nil ? "\(sc.name): drag a picture here to change it" : "Show it on \(sc.name)")
    }

    private func route(_ source: Int, _ sc: ScreenOutput) {
        let s = atem.state
        selected = nil
        let was = sc.aux.compactMap { a in s.aux[a - 1].map { (aux: a, source: $0) } }
        guard was.contains(where: { $0.source != source }) || was.count < sc.aux.count else { return }
        undo.append((sc.name, was))
        if undo.count > 20 { undo.removeFirst() }
        for a in sc.aux { atem.setAux(a - 1, source) }
        message = "\(sc.name) now shows \(store.routeLabel(source, s))."
    }

    private func undoLast() {
        guard let last = undo.popLast() else { return }
        for w in last.was { atem.setAux(w.aux - 1, w.source) }
        message = "\(last.screen) is back to what it showed."
    }
}
