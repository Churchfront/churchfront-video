import Foundation
import Network
import Combine

// PTZ cameras. Three ways in:
// - Canon (HTTP): Canon's own control protocol on port 80 (CR-N series and
//   other Canon PTZs). Works out of the box and reports the camera's preset names.
// - VISCA over IP (UDP 52381): Sony, BirdDog, newer PTZOptics, Panasonic in VISCA mode,
//   Canon when its VISCA setting is on.
// - VISCA over TCP (5678): PTZOptics and most budget cameras.

public enum VISCAProtocol: String, Codable, CaseIterable, Identifiable {
    case canonXC, sonyUDP, rawTCP
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .canonXC: return "Canon (HTTP)"
        case .sonyUDP: return "VISCA over IP (UDP)"
        case .rawTCP: return "VISCA over TCP"
        }
    }
    public var defaultPort: UInt16 {
        switch self {
        case .canonXC: return 80
        case .sonyUDP: return 52381
        case .rawTCP: return 5678
        }
    }
    /// Canon's HTTP protocol can't save presets without an admin login.
    public var canStorePresets: Bool { self != .canonXC }
}

public struct PTZCamera: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var name = "Camera"
    public var host = ""
    public var port: UInt16 = 52381
    public var proto: VISCAProtocol = .sonyUDP
    /// The ATEM input this camera feeds, so selecting it on preview picks the camera.
    public var atemInput: Int?
    /// Some VISCA cameras count presets from 1 instead of 0.
    public var firstPreset = 0
    /// Names for preset buttons, by preset number (1 based).
    public var presetNames: [Int: String] = [:]
    public init() {}
}

/// One camera connection, whatever the protocol.
protocol PTZLink: AnyObject {
    var onState: ((Bool) -> Void)? { get set }
    /// Preset names the camera reports, by number from 1.
    var onPresets: (([Int: String]) -> Void)? { get set }
    var onModel: ((String) -> Void)? { get set }
    func start()
    func stop()
    /// Speeds from -1 to 1; up is positive tilt. Zero stops that axis.
    func drive(pan: Double, tilt: Double)
    func zoom(_ v: Double)
    func autoFocus(_ on: Bool)
    func focusOnce()
    func home()
    func recall(_ n: Int)
    func store(_ n: Int)
}

// MARK: - VISCA

final class VISCALink: PTZLink {
    let camera: PTZCamera
    private let queue: DispatchQueue
    private var conn: NWConnection?
    private var seq: UInt32 = 0
    var onState: ((Bool) -> Void)?
    var onPresets: (([Int: String]) -> Void)?
    var onModel: ((String) -> Void)?
    private var online = false { didSet { if online != oldValue { onState?(online) } } }

    init(_ camera: PTZCamera, queue: DispatchQueue) {
        self.camera = camera
        self.queue = queue
    }

