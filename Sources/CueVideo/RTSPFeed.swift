import Foundation
import Network
import CoreMedia
import CoreVideo
import VideoToolbox
import CryptoKit
import Combine

// Live pictures from cameras over RTSP (PTZOptics, OBSBOT and most IP cameras), with no
// license and nothing to install. Churchfront Video speaks RTSP itself, asks for the video
// over the same TCP connection (no lost packets, nothing for firewalls to block), unpacks the
// H.264 or H.265 from RTP and hands each picture straight to the Mac's hardware decoder
// (VideoToolbox). There is no buffering anywhere: a picture is decoded the moment its last
// packet arrives and shown at the next screen refresh.
//
// Each stream runs on its own queue, apart from the main thread, the switcher and the camera
// controls, so a slow or broken stream can never hold up a Cut or a joystick move.

/// What an RTSP picture is doing, for its tile, Status and Claude.
enum RTSPStatus: Equatable {
    case connecting
    case live(width: Int, height: Int, fps: Int)
    /// Down, with the last error. It keeps retrying.
    case offline(String)

    var isLive: Bool { if case .live = self { return true }; return false }

    /// "640×360 · 30 fps"
    var liveText: String? {
        guard case .live(let w, let h, let fps) = self else { return nil }
        return fps > 0 ? "\(w)×\(h) · \(fps) fps" : "\(w)×\(h)"
    }

    var text: String {
        switch self {
        case .connecting: return "Connecting"
        case .live: return "Live, " + (liveText ?? "")
        case .offline(let why): return "Offline: \(why)"
        }
    }
}

/// One RTSP stream: keeps it open while anything shows it, reconnecting on its own after a
/// dropped cable or a camera reboot (after 2 seconds, then longer, up to 10).
final class RTSPFeed: ObservableObject, @unchecked Sendable {
    @Published private(set) var status: RTSPStatus = .connecting
    /// The picture's pixel size, once one has been decoded.
    @Published private(set) var size: CGSize?
    /// The codec and decoder in use, for Status: "H.264, hardware decode".
    @Published private(set) var detail = ""

    let url: String
    var live: Bool { status.isLive }

    private let queue: DispatchQueue
    private let frameLock = NSLock()
    private var latestFrame: CVPixelBuffer?
    private var frameNumber: UInt64 = 0
    private var decodeTime = 0.0

    // Only touched on `queue`.
    private var running = false
    private var session: RTSPSession?
    private var backoff = 2.0
    private var retry: DispatchWorkItem?
    private var fpsCount = 0
    private var fpsSince = Date()
    private var shownFPS = 0
    private var shownSize = (0, 0)  // (0, 0) until this connection's first picture

