import SwiftUI
import ImageIO
import CueATEM

/// Live picture from a Canon PTZ camera: the same motion-JPEG preview its web page shows
/// (/-wvhttp-01-/video.cgi, 1280x720 at about 15 fps on the CR-N series). Needs no login,
/// claims no control session and changes nothing on the camera, so it is safe while live.
final class CanonFeed: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published private(set) var image: CGImage?
    @Published private(set) var live = false

    let host: String
    let port: UInt16
    // Everything below is only touched on `work`.
    private let work = DispatchQueue(label: "cuevideo.canonfeed")
    private var session: URLSession?
    private var buffer = Data()
    private var running = false
    private var decoding = false
    private var lastFrame = Date.distantPast
    private var watchdog: DispatchSourceTimer?

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    private var url: URL? {
        URL(string: "http://\(host)\(port == 80 ? "" : ":\(port)")/-wvhttp-01-/video.cgi")
    }

    func start() {
        work.async {
            guard !self.running, !self.host.isEmpty else { return }
            self.running = true
            self.connect()
            // A stream can stall without closing; reopen it when frames stop.
            let t = DispatchSource.makeTimerSource(queue: self.work)
            t.schedule(deadline: .now() + 3, repeating: 2)
            t.setEventHandler { [weak self] in
                guard let self, self.running, Date().timeIntervalSince(self.lastFrame) > 5 else { return }
                self.setLive(false)
                self.connect()
            }
            t.resume()
            self.watchdog = t
        }
    }

    func stop() {
        work.async {
            self.running = false
            self.watchdog?.cancel(); self.watchdog = nil
            self.session?.invalidateAndCancel(); self.session = nil
            self.buffer.removeAll()
            self.setLive(false)
        }
    }

    private func connect() {
        session?.invalidateAndCancel()
        buffer.removeAll()
        lastFrame = Date()  // give the new stream time to start before the watchdog steps in
        guard let url else { return }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let q = OperationQueue()
        q.underlyingQueue = work
        q.maxConcurrentOperationCount = 1
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: q)
        session = s
        s.dataTask(with: url).resume()
    }

    private func setLive(_ v: Bool) {
        DispatchQueue.main.async { if self.live != v { self.live = v } }
    }

    // MARK: URLSessionDataDelegate (on `work`)

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let ok = (response as? HTTPURLResponse).map { $0.statusCode == 200 } ?? true
        // URLSession splits multipart/x-mixed-replace itself: every frame arrives as its own
        // image/jpeg response followed by the bare JPEG. A new part means the last one is done.
        if ok, s === session, response.mimeType?.hasPrefix("image/") == true { flushPart() }
        completionHandler(ok && s === session ? .allow : .cancel)
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard s === session, running else { return }
        buffer.append(data)
        if buffer.starts(with: [0xFF, 0xD8]) {
            // A bare JPEG from a split part: show it as soon as its end marker arrives.
            if buffer.count > 4, buffer.suffix(2).elementsEqual([0xFF, 0xD9]) { flushPart() }
            if buffer.count > 8 << 20 { buffer.removeAll() }
        } else {
            parse()  // the raw multipart stream, headers and all
        }
    }

    private func flushPart() {
        if buffer.starts(with: [0xFF, 0xD8]) { frame(buffer) }
        buffer.removeAll(keepingCapacity: true)
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard s === session, running else { return }
        setLive(false)
        work.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.running, self.session === s else { return }
            self.connect()
        }
    }

    /// Each part is "--boundary", a Content-Type and a Content-Length header, a blank line, then the JPEG.
    private func parse() {
        let blank = Data("\r\n\r\n".utf8)
        while let headEnd = buffer.range(of: blank) {
            let head = String(decoding: buffer[buffer.startIndex..<headEnd.lowerBound], as: UTF8.self)
            guard let len = Self.contentLength(head) else {
                buffer.removeSubrange(buffer.startIndex..<headEnd.upperBound)
                continue
            }
            let start = headEnd.upperBound
            guard buffer.distance(from: start, to: buffer.endIndex) >= len else { return }
            let end = buffer.index(start, offsetBy: len)
            let jpeg = buffer.subdata(in: start..<end)
            buffer.removeSubrange(buffer.startIndex..<end)
            frame(jpeg)
        }
        // Junk with no header in sight: drop it rather than grow forever.
        if buffer.count > 4 << 20 { buffer.removeAll() }
    }

    static func contentLength(_ head: String) -> Int? {
        for line in head.split(whereSeparator: \.isNewline) {
            let l = line.lowercased()
            if l.hasPrefix("content-length:") { return Int(l.dropFirst(15).trimmingCharacters(in: .whitespaces)) }
        }
        return nil
    }

    private func frame(_ jpeg: Data) {
        lastFrame = Date()
        guard !decoding else { return }  // still drawing the last one: skip this frame
        decoding = true
        DispatchQueue.global(qos: .userInteractive).async {
            let opts = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            let img = CGImageSourceCreateWithData(jpeg as CFData, nil)
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, opts) }
            DispatchQueue.main.async {
                if let img { self.image = img; if !self.live { self.live = true } }
                self.work.async { self.decoding = false }
            }
        }
    }
}

