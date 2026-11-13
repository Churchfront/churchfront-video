import SwiftUI
import CueATEM

/// Engineer → Stage scan (⇧⌘S): find everyone on stage, label them, and save a shot for
/// each person on each camera. Laid out as its three steps. See StageScan.
struct StageScanWindow: View {
    @ObservedObject private var scan = StageScan.shared
    @ObservedObject private var cast = StageCast.shared
    @EnvironmentObject var ptz: PTZController
    @EnvironmentObject var atem: ATEMClient
    @State private var saved: [String] = []

    private var cameras: [PTZCamera] { ptz.cameras.filter { !$0.host.isEmpty } }
    private var ready: Int { cameras.filter { scan.blocked($0) == nil }.count }

    var body: some View {
        Page {
            PageHeader(title: "Stage scan", purpose: "With everyone in place, find each person, name them, and save a shot of them on every camera.",
                       help: "Each camera that isn't on Live goes to a wide shot, finds the people in it, and comes back. Label each person, and CueVideo saves a shot of them on every camera that saw them and can follow them by name for the rest of the day.\n\nThe wide shot is a camera's shot named Stage or Wide if it has one. Otherwise it's where the camera points now, zoomed all the way out. A tighter Stage shot makes people bigger in the picture and easier to find.\n\nThe shots are for where people stood during the scan, so run it at rehearsal or soundcheck.")
            HStack(alignment: .top, spacing: T.s4) {
                step(1, "Cameras") {
                    if cameras.isEmpty {
                        Text("No cameras set up yet. Add them in Setup.").font(.sans(13)).foregroundStyle(T.inkMuted)
                    }
                    ForEach(cameras) { c in
                        let why = scan.blocked(c)
                        HStack(spacing: T.s2) {
                            Circle().fill(why == nil ? T.success : T.lineStrong).frame(width: 8, height: 8)
                            Text(c.name).font(.sans(13, .semibold)).frame(width: 90, alignment: .leading).lineLimit(1)
                            Text(why.map { "Left out: \($0)" } ?? "Will go wide and come back").font(.sans(12))
                                .foregroundStyle(why == nil ? T.inkMuted : T.warning).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                step(2, "Scan") {
                    HStack(spacing: T.s3) {
                        Text("Frame each person").font(.sans(12)).foregroundStyle(T.inkMuted)
                        Segments(items: ShotSize.allCases.map { ($0.name, $0) }, selection: $scan.size)
                    }
                    HStack(spacing: T.s3) {
                        Button { saved = []; Task { await scan.scan() } } label: {
                            Text(scan.running ? "Scanning…" : (scan.people.isEmpty ? "Scan the stage" : "Scan again"))
                        }
                        .buttonStyle(CueButton(kind: .primary))
                        .disabled(scan.running || ready == 0)
                        .help("Moves each camera marked \"Will go wide and come back\". Cameras on Live don't move.")
                        if scan.running {
                            ProgressView().controlSize(.small)
                            Text(scan.progress).font(.sans(12)).foregroundStyle(T.inkMuted)
                        } else if ready == 0 {
                            Text("No camera is free to scan right now.").font(.sans(12)).foregroundStyle(T.warning)
                        } else {
                            Text("\(ready) camera\(ready == 1 ? "" : "s") will move.").font(.sans(12)).foregroundStyle(T.inkSubtle)
                        }
                    }
                    ForEach(scan.notes, id: \.self) { n in
                        Text(n).font(.sans(12, .semibold)).foregroundStyle(T.warning).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            step(3, "Name people and save") {
                if scan.people.isEmpty {
                    Text(scan.scannedAt == nil ? "After a scan, each person each camera saw appears here with a box for their name."
                                               : "The last scan found no one. Check the notes above, then scan again.")
                        .font(.sans(13)).foregroundStyle(T.inkMuted)
                } else {
                    Text("Type a name or a role under each person. The letter is CueVideo's guess at the same person on another camera: naming one fills in the others with that letter. Fix any it got wrong, and leave a person blank to skip them.")
                        .font(.sans(12)).foregroundStyle(T.inkMuted).fixedSize(horizontal: false, vertical: true)
                    ForEach(cameras.filter { c in scan.people.contains { $0.camera == c.id } }) { c in
                        VStack(alignment: .leading, spacing: T.s2) {
                            Text(c.name).font(.sans(13, .bold))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 170), spacing: T.s3, alignment: .top)], alignment: .leading, spacing: T.s3) {
                                ForEach(scan.people.filter { $0.camera == c.id }) { p in PersonCard(person: p, camera: c) }
                            }
                        }
                    }
                    HStack(spacing: T.s3) {
                        Button("Save shots and names") { saved = scan.save() }
                            .buttonStyle(CueButton(kind: .primary))
                            .disabled(scan.people.allSatisfy { $0.label.trimmingCharacters(in: .whitespaces).isEmpty })
                        Text("Replaces the shots from the last scan. Shots you made yourself are kept.")
                            .font(.sans(12)).foregroundStyle(T.inkSubtle)
                    }
                    ForEach(saved, id: \.self) { line in Text(line).font(.sans(12, .semibold)).foregroundStyle(T.success) }
                }
            }
            if !cast.names.isEmpty {
                Card(title: "Can follow by name") {
                    Text(cast.names.joined(separator: ", ")).font(.sans(13, .semibold))
                    Text("On Operate, under Track, choose Follow by name. This lasts until CueVideo quits or the next scan is saved.")
                        .font(.sans(12)).foregroundStyle(T.inkSubtle)
                }
            }
        }
    }

    private func step<C: View>(_ n: Int, _ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: T.s3) {
            StepLabel(n: n, text: title)
            content()
        }
        .padding(T.s4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: T.rLG).fill(T.surface))
        .overlay(RoundedRectangle(cornerRadius: T.rLG).stroke(T.line))
    }
}

/// One person from the scan: their picture, the same-person letter, a label, and a way to
/// try the shot.
private struct PersonCard: View {
    let person: StageScan.Person
    let camera: PTZCamera
    @ObservedObject private var scan = StageScan.shared
    @EnvironmentObject var ptz: PTZController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                Color.black
                if let img = person.thumb {
                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                }
                Text(person.letter).font(.sans(12, .bold)).foregroundStyle(T.onAction)
                    .frame(width: 22, height: 22).background(Circle().fill(T.accent)).padding(6)
            }
            .frame(height: 170)
            .clipShape(Rectangle())
            .overlay(Rectangle().stroke(T.line))
            TextField("Name or role", text: Binding(get: { person.label }, set: { scan.label(person.id, $0) }))
                .textFieldStyle(CueFieldStyle())
            HStack(spacing: 6) {
                Button("Try the shot") { ptz.go(to: PTZShot(name: "", person.shot), camera: camera.id) }
                    .buttonStyle(CueButton(kind: .quiet))
                    .disabled(scan.running || scan.blocked(camera) != nil)
                    .help(scan.blocked(camera).map { "\(camera.name) can't move now: \($0)." } ?? "Send \(camera.name) to this shot to check it")
                if person.rough {
                    Text("size is a guess").font(.sans(10)).foregroundStyle(T.warning)
                        .help("Only this person's outline was found, so how tight the shot is was estimated. Try the shot and adjust.")
                }
            }
        }
    }
}
