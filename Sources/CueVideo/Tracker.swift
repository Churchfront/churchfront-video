import Foundation
import Combine
import Vision
import CueATEM

/// The three follow shots a broadcast camera operator works with, and how each is framed.
///
/// Framing follows standard broadcast practice:
/// - Eyes sit on or near the upper third line, with modest headroom (more room above the
///   head on wide shots, less on close ones), never the head in the middle of the frame.
/// - Frame edges cut between joints, not at them: a shoulders-up shot ends at mid-chest,
///   a waist-up shot just below the waist, a full-length shot leaves a little room under
///   the feet. Never at the neck, elbows, knees or ankles.
/// - Lead room (looking or walking room): a person facing or moving to one side gets more
///   space on that side, so they aren't walking into the edge of the frame.
/// - The camera doesn't chase every small move. It lets the person move a little inside the
///   frame, eases into and out of each move, and settles rather than hunting.
/// - Shot size stays consistent as people walk nearer or farther, with slow zooms.
///
/// Sizes are measured by the head: the drop from the eyes to the shoulders as a share of the
/// frame height. That stays visible in every shot size, and grows as the shot gets tighter.
enum ShotSize: String, CaseIterable, Identifiable {
    case shoulders, waist, full
    var id: String { rawValue }

    var name: String {
        switch self {
        case .shoulders: return "Shoulders up"
        case .waist: return "Waist up"
        case .full: return "Full length"
        }
    }
    var short: String {
        switch self { case .shoulders: return "Close"; case .waist: return "Waist"; case .full: return "Full" }
    }

    /// Where the eyes sit, down from the top of the frame (0 to 1).
    var eyeLine: Double {
        switch self { case .shoulders: return 0.34; case .waist: return 0.29; case .full: return 0.15 }
    }
    /// Eyes to shoulders as a share of frame height, the standard for this size.
    var scale: Double {
        switch self { case .shoulders: return 0.36; case .waist: return 0.21; case .full: return 0.095 }
    }
    /// How far off center a person facing or walking one way sits, giving lead room.
    var leadRoom: Double {
        switch self { case .shoulders: return 0.09; case .waist: return 0.11; case .full: return 0.13 }
    }
    /// How far they can drift across or up and down before the camera moves.
    var deadX: Double {
        switch self { case .shoulders: return 0.08; case .waist: return 0.07; case .full: return 0.06 }
    }
    var deadY: Double {
        switch self { case .shoulders: return 0.07; case .waist: return 0.08; case .full: return 0.10 }
    }

    /// The size a framing is closest to, from its head scale and what's in shot.
    static func classify(scale: Double?, anklesInShot: Bool, hipsInShot: Bool) -> ShotSize? {
        if let s = scale {
            if s < 0.145 { return .full }      // between the full and waist standards
            if s < 0.275 { return anklesInShot ? .full : .waist }
            return hipsInShot ? .waist : .shoulders
        }
        if anklesInShot { return .full }
        return hipsInShot ? .waist : nil
    }
}

/// One person found in a frame. Coordinates are normalized with the origin top left.
struct TrackedPerson {
    var box: CGRect
    /// Between the eyes (or the nose, or the ears).
    var eye: CGPoint
    /// Eyes to shoulders, as a share of frame height. Nil when the body landmarks aren't clear.
    var scale: Double?
    var hipsInShot = false
    var anklesInShot = false
    /// -1 facing left in the picture, 1 facing right, 0 toward the camera or unclear.
    var facing = 0

    var size: ShotSize? { ShotSize.classify(scale: scale, anklesInShot: anklesInShot, hipsInShot: hipsInShot) }
}