/// One stream per camera, shared by everything showing it (its source tile, the Next or
/// Live monitor), started while something is on screen and stopped when nothing is.
final class CanonFeedHub {
    static let shared = CanonFeedHub()
    private var feeds: [String: CanonFeed] = [:]
    private var users: [String: Int] = [:]

    private func key(_ c: PTZCamera) -> String { "\(c.host):\(c.port)" }

    func feed(for c: PTZCamera) -> CanonFeed {
        let k = key(c)
        if let f = feeds[k] { return f }
        let f = CanonFeed(host: c.host, port: c.port)
        feeds[k] = f
        return f
    }

    func retain(_ c: PTZCamera) {
        let k = key(c)
        users[k, default: 0] += 1
        if users[k] == 1 { feed(for: c).start() }
    }

    func release(_ c: PTZCamera) {
        let k = key(c)
        guard let n = users[k] else { return }
        if n <= 1 { users[k] = nil; feeds[k]?.stop() } else { users[k] = n - 1 }
    }

    /// For the Status window: whether each camera's picture is coming in.
    func isLive(_ c: PTZCamera) -> Bool? { users[key(c)] == nil ? nil : feeds[key(c)]?.live }
}

/// A Canon camera's live picture, fitted to its frame. While the camera is auto tracking,
/// the person it follows is outlined. With `onPick`, clicking the picture reports where
/// (0 to 1 across and down the picture).
struct CameraVideo: View {
    let camera: PTZCamera
    var onPick: ((CGPoint) -> Void)? = nil
    @ObservedObject private var feed: CanonFeed
    @ObservedObject private var tracker = AutoTracker.shared

    init(camera: PTZCamera, onPick: ((CGPoint) -> Void)? = nil) {
        self.camera = camera
        self.onPick = onPick
        feed = CanonFeedHub.shared.feed(for: camera)
    }

    var body: some View {
        GeometryReader { g in
            let box = fitted(g.size)
            ZStack {
                Color.black
                if let img = feed.image {
                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                }
                if let s = tracker.sessions[camera.id], let t = s.target?.box {
                    let r = CGRect(x: box.minX + t.minX * box.width, y: box.minY + t.minY * box.height,
                                   width: t.width * box.width, height: t.height * box.height)
                    let color = s.phase == .following ? T.accent : T.warning
                    RoundedRectangle(cornerRadius: 4).stroke(color, style: StrokeStyle(lineWidth: 2, dash: s.phase == .following ? [] : [5, 4]))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .animation(.linear(duration: 0.1), value: t)
                }
                if !feed.live {
                    VStack(spacing: T.s1) {
                        ProgressView().controlSize(.small)
                        Text(feed.image == nil ? "Connecting" : "Picture stopped").font(.sans(11)).foregroundStyle(T.inkMuted)
                    }
                    .padding(T.s2)
                    .background(RoundedRectangle(cornerRadius: T.rMD).fill(Color.black.opacity(0.6)))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { p in
                guard let onPick, box.width > 0, box.contains(p) else { return }
                onPick(CGPoint(x: (p.x - box.minX) / box.width, y: (p.y - box.minY) / box.height))
            }
            .allowsHitTesting(onPick != nil)
        }
        .onAppear { CanonFeedHub.shared.retain(camera) }
        .onDisappear { CanonFeedHub.shared.release(camera) }
    }

    /// Where the picture sits inside a frame of this size.
    private func fitted(_ size: CGSize) -> CGRect {
        let iw = CGFloat(feed.image?.width ?? 16), ih = CGFloat(feed.image?.height ?? 9)
        let scale = min(size.width / iw, size.height / ih)
        let w = iw * scale, h = ih * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}