    init(url: String) {
        self.url = url
        queue = DispatchQueue(label: "cuevideo.rtsp", qos: .userInitiated)
    }

    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.backoff = 2
            self.publish(.connecting)
            self.open()
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.retry?.cancel(); self.retry = nil
            self.session?.close(teardown: true); self.session = nil
            self.frameLock.lock(); self.latestFrame = nil; self.frameLock.unlock()
            self.shownFPS = 0; self.shownSize = (0, 0)
            self.publish(.connecting)
        }
    }

    /// The newest decoded picture, if it is newer than `after` (a number from an earlier call).
    func latest(after: UInt64) -> (CVPixelBuffer, UInt64)? {
        frameLock.lock(); defer { frameLock.unlock() }
        guard let f = latestFrame, frameNumber != after else { return nil }
        return (f, frameNumber)
    }

    /// How long the last pictures took from their last packet to a decoded picture, in
    /// milliseconds (a running average), and how many have been decoded.
    var decodeStats: (ms: Double, frames: UInt64) {
        frameLock.lock(); defer { frameLock.unlock() }
        return (decodeTime * 1000, frameNumber)
    }

    /// The newest picture as a CGImage, for auto tracking and snapshots. Nil unless live.
    var liveImage: CGImage? {
        guard live, let (pb, _) = latest(after: .max) else { return nil }
        return Self.image(pb)
    }

    /// New pictures as CGImages, about 15 a second, on the main thread: what auto tracking watches.
    var images: AnyPublisher<CGImage, Never> {
        var last: UInt64 = 0
        return Timer.publish(every: 1.0 / 15, on: .main, in: .common).autoconnect()
            .compactMap { [weak self] _ -> CGImage? in
                guard let self, self.live, let (pb, n) = self.latest(after: last) else { return nil }
                last = n
                return Self.image(pb)
            }
            .eraseToAnyPublisher()
    }

    static func image(_ pb: CVPixelBuffer) -> CGImage? {
        var img: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &img)
        return img
    }

    // MARK: On `queue`

    private func open() {
        guard running else { return }
        let s = RTSPSession(url: url, queue: queue)
        s.onFrame = { [weak self, weak s] pb, took in
            guard let self, let s, s === self.session else { return }
            self.frame(pb, took)
        }
        s.onReady = { [weak self, weak s] detail in
            guard let self, let s, s === self.session else { return }
            DispatchQueue.main.async { if self.detail != detail { self.detail = detail } }
        }
        s.onFail = { [weak self, weak s] why in
            guard let self, let s, s === self.session else { return }
            self.failed(why)
        }
        session = s
        fpsCount = 0; fpsSince = Date()
        s.start()
    }

    private func failed(_ why: String) {
        session?.close(teardown: false)
        session = nil
        shownFPS = 0; shownSize = (0, 0)
        publish(.offline(why))
        guard running else { return }
        let wait = backoff
        backoff = min(10, backoff * 1.5)
        let w = DispatchWorkItem { [weak self] in self?.open() }
        retry = w
        queue.asyncAfter(deadline: .now() + wait, execute: w)
    }

    private func frame(_ pb: CVPixelBuffer, _ took: TimeInterval) {
        frameLock.lock()
        latestFrame = pb; frameNumber &+= 1
        decodeTime = decodeTime == 0 ? took : decodeTime * 0.95 + took * 0.05
        frameLock.unlock()
        backoff = 2
        fpsCount += 1
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let now = Date(), elapsed = now.timeIntervalSince(fpsSince)
        // Status is redrawn about once a second, not every frame.
        if elapsed >= 1 {
            shownFPS = Int((Double(fpsCount) / elapsed).rounded())
            fpsCount = 0; fpsSince = now
        } else if (w, h) == shownSize {
            return
        }
        shownSize = (w, h)
        publish(.live(width: w, height: h, fps: shownFPS), size: CGSize(width: w, height: h))
    }

    private func publish(_ s: RTSPStatus, size: CGSize? = nil) {
        DispatchQueue.main.async {
            if self.status != s { self.status = s }
            if let size, self.size != size { self.size = size }
        }
    }
}

/// One RTSP stream per address, shared by everything showing it, running only while shown.
final class RTSPFeedHub {
    static let shared = RTSPFeedHub()
    private var feeds: [String: RTSPFeed] = [:]
    private var users: [String: Int] = [:]

    func feed(_ url: String) -> RTSPFeed {
        if let f = feeds[url] { return f }
        let f = RTSPFeed(url: url)
        feeds[url] = f
        return f
    }

    func retain(_ url: String) {
        users[url, default: 0] += 1
        if users[url] == 1 { feed(url).start() }
    }

    func release(_ url: String) {
        guard let n = users[url] else { return }
        if n <= 1 { users[url] = nil; feeds[url]?.stop() } else { users[url] = n - 1 }
    }

    /// For Status and Claude: the stream's state, or nil when nothing is showing it.
    func status(_ url: String) -> RTSPStatus? { users[url] == nil ? nil : feeds[url]?.status }
    func detail(_ url: String) -> String { feeds[url]?.detail ?? "" }
}

// MARK: - The RTSP conversation

/// One connection to a camera, from the first request to the end. When anything goes wrong
/// it reports once through `onFail` and goes quiet; RTSPFeed then starts a new one.
/// Everything here runs on the feed's queue.
final class RTSPSession {
    var onFrame: ((CVPixelBuffer, TimeInterval) -> Void)?
    var onReady: ((String) -> Void)?
    var onFail: ((String) -> Void)?

    private let queue: DispatchQueue
    private let target: RTSPTarget?
    private var conn: NWConnection?
    private var closed = false

