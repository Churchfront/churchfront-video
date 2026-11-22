import Foundation
import Combine
import CoreGraphics
import ImageIO
import CueATEM

// Stage scan: before a service, with everyone in place (rehearsal or soundcheck), each Canon
// camera that isn't on Live goes to a wide shot, CueVideo finds everyone in it, and works out
// the shot that frames each person from that camera. A person labels them ("Pastor", "Keys"),
// and CueVideo saves a shot per person per camera and remembers what each one looks like, so
// auto tracking can follow someone by name for the rest of the day.
//
// The wide shot is the camera's shot named "Stage" or "Wide" if it has one; otherwise where
// it's pointing now, zoomed all the way out. Cameras go back to where they were afterwards.
// A camera that is on Live or auto tracking is left alone.

/// Turning a place in a camera's picture into where to point the camera. Canon cameras report
/// pan and tilt in degrees and their zoom as the horizontal angle of view, so this is exact
/// geometry, not a guess. Free of cameras and pictures so it can be tested on its own.
enum ShotMath {
    /// Where a camera points (degrees; right and up are positive) and how wide it sees.
    struct View: Equatable {
        var pan: Double, tilt: Double, fov: Double
    }

    struct Limits {
        var fov: ClosedRange<Double> = 3...75
        var pan: ClosedRange<Double> = -170...170
        var tilt: ClosedRange<Double> = -30...90
    }

    private static let rad = Double.pi / 180

    /// How far right of and above the middle of the picture a point is, in degrees
    /// (x and y from 0 to 1, origin top left; the picture is 16:9).
    static func angles(_ p: CGPoint, fov: Double) -> (right: Double, up: Double) {
        let t = tan(fov / 2 * rad)
        return (atan((Double(p.x) - 0.5) * 2 * t) / rad, atan((0.5 - Double(p.y)) * 2 * t * 9 / 16) / rad)
    }

    /// The view that frames a person seen in `from`: their eyes `eyeLine` down from the top,
    /// and their eyes-to-shoulders drop `wantScale` of the frame height (see ShotSize).
    /// `scale` is that drop as measured in the picture now.
    static func shot(eye: CGPoint, scale: Double, from: View, eyeLine: Double, wantScale: Double, limits: Limits = Limits()) -> View {
        // Size in the picture goes with 1 / tan(half the angle of view).
        let wanted = 2 * atan(tan(from.fov / 2 * rad) * scale / wantScale) / rad
        let fov = min(limits.fov.upperBound, max(limits.fov.lowerBound, wanted))
        let (right, up) = angles(eye, fov: from.fov)
        // In the new shot the eyes sit above the middle by this much.
        let lift = atan((0.5 - eyeLine) * 2 * tan(fov / 2 * rad) * 9 / 16) / rad
        // A camera tilted up or down turns a little farther to cover the same sideways distance.
        let pan = from.pan + right / max(0.5, cos(from.tilt * rad))
        let tilt = from.tilt + up - lift
        return View(pan: min(limits.pan.upperBound, max(limits.pan.lowerBound, pan)),
                    tilt: min(limits.tilt.upperBound, max(limits.tilt.lowerBound, tilt)), fov: fov)
    }
}

/// What a Canon camera says about itself in one read: where it is and how far it can go.
struct CanonState {
    var position: PTZPosition
    var limits = ShotMath.Limits()

    var view: ShotMath.View {
        ShotMath.View(pan: Double(position.pan) / 100, tilt: Double(position.tilt) / 100, fov: Double(position.zoom) / 100)
    }

    /// From the camera's info page ("key:=value" lines; "key==value" while a value is changing).
    static func parse(_ text: String) -> CanonState? {
        var kv: [String: Double] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let l = String(line)
            guard let r = l.range(of: ":=") ?? l.range(of: "=="), let v = Double(l[r.upperBound...]) else { continue }
            kv[String(l[..<r.lowerBound])] = v
        }
        guard let p = kv["c.1.pan"], let t = kv["c.1.tilt"], let z = kv["c.1.zoom"] else { return nil }
        var s = CanonState(position: PTZPosition(pan: Int(p), tilt: Int(t), zoom: Int(z)))
        func range(_ k: String, _ fallback: ClosedRange<Double>) -> ClosedRange<Double> {
            guard let lo = kv["c.1.\(k).limit.min"], let hi = kv["c.1.\(k).limit.max"], lo < hi else { return fallback }
            return (lo / 100)...(hi / 100)
        }
        s.limits = ShotMath.Limits(fov: range("zoom", s.limits.fov), pan: range("pan", s.limits.pan), tilt: range("tilt", s.limits.tilt))
        return s
    }

    static func read(_ c: PTZCamera) async -> CanonState? {
        let port = c.port == 80 ? "" : ":\(c.port)"
        guard let url = URL(string: "http://\(c.host)\(port)/-wvhttp-01-/info.cgi?item=c.1.pan,c.1.tilt,c.1.zoom") else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 3)
        r.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: r) else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// A still picture from the camera (the same one camera_snapshots uses; changes nothing on it).
    static func still(_ c: PTZCamera) async -> CGImage? {
        let port = c.port == 80 ? "" : ":\(c.port)"
        guard let url = URL(string: "http://\(c.host)\(port)/-wvhttp-01-/image.cgi") else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 5)
        r.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: r),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

