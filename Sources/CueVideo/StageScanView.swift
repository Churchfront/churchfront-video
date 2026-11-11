import SwiftUI
import CueATEM

/// Window → Stage Scan (⇧⌘S): find everyone on stage, label them, and save a shot for each
/// person on each camera. See StageScan.
struct StageScanWindow: View {
    @ObservedObject private var scan = StageScan.shared
    @ObservedObject private var cast = StageCast.shared
    @EnvironmentObject var ptz: PTZController
    @EnvironmentObject var atem: ATEMClient
    @State private var saved: [String] = []

    private var cameras: [PTZCamera] { ptz.cameras.filter { !$0.host.isEmpty } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: T.s4) {
                VStack(alignment: .leading, spacing: T.s1) {
                    Text("Stage scan").font(.sans(22, .bold))
                    Text("With everyone in place, each camera that isn't on Live goes to a wide shot, finds the people in it, and comes back. Label each person, and CueVideo saves a shot of them on every camera that saw them and can follow them by name for the rest of the day.")
                        .font(.sans(13)).foregroundStyle(T.inkMuted).fixedSize(horizontal: false, vertical: true)
                    Text("The wide shot is a camera's shot named Stage or Wide if it has one. Otherwise it's where the camera points now, zoomed all the way out.")
                        .font(.sans(12)).foregroundStyle(T.inkSubtle).fixedSize(horizontal: false, vertical: true)
                }

                // Which cameras will take part.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(cameras) { c in
                        let why = scan.blocked(c)
                        HStack(spacing: T.s2) {
                            Circle().fill(why == nil ? T.success : T.lineStrong).frame(width: 8, height: 8)
                            Text(c.name).font(.sans(13, .semibold))
                            Text(why.map { "Left out: \($0)" } ?? "Will be scanned").font(.sans(12))
                                .foregroundStyle(why == nil ? T.inkMuted : T.warning)
                        }
                    }
                    if cameras.isEmpty { Text("No cameras set up yet. Add them in Setup (⌘,).").font(.sans(13)).foregroundStyle(T.inkMuted) }
                }

                HStack(spacing: T.s3) {
                    Text("Frame each person").font(.sans(12)).foregroundStyle(T.inkMuted)
                    Picker("", selection: $scan.size) {
                        ForEach(ShotSize.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 320)
                    Button { saved = []; Task { await scan.scan() } } label: {
                        Text(scan.running ? "Scanning…" : (scan.people.isEmpty ? "Scan the stage" : "Scan again"))
                            .font(.sans(14, .bold)).foregroundStyle(T.onAction)
                            .padding(.horizontal, T.s4).frame(height: 34)
                            .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.accent.opacity(scan.running ? 0.5 : 1)))
                    }
                    .buttonStyle(.plain)
                    .disabled(scan.running || cameras.allSatisfy { scan.blocked($0) != nil })
                    .help("Moves each camera listed as \"Will be scanned\" to its wide shot and back. Cameras on Live don't move.")
                    if scan.running {
                        ProgressView().controlSize(.small)
                        Text(scan.progress).font(.sans(12)).foregroundStyle(T.inkMuted)
                    }
                }

                ForEach(scan.notes, id: \.self) { n in
                    Text(n).font(.sans(12, .semibold)).foregroundStyle(T.warning)
                }

                if !scan.people.isEmpty {
                    Rectangle().fill(T.line).frame(height: 1)
                    Text("Who is who").font(.sans(16, .bold))
                    Text("Type a name or a role under each person. The letter is CueVideo's guess at who is the same person on another camera: naming one fills in the others with the same letter. Fix any it got wrong. Leave a person blank to skip them.")
                        .font(.sans(12)).foregroundStyle(T.inkMuted).fixedSize(horizontal: false, vertical: true)
                    ForEach(cameras.filter { c in scan.people.contains { $0.camera == c.id } }) { c in
                        VStack(alignment: .leading, spacing: T.s2) {
                            Text(c.name).panelLabel()
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 170), spacing: T.s3, alignment: .top)], alignment: .leading, spacing: T.s3) {
                                ForEach(scan.people.filter { $0.camera == c.id }) { p in PersonCard(person: p, camera: c) }
                            }
                        }
                    }
                    HStack(spacing: T.s3) {
                        Button { saved = scan.save() } label: {
                            Text("Save shots and names").font(.sans(14, .bold)).foregroundStyle(T.onAction)
                                .padding(.horizontal, T.s4).frame(height: 34)
                                .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.accent))
                        }
                        .buttonStyle(.plain)
                        .disabled(scan.people.allSatisfy { $0.label.trimmingCharacters(in: .whitespaces).isEmpty })
                        Text("Replaces the shots from the last scan. Shots you made yourself are kept.")
                            .font(.sans(12)).foregroundStyle(T.inkSubtle)
                    }
                    ForEach(saved, id: \.self) { line in Text(line).font(.sans(12, .semibold)).foregroundStyle(T.success) }
                }

                if !cast.names.isEmpty {
                    Rectangle().fill(T.line).frame(height: 1)
                    Text("Can follow by name: \(cast.names.joined(separator: ", "))").font(.sans(13, .semibold))
                    Text("Under Track on the main screen, choose Follow by name. This lasts until CueVideo quits or the next scan is saved.")
                        .font(.sans(12)).foregroundStyle(T.inkSubtle)
                }
            }
            .padding(T.s5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(T.bg)
        .foregroundStyle(T.ink)
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
            .clipShape(RoundedRectangle(cornerRadius: T.rMD))
            .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(T.line))
            TextField("Name or role", text: Binding(get: { person.label }, set: { scan.label(person.id, $0) }))
                .textFieldStyle(.roundedBorder).font(.sans(13))
            HStack(spacing: 6) {
                Button("Try the shot") { ptz.go(to: PTZShot(name: "", person.shot), camera: camera.id) }
                    .buttonStyle(.borderless).font(.sans(11, .semibold)).foregroundStyle(T.accentStrong)
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
