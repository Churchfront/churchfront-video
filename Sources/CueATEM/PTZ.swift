import Foundation
import Network
import Combine

// PTZ cameras over VISCA: Sony-style VISCA over IP (UDP 52381; Sony, BirdDog,
// newer PTZOptics, Canon, Panasonic AW in VISCA mode) or raw VISCA over TCP
// (PTZOptics and most budget cameras, port 5678).

public enum VISCAProtocol: String, Codable, CaseIterable, Identifiable {
    case sonyUDP, rawTCP
    public var id: String { rawValue }
    public var label: String { self == .sonyUDP ? "VISCA over IP (UDP)" : "VISCA over TCP" }
    public var defaultPort: UInt16 { self == .sonyUDP ? 52381 : 5678 }
}

public struct PTZCamera: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var name = "Camera"
    public var host = ""
    public var port: UInt16 = 52381
    public var proto: VISCAProtocol = .sonyUDP
    /// The ATEM input this camera feeds, so selecting it on preview picks the camera.
    public var atemInput: Int?
    /// Some cameras count presets from 1 instead of 0.
    public var firstPreset = 0
    /// Names for preset buttons, by preset number (1 based).
    public var presetNames: [Int: String] = [:]
    public init() {}
}

final class VISCALink {
    let camera: PTZCamera
    private let queue: DispatchQueue
    private var conn: NWConnection?
    private var seq: UInt32 = 0
    var onState: ((Bool) -> Void)?
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
}

public final class PTZController: ObservableObject {
    @Published public var cameras: [PTZCamera] = [] { didSet { save(); restart() } }
    @Published public var selected: UUID?
    @Published public private(set) var online: Set<UUID> = []

    private let queue = DispatchQueue(label: "cuevideo.ptz")
    private var links: [UUID: VISCALink] = [:]
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

    private func restart() {
        let cams = cameras
        queue.async {
            for l in self.links.values { l.stop() }
            self.links = [:]
            for c in cams {
                let l = VISCALink(c, queue: self.queue)
                l.onState = { [weak self] on in
                    DispatchQueue.main.async {
                        if on { self?.online.insert(c.id) } else { self?.online.remove(c.id) }
                    }
                }
                self.links[c.id] = l
                l.start()
            }
        }
        if let s = selected, !cameras.contains(where: { $0.id == s }) { selected = cameras.first?.id }
        if selected == nil { selected = cameras.first?.id }
    }

    public var current: PTZCamera? { cameras.first { $0.id == selected } }

    /// Picks the camera wired to this ATEM input, if there is one.
    public func follow(atemInput: Int?) {
        guard let i = atemInput, let c = cameras.first(where: { $0.atemInput == i }), c.id != selected else { return }
        selected = c.id
    }

    private func send(_ bytes: [UInt8], to id: UUID? = nil) {
        guard let id = id ?? selected else { return }
        queue.async { self.links[id]?.send(bytes) }
    }

    /// Pan and tilt from a joystick: x and y from -1 to 1, up is positive y.
    public func drive(x: Double, y: Double) {
        let dead = 0.08
        let px = abs(x) < dead ? 0 : x, py = abs(y) < dead ? 0 : y
        // Squared response gives fine control near the middle.
        let ps = px == 0 ? 0 : max(1, Int((px * px * 24).rounded()))
        let ts = py == 0 ? 0 : max(1, Int((py * py * 20).rounded()))
        let dir = (px == 0 ? 0 : (px < 0 ? -ps : ps), py == 0 ? 0 : (py > 0 ? ts : -ts))
        if let l = lastDrive, l == dir { return }
        lastDrive = dir
        let pan: UInt8 = px == 0 ? 0x03 : (px < 0 ? 0x01 : 0x02)
        let tilt: UInt8 = py == 0 ? 0x03 : (py > 0 ? 0x01 : 0x02)
        send([0x81, 0x01, 0x06, 0x01, UInt8(max(1, min(0x18, ps))), UInt8(max(1, min(0x14, ts))), pan, tilt, 0xFF])
    }

    public func stopDrive() { lastDrive = nil; send([0x81, 0x01, 0x06, 0x01, 0x01, 0x01, 0x03, 0x03, 0xFF]) }

    /// Zoom speed from -1 (wide) to 1 (tele); 0 stops.
    public func zoom(_ v: Double) {
        let p = UInt8(min(7, max(0, Int((abs(v) * 7).rounded()))))
        if abs(v) < 0.05 { send([0x81, 0x01, 0x04, 0x07, 0x00, 0xFF]) }
        else { send([0x81, 0x01, 0x04, 0x07, (v > 0 ? 0x20 : 0x30) | p, 0xFF]) }
    }

    public func autoFocus(_ on: Bool) { send([0x81, 0x01, 0x04, 0x38, on ? 0x02 : 0x03, 0xFF]) }
    public func focusOnce() { send([0x81, 0x01, 0x04, 0x18, 0x01, 0xFF]) }
    public func home() { send([0x81, 0x01, 0x06, 0x04, 0xFF]) }

    /// Presets are numbered from 1 here, whatever the camera counts from.
    public func recall(_ n: Int, camera: UUID? = nil) {
        guard let c = cameras.first(where: { $0.id == (camera ?? selected) }) else { return }
        send([0x81, 0x01, 0x04, 0x3F, 0x02, UInt8(clamping: n - 1 + c.firstPreset), 0xFF], to: c.id)
    }

    public func store(_ n: Int) {
        guard let c = current else { return }
        send([0x81, 0x01, 0x04, 0x3F, 0x01, UInt8(clamping: n - 1 + c.firstPreset), 0xFF], to: c.id)
    }
}