    private var inbox = [UInt8]()
    private var readAt = 0

    private enum Step { case options, describe, setup, play, playing }
    private var step = Step.options
    private var cseq = 0
    private var pending: (method: String, uri: String, extra: String)?
    private var triedAuth = false
    private var auth: RTSPAuth?
    private var serverMethods: Set<String> = []
    private var sessionID: String?
    private var keepAliveEvery = 25.0
    private var track: SDPVideoTrack?
    private var videoChannel: UInt8 = 0

    private var depacketizer: RTPDepacketizer?
    private var decoder: VideoDecoder?

    private var timer: DispatchSourceTimer?
    private var startedAt = Date()
    private var lastPacket = Date()
    private var lastKeepAlive = Date()
    private var playingSince: Date?
    private var gotPicture = false

    init(url: String, queue: DispatchQueue) {
        self.queue = queue
        target = RTSPTarget(url)
    }

    func start() {
        guard let target else { fail("That isn't an RTSP address (rtsp://camera-ip:554/1)"); return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        let c = NWConnection(host: NWEndpoint.Host(target.host), port: NWEndpoint.Port(rawValue: target.port) ?? 554,
                             using: NWParameters(tls: nil, tcp: tcp))
        conn = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                self.receive()
                self.request("OPTIONS", target.uri)
            case .waiting(let e), .failed(let e):
                self.fail(Self.explain(e, target))
            default: break
            }
        }
        c.start(queue: queue)
        startedAt = Date()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Ends the connection. With `teardown`, politely tells the camera first, so it frees
    /// the stream for other viewers straight away.
    func close(teardown: Bool) {
        guard !closed else { return }
        closed = true
        timer?.cancel(); timer = nil
        decoder?.invalidate(); decoder = nil
        guard let conn else { return }
        if teardown, step == .playing, let target {
            let msg = message("TEARDOWN", target.uri, "")
            conn.send(content: Data(msg.utf8), completion: .contentProcessed { _ in conn.cancel() })
            queue.asyncAfter(deadline: .now() + 1) { conn.cancel() }
        } else {
            conn.cancel()
        }
        self.conn = nil
    }

    private func fail(_ why: String) {
        guard !closed else { return }
        let report = onFail
        close(teardown: false)
        report?(why)
    }

    private func tick() {
        guard !closed else { return }
        let now = Date()
        if step != .playing {
            if now.timeIntervalSince(startedAt) > 6 { fail(step == .options ? "No answer from the camera" : "The camera stopped answering while starting the stream") }
            return
        }
        if now.timeIntervalSince(lastPacket) > 5 { fail("No video for 5 seconds"); return }
        if !gotPicture, let since = playingSince, now.timeIntervalSince(since) > 10 {
            fail(decoder == nil ? "Video arrived but couldn't be read (\(track?.codec.label ?? "unknown codec"))" : "Video arrived but no picture could be decoded")
            return
        }
        if now.timeIntervalSince(lastKeepAlive) > keepAliveEvery, let target {
            lastKeepAlive = now
            // Keeps the camera from closing the session. The reply is ignored.
            send(message(serverMethods.contains("GET_PARAMETER") ? "GET_PARAMETER" : "OPTIONS", target.uri, ""))
        }
    }

    // MARK: Requests and replies

    private func message(_ method: String, _ uri: String, _ extra: String) -> String {
        cseq += 1
        var m = "\(method) \(uri) RTSP/1.0\r\nCSeq: \(cseq)\r\nUser-Agent: Churchfront Video\r\n"
        if let sessionID, method != "OPTIONS" || step == .playing { m += "Session: \(sessionID)\r\n" }
        if let auth, let target, let h = auth.header(method: method, uri: uri, target: target) { m += "Authorization: \(h)\r\n" }
        return m + extra + "\r\n"
    }

    private func request(_ method: String, _ uri: String, _ extra: String = "") {
        pending = (method, uri, extra)
        send(message(method, uri, extra))
    }

    private func send(_ text: String) {
        conn?.send(content: Data(text.utf8), completion: .contentProcessed { [weak self] e in
            guard let self, let e else { return }
            self.queue.async { self.fail("Couldn't send to the camera: \(e.localizedDescription)") }
        })
    }