/// Auto tracking: a camera follows one person around the stage.
///
/// It watches the same preview picture the volunteer sees (CanonFeed), finds people and their
/// body landmarks in each frame with Apple's Vision framework, keeps hold of the one it was
/// told to follow, works out whether the shot is shoulders up, waist up or full length, and
/// pans, tilts and (gently) zooms to frame them the way a broadcast operator would (see
/// ShotSize). Any manual move of that camera (joystick, shot, preset, home) ends tracking at
/// once. Zooming by hand keeps tracking going and makes that zoom the size to hold.
final class AutoTracker: ObservableObject {
    static let shared = AutoTracker()

    enum Phase: String { case starting, following, searching, lost }

    struct Session {
        let camera: UUID
        var phase: Phase = .starting
        var target: TrackedPerson?
        /// The shot it's framing to, and the head scale to hold (the standard for the size,
        /// or whatever the volunteer zoomed to).
        var size: ShotSize = .waist
        var holdScale: Double?
        /// What the person asked for; nil means work it out from the shot when tracking starts.
        var asked: ShotSize?
        /// What the picture is right now.
        var seen: ShotSize?
        var pick: CGPoint?
        var people: [TrackedPerson] = []
        var eye: CGPoint?          // smoothed
        var scale: Double?         // smoothed
        var lead = 0.0             // smoothed lead-room offset
        var lastSeen = Date()
        var started = Date()
        var lastFrame = Date()
        var manualZoomAt: Date?
        var panning = false, tilting = false, zooming = false
        var sentPan = 0.0, sentTilt = 0.0, sentZoom = 0.0
        var panDir = 0, panDirSince = Date()
    }

    @Published private(set) var sessions: [UUID: Session] = [:]

    private var feeds: [UUID: AnyCancellable] = [:]
    private var cameras: [UUID: PTZCamera] = [:]
    private var busy: Set<UUID> = []
    private var waiters: [UUID: [(String?) -> Void]] = [:]
    private var timer: Timer?
    // Concurrent, so cameras tracking at once each get their own frames looked at; `busy` keeps
    // one frame per camera in flight.
    private let vision = DispatchQueue(label: "cuevideo.tracker", qos: .userInitiated, attributes: .concurrent)

    private var ptz: PTZController { Booth.shared.ptz }
    private var config: CueConfig { Booth.shared.store.config }

    private init() {}

    /// Hooks the tracker to the camera controls. Called once at launch.
    func attach() {
        ptz.onManualMove = { [weak self] id in self?.stop(id) }
        ptz.onManualZoom = { [weak self] id in self?.manualZoom(id) }
    }

    func isTracking(_ id: UUID) -> Bool { sessions[id] != nil }

    /// Start following someone on a camera. `point` (0 to 1, top left) picks the person
    /// nearest it; without one, the person nearest the middle. `size` frames them as that
    /// shot; without one, as whichever shot the camera is closest to now. `done` gets nil
    /// once someone is found, or the reason no one was.
    func start(_ camera: PTZCamera, at point: CGPoint? = nil, size: ShotSize? = nil, done: ((String?) -> Void)? = nil) {
        let keep = sessions[camera.id]?.asked
        stop(camera.id)
        guard camera.proto == .canonXC, !camera.host.isEmpty else {
            done?("Auto tracking needs the camera's preview picture, which only Canon cameras give CueVideo.")
            return
        }
        var s = Session(camera: camera.id)
        s.pick = point
        s.asked = size ?? keep
        if let a = s.asked { s.size = a }
        sessions[camera.id] = s
        cameras[camera.id] = camera
        if let done { waiters[camera.id, default: []].append(done) }
        CanonFeedHub.shared.retain(camera)
        let feed = CanonFeedHub.shared.feed(for: camera)
        feeds[camera.id] = feed.$image.compactMap { $0 }.sink { [weak self] img in self?.frame(img, camera.id) }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    /// Reframe a tracking camera as a different shot size.
    func setSize(_ id: UUID, _ size: ShotSize) {
        guard var s = sessions[id] else { return }
        s.asked = size
        s.size = size
        s.holdScale = size.scale
        s.manualZoomAt = nil
        sessions[id] = s
    }

    func stop(_ id: UUID) {
        guard let s = sessions[id] else { return }
        sessions[id] = nil
        feeds[id] = nil
        busy.remove(id)
        if let c = cameras.removeValue(forKey: id) { CanonFeedHub.shared.release(c) }
        if s.sentPan != 0 || s.sentTilt != 0 { ptz.trackDrive(pan: 0, tilt: 0, camera: id) }
        if s.sentZoom != 0 { ptz.trackZoom(0, camera: id) }
        finish(id, "Tracking was stopped.")
        if sessions.isEmpty { timer?.invalidate(); timer = nil }
    }

    func stopAll() { for id in sessions.keys { stop(id) } }

    /// The volunteer (or Claude) zoomed: stop holding the old size for a moment, then hold the new one.
    private func manualZoom(_ id: UUID) {
        guard var s = sessions[id] else { return }
        s.manualZoomAt = Date()
        s.zooming = false
        s.sentZoom = 0
        sessions[id] = s
    }

    // MARK: Frames

    private func frame(_ img: CGImage, _ id: UUID) {
        guard sessions[id] != nil, !busy.contains(id) else { return }  // still working on the last frame: skip
        busy.insert(id)
        vision.async { [weak self] in
            let people = Self.detect(img)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy.remove(id)
                self.update(id, people)
            }
        }
    }