    func start() {
        guard !camera.host.isEmpty, let port = NWEndpoint.Port(rawValue: camera.port) else { return }
        let c = NWConnection(host: NWEndpoint.Host(camera.host), port: port, using: camera.proto == .sonyUDP ? .udp : .tcp)
        c.stateUpdateHandler = { [weak self, weak c] st in
            guard let self, let c, c === self.conn else { return }
            switch st {
            case .ready:
                if self.camera.proto == .rawTCP { self.online = true }
            case .failed, .waiting:
                self.online = false
                c.cancel()
                self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, c === self.conn else { return }
                    self.start()
                }
            default: break
            }
        }
        conn = c
        c.start(queue: queue)
        receive(c)
        if camera.proto == .sonyUDP {
            seq = 0
            // Reset the camera's sequence number, then ask for power so we know it answers.
            c.send(content: Data([0x02, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0x01]), completion: .contentProcessed { _ in })
            send([0x81, 0x09, 0x04, 0x00, 0xFF], inquiry: true)
        }
    }

    func stop() { conn?.cancel(); conn = nil; online = false }

    private func receive(_ c: NWConnection) {
        let handler: (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void = { [weak self] data, _, _, err in
            guard let self, c === self.conn else { return }
            if let data, !data.isEmpty { self.online = true }
            if err == nil { self.receive(c) }
        }
        if camera.proto == .sonyUDP { c.receiveMessage(completion: handler) }
        else { c.receive(minimumIncompleteLength: 1, maximumLength: 4096, completion: handler) }
    }

    func send(_ visca: [UInt8], inquiry: Bool = false) {
        guard let conn else { return }
        if camera.proto == .rawTCP {
            conn.send(content: Data(visca), completion: .contentProcessed { _ in })
            return
        }
        seq &+= 1
        let n = UInt16(visca.count)
        let header: [UInt8] = [0x01, inquiry ? 0x10 : 0x00, UInt8(n >> 8), UInt8(n & 0xFF),
                               UInt8(seq >> 24), UInt8((seq >> 16) & 0xFF), UInt8((seq >> 8) & 0xFF), UInt8(seq & 0xFF)]
        conn.send(content: Data(header + visca), completion: .contentProcessed { _ in })
    }

    func drive(pan: Double, tilt: Double) {
        let ps = pan == 0 ? 1 : max(1, min(0x18, Int((pan * pan * 24).rounded())))
        let ts = tilt == 0 ? 1 : max(1, min(0x14, Int((tilt * tilt * 20).rounded())))
        let p: UInt8 = pan == 0 ? 0x03 : (pan < 0 ? 0x01 : 0x02)
        let t: UInt8 = tilt == 0 ? 0x03 : (tilt > 0 ? 0x01 : 0x02)
        send([0x81, 0x01, 0x06, 0x01, UInt8(ps), UInt8(ts), p, t, 0xFF])
    }

    func zoom(_ v: Double) {
        let p = UInt8(min(7, max(0, Int((abs(v) * 7).rounded()))))
        if v == 0 { send([0x81, 0x01, 0x04, 0x07, 0x00, 0xFF]) }
        else { send([0x81, 0x01, 0x04, 0x07, (v > 0 ? 0x20 : 0x30) | p, 0xFF]) }
    }

    func autoFocus(_ on: Bool) { send([0x81, 0x01, 0x04, 0x38, on ? 0x02 : 0x03, 0xFF]) }
    func focusOnce() { send([0x81, 0x01, 0x04, 0x18, 0x01, 0xFF]) }
    func home() { send([0x81, 0x01, 0x06, 0x04, 0xFF]) }
    func recall(_ n: Int) { send([0x81, 0x01, 0x04, 0x3F, 0x02, UInt8(clamping: n - 1 + camera.firstPreset), 0xFF]) }
    func store(_ n: Int) { send([0x81, 0x01, 0x04, 0x3F, 0x01, UInt8(clamping: n - 1 + camera.firstPreset), 0xFF]) }
}

// MARK: - Canon (HTTP)

/// Canon's control protocol: open a session, claim control, then control.cgi
/// with pan=left|right|stop, tilt=up|down|stop, zoom=tele|wide|stop, p=<preset>.
final class CanonLink: PTZLink {
    let camera: PTZCamera
    private let queue: DispatchQueue
    private let http: URLSession
    private var session: String?
    private var opening = false
    private var stopped = false
    private var timer: DispatchSourceTimer?
    private var lastPresetRead = Date.distantPast
    var onState: ((Bool) -> Void)?
    var onPresets: (([Int: String]) -> Void)?
    var onModel: ((String) -> Void)?
    private var online = false { didSet { if online != oldValue { onState?(online) } } }

    init(_ camera: PTZCamera, queue: DispatchQueue) {
        self.camera = camera
        self.queue = queue
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.httpMaximumConnectionsPerHost = 2
        http = URLSession(configuration: cfg)
    }

    private var base: String { "http://\(camera.host)\(camera.port == 80 ? "" : ":\(camera.port)")/-wvhttp-01-/" }