    private func receive() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.inbox.append(contentsOf: data)
                self.process()
            }
            if self.closed { return }
            if let error { self.fail(Self.explain(error, self.target)); return }
            if done { self.fail("The camera closed the connection"); return }
            self.receive()
        }
    }

    /// Takes whole messages off the front of what's arrived: "$" packets of video, or RTSP replies.
    private func process() {
        while !closed, readAt < inbox.count {
            let avail = inbox.count - readAt
            if inbox[readAt] == 0x24 {  // "$", channel, 2-byte length, packet
                guard avail >= 4 else { break }
                let channel = inbox[readAt + 1]
                let len = Int(inbox[readAt + 2]) << 8 | Int(inbox[readAt + 3])
                guard avail >= 4 + len else { break }
                if channel == videoChannel, len > 0 {
                    lastPacket = Date()
                    inbox.withUnsafeBufferPointer { b in
                        rtp(UnsafeBufferPointer(rebasing: b[(readAt + 4)..<(readAt + 4 + len)]))
                    }
                }
                readAt += 4 + len
            } else if avail >= 4, inbox[readAt] == 0x52, inbox[readAt + 1] == 0x54, inbox[readAt + 2] == 0x53, inbox[readAt + 3] == 0x50 {  // "RTSP"
                guard let headEnd = find([13, 10, 13, 10], from: readAt) else {
                    if avail > 16 << 10 { fail("The camera sent a reply that couldn't be read"); return }
                    break
                }
                let head = String(decoding: inbox[readAt..<headEnd], as: UTF8.self)
                let reply = RTSPReply(head)
                let bodyStart = headEnd + 4
                guard inbox.count - bodyStart >= reply.contentLength else { break }
                let body = String(decoding: inbox[bodyStart..<(bodyStart + reply.contentLength)], as: UTF8.self)
                readAt = bodyStart + reply.contentLength
                handle(reply, body)
            } else if avail < 4 {
                break
            } else {
                // Not the start of anything: skip ahead to the next "$" or "RTSP".
                var i = readAt + 1
                while i < inbox.count, inbox[i] != 0x24, inbox[i] != 0x52 { i += 1 }
                readAt = i
            }
        }
        // Drop what's been read, now and then rather than after every packet.
        if readAt > 0, readAt == inbox.count { inbox.removeAll(keepingCapacity: true); readAt = 0 }
        else if readAt > 1 << 16 { inbox.removeFirst(readAt); readAt = 0 }
    }

    private func find(_ needle: [UInt8], from: Int) -> Int? {
        guard inbox.count - from >= needle.count else { return nil }
        var i = from
        while i <= inbox.count - needle.count {
            if inbox[i] == needle[0], inbox[i + 1] == needle[1], inbox[i + 2] == needle[2], inbox[i + 3] == needle[3] { return i }
            i += 1
        }
        return nil
    }

    private func handle(_ reply: RTSPReply, _ body: String) {
        guard let target else { return }
        if step == .playing { return }  // keep-alive replies
        if reply.code == 401, !triedAuth, let pending {
            triedAuth = true
            guard target.user != nil else { fail("The camera wants a username and password. Add them to the address: rtsp://user:password@\(target.host)/…"); return }
            guard let a = RTSPAuth(reply.header("www-authenticate"), user: target.user ?? "", password: target.password ?? "") else {
                fail("The camera asked for a login this app can't send"); return
            }
            auth = a
            request(pending.method, pending.uri, pending.extra)
            return
        }
        if reply.code == 401 { fail("The camera refused the username or password"); return }
        // Some cameras don't do OPTIONS; that's fine, carry on.
        if step == .options, reply.code != 200 { step = .describe; describe(); return }
        guard reply.code == 200 else {
            fail(reply.code == 404 ? "No stream at \(target.uri) (check the path, such as /1 or /2)" : "The camera said \(reply.code) \(reply.reason)")
            return
        }
        triedAuth = false
        switch step {
        case .options:
            serverMethods = Set(reply.header("public").uppercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            step = .describe
            describe()
        case .describe:
            let base = reply.header("content-base").nonEmpty ?? reply.header("content-location").nonEmpty ?? target.uri
            guard let t = SDPVideoTrack.parse(body, base: base) else {
                fail("The camera's stream has no H.264 or H.265 video"); return
            }
            track = t
            step = .setup
            request("SETUP", t.control, "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n")
        case .setup:
            guard let s = reply.header("session").nonEmpty else { fail("The camera didn't start a session"); return }
            let parts = s.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            sessionID = parts.first
            if let t = parts.first(where: { $0.lowercased().hasPrefix("timeout=") }), let secs = Double(t.split(separator: "=").last ?? "") {
                keepAliveEvery = max(5, secs / 2)
            }
            if let range = reply.header("transport").lowercased().components(separatedBy: "interleaved=").dropFirst().first,
               let ch = UInt8(range.prefix { $0.isNumber }) {
                videoChannel = ch
            }
            step = .play
            request("PLAY", target.uri, "Range: npt=0.000-\r\n")
        case .play:
            step = .playing
            playingSince = Date()
            lastPacket = Date()
            lastKeepAlive = Date()
            guard let track else { return }
            depacketizer = RTPDepacketizer(codec: track.codec, payloadType: track.payloadType)
            decoder = VideoDecoder(codec: track.codec, parameterSets: track.parameterSets)
            onReady?(track.codec.label)
        case .playing:
            break
        }
    }

    private func describe() {
        guard let target else { return }
        request("DESCRIBE", target.uri, "Accept: application/sdp\r\n")
    }

    // MARK: Video

    private func rtp(_ packet: UnsafeBufferPointer<UInt8>) {
        guard let depacketizer, let decoder else { return }
        depacketizer.push(packet) { [weak self] unit in
            guard let self else { return }
            let began = Date()
            decoder.decode(unit) { [weak self] pb, hardware in
                guard let self, !self.closed else { return }
                if !self.gotPicture {
                    self.gotPicture = true
                    self.onReady?("\(self.track?.codec.label ?? "Video"), \(hardware ? "hardware decode" : "software decode")")
                }
                self.onFrame?(pb, Date().timeIntervalSince(began))
            }
        }
    }

    static func explain(_ e: Error, _ t: RTSPTarget?) -> String {
        let host = t?.host ?? "the camera"
        if let e = e as? NWError, case .posix(let code) = e {
            switch code {
            case .ECONNREFUSED: return "\(host) refused port \(t?.port ?? 554) (is RTSP turned on?)"
            case .ETIMEDOUT, .EHOSTUNREACH, .EHOSTDOWN, .ENETUNREACH, .ENETDOWN: return "No answer from \(host) (check its network cable and power)"
            case .ECONNRESET, .EPIPE: return "The camera dropped the connection"
            default: break
            }
        }
        if let e = e as? NWError, case .dns = e { return "Couldn't find \(host) on the network" }
        return e.localizedDescription
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// An rtsp:// address taken apart: where to connect, the login if any, and the address to
/// send in requests (without the login).
struct RTSPTarget {
    let host: String
    let port: UInt16
    let uri: String
    let user: String?
    let password: String?

    init?(_ text: String) {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespaces)),
              c.scheme?.lowercased() == "rtsp", let host = c.host, !host.isEmpty else { return nil }
        self.host = host
        port = UInt16(c.port ?? 554)
        user = c.user?.removingPercentEncoding ?? c.user
        password = c.password?.removingPercentEncoding ?? c.password
        var path = c.percentEncodedPath
        if path.isEmpty { path = "/" }
        uri = "rtsp://\(host):\(port)\(path)" + (c.percentEncodedQuery.map { "?\($0)" } ?? "")
    }
}

