import SwiftUI
import CueATEM

// Video routing: which picture goes to which screen.
//
// The switcher's aux outputs feed the screens and encoders around the building. CueVideo
// names them (config "screens"), says what each M/E is for (config "mixNames": M/E 1 the
// live stream, M/E 2 the side screens), and gives volunteers a few routing buttons
// (config "routes") that work like macros: one press sends one or more screens a new
// picture, and a button is lit while the switcher already matches it.

/// Volunteer routing buttons, bottom right of the main window, with what each screen shows.
struct RoutePanel: View {
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        let s = atem.state
        let routes = store.config.routes
        VStack(alignment: .leading, spacing: T.s2) {
            HStack {
                Text("Screens").panelLabel()
                Spacer()
                Button { Booth.shared.show(.routing) } label: { Image(systemName: "arrow.triangle.branch").font(.system(size: 11)) }
                    .buttonStyle(.borderless).foregroundStyle(T.inkSubtle).help("Open the Routing page")
            }
            if !routes.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: T.s2), GridItem(.flexible(), spacing: T.s2)], spacing: T.s2) {
                    ForEach(routes) { r in RouteButtonView(route: r) }
                }
            }
            // What every volunteer-facing screen shows right now.
            VStack(alignment: .leading, spacing: 3) {
                ForEach(store.config.screens.filter(\.forVolunteers)) { sc in
                    HStack(spacing: 6) {
                        Text(sc.name).font(.sans(11, .semibold)).foregroundStyle(T.inkMuted).lineLimit(1)
                        Image(systemName: "arrow.left").font(.system(size: 8, weight: .bold)).foregroundStyle(T.inkSubtle)
                        Text(RoutingText.showing(sc, s, store)).font(.sans(11)).foregroundStyle(T.ink).lineLimit(1)
                    }
                }
            }
            .padding(.top, 2)
        }
    }
}