@MainActor
final class StageScan: ObservableObject {
    static let shared = StageScan()

    /// One person as one camera saw them.
    struct Person: Identifiable {
        /// 1, 2, 3 and so on across the scan.
        let id: Int
        let camera: UUID
        let cameraName: String
        /// A small picture of them, for labelling.
        let thumb: CGImage?
        /// The shot that frames them from this camera.
        let shot: PTZPosition
        /// True when only their outline was found (too small or turned away for body
        /// landmarks), so the shot's size is an estimate.
        let rough: Bool
        let look: Appearance?
        /// People with the same group are CueVideo's guess at the same person seen by
        /// different cameras (by their look). A suggestion: labels decide.
        var group: Int
        var label = ""

        var letter: String { String(UnicodeScalar(UInt8(65 + group % 26))) }
    }

    @Published private(set) var people: [Person] = []
    @Published private(set) var running = false
    @Published private(set) var progress = ""
    /// Cameras left out and why, and anything else worth knowing about the last scan.
    @Published private(set) var notes: [String] = []
    @Published private(set) var scannedAt: Date?
    /// The shot size the scan frames people as.
    @Published var size: ShotSize = .waist

    private var booth: Booth { Booth.shared }

    /// Why a camera can't be scanned right now, or nil if it can.
    func blocked(_ c: PTZCamera) -> String? {
        if c.proto != .canonXC || c.host.isEmpty { return String(localized: "only Canon cameras report where they point") }
        if let i = c.atemInput, (booth.atem.state.tally[i] ?? 0) & 1 != 0 { return String(localized: "it's on Live") }
        if AutoTracker.shared.isTracking(c.id) { return String(localized: "it's auto tracking") }
        if !booth.ptz.hasControl(c) { return String(localized: "Churchfront Video doesn't have control of it") }
        return nil
    }

    /// Scans with the cameras given (all of them by default). Moves each camera that isn't
    /// blocked to a wide shot and back.
    func scan(_ cameras: [PTZCamera]? = nil) async {
        guard !running else { return }
        running = true
        people = []
        notes = []
        defer { running = false; progress = "" }

        var found: [Person] = []
        for c in cameras ?? booth.ptz.cameras {
            if let why = blocked(c) { notes.append(String(localized: "\(c.name) was left out: \(why).")); continue }
            progress = String(localized: "\(c.name): going wide")
            guard let start = await CanonState.read(c) else { notes.append(String(localized: "\(c.name) was left out: it didn't answer.")); continue }

            let named = c.shots.first { $0.kind == .position && ["stage", "wide"].contains($0.name.lowercased()) }
            let wide = named?.position ?? PTZPosition(pan: start.position.pan, tilt: start.position.tilt,
                                                      zoom: Int(start.limits.fov.upperBound * 100))
            booth.ptz.go(to: PTZShot(name: "", wide), camera: c.id)
            let there = await settle(c)
            // Let the preview catch up and focus settle before taking the picture.
            try? await Task.sleep(nanoseconds: 900_000_000)

            progress = String(localized: "\(c.name): looking for people")
            var seen: [TrackedPerson] = []
            var picture: CGImage?
            if blocked(c) == nil, let img = await CanonState.still(c) {
                picture = img
                seen = await Task.detached(priority: .userInitiated) { AutoTracker.detect(img) }.value
            } else {
                notes.append(String(localized: "\(c.name): no picture came in, so no one was found on it."))
            }
            let view = (await CanonState.read(c) ?? there ?? start)

            for p in seen.sorted(by: { $0.box.midX < $1.box.midX }) {
                // Without body landmarks, take the outline as head to waist (about 4.5 times eyes to shoulders).
                let scale = p.scale ?? Double(p.box.height) / 4.5
                let v = ShotMath.shot(eye: p.eye, scale: max(0.004, scale), from: view.view,
                                      eyeLine: size.eyeLine, wantScale: size.scale, limits: view.limits)
                let shot = PTZPosition(pan: Int((v.pan * 100).rounded()), tilt: Int((v.tilt * 100).rounded()), zoom: Int((v.fov * 100).rounded()))
                found.append(Person(id: found.count + 1, camera: c.id, cameraName: c.name, thumb: picture.flatMap { Self.thumb($0, p.box) },
                                    shot: shot, rough: p.scale == nil, look: p.appearance, group: -1))
            }
            if picture != nil, seen.isEmpty { notes.append(String(localized: "\(c.name) saw no one in its wide shot.")) }

            // Back to where it was, unless it went Live in the meantime: nothing moves on Live.
            if blocked(c) == nil {
                booth.ptz.go(to: PTZShot(name: "", start.position), camera: c.id)
            } else {
                notes.append(String(localized: "\(c.name) was left on its wide shot because it's now in use."))
            }
        }
        people = Self.grouped(found)
        scannedAt = Date()
    }

