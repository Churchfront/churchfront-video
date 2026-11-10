import SwiftUI
import CueATEM

struct ContentView: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @Environment(\.openWindow) var openWindow

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Rectangle().fill(T.line).frame(height: 1)
            if booth.connectedOnce || atem.link == .online {
                VolunteerView()
                    .overlay(alignment: .top) { LinkBanner() }
            } else {
                ConnectView()
            }
        }
        .background(T.bg)
        .foregroundStyle(T.ink)
        // Windows opened by Claude through the show_window tool.
        .onReceive(NotificationCenter.default.publisher(for: .cueVideoShowWindow)) { n in
            switch n.object as? String {
            case "setup": openWindow(id: "setup")
            case "switcher": openWindow(id: "switcher")
            default: NSApp.windows.first { $0.title == "CueVideo" }?.makeKeyAndOrderFront(nil)
            }
        }
    }
}

/// Kept short for volunteers: are we connected, recording and streaming, and the way into Setup.
struct TopBar: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @Environment(\.openWindow) var openWindow

    var body: some View {
        HStack(spacing: T.s4) {
            Text("CueVideo").font(.sans(16, .bold)).padding(.leading, 64)
            LinkPill()
            let down = ptz.cameras.filter { !$0.host.isEmpty && !ptz.online.contains($0.id) }
            let waiting = ptz.cameras.filter { ptz.online.contains($0.id) && !ptz.hasControl($0) }
            if !ptz.cameras.isEmpty {
                let problem = (down.isEmpty ? [] : ["\(down.map(\.name).joined(separator: ", ")) not answering"])
                    + (waiting.isEmpty ? [] : ["\(waiting.map(\.name).joined(separator: ", ")) waiting for control"])
                Text(problem.isEmpty ? "\(ptz.cameras.count) cameras" : problem.joined(separator: " · "))
                    .font(.sans(12, problem.isEmpty ? .regular : .semibold))
                    .foregroundStyle(problem.isEmpty ? T.inkMuted : T.warning)
                    .help("Canon cameras take commands from one controller at a time. A logged-in session, like the camera's own web page, outranks CueVideo.")
            }
            Spacer()
            if atem.state.hasRecording {
                StatusButton(title: atem.state.recording ? "Recording" : "Record", on: atem.state.recording, color: T.program) {
                    atem.setRecording(!atem.state.recording)
                }
            }
            if atem.state.hasStreaming { StatusButton(title: atem.state.streaming ? "Streaming" : (atem.state.streamConnecting ? "Connecting" : "Stream"),
                         on: atem.state.streaming || atem.state.streamConnecting, color: atem.state.streaming ? T.program : T.warning) {
                atem.setStreaming(!(atem.state.streaming || atem.state.streamConnecting))
            } }
            Button { openWindow(id: "setup") } label: { Image(systemName: "gearshape").font(.system(size: 15)) }
                .buttonStyle(.plain).foregroundStyle(T.inkMuted).help("Setup and status (⌘,)")
        }
        .padding(.horizontal, T.s4)
        .frame(height: 48)
        .background(T.surface)
    }
}

struct StatusButton: View {
    let title: String
    let on: Bool
    let color: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(on ? color : T.lineStrong).frame(width: 8, height: 8)
                Text(title).font(.sans(12, .semibold))
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(Capsule().fill(on ? color.opacity(0.18) : T.surfaceRaised))
            .overlay(Capsule().stroke(on ? color.opacity(0.6) : T.line))
        }
        .buttonStyle(.plain)
    }
}

struct LinkPill: View {
    @EnvironmentObject var atem: ATEMClient
    var body: some View {
        let (text, color): (String, Color) = {
            switch atem.link {
            case .online: return ("Online", T.success)
            case .connecting: return ("Connecting", T.warning)
            case .offline: return ("Offline", T.danger)
            case .idle: return ("Not set up", T.inkSubtle)
            }
        }()
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.sans(12, .semibold)).foregroundStyle(color)
        }
    }
}

struct LinkBanner: View {
    @EnvironmentObject var atem: ATEMClient
    var body: some View {
        if case .offline(let why) = atem.link {
            Text("\(why). Reconnecting on its own; buttons do nothing until it's back.")
                .font(.sans(13, .semibold)).foregroundStyle(T.onAction)
                .padding(.horizontal, T.s4).padding(.vertical, T.s2)
                .background(Capsule().fill(T.warning)).padding(.top, T.s3)
        }
    }
}

struct ConnectView: View {
    @EnvironmentObject var atem: ATEMClient
    @State private var host = Booth.shared.store.config.atemHost

    var body: some View {
        VStack(spacing: T.s4) {
            Spacer()
            Text("Connect to your ATEM").font(.sans(26, .bold))
            Text("CueVideo talks to the switcher directly over your network. No Blackmagic software needed.\nFind the switcher's IP address in ATEM Setup under Network.")
                .font(.sans(14)).foregroundStyle(T.inkMuted).multilineTextAlignment(.center)
            HStack {
                TextField("192.168.10.240", text: $host)
                    .textFieldStyle(.plain).font(.sans(16))
                    .padding(.horizontal, T.s3).frame(width: 260, height: 40)
                    .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.surfaceSunken))
                    .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(T.line))
                    .onSubmit(go)
                Button(action: go) {
                    Text("Connect").font(.sans(15, .bold)).foregroundStyle(T.onAction)
                        .padding(.horizontal, T.s5).frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.accent))
                }.buttonStyle(.plain)
            }
            switch atem.link {
            case .connecting: Text("Connecting to \(atem.host)…").foregroundStyle(T.warning)
            case .offline(let why): Text(why).foregroundStyle(T.danger)
            default: EmptyView()
            }
            Spacer()
        }
        .font(.sans(14))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func go() {
        Booth.shared.store.update { $0.atemHost = host.trimmingCharacters(in: .whitespaces) }
    }
}
