import SwiftUI
import AppKit
import Combine
import CoreVideo
import CueATEM

/// Where a picture is shown: a small tile (source row, routing, auto tracking, snapshots), or
/// the big Next and Live monitors. RTSP cameras send the sub stream to tiles and the main
/// stream to monitors, unless set otherwise.
enum PictureRole { case tile, monitor }

/// Where a camera's live picture comes from: a Canon's own HTTP preview, an NDI stream, or
/// the camera's RTSP stream. Set per camera in Setup (`video` in the config file). Cameras
/// set up before RTSP was added keep working as they did: a Canon's own preview, otherwise
/// the NDI picture set for its switcher input. Auto tracking, snapshots, the camera's tile and
/// the Next and Live monitors all read whichever one this gives.
enum CameraPicture {
    case canon(PTZCamera)
    case ndi(String)
    case rtsp(String)

    static func of(_ c: PTZCamera, _ store: ConfigStore = Booth.shared.store, role: PictureRole = .tile) -> CameraPicture? {
        switch c.video {
        case nil:
            if c.proto == .canonXC { return c.host.isEmpty ? nil : .canon(c) }
            return store.ndi(c.atemInput).map { .ndi($0) }
        case .off?:
            return nil
        case .canon?:
            return c.proto == .canonXC && !c.host.isEmpty ? .canon(c) : nil
        case .ndi?:
            if let n = c.ndi, !n.isEmpty { return .ndi(n) }
            return store.ndi(c.atemInput).map { .ndi($0) }
        case .rtsp?:
            let stream = role == .monitor ? (c.rtspMonitors ?? .main) : (c.rtspTiles ?? .sub)
            let url = c.rtspURL(stream)
            return c.host.isEmpty && (stream == .main ? c.rtspMain : c.rtspSub) == nil ? nil : .rtsp(url)
        }
    }

    /// The picture type in words, for Setup and Status.
    static func kind(_ c: PTZCamera, _ store: ConfigStore = Booth.shared.store) -> CameraVideoSource {
        switch of(c, store) {
        case .canon: return .canon
        case .ndi: return .ndi
        case .rtsp: return .rtsp
        case nil: return .off
        }
    }

    /// Every new frame, on the main thread.
    var frames: AnyPublisher<CGImage, Never> {
        switch self {
        case .canon(let c): return CanonFeedHub.shared.feed(for: c).$image.compactMap { $0 }.eraseToAnyPublisher()
        case .ndi(let n): return NDIFeedHub.shared.feed(n).$image.compactMap { $0 }.eraseToAnyPublisher()
        case .rtsp(let u): return RTSPFeedHub.shared.feed(u).images
        }
    }

    /// The latest frame, only while the picture is really coming in.
    var liveImage: CGImage? {
        switch self {
        case .canon(let c): let f = CanonFeedHub.shared.feed(for: c); return f.live ? f.image : nil
        case .ndi(let n): let f = NDIFeedHub.shared.feed(n); return f.live ? f.image : nil
        case .rtsp(let u): return RTSPFeedHub.shared.feed(u).liveImage
        }
    }

    /// Keeps the picture running while something other than a view needs it. Pair with release.
    func retain() {
        switch self {
        case .canon(let c): CanonFeedHub.shared.retain(c)
        case .ndi(let n): NDIFeedHub.shared.retain(n)
        case .rtsp(let u): RTSPFeedHub.shared.retain(u)
        }
    }

    func release() {
        switch self {
        case .canon(let c): CanonFeedHub.shared.release(c)
        case .ndi(let n): NDIFeedHub.shared.release(n)
        case .rtsp(let u): RTSPFeedHub.shared.release(u)
        }
    }
}

extension PTZController {
    /// The camera on this switcher input that CueVideo has a live picture for.
    func pictured(on input: Int?, _ store: ConfigStore) -> PTZCamera? {
        guard let input else { return nil }
        return cameras.first { $0.atemInput == input && CameraPicture.of($0, store) != nil }
    }
}