    /// People in a frame, with their landmarks where Vision can see them.
    static func detect(_ img: CGImage) -> [TrackedPerson] {
        let pose = VNDetectHumanBodyPoseRequest()
        let rects = VNDetectHumanRectanglesRequest()
        rects.upperBodyOnly = true
        do { try VNImageRequestHandler(cgImage: img).perform([pose, rects]) } catch { return [] }

        var found: [TrackedPerson] = []
        for o in pose.results ?? [] {
            guard let pts = try? o.recognizedPoints(.all) else { continue }
            func at(_ j: VNHumanBodyPoseObservation.JointName, _ min: Float = 0.3) -> CGPoint? {
                guard let p = pts[j], p.confidence >= min else { return nil }
                return CGPoint(x: p.location.x, y: 1 - p.location.y)
            }
            func mid(_ a: CGPoint?, _ b: CGPoint?) -> CGPoint? {
                switch (a, b) {
                case let (a?, b?): return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                default: return a ?? b
                }
            }
            let eyes = mid(at(.leftEye), at(.rightEye))
            let ears = mid(at(.leftEar), at(.rightEar))
            guard let eye = eyes ?? at(.nose) ?? ears else { continue }
            let ls = at(.leftShoulder), rs = at(.rightShoulder)
            let shoulders = mid(ls, rs) ?? at(.neck)
            let all = pts.values.filter { $0.confidence >= 0.3 }.map { CGPoint(x: $0.location.x, y: 1 - $0.location.y) }
            guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(), let maxY = all.map(\.y).max() else { continue }
            let scale = shoulders.map { $0.y - eye.y }.flatMap { $0 > 0.01 ? $0 : nil }
            // Top of the head is about half the eyes-to-shoulders drop above the eyes.
            let top = eye.y - (scale ?? 0.05) * 0.6
            var p = TrackedPerson(box: CGRect(x: minX, y: top, width: max(0.02, maxX - minX), height: max(0.02, maxY - top)),
                                  eye: eye, scale: scale.map { Double($0) })
            p.hipsInShot = at(.root) != nil || at(.leftHip) != nil || at(.rightHip) != nil
            p.anklesInShot = at(.leftAnkle) != nil || at(.rightAnkle) != nil
            // Facing: the nose sits off the line between the shoulders on the side they face.
            if let nose = at(.nose), let l = ls, let r = rs {
                let w = abs(l.x - r.x)
                let off = (nose.x - (l.x + r.x) / 2) / max(w, 0.01)
                if w > 0.02, abs(off) > 0.3 { p.facing = off > 0 ? 1 : -1 }
            } else if at(.leftEar) != nil, at(.rightEar) == nil, let n = at(.nose), let e = at(.leftEar) {
                p.facing = n.x > e.x ? 1 : -1  // profile: only one ear shows
            } else if at(.rightEar) != nil, at(.leftEar) == nil, let n = at(.nose), let e = at(.rightEar) {
                p.facing = n.x > e.x ? 1 : -1
            }
            found.append(p)
        }
        // People too small or turned away for landmarks still show as a body: follow them by
        // their outline (no shot size or zoom from these).
        for r in rects.results ?? [] where r.confidence > 0.3 {
            let b = r.boundingBox
            let box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
            if found.contains(where: { $0.box.intersects(box) && box.contains($0.eye) }) { continue }
            found.append(TrackedPerson(box: box, eye: CGPoint(x: box.midX, y: box.minY + box.height * 0.12)))
        }
        return found
    }

