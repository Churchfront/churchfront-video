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

/// Routing as a schematic of the switcher: its sources down the left, its mixes (M/Es) in
/// the middle, its outputs down the right, and wires showing what feeds what.
///
/// A mix blends sources, so it's drawn as a small switcher with Live and Next and takes a
/// red wire from its Live source and a dashed green one from Next. A destination is an aux
/// output: it shows one thing, so it has one wire in. Wires run in lanes through the gaps
/// between the columns and between the mixes, never behind a tile. Drag a source or a mix
/// onto a destination (or click one, then the other) to change it right away.
struct RoutingSchematic: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @EnvironmentObject var store: ConfigStore
    @AppStorage("routingSpareIn") private var showSpareIn = false
    @AppStorage("routingInternal") private var showInternal = false
    @AppStorage("routingSpareOut") private var showSpareOut = false
    @State private var feedsUnlocked = false
    @State private var selected: Int?
    @State private var hover: Int?
    @State private var drag: (source: Int, at: CGPoint)?
    @State private var undo: [(what: String, back: () -> Void)] = []
    @State private var message = ""

    // MARK: Model

    enum Group: String { case cameras = "Cameras", graphics = "Graphics", ndi = "NDI", spareIn = "Spare inputs", inside = "Media and color"
        case screens = "Screens", feeds = "Encoders and feeds", spareOut = "Spare outputs" }

    struct Head { let group: Group; let y: CGFloat; let count: Int; let foldable: Bool; let open: Bool }
    struct Src { let id: Int; let frame: CGRect; let pic: Bool }
    struct Dst { let screen: ScreenOutput; let frame: CGRect; let pic: Bool; let source: Int?; let mixed: Bool; let locked: Bool }
    struct Mix { let me: Int; let frame: CGRect; let live: CGRect; let next: CGRect; let pic: Bool
        var output: Int { 10010 + me * 10 } }
    /// One wire, as the corners it turns at, plus where branches leave it.
    struct Wire { let from: Int; let color: Color; var dashed = false; var runs: [[CGPoint]]; var dots: [CGPoint] = [] }
    struct Layout { var heads: [Head] = [], srcs: [Src] = [], dsts: [Dst] = [], mixes: [Mix] = [], wires: [Wire] = []
        var colors: [Int: Color] = [:]; var height: CGFloat = 0 }

    private let rowH: CGFloat = 30, headH: CGFloat = 24, gap: CGFloat = 6

    /// Sizes grow with the page, so a wide window gets bigger pictures instead of empty space.
    struct Sizes { let side: CGFloat, mix: CGFloat, thumb: CGSize
        var picH: CGFloat { thumb.height + 8 } }
    private func sizes(_ w: CGFloat) -> Sizes {
        let side = min(340, max(196, (w * 0.235).rounded()))
        let tw = (side * 0.5).rounded()
        return Sizes(side: side, mix: min(440, max(236, (w * 0.28).rounded())), thumb: CGSize(width: tw, height: (tw * 9 / 16).rounded()))
    }
    /// None is tally red or green, which only ever mean Live and Next.
    private static let palette: [Color] = [0x7CC2EE, 0xF2B84B, 0xB39DF5, 0xD9DE6A, 0xF58FB8, 0xFF9E6B, 0x9BB7C9, 0xC9C9C9].map(T.hex)

    private func isMix(_ id: Int) -> Bool { (10000..<11000).contains(id) }

    /// Whether a source has a live picture to show (a mix shows what's live on it).
    private func hasPicture(_ input: Int?) -> Bool {
        guard var id = input else { return false }
        if isMix(id), id % 10 == 0 { id = atem.state.program[(id - 10000) / 10 - 1] ?? id }
        return ptz.cameras.contains { $0.atemInput == id && $0.proto == .canonXC && !$0.host.isEmpty } || store.ndi(id) != nil
    }

    /// A port that only goes to a patch bay tie line, by its name.
    private func isSpare(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("patchbay") || n.contains("patch bay") || n.range(of: #"\(pb ?\d+\)"#, options: .regularExpression) != nil
    }

    private func group(_ i: ATEMInput) -> Group {
        guard i.isExternal else { return .inside }
        if isSpare(i.long) { return .spareIn }
        let n = (i.long + " " + store.label(i.id, atem.state)).lowercased()
        if store.config.cameras.contains(where: { $0.atemInput == i.id }) || n.contains("cam") || n.contains("ptz") { return .cameras }
        return n.contains("ndi") ? .ndi : .graphics
    }

    private func layout(_ w: CGFloat) -> Layout {
        let s = atem.state
        var L = Layout()
        let z = sizes(w), sw = z.side, dw = z.side, mw = z.mix, picH = z.picH

        // Destinations: every aux, named or not.
        let named = store.config.screens
        let used = Set(named.flatMap(\.aux))
        let unnamed = (1...max(1, s.auxCount)).filter { !used.contains($0) && s.aux[$0 - 1] != nil }.map { ScreenOutput(name: "Aux \($0)", aux: [$0]) }
        let dGroups: [(Group, [ScreenOutput])] = [
            (.screens, named.filter { $0.forVolunteers && !isSpare($0.name) }),
            (.feeds, named.filter { !$0.forVolunteers && !isSpare($0.name) }),
            (.spareOut, named.filter { isSpare($0.name) } + unnamed)]
        func now(_ sc: ScreenOutput) -> (Int?, Bool) {
            let set = Set(sc.aux.map { s.aux[$0 - 1] })
            return (set.count == 1 ? (set.first ?? nil) : nil, set.count > 1)
        }
        let dOpen: [Group: Bool] = [.screens: true, .feeds: true, .spareOut: showSpareOut]
        let shownDsts = dGroups.flatMap { g, list in dOpen[g] == true ? list : [] }

        // What's in use, so a folded group still shows the sources that matter.
        var inUse = Set(shownDsts.compactMap { now($0).0 })
        for me in s.program.keys { if let v = s.program[me] { inUse.insert(v) }; if let v = s.preview[me] { inUse.insert(v) } }

        // Sources.
        var y: CGFloat = 0
        let inputs = s.auxSources.filter { !isMix($0.id) && !(7000..<7100).contains($0.id) }
        let sOpen: [Group: Bool] = [.cameras: true, .graphics: true, .ndi: true, .spareIn: showSpareIn, .inside: showInternal]
        for g in [Group.cameras, .graphics, .ndi, .spareIn, .inside] {
            let all = inputs.filter { group($0) == g }
            guard !all.isEmpty else { continue }
            let foldable = g == .spareIn || g == .inside
            L.heads.append(Head(group: g, y: y, count: all.count, foldable: foldable, open: sOpen[g] == true))
            y += headH
            for i in all where sOpen[g] == true || inUse.contains(i.id) {
                let pic = hasPicture(i.id), h = pic ? picH : rowH
                L.srcs.append(Src(id: i.id, frame: CGRect(x: 0, y: y, width: sw, height: h), pic: pic))
                y += h + gap
            }
            y += 8
        }
        let sBottom = y

        // Destinations.
        y = 0
        for (g, list) in dGroups where !list.isEmpty {
            L.heads.append(Head(group: g, y: y, count: list.count, foldable: g == .spareOut, open: dOpen[g] == true))
            y += headH
            if dOpen[g] == true {
                for sc in list {
                    let (src, mixed) = now(sc)
                    let pic = hasPicture(src), h = pic ? picH : rowH
                    L.dsts.append(Dst(screen: sc, frame: CGRect(x: w - dw, y: y, width: dw, height: h), pic: pic, source: src, mixed: mixed,
                                      locked: g == .feeds && !feedsUnlocked))
                    y += h + gap
                }
            }
            y += 8
        }
        let dBottom = y

        // Mixes, with a clear channel above, between and below them for wires to cross in.
        let mx = (w - mw) / 2, channel: CGFloat = 46
        y = channel
        for me in s.program.keys.sorted() {
            let pic = hasPicture(s.program[me])
            let liveH: CGFloat = pic ? (mw - 20) * 9 / 16 : 44
            let live = CGRect(x: mx + 10, y: y + 34, width: mw - 20, height: liveH)
            let next = CGRect(x: mx + 10, y: live.maxY + 6, width: mw - 20, height: 30)
            let f = CGRect(x: mx, y: y, width: mw, height: next.maxY + 28 - y)
            L.mixes.append(Mix(me: me, frame: f, live: live, next: next, pic: pic))
            y = f.maxY + channel
        }
        L.height = max(sBottom, dBottom, y)

        // Wires. Each gets its own lane in the gutter it runs through.
        let srcY = Dictionary(uniqueKeysWithValues: L.srcs.map { ($0.id, $0.frame.midY) })
        let gutter = max(40, mx - sw)
        var leftLane = 0, rightLane = 0
        func lx() -> CGFloat { leftLane += 1; return sw + min(gutter - 12, 6 + CGFloat(leftLane) * 9) }
        func rx() -> CGFloat { rightLane += 1; return mx + mw + min(gutter - 12, 6 + CGFloat(rightLane) * 9) }
        var color = 0
        func nextColor() -> Color { color += 1; return Self.palette[(color - 1) % Self.palette.count] }

        // Mix outputs: one trunk down the right gutter, a branch to each destination.
        for m in L.mixes {
            let c = nextColor(); L.colors[m.output] = c
            let ys = L.dsts.filter { $0.source == m.output }.map(\.frame.midY)
            guard !ys.isEmpty else { continue }
            let x = rx(), py = m.frame.midY
            var wire = Wire(from: m.output, color: c, runs: [[CGPoint(x: m.frame.maxX, y: py), CGPoint(x: x, y: py)],
                                                             [CGPoint(x: x, y: min(py, ys.min()!)), CGPoint(x: x, y: max(py, ys.max()!))]])
            for d in ys { wire.runs.append([CGPoint(x: x, y: d), CGPoint(x: w - dw, y: d)]); wire.dots.append(CGPoint(x: x, y: d)) }
            if ys.count == 1, ys[0] == py { wire.dots = [] }
            L.wires.append(wire)
        }
        // Into each mix: Live solid red, Next dashed green.
        for m in L.mixes {
            for (src, slot, tally, dashed) in [(s.program[m.me], m.live, T.program, false), (s.preview[m.me], m.next, T.preview, true)] {
                guard let src, let sy = srcY[src] else { continue }
                let x = lx()
                L.wires.append(Wire(from: src, color: tally, dashed: dashed, runs: [[CGPoint(x: sw, y: sy), CGPoint(x: x, y: sy), CGPoint(x: x, y: slot.midY), CGPoint(x: mx, y: slot.midY)]]))
            }
        }
        // Sources sent straight to a destination cross in the channel nearest them.
        var channels: [CGFloat] = [channel / 2]
        for m in L.mixes { channels.append(m.frame.maxY + channel / 2) }
        var usedIn: [Int: Int] = [:]
        for src in L.srcs {
            let ys = L.dsts.filter { $0.source == src.id }.map(\.frame.midY)
            guard !ys.isEmpty else { continue }
            let c = nextColor(); L.colors[src.id] = c
            let sy = src.frame.midY, mean = ys.reduce(0, +) / CGFloat(ys.count)
            let k = channels.indices.min { abs(channels[$0] - sy) + abs(channels[$0] - mean) < abs(channels[$1] - sy) + abs(channels[$1] - mean) }!
            let n = usedIn[k, default: 0]; usedIn[k] = n + 1
            let cy = channels[k] + CGFloat((n + 1) / 2) * 8 * (n % 2 == 0 ? 1 : -1)
            let a = lx(), b = rx()
            var wire = Wire(from: src.id, color: c, runs: [[CGPoint(x: sw, y: sy), CGPoint(x: a, y: sy), CGPoint(x: a, y: cy), CGPoint(x: b, y: cy)],
                                                           [CGPoint(x: b, y: min(cy, ys.min()!)), CGPoint(x: b, y: max(cy, ys.max()!))]])
            for d in ys { wire.runs.append([CGPoint(x: b, y: d), CGPoint(x: w - dw, y: d)]); if ys.count > 1 { wire.dots.append(CGPoint(x: b, y: d)) } }
            L.wires.append(wire)
        }
        return L
    }

    // MARK: View

    var body: some View {
        let focus = drag?.source ?? selected ?? hover
        VStack(alignment: .leading, spacing: T.s3) {
            // The three columns, named: left to right is the way the signal flows.
            ZStack {
                column("Sources", "Switcher inputs").frame(maxWidth: .infinity, alignment: .leading)
                column("Mixes", "M/Es: blend sources, cut and fade").frame(maxWidth: .infinity, alignment: .center)
                column("Destinations", "Switcher outputs").frame(maxWidth: .infinity, alignment: .trailing)
            }
            Rectangle().fill(T.line).frame(height: 1)
            GeometryReader { g in
                let w = g.size.width
                let L = layout(w)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in
                        for wire in L.wires {
                            let dim = focus != nil && focus != wire.from && !(isMix(focus!) && wire.from == focus)
                            var p = Path()
                            for run in wire.runs { p.addLines(run) }
                            ctx.stroke(p, with: .color(wire.color.opacity(dim ? 0.15 : 1)),
                                       style: StrokeStyle(lineWidth: wire.dashed ? 2 : 3, lineCap: .round, lineJoin: .round, dash: wire.dashed ? [6, 6] : []))
                            for d in wire.dots {
                                ctx.fill(Path(ellipseIn: CGRect(x: d.x - 4, y: d.y - 4, width: 8, height: 8)), with: .color(wire.color.opacity(dim ? 0.15 : 1)))
                            }
                        }
                        if let drag {
                            ctx.stroke(Path(ellipseIn: CGRect(x: drag.at.x - 7, y: drag.at.y - 7, width: 14, height: 14)), with: .color(T.accent), lineWidth: 2)
                        }
                    }
                    .allowsHitTesting(false)
                    ForEach(L.heads, id: \.group) { h in head(h, w) }
                    ForEach(L.srcs, id: \.id) { s in
                        sourceRow(s, L.colors[s.id], on: focus == s.id, L, w).position(x: s.frame.midX, y: s.frame.midY)
                    }
                    ForEach(L.mixes, id: \.me) { m in
                        mixCard(m, L.colors[m.output] ?? T.lineStrong, target: canDrop(on: m), L, w).position(x: m.frame.midX, y: m.frame.midY)
                    }
                    ForEach(L.dsts, id: \.screen.id) { d in
                        destRow(d, d.source.flatMap { L.colors[$0] }, target: target(d, L, w), w).position(x: d.frame.midX, y: d.frame.midY)
                    }
                    if let drag {
                        Text(store.routeLabel(drag.source, atem.state)).font(.sans(12, .semibold)).foregroundStyle(T.onAction)
                            .padding(.horizontal, 8).frame(height: 24).background(Capsule().fill(T.accent))
                            .position(x: drag.at.x, y: drag.at.y - 22).allowsHitTesting(false)
                    }
                }
                .frame(width: w, height: L.height, alignment: .topLeading)
                .coordinateSpace(name: "schematic")
                .preference(key: SchematicHeight.self, value: L.height)
            }
            .frame(height: height)
            .onPreferenceChange(SchematicHeight.self) { height = $0 }
            HStack(spacing: T.s3) {
                Text(selected.map { "Now click where \(store.routeLabel($0, atem.state)) should go." }
                     ?? (message.isEmpty ? "Drag a source or a mix onto a destination, or click one and then the other. It changes right away." : message))
                    .font(.sans(12, message.isEmpty || selected != nil ? .regular : .semibold))
                    .foregroundStyle(selected != nil ? T.accent : (message.isEmpty ? T.inkSubtle : T.success))
                Spacer()
                Button("Undo") { if let u = undo.popLast() { u.back(); message = "\(u.what) is back to what it was." } }
                    .buttonStyle(CueButton()).disabled(undo.isEmpty).help("Put back the last thing changed here")
            }
        }
        .padding(T.s4)
        .background(RoundedRectangle(cornerRadius: T.rLG).fill(T.surface))
        .overlay(RoundedRectangle(cornerRadius: T.rLG).stroke(T.line))
    }

    @State private var height: CGFloat = 400

    private func head(_ h: Head, _ w: CGFloat) -> some View {
        let right = [Group.screens, .feeds, .spareOut].contains(h.group)
        return HStack(spacing: 6) {
            if h.foldable { Image(systemName: h.open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(T.inkSubtle) }
            Text(h.group.rawValue).panelLabel()
            if h.foldable { Text("\(h.count)").font(.sans(11, .semibold)).foregroundStyle(T.inkSubtle) }
            if h.group == .feeds {
                Spacer(minLength: 4)
                Button { feedsUnlocked.toggle() } label: {
                    Label(feedsUnlocked ? "Unlocked" : "Locked", systemImage: feedsUnlocked ? "lock.open" : "lock.fill")
                        .font(.sans(11, .semibold)).foregroundStyle(feedsUnlocked ? T.inkMuted : T.warning).fixedSize()
                }
                .buttonStyle(.plain)
                .help(feedsUnlocked ? "Lock these again" : "One of these may carry the live stream. Unlock to change them.")
            }
        }
        .frame(width: sizes(w).side, height: headH - 4, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            switch h.group {
            case .spareIn: showSpareIn.toggle()
            case .inside: showInternal.toggle()
            case .spareOut: showSpareOut.toggle()
            default: break
            }
        }
        .help(h.group == .spareIn || h.group == .spareOut ? "Ports that only go to patch bay tie lines" : "")
        .position(x: (right ? w - sizes(w).side / 2 : sizes(w).side / 2), y: h.y + (headH - 4) / 2)
    }

    private func column(_ title: String, _ note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: T.s2) {
            Text(title).font(.sans(17, .bold))
            Text(note).font(.sans(12)).foregroundStyle(T.inkSubtle).lineLimit(1)
        }
    }

    /// Which connector on the switcher this is: "IN 9", "OUT 4+5".
    private func port(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(T.inkMuted)
            .padding(.horizontal, 5).frame(height: 18)
            .background(RoundedRectangle(cornerRadius: T.rSM).fill(T.surfaceRaised.opacity(0.9)))
            .overlay(RoundedRectangle(cornerRadius: T.rSM).stroke(T.line))
            .fixedSize()
    }

    private func thumb(_ input: Int?, _ w: CGFloat) -> some View {
        let t = sizes(w).thumb
        return SourcePicture(input: input, named: false).frame(width: t.width, height: t.height).clipShape(RoundedRectangle(cornerRadius: T.rSM))
    }

    private func sourceRow(_ s: Src, _ c: Color?, on: Bool, _ L: Layout, _ w: CGFloat) -> some View {
        HStack(spacing: T.s2) {
            if s.pic { thumb(s.id, w) }
            Text(store.label(s.id, atem.state)).font(.sans(s.pic ? 14 : 13, .semibold)).lineLimit(2).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if (1...999).contains(s.id) { port("IN \(s.id)") }
            if (1...999).contains(s.id), !ptz.cameras.contains(where: { $0.atemInput == s.id && $0.proto == .canonXC && !$0.host.isEmpty }) {
                SourcePictureButton(input: s.id)
            }
        }
        .padding(.leading, s.pic ? 4 : 10).padding(.trailing, 4)
        .frame(width: s.frame.width, height: s.frame.height)
        .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.surfaceSunken))
        .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(on ? T.accent : (c ?? T.line), lineWidth: on ? 3 : (c == nil ? 1 : 2)))
        .draggable(s.id, self, L, w)
        .help(((1...999).contains(s.id) ? "Switcher input \(s.id): \(atem.state.inputs[s.id]?.long ?? "")\n" : "")
              + "Drag onto a destination or a mix, or click this and then click where it should go")
    }

    private func mixCard(_ m: Mix, _ c: Color, target: Bool, _ L: Layout, _ w: CGFloat) -> some View {
        let s = atem.state, mine = m.me == booth.me
        let name = store.config.mixNames.indices.contains(m.me) ? store.config.mixNames[m.me] : ""
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name.isEmpty ? "M/E \(m.me + 1)" : name).font(.sans(14, .bold)).lineLimit(1)
                Spacer()
                Text("M/E \(m.me + 1)").font(.sans(11)).foregroundStyle(T.inkSubtle)
                MixNameButton(me: m.me)
            }
            .frame(height: 18)
            ZStack(alignment: .topLeading) {
                if m.pic { SourcePicture(input: s.program[m.me], named: false) } else { T.surfaceSunken }
                HStack(spacing: 6) {
                    Tag(text: "Live", color: T.program, ink: .white)
                    Text(store.label(s.program[m.me], s)).font(.sans(13, .semibold)).foregroundStyle(.white).lineLimit(1)
                }
                .padding(.horizontal, 6).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: T.rSM).fill(Color.black.opacity(m.pic ? 0.6 : 0))).padding(m.pic ? 5 : 4)
            }
            .frame(width: m.live.width, height: m.live.height)
            .clipShape(RoundedRectangle(cornerRadius: T.rSM))
            .overlay(RoundedRectangle(cornerRadius: T.rSM).stroke(T.program, lineWidth: 2.5))
            HStack(spacing: 6) {
                Tag(text: "Next", color: T.preview, ink: T.onAction)
                Text(store.label(s.preview[m.me], s)).font(.sans(12, .semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).frame(width: m.next.width, height: m.next.height)
            .background(RoundedRectangle(cornerRadius: T.rSM).fill(T.surfaceSunken))
            .overlay(RoundedRectangle(cornerRadius: T.rSM).stroke(T.preview, lineWidth: 1.5))
            Text(mine ? "Run from the Operator view" : "Drop a source here to put it live on this mix")
                .font(.sans(11)).foregroundStyle(T.inkSubtle).lineLimit(1).minimumScaleFactor(0.8).frame(height: 14)
        }
        .padding(.horizontal, 10)
        .frame(width: m.frame.width, height: m.frame.height)
        .background(RoundedRectangle(cornerRadius: T.rLG).fill(T.surfaceRaised.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: T.rLG).stroke(target ? T.accent : c, lineWidth: target ? 4 : 2.5))
        .onTapGesture {
            if let sel = selected, !isMix(sel), !mine { putLive(sel, m.me) } else { selected = selected == m.output ? nil : m.output }
        }
        .draggable(m.output, self, L, w)
        .help(mine ? "\(store.mixName(m.me)): what the Operator view cuts and fades. Drag it onto a destination to send it there."
                   : "\(store.mixName(m.me)): drop a source here to put it live, or drag this onto a destination")
    }

    private func destRow(_ d: Dst, _ c: Color?, target: Bool, _ w: CGFloat) -> some View {
        // A mix by its short name ("Live stream"); the M/E number is on its card.
        var label = d.mixed ? "Mixed" : (d.source == nil ? "" : store.routeLabel(d.source, atem.state))
        if let src = d.source, isMix(src), src % 10 == 0 {
            let me = (src - 10000) / 10 - 1
            if store.config.mixNames.indices.contains(me), !store.config.mixNames[me].isEmpty { label = store.config.mixNames[me] }
        }
        let out = "OUT " + d.screen.aux.map(String.init).joined(separator: "+")
        return HStack(spacing: T.s2) {
            // On the picture's corner when there is one, so the name keeps its room.
            if d.pic { thumb(d.source, w).overlay(alignment: .topLeading) { port(out).padding(3) } } else { port(out) }
            if d.pic {
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.screen.name).font(.sans(14, .semibold)).lineLimit(2).minimumScaleFactor(0.8)
                    Text(label).font(.sans(12)).foregroundStyle(T.inkMuted).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            } else {
                // No live picture: one line, the name and what it's showing.
                Text(d.screen.name).font(.sans(13, .semibold)).lineLimit(1).minimumScaleFactor(0.8).layoutPriority(1)
                Spacer(minLength: 4)
                Text(label).font(.sans(11)).foregroundStyle(T.inkMuted).lineLimit(1).minimumScaleFactor(0.8)
            }
            if d.locked { Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(T.warning) }
            ScreenEditButton(screen: d.screen)
        }
        .padding(.leading, d.pic ? 4 : 6).padding(.trailing, 2)
        .frame(width: d.frame.width, height: d.frame.height)
        .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.surfaceSunken))
        .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(target ? T.accent : (c ?? T.line), lineWidth: target ? 4 : (c == nil ? 1 : 2)))
        .contentShape(Rectangle())
        .onHover { hover = $0 ? d.source : (hover == d.source ? nil : hover) }
        .onTapGesture { if let s = selected { route(s, d) } }
        .help("\(d.screen.name), switcher output \(d.screen.aux.map(String.init).joined(separator: ", "))"
              + ((d.screen.note ?? "").isEmpty ? "" : "\n\(d.screen.note!)") + (d.locked ? "\nLocked. Unlock Encoders and feeds to change it." : ""))
    }

    // MARK: Changing things

    private func canDrop(on m: Mix) -> Bool {
        guard m.me != booth.me, let s = drag?.source ?? selected else { return false }
        return !isMix(s)
    }

    private func target(_ d: Dst, _ L: Layout, _ w: CGFloat) -> Bool {
        if let drag { return d.frame.insetBy(dx: -16, dy: -3).contains(drag.at) && !d.locked }
        return selected != nil && !d.locked
    }

    /// Where a drag ended: on a destination, or on a mix that takes drops.
    fileprivate func drop(_ source: Int, at p: CGPoint, _ L: Layout) {
        if let d = L.dsts.first(where: { $0.frame.insetBy(dx: -16, dy: -3).contains(p) }) { route(source, d) }
        else if let m = L.mixes.first(where: { $0.frame.contains(p) }), m.me != booth.me, !isMix(source) { putLive(source, m.me) }
    }

    private func route(_ source: Int, _ d: Dst) {
        let s = atem.state, sc = d.screen
        selected = nil
        guard !d.locked else { message = "\(sc.name) is locked. Unlock Encoders and feeds to change it."; return }
        let was = sc.aux.compactMap { a in s.aux[a - 1].map { (a, $0) } }
        guard was.contains(where: { $0.1 != source }) || was.count < sc.aux.count else { return }
        let atem = atem
        push(sc.name) { for (a, v) in was { atem.setAux(a - 1, v) } }
        for a in sc.aux { atem.setAux(a - 1, source) }
        message = "\(sc.name) now shows \(store.routeLabel(source, s))."
    }

    private func putLive(_ source: Int, _ me: Int) {
        let s = atem.state
        selected = nil
        guard let was = s.program[me], was != source else { return }
        let atem = atem
        push(store.mixName(me)) { atem.setProgram(was, me: me) }
        atem.setProgram(source, me: me)
        message = "\(store.label(source, s)) is now live on \(store.mixName(me))."
    }

    private func push(_ what: String, _ back: @escaping () -> Void) {
        undo.append((what, back))
        if undo.count > 20 { undo.removeFirst() }
    }

    fileprivate func setDrag(_ v: (source: Int, at: CGPoint)?) { drag = v; if v != nil { selected = nil } }
    fileprivate func tap(_ id: Int) { selected = selected == id ? nil : id }
    fileprivate func setHover(_ id: Int, _ on: Bool) { hover = on ? id : (hover == id ? nil : hover) }
}