/// A camera's live picture, fitted to its frame, whichever way it arrives. While the camera
/// is auto tracking, the person it follows is outlined. With `onPick`, clicking the picture
/// reports where (0 to 1 across and down the picture).
struct CameraVideo: View {
    let camera: PTZCamera
    var role: PictureRole = .tile
    var onPick: ((CGPoint) -> Void)? = nil
    @ObservedObject private var store = Booth.shared.store

    var body: some View {
        switch CameraPicture.of(camera, store, role: role) {
        case .canon: CanonCameraVideo(camera: camera, onPick: onPick)
        case .ndi(let n): NDICameraVideo(camera: camera, source: n, onPick: onPick).id(n)
        case .rtsp(let u): RTSPCameraVideo(camera: camera, url: u, compact: role == .tile, onPick: onPick).id(u)
        case nil: Color.black
        }
    }
}

private struct CanonCameraVideo: View {
    let camera: PTZCamera
    var onPick: ((CGPoint) -> Void)?
    @ObservedObject private var feed: CanonFeed

    init(camera: PTZCamera, onPick: ((CGPoint) -> Void)?) {
        self.camera = camera
        self.onPick = onPick
        feed = CanonFeedHub.shared.feed(for: camera)
    }

    var body: some View {
        TrackedPicture(camera: camera, size: feed.image.map(\.size), live: feed.live, waiting: "Connecting", onPick: onPick) {
            if let img = feed.image { Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit) }
        }
            .onAppear { CanonFeedHub.shared.retain(camera) }
            .onDisappear { CanonFeedHub.shared.release(camera) }
    }
}

private struct NDICameraVideo: View {
    let camera: PTZCamera
    let source: String
    var onPick: ((CGPoint) -> Void)?
    @ObservedObject private var feed: NDIFeed

    init(camera: PTZCamera, source: String, onPick: ((CGPoint) -> Void)?) {
        self.camera = camera
        self.source = source
        self.onPick = onPick
        feed = NDIFeedHub.shared.feed(source)
    }

    var body: some View {
        TrackedPicture(camera: camera, size: feed.image.map(\.size), live: feed.live,
                       waiting: "Waiting for \(NDIMonitor.shortName(source))", onPick: onPick) {
            if let img = feed.image { Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit) }
        }
            .onAppear { NDIFeedHub.shared.retain(source) }
            .onDisappear { NDIFeedHub.shared.release(source) }
    }
}

private struct RTSPCameraVideo: View {
    let camera: PTZCamera
    let url: String
    /// A small tile: shorter status text.
    let compact: Bool
    var onPick: ((CGPoint) -> Void)?
    @ObservedObject private var feed: RTSPFeed

    init(camera: PTZCamera, url: String, compact: Bool, onPick: ((CGPoint) -> Void)?) {
        self.camera = camera
        self.url = url
        self.compact = compact
        self.onPick = onPick
        feed = RTSPFeedHub.shared.feed(url)
    }

    var body: some View {
        TrackedPicture(camera: camera, size: feed.size, live: feed.live, waiting: "Connecting to \(camera.name)",
                       status: feed.status, compact: compact, onPick: onPick) {
            RTSPVideo(feed: feed)
        }
        .onAppear { RTSPFeedHub.shared.retain(url) }
        .onDisappear { RTSPFeedHub.shared.release(url) }
    }
}

/// The picture itself, with the tracking outline and the click-to-pick layer. With `status`
/// (RTSP pictures), the stream's state shows on it: Connecting, Live with size and frame
/// rate, or Offline with the reason, so a volunteer sees at a glance which feed is down.
private struct TrackedPicture<Picture: View>: View {
    let camera: PTZCamera
    /// The picture's pixel size, once there is one.
    let size: CGSize?
    let live: Bool
    let waiting: String
    var status: RTSPStatus? = nil
    var compact = false
    var onPick: ((CGPoint) -> Void)?
    @ViewBuilder let picture: () -> Picture
    @ObservedObject private var tracker = AutoTracker.shared