    private func update(_ id: UUID, _ people: [TrackedPerson]) {
        guard var s = sessions[id] else { return }
        let now = Date()
        s.people = people
        s.lastFrame = now

        if s.target == nil {
            // First sight: take the person under the click, or nearest it (the middle by default).
            let p = s.pick ?? CGPoint(x: 0.5, y: 0.5)
            let pick = people.first { $0.box.contains(p) } ?? people.min { dist($0.box.center, p) < dist($1.box.center, p) }
            if let pick {
                s.target = pick
                s.eye = pick.eye
                s.scale = pick.scale
                s.seen = pick.size
                // Frame as asked, or as the shot the volunteer set up is closest to.
                s.size = s.asked ?? pick.size ?? .waist
                s.holdScale = s.size.scale
                s.lastSeen = now
                s.phase = .following
                sessions[id] = s
                finish(id, nil)
                return
            }
            sessions[id] = s
            if now.timeIntervalSince(s.started) > 4 { finish(id, "No one is in the picture.") }
            return
        }

        // Keep hold of the same person: the nearest one to where they were, if close enough.
        let last = s.target!
        let gone = now.timeIntervalSince(s.lastSeen)
        let reach = min(0.5, 0.2 + max(last.box.width, last.box.height) * 0.6 + gone * 0.15)
        let next = people.min { dist($0.box.center, last.box.center) < dist($1.box.center, last.box.center) }
        if let next, dist(next.box.center, last.box.center) < reach {
            s.target = next
            s.lastSeen = now
            s.phase = .following
            let o = s.eye ?? next.eye
            s.eye = CGPoint(x: o.x + (next.eye.x - o.x) * 0.5, y: o.y + (next.eye.y - o.y) * 0.4)
            if let n = next.scale { s.scale = s.scale.map { $0 + (n - $0) * 0.25 } ?? n }
            if let z = next.size { s.seen = z }
            steer(&s, next)
        } else {
            if gone > 0.6 { hold(&s) }
            s.phase = gone > 5 ? .lost : .searching
        }
        sessions[id] = s
    }

