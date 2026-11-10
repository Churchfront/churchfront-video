import Foundation
import Combine
import CueATEM

/// One tile in the volunteer's source row: an ATEM input, with an optional friendlier name.
struct VolunteerSource: Codable, Hashable, Identifiable {
    var input: Int
    var label: String?
    var id: Int { input }
}

/// A volunteer button that puts a key on or off air: an upstream key (`me` and `keyer`,
/// both counted from 1) or a downstream key (`dsk`, from 1). Upstream keys cut on and off;
/// DSKs fade with their own rate.
struct KeyButton: Codable, Hashable, Identifiable {
    var label: String
    var me: Int?
    var keyer: Int?
    var dsk: Int?
    var id: String { "\(label)|\(me ?? 0)|\(keyer ?? 0)|\(dsk ?? 0)" }

    func isOn(_ s: ATEMState) -> Bool {
        if let dsk { return s.dskOnAir[dsk - 1] ?? false }
        guard let keyer else { return false }
        return s.keyOnAir[(me ?? 1) - 1]?[keyer - 1] ?? false
    }

    func toggle(_ atem: ATEMClient) {
        if let dsk { atem.dskAuto(dsk - 1); return }
        guard let keyer else { return }
        atem.setKeyOnAir(keyer - 1, !isOn(atem.state), me: (me ?? 1) - 1)
    }

    /// "M/E 1 Key 1" or "DSK 2".
    var target: String { dsk.map { "DSK \($0)" } ?? "M/E \(me ?? 1) Key \(keyer ?? 0)" }
}

/// How CueVideo is set up, kept as plain JSON so a person or Claude can read and edit it:
/// ~/Library/Application Support/CueVideo/config.json. Every field is optional when
/// written by hand.
///
///     {
///       "atemHost": "192.168.20.31",
///       "me": 1,
///       "sources": [ { "input": 9, "label": "Cam 1" }, { "input": 3 } ],
///       "cameras": [ { "name": "Cam 1", "host": "192.168.20.91", "proto": "canonXC", "atemInput": 9 } ],
///       "keys": [ { "label": "Lower thirds", "me": 1, "keyer": 1 } ]
///     }
///
/// `proto` is canonXC (Canon HTTP), sonyUDP (VISCA over IP, UDP 52381) or rawTCP (VISCA over TCP 5678).
struct CueConfig: Codable, Equatable {
    var atemHost = ""
    /// The M/E the volunteer runs, counted from 1 as on the switcher.
    var me = 1
    /// The volunteer's source row, left to right. Inputs not listed stay out of their way.
    var sources: [VolunteerSource] = []
    var cameras: [PTZCamera] = []
    /// On/off buttons for keys, such as lower thirds, under the take buttons.
    var keys: [KeyButton] = []

    init() {}

    private enum Keys: String, CodingKey { case atemHost, me, sources, cameras, keys }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        atemHost = try c.decodeIfPresent(String.self, forKey: .atemHost) ?? ""
        me = try c.decodeIfPresent(Int.self, forKey: .me) ?? 1
        sources = try c.decodeIfPresent([VolunteerSource].self, forKey: .sources) ?? []
        cameras = try c.decodeIfPresent([PTZCamera].self, forKey: .cameras) ?? []
        keys = try c.decodeIfPresent([KeyButton].self, forKey: .keys) ?? []
    }
}

/// Keeps the config file and the running app in step: edits to the file are picked up
/// within a second, and changes made in the app are written back to the file.
final class ConfigStore: ObservableObject {
    @Published private(set) var config = CueConfig()
    /// Why the file couldn't be read, if it couldn't. The app keeps running on the last good setup.
    @Published private(set) var fileError: String?
    @Published private(set) var loadedAt: Date?

    let url: URL
    /// Self-tests (any CUEVIDEO_ environment setting) bring their own switcher and
    /// cameras; they must never be written over the real setup.
    let readOnly: Bool
    private var lastModified: Date?
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    private weak var booth: Booth?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = support.appendingPathComponent("CueVideo", isDirectory: true).appendingPathComponent("config.json")
        readOnly = ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("CUEVIDEO_") }
    }

    func attach(_ booth: Booth) {
        self.booth = booth
        if let c = read() {
            config = c
        } else if fileError == nil {
            config = migrated(booth)
            write()
        }
        apply()
        // Cameras edited in the app go back to the file.
        booth.ptz.$cameras.dropFirst().receive(on: RunLoop.main).sink { [weak self] cams in
            self?.update { $0.cameras = cams }
        }.store(in: &bag)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    }

    /// Change the setup from the app. Writes the file and applies what changed.
    func update(_ change: (inout CueConfig) -> Void) {
        var c = config
        change(&c)
        guard c != config else { return }
        config = c
        write()
        apply()
    }

    /// Sources for the volunteer's row: the configured ones, or every camera input until it's set up.
    func volunteerSources(_ state: ATEMState) -> [VolunteerSource] {
        if !config.sources.isEmpty { return config.sources }
        return config.cameras.compactMap(\.atemInput).map { VolunteerSource(input: $0) }
    }

    func label(_ input: Int?, _ state: ATEMState) -> String {
        guard let input else { return "Nothing" }
        if let l = config.sources.first(where: { $0.input == input })?.label, !l.isEmpty { return l }
        if let cam = config.cameras.first(where: { $0.atemInput == input }), !cam.name.isEmpty { return cam.name }
        return state.inputs[input]?.long ?? "Input \(input)"
    }

    // MARK: Private

    private func apply() {
        guard let b = booth else { return }
        let me = max(0, config.me - 1)
        if b.me != me { b.me = me }
        guard !readOnly else { return }
        if b.atem.host != config.atemHost { b.atem.connect(config.atemHost) }
        if b.ptz.cameras != config.cameras { b.ptz.cameras = config.cameras }
    }

    private func poll() {
        let mod = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard mod != lastModified else { return }
        if let c = read(), c != config {
            config = c
            apply()
        }
    }

    private func read() -> CueConfig? {
        lastModified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let c = try JSONDecoder().decode(CueConfig.self, from: data)
            fileError = nil
            loadedAt = Date()
            return c
        } catch {
            fileError = Self.explain(error)
            return nil
        }
    }

    private func write() {
        guard !readOnly else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(config) else { return }
        if let old = try? Data(contentsOf: url), old == data { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: .atomic)
            lastModified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            fileError = nil
        } catch {
            fileError = "Couldn't save the setup: \(error.localizedDescription)"
        }
    }

    /// First run with a config file: carry over what earlier versions kept in the app's preferences.
    private func migrated(_ b: Booth) -> CueConfig {
        var c = CueConfig()
        c.atemHost = UserDefaults.standard.string(forKey: "atemHost") ?? ""
        c.me = b.me + 1
        c.cameras = b.ptz.cameras
        return c
    }

    private static func explain(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return error.localizedDescription }
        func path(_ p: [CodingKey]) -> String { p.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined() }
        switch e {
        case .dataCorrupted(let ctx): return "Not valid JSON: \(ctx.underlyingError?.localizedDescription ?? ctx.debugDescription)"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx): return "Wrong value at \(path(ctx.codingPath)): \(ctx.debugDescription)"
        case .keyNotFound(let k, let ctx): return "Missing \(k.stringValue) at \(path(ctx.codingPath))"
        @unknown default: return error.localizedDescription
        }
    }
}