    var body: some View {
        GeometryReader { g in
            let box = fitted(g.size)
            ZStack {
                Color.black
                picture()
                if let s = tracker.sessions[camera.id], let t = s.target?.box {
                    let r = CGRect(x: box.minX + t.minX * box.width, y: box.minY + t.minY * box.height,
                                   width: t.width * box.width, height: t.height * box.height)
                    let color = s.phase == .following ? T.accent : T.warning
                    RoundedRectangle(cornerRadius: 4).stroke(color, style: StrokeStyle(lineWidth: 2, dash: s.phase == .following ? [] : [5, 4]))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .animation(.linear(duration: 0.1), value: t)
                }
                if case .offline(let why)? = status {
                    StreamOffline(why: why, compact: compact)
                } else if !live {
                    VStack(spacing: T.s1) {
                        ProgressView().controlSize(.small)
                        Text(size == nil ? waiting : "Picture stopped").font(.sans(11)).foregroundStyle(T.inkMuted)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .padding(T.s2)
                    .background(RoundedRectangle(cornerRadius: T.rMD).fill(Color.black.opacity(0.6)))
                }
                if let text = status?.liveText {
                    // Live: the stream's size and frame rate, small, out of the way.
                    HStack(spacing: 4) {
                        Circle().fill(T.success).frame(width: 6, height: 6)
                        Text(text).font(.sans(compact ? 9 : 11, .semibold)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    }
                    .padding(.horizontal, 6).frame(height: compact ? 16 : 20)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(compact ? 4 : T.s3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .topTrailing : .bottomTrailing)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { p in
                guard let onPick, box.width > 0, box.contains(p) else { return }
                onPick(CGPoint(x: (p.x - box.minX) / box.width, y: (p.y - box.minY) / box.height))
            }
            .allowsHitTesting(onPick != nil)
        }
    }

    /// Where the picture sits inside a frame of this size.
    private func fitted(_ frame: CGSize) -> CGRect {
        let iw = size?.width ?? 16, ih = size?.height ?? 9
        let size = frame
        let scale = min(size.width / iw, size.height / ih)
        let w = iw * scale, h = ih * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

/// An RTSP stream that has dropped: says so plainly, with the reason, while it reconnects.
private struct StreamOffline: View {
    let why: String
    let compact: Bool

    var body: some View {
        VStack(spacing: compact ? 2 : T.s1) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: compact ? 10 : 13, weight: .bold))
                Text("Offline").font(.sans(compact ? 12 : 15, .bold))
            }
            .foregroundStyle(T.danger)
            Text(why).font(.sans(compact ? 9 : 12)).foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center).lineLimit(compact ? 2 : 3).minimumScaleFactor(0.8)
            if !compact {
                Text("Reconnecting on its own").font(.sans(11)).foregroundStyle(T.inkMuted)
            }
        }
        .padding(compact ? 6 : T.s3)
        .background(RoundedRectangle(cornerRadius: T.rMD).fill(Color.black.opacity(0.75)))
        .padding(compact ? 4 : T.s3)
    }
}

/// Shows an RTSP stream's newest decoded picture at every screen refresh, straight from the
/// decoder's IOSurface: no copies and no conversion on the processor.
struct RTSPVideo: NSViewRepresentable {
    let feed: RTSPFeed

    final class LayerView: NSView {
        var feed: RTSPFeed
        private var shown: UInt64 = 0
        /// The picture on screen, held so the decoder doesn't reuse its memory while shown.
        private var holding: CVPixelBuffer?
        private var link: CADisplayLink?

        init(feed: RTSPFeed) {
            self.feed = feed
            super.init(frame: .zero)
            wantsLayer = true
            layer?.contentsGravity = .resizeAspect
            layer?.backgroundColor = NSColor.clear.cgColor
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            link?.invalidate(); link = nil
            guard window != nil else { holding = nil; layer?.contents = nil; return }
            let l = displayLink(target: self, selector: #selector(step))
            l.add(to: .main, forMode: .common)
            link = l
        }

        @objc private func step() {
            guard let (pb, n) = feed.latest(after: shown) else { return }
            shown = n
            holding = pb
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue()
            CATransaction.commit()
        }

        deinit { link?.invalidate() }
    }

    func makeNSView(context: Context) -> LayerView { LayerView(feed: feed) }
    func updateNSView(_ v: LayerView, context: Context) { v.feed = feed }
}

extension CGImage {
    var size: CGSize { CGSize(width: width, height: height) }
}