/// An RTSP reply's status line and headers.
struct RTSPReply {
    var code = 0
    var reason = ""
    var headers: [String: String] = [:]

    init(_ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let status = lines.first?.split(separator: " ", maxSplits: 2).map(String.init) ?? []
        code = status.count > 1 ? Int(status[1]) ?? 0 : 0
        reason = status.count > 2 ? status[2] : ""
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // WWW-Authenticate can come more than once; prefer Digest.
            if k == "www-authenticate", let old = headers[k], old.lowercased().hasPrefix("digest") { continue }
            headers[k] = v
        }
    }

    var contentLength: Int { max(0, Int(header("content-length")) ?? 0) }
    func header(_ name: String) -> String { headers[name] ?? "" }
}

/// Basic or Digest login for cameras that ask for one.
struct RTSPAuth {
    let digest: Bool
    let realm: String
    let nonce: String
    let user: String
    let password: String

    init?(_ challenge: String, user: String, password: String) {
        self.user = user
        self.password = password
        let lower = challenge.lowercased()
        if lower.hasPrefix("basic") {
            digest = false; realm = ""; nonce = ""
        } else if lower.hasPrefix("digest") {
            digest = true
            func field(_ name: String) -> String? {
                guard let r = challenge.range(of: "\(name)=\"", options: .caseInsensitive) else { return nil }
                let rest = challenge[r.upperBound...]
                return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
            }
            guard let n = field("nonce") else { return nil }
            realm = field("realm") ?? ""
            nonce = n
        } else {
            return nil
        }
    }

