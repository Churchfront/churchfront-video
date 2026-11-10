import SwiftUI
import CueATEM

/// The preview monitor: the ATEM multiview (or any NDI source), with the
/// live and next sources written large underneath when there's no picture.
struct MonitorView: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ndi: NDIMonitor

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: T.rLG).fill(Color.black)
            if ndi.source != nil {
                NDIVideoView().clipShape(RoundedRectangle(cornerRadius: T.rLG))
                if !ndi.receiving { waiting }
            } else {
                noPicture
            }
        }
        .overlay(RoundedRectangle(cornerRadius: T.rLG).stroke(T.line))
        .overlay(alignment: .topTrailing) { sourceMenu.padding(T.s3) }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var waiting: some View {
        VStack(spacing: T.s2) {
            ProgressView().controlSize(.small)
            Text("Waiting for \(NDIMonitor.shortName(ndi.source ?? ""))").font(.sans(13)).foregroundStyle(T.inkMuted)
        }
    }

    var noPicture: some View {
        VStack(spacing: T.s5) {
            HStack(spacing: T.s6) {
                bigTally("LIVE", atem.state.program[booth.me], T.program)
                bigTally("NEXT", atem.state.preview[booth.me], T.preview)
            }
            Text(ndi.hasRuntime
                 ? "Pick the ATEM multiview from the NDI menu to see the cameras here. Turn on the multiview's NDI output in ATEM Setup if it isn't listed."
                 : "Install the free NDI Tools from ndi.video to see the ATEM multiview here.")
                .font(.sans(13)).foregroundStyle(T.inkSubtle).multilineTextAlignment(.center).frame(maxWidth: 460)
        }
    }

    func bigTally(_ label: String, _ id: Int?, _ color: Color) -> some View {
        VStack(spacing: T.s2) {
            Text(label).panelLabel(color)
            Text(id.flatMap { atem.state.inputs[$0]?.long } ?? atem.state.name(id))
                .font(.sans(30, .bold)).lineLimit(1).minimumScaleFactor(0.5)
        }
        .frame(width: 260, height: 120)
        .background(RoundedRectangle(cornerRadius: T.rLG).stroke(color, lineWidth: 3))
    }

    var sourceMenu: some View {
        Menu {
            if ndi.sources.isEmpty { Text(ndi.hasRuntime ? "No NDI sources found yet" : "NDI Tools isn't installed") }
            ForEach(ndi.sources, id: \.self) { s in
                Button { ndi.start(s) } label: {
                    if s == ndi.source { Label(NDIMonitor.shortName(s), systemImage: "checkmark") } else { Text(NDIMonitor.shortName(s)) }
                }
            }
            Divider()
            Button("Look again") { ndi.scan() }
            if ndi.source != nil { Button("No picture") { ndi.start(nil) } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.on.rectangle")
                Text(ndi.source.map(NDIMonitor.shortName) ?? "NDI").lineLimit(1)
            }
            .font(.sans(12, .semibold)).foregroundStyle(T.ink)
            .padding(.horizontal, 10).frame(height: 26)
            .background(Capsule().fill(Color.black.opacity(0.6)))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in ndi.scan() }
    }
}