    /// Canon replies with "key:=value" lines ("key==value" while a value is changing).
    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let l = String(line)
            if let r = l.range(of: ":=") ?? l.range(of: "==") { out[String(l[..<r.lowerBound])] = String(l[r.upperBound...]) }
        }
        return out
    }

    private func get(_ path: String, _ done: ((String?) -> Void)? = nil) {
        guard let url = URL(string: base + path) else { done?(nil); return }
        http.dataTask(with: url) { [weak self] data, resp, err in
            guard let self else { return }
            let text = data.map { String(decoding: $0, as: UTF8.self) }
            let ok = err == nil && (resp as? HTTPURLResponse)?.statusCode == 200
            self.queue.async {
                if !ok, text?.contains("Error") != false {
                    done?(nil)
                } else {
                    done?(text)
                }
            }
        }.resume()
    }

    func start() {
        stopped = false
        guard !camera.host.isEmpty else { return }
        open()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 10, repeating: 10)
        t.setEventHandler { [weak self] in self?.keepAlive() }
        t.resume()
        timer = t
    }

    func stop() {
        stopped = true
        timer?.cancel(); timer = nil
        if let s = session { get("close.cgi?s=\(s)") }
        session = nil
        online = false
    }

    private func open() {
        guard !opening, !stopped else { return }
        opening = true
        get("open.cgi") { [weak self] text in
            guard let self else { return }
            self.opening = false
            guard let text, let s = Self.parse(text)["s"] else {
                self.online = false
                self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.open() }
                return
            }
            self.session = s
            self.get("claim.cgi?s=\(s)") { [weak self] _ in
                self?.online = true
                self?.readInfo()
            }
        }
    }

    private func keepAlive() {
        guard let s = session else { open(); return }
        get("claim.cgi?s=\(s)") { [weak self] text in
            guard let self else { return }
            if text == nil { self.session = nil; self.online = false; self.open() }
        }
        if Date().timeIntervalSince(lastPresetRead) > 60 { readInfo() }
    }

    private func readInfo() {
        lastPresetRead = Date()
        get("info.cgi") { [weak self] text in
            guard let self, let text else { return }
            let kv = Self.parse(text)
            if let model = kv["s.hardware"] { self.onModel?(model) }
            var names: [Int: String] = [:]
            for (k, v) in kv where k.hasPrefix("p.") && k.hasSuffix(".name.utf8") && !v.isEmpty {
                if let n = Int(k.dropFirst(2).dropLast(10)) { names[n] = v }
            }
            self.onPresets?(names)
        }
    }

    private func control(_ query: String) {
        guard let s = session else { open(); return }
        get("control.cgi?s=\(s)&\(query)") { [weak self] text in
            guard let self, text == nil else { return }
            // The session timed out or was taken over; open a new one.
            self.session = nil
            self.open()
        }
    }

    // Canon speeds run 10 to 10000 for pan and tilt (very fast at the top), 0 to 127 for zoom.
    private func speed(_ v: Double) -> Int { Int(10 + v * v * 3000) }

    func drive(pan: Double, tilt: Double) {
        let p = pan == 0 ? "pan=stop" : "pan=\(pan < 0 ? "left" : "right")&pan.speed=\(speed(pan))"
        let t = tilt == 0 ? "tilt=stop" : "tilt=\(tilt > 0 ? "up" : "down")&tilt.speed=\(speed(tilt))"
        control(p + "&" + t)
    }

    func zoom(_ v: Double) {
        control(v == 0 ? "zoom=stop" : "zoom=\(v > 0 ? "tele" : "wide")&zoom.speed=\(Int(1 + abs(v) * 60))")
    }

    func autoFocus(_ on: Bool) { control("focus=\(on ? "auto" : "manual")") }
    func focusOnce() { control("focus.action=one_shot") }
    func home() { control("pan=0&tilt=0") }
    func recall(_ n: Int) { control("p=\(n)") }
    func store(_ n: Int) {}
}

// MARK: - Controller

public final class PTZController: ObservableObject {
    @Published public var cameras: [PTZCamera] = [] { didSet { save(); if links(differ: oldValue) { restart() } } }
    @Published public var selected: UUID?
    @Published public private(set) var online: Set<UUID> = []
    /// Preset names the cameras report themselves (Canon), by camera.
    @Published public private(set) var reportedPresets: [UUID: [Int: String]] = [:]
    @Published public private(set) var models: [UUID: String] = [:]

