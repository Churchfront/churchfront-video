import SwiftUI
import CueATEM

/// The two views of the main window. Operator is the booth volunteer's screen: Next and
/// Live on top, shots, camera control and the take buttons below. Engineer is everything
/// else, for whoever sets the system up: stage scan, routing, the full switcher, setup and status.
enum AppView: String {
    case operate, engineer
}

/// The pages of the Engineer view, as tabs across its top.
enum EngineerSection: String, CaseIterable, Identifiable {
    case scan, routing, switcher, setup, status
    var id: String { rawValue }

    var title: String {
        switch self {
        case .scan: return "Stage scan"
        case .routing: return "Routing"
        case .switcher: return "Full switcher"
        case .setup: return "Setup"
        case .status: return "Status"
        }
    }
    var note: String {
        switch self {
        case .scan: return "People, labels, shots"
        case .routing: return "Screens and buttons"
        case .switcher: return "Keys, T-bar, macros, aux"
        case .setup: return "Sources, keys, cameras"
        case .status: return "Connections and log"
        }
    }
    var icon: String {
        switch self {
        case .scan: return "person.2.crop.square.stack"
        case .routing: return "arrow.triangle.branch"
        case .switcher: return "square.grid.3x2"
        case .setup: return "gearshape"
        case .status: return "waveform.path.ecg"
        }
    }
}

/// Operator | Engineer, in the top bar.
struct ViewSwitch: View {
    @EnvironmentObject var booth: Booth

    var body: some View {
        HStack(spacing: 0) {
            item("Operator", .operate, "The booth screen: pick, frame, take (⌘1)")
            item("Engineer", .engineer, "Stage scan, routing, the full switcher, setup and status (⌘2)")
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.surfaceSunken))
        .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(T.line))
    }

    private func item(_ title: String, _ view: AppView, _ help: String) -> some View {
        let on = booth.view == view
        return Button { booth.view = view } label: {
            Text(title).font(.sans(12, .semibold)).foregroundStyle(on ? T.onAction : T.inkMuted)
                .padding(.horizontal, T.s3).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: T.rSM).fill(on ? T.accent : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The Engineer view: one strip across the top with what's on air (so nobody loses track
/// of the service while they're in here) and the page tabs, then the chosen page using
/// the whole window.
struct EngineerView: View {
    @EnvironmentObject var booth: Booth

    var body: some View {
        VStack(spacing: 0) {
            OnAirStrip()
            Rectangle().fill(T.line).frame(height: 1)
            page.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(T.bg)
    }

    @ViewBuilder private var page: some View {
        switch booth.section {
        case .scan: StageScanWindow()
        case .routing: RoutingWindow()
        case .switcher: SwitcherWindow()
        case .setup: SetupTab()
        case .status: StatusTab()
        }
    }
}

/// What's Live and Next right now, shown across the Engineer view.
struct OnAirStrip: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        let s = atem.state
        HStack(spacing: T.s3) {
            Text("On air now").panelLabel()
            pill("LIVE", store.label(s.program[booth.me], s), T.program, .white)
            pill("NEXT", store.label(s.preview[booth.me], s), T.preview, T.onAction)
            if s.ftbBlack[booth.me] ?? false {
                Text("Faded to black").font(.sans(12, .bold)).foregroundStyle(T.warning)
            }
            Spacer(minLength: T.s3)
            // The pages. In the middle of the strip, so each page gets the full width below.
            HStack(spacing: 2) {
                ForEach(EngineerSection.allCases) { sec in
                    let on = booth.section == sec
                    Button { booth.section = sec } label: {
                        HStack(spacing: 6) {
                            Image(systemName: sec.icon).font(.system(size: 12))
                            Text(sec.title).font(.sans(13, .semibold)).lineLimit(1)
                        }
                        .foregroundStyle(on ? T.onAction : T.inkMuted)
                        .padding(.horizontal, T.s3).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: T.rSM).fill(on ? T.accent : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(sec.note)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.surfaceSunken))
            .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(T.line))
            .fixedSize()
            Spacer(minLength: T.s3)
            Button { booth.view = .operate } label: {
                Text("Back to Operator").font(.sans(12, .semibold)).foregroundStyle(T.ink)
                    .padding(.horizontal, T.s3).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.surfaceRaised))
                    .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(T.line))
            }
            .buttonStyle(.plain)
            .help("Space, Return and the number keys do nothing in the Engineer view, so they can't cut or fade from here.")
        }
        .padding(.horizontal, T.s4).frame(height: 44)
        .background(T.surface)
    }

    private func pill(_ tag: String, _ name: String, _ color: Color, _ ink: Color) -> some View {
        HStack(spacing: 6) {
            Text(tag).font(.sans(10, .bold)).tracking(0.8).foregroundStyle(ink)
                .padding(.horizontal, 6).frame(height: 18)
                .background(RoundedRectangle(cornerRadius: T.rSM).fill(color))
            Text(name).font(.sans(13, .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 6).frame(height: 28)
        .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(color, lineWidth: 1))
    }
}
