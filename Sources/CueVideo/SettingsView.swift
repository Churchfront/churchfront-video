import SwiftUI
import CueATEM

struct SettingsView: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @Environment(\.dismiss) var dismiss
    @State private var host = UserDefaults.standard.string(forKey: "atemHost") ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: T.s5) {
            HStack {
                Text("Switcher and cameras").font(.sans(20, .bold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            VStack(alignment: .leading, spacing: T.s2) {
                Text("ATEM switcher").panelLabel()
                HStack {
                    TextField("IP address", text: $host).textFieldStyle(.roundedBorder).frame(width: 220)
                    Button("Connect") {
                        UserDefaults.standard.set(host, forKey: "atemHost")
                        atem.connect(host)
                    }
                    LinkPill()
                    if !atem.state.product.isEmpty {
                        Text("\(atem.state.product), protocol \(atem.state.version)").font(.sans(12)).foregroundStyle(T.inkMuted)
                    }
                }
            }
            VStack(alignment: .leading, spacing: T.s2) {
                HStack {
                    Text("PTZ cameras").panelLabel()
                    Spacer()
                    Button("Add camera") {
                        var c = PTZCamera()
                        c.name = "Camera \(ptz.cameras.count + 1)"
                        c.proto = .canonXC; c.port = 80
                        ptz.cameras.append(c)
                    }
                }
                if ptz.cameras.isEmpty {
                    Text("Add each PTZ camera's IP address. Pick Canon (HTTP) for Canon cameras: it works with no camera settings and shows the presets saved on the camera. Most other cameras speak VISCA over IP on UDP port 52381; PTZOptics cameras also take VISCA over TCP on port 5678. Set Switcher input to the ATEM input the camera is plugged into, so picking it on Next selects it here.")
                        .font(.sans(12)).foregroundStyle(T.inkMuted)
                }
                ScrollView {
                    VStack(spacing: T.s2) {
                        ForEach($ptz.cameras) { $c in CameraRow(camera: $c) { ptz.cameras.removeAll { $0.id == c.id } } }
                    }
                }
                .frame(maxHeight: 340)
            }
            Text("Keys: 1 to 0 put a camera on Next, Shift plus a number cuts it straight to Live, Space cuts, Return runs the transition, arrow keys move the selected PTZ camera.")
                .font(.sans(12)).foregroundStyle(T.inkSubtle)
        }
        .padding(T.s6)
        .frame(width: 820)
        .background(T.bg)
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
            .frame(width: 140)
            .help("The switcher input this camera is plugged into")
            Picker("", selection: $camera.firstPreset) {
                Text("Presets from 0").tag(0)
                Text("Presets from 1").tag(1)
            }
            .frame(width: 120)
            Button(action: remove) { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(T.inkSubtle)
        }
        .font(.sans(12))
    }
}