    private let queue = DispatchQueue(label: "cuevideo.ptz")
    private var links: [UUID: PTZLink] = [:]
    private var lastDrive: (Int, Int)?
    private let key = "ptzCameras"

    public init(load: Bool = true) {
        if load, let d = UserDefaults.standard.data(forKey: key), let c = try? JSONDecoder().decode([PTZCamera].self, from: d) {
            cameras = c
        }
        selected = cameras.first?.id
        restart()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(cameras) { UserDefaults.standard.set(d, forKey: key) }
    }

    /// Only reconnect when an address or protocol changed, not when a name did.
    private func links(differ old: [PTZCamera]) -> Bool {
        old.map { "\($0.id)\($0.host)\($0.port)\($0.proto)\($0.firstPreset)" } != cameras.map { "\($0.id)\($0.host)\($0.port)\($0.proto)\($0.firstPreset)" }
    }

    private func restart() {
        let cams = cameras
        queue.async {
            for l in self.links.values { l.stop() }
            self.links = [:]
            for c in cams {
                let l: PTZLink = c.proto == .canonXC ? CanonLink(c, queue: self.queue) : VISCALink(c, queue: self.queue)
                l.onState = { [weak self] on in
                    DispatchQueue.main.async { if on { self?.online.insert(c.id) } else { self?.online.remove(c.id) } }
                }
                l.onPresets = { [weak self] names in DispatchQueue.main.async { self?.reportedPresets[c.id] = names } }
                l.onModel = { [weak self] m in DispatchQueue.main.async { self?.models[c.id] = m } }
                self.links[c.id] = l
                l.start()
            }
        }
        if let s = selected, !cameras.contains(where: { $0.id == s }) { selected = cameras.first?.id }
        if selected == nil { selected = cameras.first?.id }
    }

    public var current: PTZCamera? { cameras.first { $0.id == selected } }

    /// Preset names for a camera: what you typed wins, then what the camera reports.
    public func presetNames(_ c: PTZCamera) -> [Int: String] {
        (reportedPresets[c.id] ?? [:]).merging(c.presetNames) { _, mine in mine }
    }

    /// Picks the camera wired to this ATEM input, if there is one.
    public func follow(atemInput: Int?) {
        guard let i = atemInput, let c = cameras.first(where: { $0.atemInput == i }), c.id != selected else { return }
        selected = c.id
    }

    private func with(_ id: UUID? = nil, _ f: @escaping (PTZLink) -> Void) {
        guard let id = id ?? selected else { return }
        queue.async { if let l = self.links[id] { f(l) } }
    }

    /// Pan and tilt from a joystick: x and y from -1 to 1, up is positive y.
    public func drive(x: Double, y: Double) {
        let dead = 0.08
        let px = abs(x) < dead ? 0 : max(-1, min(1, x)), py = abs(y) < dead ? 0 : max(-1, min(1, y))
        // Only send when the direction or speed step changes, so a drag doesn't flood the camera.
        let step = (Int((px * 12).rounded()), Int((py * 12).rounded()))
        if let l = lastDrive, l == step { return }
        lastDrive = step
        with { $0.drive(pan: px, tilt: py) }
    }

    public func stopDrive() { lastDrive = nil; with { $0.drive(pan: 0, tilt: 0) } }

    /// Zoom speed from -1 (wide) to 1 (tele); 0 stops.
    public func zoom(_ v: Double) { let z = abs(v) < 0.05 ? 0 : v; with { $0.zoom(z) } }
    public func autoFocus(_ on: Bool) { with { $0.autoFocus(on) } }
    public func focusOnce() { with { $0.focusOnce() } }
    public func home() { with { $0.home() } }

    /// Presets are numbered from 1 here, whatever the camera counts from.
    public func recall(_ n: Int, camera: UUID? = nil) { with(camera) { $0.recall(n) } }
    public func store(_ n: Int) { with { $0.store(n) } }
}