    /// Pan, tilt and zoom toward the framing for this shot size.
    private func steer(_ s: inout Session, _ person: TrackedPerson) {
        guard let eye = s.eye else { return }
        let now = Date()

        // After a manual zoom settles, hold whatever size the volunteer chose.
        if let m = s.manualZoomAt {
            if now.timeIntervalSince(m) > 0.8 {
                s.manualZoomAt = nil
                if let sc = s.scale {
                    s.holdScale = sc
                    s.size = ShotSize.classify(scale: sc, anklesInShot: person.anklesInShot, hipsInShot: person.hipsInShot) ?? s.size
                }
            }
        }
        let size = s.size

        // Lead room: walking one way (the camera has been panning that way a while) wins over
        // which way they face. Eased so the frame doesn't jump when they turn.
        let dir = s.panDir != 0 && now.timeIntervalSince(s.panDirSince) > 0.7 ? s.panDir : person.facing
        s.lead += (Double(-dir) * size.leadRoom - s.lead) * 0.06
        let markX = 0.5 + s.lead

        let ex = eye.x - markX                 // right of the mark: pan right
        let ey = size.eyeLine - eye.y          // eyes above the line: tilt up
        // Start moving past the outer line, stop well inside it, so it doesn't hunt.
        if abs(ex) > size.deadX { s.panning = true } else if abs(ex) < size.deadX * 0.35 { s.panning = false }
        let tiltOn = config.trackTilt
        if tiltOn, abs(ey) > size.deadY { s.tilting = true } else if !tiltOn || abs(ey) < size.deadY * 0.4 { s.tilting = false }
        let k = config.trackSpeed
        func speed(_ e: Double, _ on: Bool, _ cap: Double) -> Double {
            guard on else { return 0 }
            let v = min(cap, max(0.07, abs(e) * 1.1)) * k
            return e < 0 ? -v : v
        }
        // Ease in and out: speed up gradually, slow down a bit quicker, so moves don't jerk.
        func ease(_ from: Double, _ to: Double) -> Double {
            let up = 0.045, down = 0.09
            let d = to - from
            let limit = (abs(to) < abs(from) || (to * from) < 0) ? down : up
            let v = from + max(-limit, min(limit, d))
            return (v * 50).rounded() / 50  // in steps, so the camera isn't flooded
        }
        let pan = ease(s.sentPan, speed(ex, s.panning, 0.45))
        let tilt = ease(s.sentTilt, speed(ey, s.tilting, 0.3) * 0.8)

        let d = pan > 0.05 ? 1 : (pan < -0.05 ? -1 : 0)
        if d != s.panDir { s.panDir = d; s.panDirSince = now }

        // Hold the shot size as they come nearer or move away: slow zooms only.
        var zoom = 0.0
        if config.trackZoom, s.manualZoomAt == nil, let hold = s.holdScale, let sc = s.scale, person.scale != nil {
            let r = log(hold / sc)             // positive: they look too small, zoom in
            if abs(r) > 0.18 { s.zooming = true } else if abs(r) < 0.06 { s.zooming = false }
            if s.zooming {
                let v = min(0.3, max(0.05, abs(r) * 0.5)) * min(1.5, k)
                zoom = ((r > 0 ? v : -v) * 50).rounded() / 50
            }
        }
        send(&s, pan, tilt, zoom)
    }

    private func hold(_ s: inout Session) {
        s.panning = false; s.tilting = false; s.zooming = false
        send(&s, 0, 0, 0)
    }

    private func send(_ s: inout Session, _ pan: Double, _ tilt: Double, _ zoom: Double) {
        if pan != s.sentPan || tilt != s.sentTilt {
            s.sentPan = pan; s.sentTilt = tilt
            ptz.trackDrive(pan: pan, tilt: tilt, camera: s.camera)
        }
        if zoom != s.sentZoom {
            s.sentZoom = zoom
            ptz.trackZoom(zoom, camera: s.camera)
        }
    }

    /// Stops a camera whose picture has stopped coming in, so it never drifts on old frames.
    private func tick() {
        let now = Date()
        for (id, var s) in sessions where now.timeIntervalSince(s.lastFrame) > 0.6 && (s.sentPan != 0 || s.sentTilt != 0 || s.sentZoom != 0) {
            hold(&s)
            s.phase = .searching
            sessions[id] = s
        }
        for (id, s) in sessions where s.target == nil && now.timeIntervalSince(s.started) > 4 {
            finish(id, "No one is in the picture, or the picture isn't coming in.")
        }
    }

    private func finish(_ id: UUID, _ why: String?) {
        guard let w = waiters.removeValue(forKey: id) else { return }
        for f in w { f(why) }
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
