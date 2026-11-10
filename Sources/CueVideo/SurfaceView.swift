import SwiftUI
import CueATEM

/// The switcher panel, laid out like an ATEM control surface: keys on the left,
/// program and preview rows in the middle, the transition block on the right.
struct SurfaceView: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient

    var me: Int { booth.me }
    var st: ATEMState { atem.state }
    var simple: Bool { booth.simple }
    var bw: CGFloat { simple ? 100 : 76 }
    var bh: CGFloat { simple ? 72 : 56 }

    var body: some View {
        HStack(alignment: .top, spacing: T.s5) {
            if !simple && (st.keyerCount > 0 || st.dskCount > 0) {
                keys
                divider
            }
            VStack(alignment: .leading, spacing: T.s3) {
                bus(simple ? "Live" : "Program", st.program[me], T.program) { atem.setProgram($0, me: me) }
                bus(simple ? "Next" : "Preview", st.preview[me], T.preview) { atem.setPreview($0, me: me) }
                if !simple && (!st.macros.isEmpty || st.auxCount > 0) {
                    HStack(alignment: .top, spacing: T.s5) {
                        if !st.macros.isEmpty { macros }
                        if st.auxCount > 0 { aux }
                    }
                    .padding(.top, T.s2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            divider
            transition
        }
        .padding(T.s4)
        .background(T.surfaceSunken)
    }

    var divider: some View { Rectangle().fill(T.line).frame(width: 1).frame(maxHeight: 150) }

    // MARK: Buses

    func bus(_ label: String, _ selected: Int?, _ color: Color, _ pick: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).panelLabel(color)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: T.s2) {
                    ForEach(st.busSources.filter { !simple || $0.isExternal || $0.id == 0 || ($0.id >= 3000 && $0.id < 4000) }) { s in
                        PanelButton(title: s.short, subtitle: simple ? s.long : nil, lit: s.id == selected ? color : nil,
                                    width: bw, height: bh, titleSize: simple ? 18 : 14) { pick(s.id) }
                            .help(s.long)
                    }
                }
                .padding(.vertical, 6).padding(.horizontal, 2)
            }
        }
    }

    // MARK: Keys

    var keys: some View {
        HStack(alignment: .top, spacing: T.s4) {
            if st.keyerCount > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Next transition").panelLabel()
                    let sel = st.nextSelection[me] ?? 1
                    HStack(spacing: T.s2) {
                        PanelButton(title: "BKGD", lit: sel & 1 != 0 ? T.warning : nil, width: 62, height: 40, titleSize: 12) {
                            atem.setNextSelection(sel ^ 1, me: me)
                        }
                        ForEach(0..<st.keyerCount, id: \.self) { k in
                            PanelButton(title: "KEY \(k + 1)", lit: sel & (2 << k) != 0 ? T.warning : nil, width: 62, height: 40, titleSize: 12) {
                                atem.setNextSelection(sel ^ (2 << k), me: me)
                            }
                        }
                    }
                    Text("Key on air").panelLabel().padding(.top, T.s2)
                    HStack(spacing: T.s2) {
                        ForEach(0..<st.keyerCount, id: \.self) { k in
                            let on = st.keyOnAir[me]?[k] ?? false
                            PanelButton(title: "KEY \(k + 1)", lit: on ? T.program : nil, width: 62, height: 40, titleSize: 12) {
                                atem.setKeyOnAir(k, !on, me: me)
                            }
                        }
                    }
                }
            }
            ForEach(0..<st.dskCount, id: \.self) { d in
                VStack(spacing: T.s2) {
                    Text("DSK \(d + 1)").panelLabel()
                    PanelButton(title: "TIE", lit: st.dskTie[d] == true ? T.warning : nil, width: 62, height: 34, titleSize: 12) {
                        atem.setDSKTie(d, !(st.dskTie[d] ?? false))
                    }
                    PanelButton(title: "CUT", lit: st.dskOnAir[d] == true ? T.program : nil, width: 62, height: 34, titleSize: 12) {
                        atem.setDSKOnAir(d, !(st.dskOnAir[d] ?? false))
                    }
                    PanelButton(title: "AUTO", lit: st.dskInTransition[d] == true ? T.program : nil, width: 62, height: 34, titleSize: 12,
                                blink: st.dskInTransition[d] == true) {
                        atem.dskAuto(d)
                    }
                }
            }
        }
    }

    // MARK: Macros and aux

    var macros: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Macros").panelLabel()
                if st.macroRunning != nil {
                    Button("Stop") { atem.stopMacro() }.buttonStyle(.plain).font(.sans(11, .bold)).foregroundStyle(T.danger)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: T.s2) {
                    ForEach(st.macros.keys.sorted(), id: \.self) { i in
                        PanelButton(title: st.macros[i] ?? "", subtitle: "\(i + 1)", lit: st.macroRunning == i ? T.warning : nil,
                                    width: 96, height: 40, titleSize: 12, blink: st.macroRunning == i) { atem.runMacro(i) }
                    }
                }
                .padding(.vertical, 6).padding(.horizontal, 2)
            }
        }
    }

    var aux: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Aux outputs").panelLabel()
            HStack(spacing: T.s2) {
                ForEach(st.aux.keys.sorted(), id: \.self) { a in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AUX \(a + 1)").font(.sans(9, .bold)).foregroundStyle(T.inkSubtle)
                        Picker("", selection: Binding(get: { st.aux[a] ?? 0 }, set: { atem.setAux(a, $0) })) {
                            ForEach(st.auxSources) { Text($0.long).tag($0.id) }
                        }
                        .labelsHidden().pickerStyle(.menu).frame(width: 150)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: Transition block

    var transition: some View {
        let inT = st.inTransition[me] ?? false
        let black = st.ftbBlack[me] ?? false
        return HStack(alignment: .top, spacing: T.s3) {
            if !simple {
                VStack(spacing: T.s2) {
                    Text("Style").panelLabel()
                    ForEach([(0, "MIX"), (1, "DIP"), (2, "WIPE"), (3, "DVE")], id: \.0) { id, name in
                        PanelButton(title: name, lit: (st.style[me] ?? 0) == id ? T.warning : nil, width: 62, height: 30, titleSize: 11) {
                            atem.setStyle(id, me: me)
                        }
                    }
                    HStack(spacing: 2) {
                        Button { atem.setMixRate((st.mixRate[me] ?? 30) - 5, me: me) } label: { Image(systemName: "minus") }
                        Text(rate(st.mixRate[me] ?? 30)).font(.sans(11, .semibold)).frame(width: 34)
                        Button { atem.setMixRate((st.mixRate[me] ?? 30) + 5, me: me) } label: { Image(systemName: "plus") }
                    }
                    .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).foregroundStyle(T.inkMuted)
                    .help("Mix rate in seconds and frames")
                }
            }
            VStack(spacing: T.s2) {
                Text(" ").panelLabel()
                PanelButton(title: "CUT", width: simple ? 110 : 84, height: simple ? 64 : 52, titleSize: simple ? 18 : 15) { atem.cut(me: me) }
                PanelButton(title: simple ? "FADE" : "AUTO", lit: inT ? T.program : nil, width: simple ? 110 : 84,
                            height: simple ? 64 : 52, titleSize: simple ? 18 : 15) { atem.auto(me: me) }
                PanelButton(title: simple ? "BLACK" : "FTB", lit: black || (st.ftbInTransition[me] ?? false) ? T.program : nil,
                            width: simple ? 110 : 84, height: 36, titleSize: 12, blink: black) { atem.fadeToBlack(me: me) }
                    .help("Fade to black")
            }
            if !simple {
                TBar(me: me).frame(width: 56, height: 170).padding(.top, 18)
            }
        }
    }

    func rate(_ frames: Int) -> String { "\(frames / 30):\(String(format: "%02d", frames % 30))" }
}