    func header(method: String, uri: String, target: RTSPTarget) -> String? {
        guard digest else { return "Basic " + Data("\(user):\(password)".utf8).base64EncodedString() }
        func md5(_ s: String) -> String { Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
        let response = md5("\(md5("\(user):\(realm):\(password)")):\(nonce):\(md5("\(method):\(uri)"))")
        return "Digest username=\"\(user)\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"\(uri)\", response=\"\(response)\""
    }
}

enum VideoCodec: Equatable {
    case h264, h265
    var label: String { self == .h264 ? "H.264" : "H.265" }
}

/// The video track from a camera's SDP description: its codec, RTP payload type, the address
/// to SETUP, and any parameter sets (SPS, PPS, VPS) given up front.
struct SDPVideoTrack: Equatable {
    var codec: VideoCodec
    var payloadType: UInt8
    var control: String
    var parameterSets: [[UInt8]]

    static func parse(_ sdp: String, base: String) -> SDPVideoTrack? {
        var inVideo = false, found = false
        var pt: UInt8?
        var codec: VideoCodec?
        var control = ""
        var sets: [[UInt8]] = []
        for raw in sdp.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                if found { break }  // only the first video track
                inVideo = line.hasPrefix("m=video")
                if inVideo {
                    found = true
                    let f = line.split(separator: " ")
                    pt = f.count > 3 ? UInt8(f[3]) : nil
                }
                continue
            }
            guard inVideo else { continue }
            if line.hasPrefix("a=control:") {
                control = String(line.dropFirst(10)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("a=rtpmap:") {
                let rest = line.dropFirst(9).split(separator: " ", maxSplits: 1)
                guard rest.count == 2, pt == nil || UInt8(rest[0]) == pt else { continue }
                let name = rest[1].split(separator: "/").first.map { $0.uppercased() } ?? ""
                if name == "H264" { codec = .h264 } else if name == "H265" || name == "HEVC" { codec = .h265 }
                if pt == nil { pt = UInt8(rest[0]) }
            } else if line.hasPrefix("a=fmtp:") {
                let params = line.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                for p in params.split(separator: ";") {
                    let kv = p.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard kv.count == 2 else { continue }
                    switch kv[0].lowercased() {
                    case "sprop-parameter-sets":
                        sets += kv[1].split(separator: ",").compactMap { Data(base64Encoded: String($0), options: .ignoreUnknownCharacters).map { [UInt8]($0) } }
                    case "sprop-vps", "sprop-sps", "sprop-pps":
                        if let d = Data(base64Encoded: kv[1], options: .ignoreUnknownCharacters) { sets.append([UInt8](d)) }
                    default: break
                    }
                }
            }
        }
        guard found, let codec else { return nil }
        return SDPVideoTrack(codec: codec, payloadType: pt ?? 96, control: resolve(control, base: base), parameterSets: sets.filter { !$0.isEmpty })
    }