private struct SchematicHeight: PreferenceKey {
    static let defaultValue: CGFloat = 400
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private extension View {
    /// Something that can be picked up as a source: hover to see its wires, click to choose
    /// it, drag it onto a destination or a mix.
    func draggable(_ id: Int, _ owner: RoutingSchematic, _ L: RoutingSchematic.Layout, _ w: CGFloat) -> some View {
        self.contentShape(Rectangle())
            .onHover { owner.setHover(id, $0) }
            .onTapGesture { owner.tap(id) }
            .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("schematic"))
                .onChanged { owner.setDrag((id, $0.location)) }
                .onEnded { v in owner.drop(id, at: v.location, L); owner.setDrag(nil) })
    }
}

/// The pencil on a mix: what that M/E is for, such as "Live stream".
struct MixNameButton: View {
    let me: Int
    @EnvironmentObject var store: ConfigStore
    @State private var editing = false

    var body: some View {
        IconButton(icon: "pencil", help: "Name what this mix is for") { editing = true }
            .popover(isPresented: $editing, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: T.s2) {
                    Text("What M/E \(me + 1) is for").font(.sans(14, .bold))
                    TextField("Such as Live stream", text: Binding(
                        get: { store.config.mixNames.indices.contains(me) ? store.config.mixNames[me] : "" },
                        set: { v in store.update { c in
                            while c.mixNames.count <= me { c.mixNames.append("") }
                            c.mixNames[me] = v
                        } }))
                    .textFieldStyle(CueFieldStyle()).frame(width: 260).onSubmit { editing = false }
                    HStack { Spacer(); Button("Done") { editing = false }.buttonStyle(CueButton(kind: .primary)) }
                }
                .padding(T.s4).foregroundStyle(T.ink)
            }
    }
}

/// The pencil on a source: the NDI picture that shows what this switcher input carries.
struct SourcePictureButton: View {
    let input: Int
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var store: ConfigStore
    @State private var editing = false

    var body: some View {
        IconButton(icon: "pencil", help: "Choose a live picture for this source") { editing = true }
            .popover(isPresented: $editing, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: T.s2) {
                    Text("Picture for \(store.label(input, atem.state))").font(.sans(14, .bold))
                    Text("An NDI source showing what switcher input \(input) carries. It's only for looking at here; it changes nothing on the switcher.")
                        .font(.sans(12)).foregroundStyle(T.inkMuted).fixedSize(horizontal: false, vertical: true)
                    NDIPicker(selection: store.ndi(input), none: "No picture, just the name") { store.setPicture(input, $0) }
                    HStack { Spacer(); Button("Done") { editing = false }.buttonStyle(CueButton(kind: .primary)) }
                }
                .padding(T.s4).frame(width: 340).foregroundStyle(T.ink)
            }
    }
}