struct RouteButtonView: View {
    let route: RouteButton
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        let on = route.isActive(atem.state)
        Button { route.run(atem) } label: {
            VStack(spacing: 1) {
                Text(route.label).font(.sans(12, .semibold)).lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
                Text(on ? "ON" : RoutingText.summary(route, store, atem.state)).font(.sans(9, .bold)).tracking(0.5)
                    .lineLimit(1).minimumScaleFactor(0.7).opacity(0.75)
            }
            .foregroundStyle(on ? T.onAction : T.ink)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity).frame(height: 46)
            .background(RoundedRectangle(cornerRadius: T.rMD).fill(on ? T.accent : T.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(on ? T.accent : T.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(RoutingText.detail(route, store, atem.state))
    }
}

enum RoutingText {
    /// What a screen shows: one source, or "mixed" when its linked auxes disagree.
    static func showing(_ sc: ScreenOutput, _ s: ATEMState, _ store: ConfigStore) -> String {
        let now = Set(sc.aux.map { s.aux[$0 - 1] })
        guard now.count == 1, let one = now.first else { return "Mixed" }
        return store.routeLabel(one, s)
    }

    /// Screen names a button changes: "LED wall, Lobby TVs".
    static func summary(_ r: RouteButton, _ store: ConfigStore, _ s: ATEMState) -> String {
        var names: [String] = []
        for c in r.set {
            let n = store.screen(aux: c.aux)?.name ?? "Aux \(c.aux)"
            if !names.contains(n) { names.append(n) }
        }
        return names.joined(separator: ", ").uppercased()
    }

    static func detail(_ r: RouteButton, _ store: ConfigStore, _ s: ATEMState) -> String {
        var lines: [String] = [], seen = Set<String>()
        for c in r.set {
            let n = store.screen(aux: c.aux)?.name ?? "Aux \(c.aux)"
            let line = "\(n) ← \(store.routeLabel(c.source, s))"
            if seen.insert(line).inserted { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Routing page

/// The whole picture for the system owner: what each mix is for, what every aux output
/// shows and where it's wired, and the volunteer routing buttons.
struct RoutingWindow: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var store: ConfigStore
    @State private var editing = false
    @State private var newButton = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: T.s4) {
                mixes
                screens
                buttons
            }
            .padding(T.s4)
        }
        .background(T.bg)
        .frame(minWidth: 820, minHeight: 560)
    }

    // MARK: Mixes

    var mixes: some View {
        let s = atem.state
        let mes = s.program.keys.sorted()
        return SetupSection(title: "Mixes",
                            note: "Each M/E is its own mix. Name what it's for. The volunteer screen runs \(store.mixName(booth.me)); the other mixes can be switched here.") {
            HStack(alignment: .top, spacing: T.s3) {
                ForEach(mes, id: \.self) { me in
                    VStack(alignment: .leading, spacing: T.s2) {
                        HStack {
                            Text("M/E \(me + 1)").panelLabel()
                            TextField("What it's for", text: Binding(
                                get: { store.config.mixNames.indices.contains(me) ? store.config.mixNames[me] : "" },
                                set: { v in store.update { c in
                                    while c.mixNames.count <= me { c.mixNames.append("") }
                                    c.mixNames[me] = v
                                } }))
                            .textFieldStyle(.roundedBorder)
                        }
                        HStack(spacing: T.s3) {
                            Label(store.label(s.program[me], s), systemImage: "circle.fill").foregroundStyle(T.program)
                            Label(store.label(s.preview[me], s), systemImage: "circle").foregroundStyle(T.preview)
                        }
                        .font(.sans(13, .semibold))
                        if me != booth.me {
                            // Quick switching for the other mix (such as the side screens).
                            let sources = store.volunteerSources(s)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], spacing: 6) {
                                ForEach(sources) { src in
                                    let on = s.program[me] == src.input
                                    Button { atem.setProgram(src.input, me: me) } label: {
                                        Text(store.label(src.input, s)).font(.sans(12, .semibold)).lineLimit(1)
                                            .foregroundStyle(on ? .white : T.ink)
                                            .frame(maxWidth: .infinity).frame(height: 30)
                                            .background(RoundedRectangle(cornerRadius: T.rSM).fill(on ? T.program : T.surfaceRaised))
                                    }
                                    .buttonStyle(PressStyle())
                                    .help("Put \(store.label(src.input, s)) on \(store.mixName(me)) now")
                                }
                            }
                        }
                    }
                    .padding(T.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.surfaceSunken))
                }
            }
        }
    }

    // MARK: Screens

    /// Configured screens, then every aux nobody has named yet.
    var rows: [ScreenOutput] {
        let named = store.config.screens
        let used = Set(named.flatMap(\.aux))
        let spare = (1...max(1, atem.state.auxCount)).filter { !used.contains($0) && atem.state.aux[$0 - 1] != nil }
        return named + spare.map { ScreenOutput(name: "", aux: [$0]) }
    }

    var screens: some View {
        SetupSection(title: "Screens and outputs",
                     note: "Every switcher aux output: the picture it gets, and where it's wired. Change a picture here and it changes right away. Linked auxes (such as a pair of lobby TVs) switch together.") {
            HStack {
                Spacer()
                Toggle("Edit names and wiring", isOn: $editing).toggleStyle(.switch).controlSize(.small).font(.sans(12))
            }
            ForEach(rows) { sc in ScreenRow(screen: sc, editing: editing) }
        }
    }

    // MARK: Buttons

    var buttons: some View {
        SetupSection(title: "Volunteer routing buttons",
                     note: "Buttons in the bottom right of the main window. Each one sends one or more screens a picture, like a macro, and lights up while the screens match it. The easy way to make one: route the screens the way you want above, then save it as a button.") {
            ForEach(Array(store.config.routes.enumerated()), id: \.element.id) { i, r in
                HStack(spacing: T.s2) {
                    TextField("Label", text: Binding(get: { r.label }, set: { v in store.update { c in
                        if let j = c.routes.firstIndex(of: r), !v.isEmpty { c.routes[j].label = v }
                    } }))
                    .textFieldStyle(.roundedBorder).frame(width: 200)
                    Text(RoutingText.detail(r, store, atem.state).replacingOccurrences(of: "\n", with: " · "))
                        .font(.sans(12)).foregroundStyle(T.inkMuted).lineLimit(2)
                    Spacer()
                    if r.isActive(atem.state) { Text("ON").font(.sans(10, .bold)).foregroundStyle(T.accent) }
                    Button("Run") { r.run(atem) }
                    Button { moveRoute(i, -1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
                    Button { moveRoute(i, 1) } label: { Image(systemName: "chevron.down") }.disabled(i == store.config.routes.count - 1)
                    Button { store.update { $0.routes.removeAll { $0 == r } } } label: { Image(systemName: "minus.circle") }
                }
                .buttonStyle(.borderless)
            }
            Button("Save the current routing as a button…") { newButton = true }
                .popover(isPresented: $newButton) { NewRouteButton(done: { newButton = false }) }
        }
    }

    func moveRoute(_ i: Int, _ d: Int) {
        store.update { c in
            let j = i + d
            guard c.routes.indices.contains(i), c.routes.indices.contains(j) else { return }
            c.routes.swapAt(i, j)
        }
    }
}

/// One screen (or a spare aux): source picker → aux numbers → name and wiring.
struct ScreenRow: View {
    let screen: ScreenOutput
    let editing: Bool
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var store: ConfigStore
    @State private var name = ""
    @State private var auxText = ""
    @State private var note = ""

    var named: Bool { !screen.name.isEmpty }

    var body: some View {
        let s = atem.state
        HStack(spacing: T.s3) {
            SourceMenu(current: Set(screen.aux.map { s.aux[$0 - 1] }).count == 1 ? s.aux[screen.aux[0] - 1] : nil,
                       mixed: Set(screen.aux.map { s.aux[$0 - 1] }).count > 1) { src in
                for a in screen.aux { atem.setAux(a - 1, src) }
            }
            .frame(width: 250, alignment: .leading)
            Image(systemName: "arrow.right").foregroundStyle(T.inkSubtle)
            Text(screen.aux.count == 1 ? "Aux \(screen.aux[0])" : "Aux " + screen.aux.map(String.init).joined(separator: ", "))
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(T.inkMuted).frame(width: 90, alignment: .leading)
            Image(systemName: "arrow.right").foregroundStyle(T.inkSubtle)
            if editing {
                TextField("Name (such as Lobby TVs)", text: $name).textFieldStyle(.roundedBorder).frame(width: 170)
                    .onSubmit(save)
                TextField("Auxes", text: $auxText).textFieldStyle(.roundedBorder).frame(width: 70).onSubmit(save)
                    .help("Aux outputs, counted from 1. Several, such as 4, 5, switch together.")
                TextField("Wiring note", text: $note).textFieldStyle(.roundedBorder).onSubmit(save)
                if named {
                    Toggle("Volunteers", isOn: Binding(get: { screen.forVolunteers }, set: { v in update { $0.volunteer = v } }))
                        .toggleStyle(.checkbox).font(.sans(11))
                        .help("Show this screen in the volunteer's screen summary")
                    Button { store.update { $0.screens.removeAll { $0 == screen } } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Forget this name (the aux stays)")
                }
                Button("Save", action: save).controlSize(.small)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(named ? screen.name : "Not named").font(.sans(13, .semibold)).foregroundStyle(named ? T.ink : T.inkSubtle)
                        if named, !screen.forVolunteers {
                            Text("HIDDEN FROM VOLUNTEERS").font(.sans(9, .bold)).foregroundStyle(T.inkSubtle)
                        }
                    }
                    if let n = screen.note, !n.isEmpty { Text(n).font(.sans(11)).foregroundStyle(T.inkMuted).lineLimit(1) }
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
        .onAppear(perform: load)
        .onChange(of: editing) { _, _ in load() }
    }

    func load() {
        name = screen.name
        auxText = screen.aux.map(String.init).joined(separator: ", ")
        note = screen.note ?? ""
    }

    func save() {
        let auxes = auxText.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }.filter { $0 >= 1 }
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !auxes.isEmpty else { return }
        store.update { c in
            let new = ScreenOutput(name: n, aux: auxes, note: note.isEmpty ? nil : note, volunteer: screen.volunteer)
            // An aux belongs to one screen: take these auxes away from any other.
            for i in c.screens.indices where c.screens[i] != screen { c.screens[i].aux.removeAll { auxes.contains($0) } }
            c.screens.removeAll { $0.aux.isEmpty }
            if let i = c.screens.firstIndex(of: screen) { c.screens[i] = new } else { c.screens.append(new) }
        }
    }

    func update(_ f: (inout ScreenOutput) -> Void) {
        store.update { c in if let i = c.screens.firstIndex(of: screen) { f(&c.screens[i]) } }
    }
}

/// Picks any source an aux can take, grouped: the mixes first, then the volunteer's sources, then everything.
struct SourceMenu: View {
    let current: Int?
    var mixed = false
    let pick: (Int) -> Void
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        let s = atem.state
        let all = s.auxSources
        let mixes = all.filter { (10000..<11000).contains($0.id) }
        let favorites = store.volunteerSources(s).map(\.input).filter { id in all.contains { $0.id == id } }
        Menu {
            Section("Mixes") {
                ForEach(mixes) { i in Button(store.routeLabel(i.id, s)) { pick(i.id) } }
            }
            Section("Sources") {
                ForEach(favorites, id: \.self) { id in Button(store.label(id, s)) { pick(id) } }
            }
            Menu("Everything else") {
                ForEach(all.filter { i in !mixes.contains(i) && !favorites.contains(i.id) }) { i in
                    Button("\(i.long) (\(i.short))") { pick(i.id) }
                }
            }
        } label: {
            Text(mixed ? "Mixed" : store.routeLabel(current, s)).font(.sans(13, .semibold)).lineLimit(1)
        }
        .fixedSize()
    }
}

/// Saves what chosen screens show now as a volunteer button.
struct NewRouteButton: View {
    let done: () -> Void
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var store: ConfigStore
    @State private var label = ""
    @State private var picked: Set<String> = []

    var body: some View {
        let s = atem.state
        VStack(alignment: .leading, spacing: T.s3) {
            Text("New routing button").font(.sans(14, .bold))
            TextField("Label, such as Lobby: stream", text: $label).textFieldStyle(.roundedBorder).frame(width: 300)
            Text("Screens it sets, to what they show now:").font(.sans(12)).foregroundStyle(T.inkMuted)
            ForEach(store.config.screens) { sc in
                Toggle(isOn: Binding(get: { picked.contains(sc.id) }, set: { v in if v { picked.insert(sc.id) } else { picked.remove(sc.id) } })) {
                    Text("\(sc.name) ← \(RoutingText.showing(sc, s, store))").font(.sans(12))
                }
                .toggleStyle(.checkbox)
            }
            if store.config.screens.isEmpty {
                Text("Name the screens first (Edit names and wiring).").font(.sans(12)).foregroundStyle(T.warning)
            }
            HStack {
                Spacer()
                Button("Cancel", action: done)
                Button("Save button") {
                    let set = store.config.screens.filter { picked.contains($0.id) }.flatMap { sc in
                        sc.aux.compactMap { a in s.aux[a - 1].map { RouteChange(aux: a, source: $0) } }
                    }
                    let l = label.trimmingCharacters(in: .whitespaces)
                    store.update { c in c.routes.removeAll { $0.label == l }; c.routes.append(RouteButton(label: l, set: set)) }
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || picked.isEmpty)
            }
        }
        .padding(T.s4)
    }
}