    static func resolve(_ control: String, base: String) -> String {
        if control.lowercased().hasPrefix("rtsp://") { return control }
        if control.isEmpty || control == "*" { return base }
        return base.hasSuffix("/") ? base + control : base + "/" + control
    }
}

/// One picture's worth of NAL units, as they came off the wire.
struct AccessUnit {
    var nals: [[UInt8]]
}

/// Turns RTP packets back into whole pictures (H.264 per RFC 6184, H.265 per RFC 7798):
/// single NAL units, aggregation packets, and fragmented units. A picture is done when the
/// marker bit says so, or when the next one's timestamp starts.
final class RTPDepacketizer {
    let codec: VideoCodec
    let payloadType: UInt8
    private var nals: [[UInt8]] = []
    private var fragment: [UInt8]?
    private var timestamp: UInt32?
    private var lastSeq: UInt16?
    private var broken = false

    init(codec: VideoCodec, payloadType: UInt8) {
        self.codec = codec
        self.payloadType = payloadType
    }

    func push(_ p: UnsafeBufferPointer<UInt8>, _ emit: (AccessUnit) -> Void) {
        guard p.count >= 12, p[0] >> 6 == 2 else { return }
        let marker = p[1] & 0x80 != 0
        guard p[1] & 0x7f == payloadType else { return }
        let seq = UInt16(p[2]) << 8 | UInt16(p[3])
        let ts = UInt32(p[4]) << 24 | UInt32(p[5]) << 16 | UInt32(p[6]) << 8 | UInt32(p[7])
        var start = 12 + Int(p[0] & 0x0f) * 4
        if p[0] & 0x10 != 0 {
            guard p.count >= start + 4 else { return }
            start += 4 + (Int(p[start + 2]) << 8 | Int(p[start + 3])) * 4
        }
        var end = p.count
        if p[0] & 0x20 != 0 { end -= Int(p[p.count - 1]) }
        guard start < end else { return }

        if let last = lastSeq, seq != last &+ 1 {
            // A gap (rare over TCP): the half-built unit can't be trusted.
            fragment = nil
            broken = true
        }
        lastSeq = seq
        if let t = timestamp, t != ts { finish(emit) }
        timestamp = ts

        let payload = UnsafeBufferPointer(rebasing: p[start..<end])
        if codec == .h264 { h264(payload) } else { h265(payload) }
        if marker { finish(emit) }
    }

    private func finish(_ emit: (AccessUnit) -> Void) {
        fragment = nil
        if !nals.isEmpty, !broken { emit(AccessUnit(nals: nals)) }
        nals.removeAll(keepingCapacity: true)
        broken = false
    }

    private func h264(_ p: UnsafeBufferPointer<UInt8>) {
        guard let first = p.first else { return }
        switch first & 0x1f {
        case 1...23:
            nals.append(Array(p))
        case 24:  // STAP-A: several small NAL units, each with a 2-byte size
            aggregate(p, from: 1)
        case 28:  // FU-A: one NAL unit split over packets
            guard p.count > 2 else { return }
            let fu = p[1]
            if fu & 0x80 != 0 { fragment = [(first & 0xe0) | (fu & 0x1f)] }
            guard fragment != nil else { return }
            fragment!.append(contentsOf: p[2...])
            if fu & 0x40 != 0, let f = fragment { nals.append(f); fragment = nil }
        default:
            break
        }
    }

    private func h265(_ p: UnsafeBufferPointer<UInt8>) {
        guard p.count >= 2 else { return }
        switch (p[0] >> 1) & 0x3f {
        case 48:  // aggregation packet
            aggregate(p, from: 2)
        case 49:  // fragmentation unit
            guard p.count > 3 else { return }
            let fu = p[2]
            if fu & 0x80 != 0 { fragment = [(p[0] & 0x81) | ((fu & 0x3f) << 1), p[1]] }
            guard fragment != nil else { return }
            fragment!.append(contentsOf: p[3...])
            if fu & 0x40 != 0, let f = fragment { nals.append(f); fragment = nil }
        case 50:
            break
        default:
            nals.append(Array(p))
        }
    }