/// A T-bar you drag like the real lever. Its rest end flips after each transition.
struct TBar: View {
    @EnvironmentObject var atem: ATEMClient
    let me: Int
    @State private var dragging: Double?

    var body: some View {
        let atTop = atem.tbarAtTop[me] ?? false
        let pos = atem.state.position[me] ?? 0
        let inT = atem.state.inTransition[me] ?? false
        // Knob height above the bottom, 0 to 1.
        let shown = dragging ?? (inT ? (atTop ? 1 - pos : pos) : (atTop ? 1 : 0))
        return GeometryReader { g in
            let knob: CGFloat = 26
            let travel = g.size.height - knob
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 6).fill(T.surface).overlay(RoundedRectangle(cornerRadius: 6).stroke(T.line))
                RoundedRectangle(cornerRadius: 2).fill(T.surfaceSunken).frame(width: 6).padding(.vertical, 10)
                RoundedRectangle(cornerRadius: 4).fill(inT ? T.program : T.inkMuted)
                    .overlay(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.25)).frame(height: 2))
                    .frame(width: g.size.width - 8, height: knob)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                    .offset(y: (1 - shown) * travel)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let f = min(1, max(0, 1 - (v.location.y - knob / 2) / travel))
                dragging = f
                atem.setPosition(atTop ? 1 - f : f, me: me)
            }.onEnded { _ in dragging = nil })
        }
    }
}