    /// Waits for a camera to finish moving: two reads in a row at the same place.
    private func settle(_ c: PTZCamera) async -> CanonState? {
        var last: CanonState?
        for n in 0..<40 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let now = await CanonState.read(c) else { continue }
            if n >= 2, let l = last, l.position == now.position { return now }
            last = now
        }
        return last
    }

    /// Suggests who is the same person across cameras: each later camera's people are matched
    /// to the people already found by how alike they look, best fits first. Anyone who looks
    /// like no one so far is a new person.
    nonisolated static func grouped(_ found: [Person]) -> [Person] {
        var out = found
        var groups: [[Appearance]] = []
        var cameras: [UUID] = []
        for p in found where !cameras.contains(p.camera) { cameras.append(p.camera) }
        for cam in cameras {
            let mine = out.indices.filter { out[$0].camera == cam }
            var pairs: [(i: Int, g: Int, d: Double)] = []
            for i in mine {
                guard let look = out[i].look else { continue }
                for (g, looks) in groups.enumerated() { if let d = look.distance(to: looks), d < 0.7 { pairs.append((i, g, d)) } }
            }
            var takenGroups = Set<Int>()
            for pair in pairs.sorted(by: { $0.d < $1.d }) where out[pair.i].group < 0 && !takenGroups.contains(pair.g) {
                out[pair.i].group = pair.g
                takenGroups.insert(pair.g)
            }
            for i in mine {
                if out[i].group < 0 { out[i].group = groups.count; groups.append([]) }
                if let look = out[i].look { groups[out[i].group].append(look) }
            }
        }
        return out
    }

    /// Labels one person. The same label goes to the others CueVideo thinks are the same
    /// person, when they had the same label (or none) before, so one name usually covers all cameras.
    func label(_ id: Int, _ text: String) {
        guard let i = people.firstIndex(where: { $0.id == id }) else { return }
        let before = people[i].label
        for j in people.indices where people[j].group == people[i].group && people[j].label == before { people[j].label = text }
        people[i].label = text
    }

    /// Saves a shot for every labelled person on the camera that saw them, and remembers what
    /// each one looks like for following by name. Shots from an earlier scan are replaced; a
    /// shot you made yourself with the same name is kept. Returns what happened, in plain words.
    @discardableResult
    func save() -> [String] {
        let ptz = booth.ptz
        var said: [String] = []
        var cast: [String: [Appearance]] = [:]
        var saved = 0
        for cam in Set(people.map(\.camera)) {
            guard let ci = ptz.cameras.firstIndex(where: { $0.id == cam }) else { continue }
            var shots = ptz.cameras[ci].shots.filter { !$0.auto }
            var names = Set<String>()
            for p in people where p.camera == cam {
                let name = p.label.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                if let look = p.look { cast[name, default: []].append(look) }
                guard names.insert(name.lowercased()).inserted else {
                    said.append(String(localized: "\(p.cameraName) saw two people labelled \(name); only the first got a shot."))
                    continue
                }
                if shots.contains(where: { $0.kind == .position && $0.name.lowercased() == name.lowercased() }) {
                    said.append(String(localized: "\(p.cameraName) already has your own shot called \(name), so it was kept."))
                    continue
                }
                var shot = PTZShot(name: name, p.shot)
                shot.auto = true
                shots.append(shot)
                saved += 1
            }
            if ptz.cameras[ci].shots != shots { ptz.cameras[ci].shots = shots }
        }
        StageCast.shared.set(cast)
        said.insert(String(localized: "Saved \(saved) shots for \(cast.count) people."), at: 0)
        return said
    }

    /// A small picture of one person, with a little room around them.
    nonisolated static func thumb(_ img: CGImage, _ box: CGRect) -> CGImage? {
        let w = CGFloat(img.width), h = CGFloat(img.height)
        let padded = box.insetBy(dx: -box.width * 0.25, dy: -box.height * 0.15)
        let r = CGRect(x: padded.minX * w, y: padded.minY * h, width: padded.width * w, height: padded.height * h)
            .integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard r.width >= 8, r.height >= 8 else { return nil }
        return img.cropping(to: r)
    }
}