    private func aggregate(_ p: UnsafeBufferPointer<UInt8>, from: Int) {
        var i = from
        while i + 2 <= p.count {
            let size = Int(p[i]) << 8 | Int(p[i + 1])
            i += 2
            guard size > 0, i + size <= p.count else { return }
            nals.append(Array(p[i..<(i + size)]))
            i += size
        }
    }
}

/// Hands whole pictures to VideoToolbox, on the Mac's hardware decoder, and gets back
/// BGRA pictures in IOSurfaces that can go straight onto the screen.
final class VideoDecoder {
    let codec: VideoCodec
    private var vps: [UInt8]?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var needKeyframe = true
    private var hardware = false

    init(codec: VideoCodec, parameterSets: [[UInt8]]) {
        self.codec = codec
        for s in parameterSets { take(s) }
    }

    func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }

    private func type(_ nal: [UInt8]) -> Int {
        guard let b = nal.first else { return -1 }
        return codec == .h264 ? Int(b & 0x1f) : Int((b >> 1) & 0x3f)
    }

    /// Keeps a parameter set. True if it changed.
    @discardableResult private func take(_ nal: [UInt8]) -> Bool {
        switch (codec, type(nal)) {
        case (.h264, 7), (.h265, 33): if sps != nal { sps = nal; return true }
        case (.h264, 8), (.h265, 34): if pps != nal { pps = nal; return true }
        case (.h265, 32): if vps != nal { vps = nal; return true }
        default: break
        }
        return false
    }

    private func isParameterSet(_ t: Int) -> Bool { codec == .h264 ? (t == 7 || t == 8) : (32...34).contains(t) }
    private func isPicture(_ t: Int) -> Bool { codec == .h264 ? (1...5).contains(t) : (0...31).contains(t) }
    private func isKeyframe(_ t: Int) -> Bool { codec == .h264 ? t == 5 : (16...21).contains(t) }

    func decode(_ unit: AccessUnit, _ out: (CVPixelBuffer, Bool) -> Void) {
        var changed = false
        var slices: [[UInt8]] = []
        var key = false
        for nal in unit.nals {
            let t = type(nal)
            if isParameterSet(t) { if take(nal) { changed = true } }
            else if isPicture(t) { slices.append(nal); if isKeyframe(t) { key = true } }
        }
        if changed || format == nil { rebuildFormat() }
        guard let format, !slices.isEmpty else { return }
        if needKeyframe { guard key else { return }; needKeyframe = false }
        if session == nil { makeSession(format) }
        guard let session else { return }

        // AVCC: each NAL unit with a 4-byte big-endian length in front.
        let total = slices.reduce(0) { $0 + 4 + $1.count }
        var bytes = [UInt8](); bytes.reserveCapacity(total)
        for s in slices {
            let n = UInt32(s.count)
            bytes += [UInt8(n >> 24), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)]
            bytes += s
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: total,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: total, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block,
              CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: block, offsetIntoDestination: 0, dataLength: total) == noErr else { return }
        var sample: CMSampleBuffer?
        var size = total
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return }
        var picture: CVPixelBuffer?
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [._1xRealTimePlayback], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr, let image { picture = image }
        }
        if status == kVTInvalidSessionErr { invalidate(); needKeyframe = true; return }
        if status != noErr { needKeyframe = true; return }  // wait for a clean picture rather than show a smeared one
        if let picture { out(picture, hardware) }
    }

    private func rebuildFormat() {
        guard let sps, let pps, codec == .h264 || vps != nil else { return }
        let sets = codec == .h264 ? [sps, pps] : [vps!, sps, pps]
        let copies = sets.map { s -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: s.count)
            p.initialize(from: s, count: s.count)
            return p
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers = copies.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var fd: CMFormatDescription?
        let status: OSStatus = codec == .h264
            ? CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                                                                  parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                  nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            : CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                                                                  parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                  nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
        guard status == noErr, let fd else { return }
        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: fd) {
            format = fd
            return
        }
        invalidate()
        format = fd
        needKeyframe = true
    }

    private func makeSession(_ format: CMVideoFormatDescription) {
        let spec: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var s: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                                           decoderSpecification: spec as CFDictionary, imageBufferAttributes: attrs as CFDictionary,
                                           outputCallback: nil, decompressionSessionOut: &s) == noErr, let s else { return }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        var hw: CFTypeRef?
        VTSessionCopyProperty(s, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: &hw)
        hardware = (hw as? Bool) ?? false
        session = s
    }
}
