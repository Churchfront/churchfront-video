import XCTest
@testable import CueVideo
import CueATEM

final class RTSPTests: XCTestCase {
    /// The SDP a PTZOptics camera at River Run sent for its sub stream (2026-11-25).
    let ptzOpticsSDP = """
    v=0\r
    o=CameraStreaming 3132335948 1236907222000 IN IP4 192.168.2.154\r
    s=10\r
    c=IN IP4 0.0.0.0\r
    t=0 0\r
    a=control:*\r
    m=video 0 RTP/AVP 96\r
    a=control:trackID=0\r
    a=rtpmap:96 H264/90000\r
    a=fmtp:96 packetization-mode=1;profile-level-id=64001E;sprop-parameter-sets=Z2QAHq2EAQwgCGEAQwgCGEAQwgCEO1BQF/yzcBAQECA=,aO48sA==\r
    a=framesize:96 640-360\r
    m=audio 0 RTP/AVP 104\r
    a=control:trackID=1\r
    a=rtpmap:104 MPEG4-GENERIC/48000/2\r

    """

    func testPTZOpticsSDP() throws {
        let t = try XCTUnwrap(SDPVideoTrack.parse(ptzOpticsSDP, base: "rtsp://192.168.2.154:554/2"))
        XCTAssertEqual(t.codec, .h264)
        XCTAssertEqual(t.payloadType, 96)
        XCTAssertEqual(t.control, "rtsp://192.168.2.154:554/2/trackID=0")
        XCTAssertEqual(t.parameterSets.count, 2)
        XCTAssertEqual(t.parameterSets[0].first.map { $0 & 0x1f }, 7)  // SPS
        XCTAssertEqual(t.parameterSets[1].first.map { $0 & 0x1f }, 8)  // PPS
    }

    func testHEVCSDPAndControlURLs() throws {
        let sdp = "m=video 0 RTP/AVP 98\na=rtpmap:98 H265/90000\na=control:rtsp://cam/stream/video\na=fmtp:98 sprop-vps=QAEMAf//;sprop-sps=QgEB;sprop-pps=RAHA\n"
        let t = try XCTUnwrap(SDPVideoTrack.parse(sdp, base: "rtsp://cam/stream"))
        XCTAssertEqual(t.codec, .h265)
        XCTAssertEqual(t.payloadType, 98)
        XCTAssertEqual(t.control, "rtsp://cam/stream/video")
        XCTAssertEqual(t.parameterSets.count, 3)
        XCTAssertEqual(SDPVideoTrack.resolve("*", base: "rtsp://a/1"), "rtsp://a/1")
        XCTAssertEqual(SDPVideoTrack.resolve("track1", base: "rtsp://a/1/"), "rtsp://a/1/track1")
        XCTAssertNil(SDPVideoTrack.parse("m=audio 0 RTP/AVP 0\n", base: "rtsp://a"))
    }

    func testTarget() throws {
        let t = try XCTUnwrap(RTSPTarget("rtsp://admin:p%40ss@192.168.2.153/live?ch=1"))
        XCTAssertEqual(t.host, "192.168.2.153")
        XCTAssertEqual(t.port, 554)
        XCTAssertEqual(t.user, "admin")
        XCTAssertEqual(t.password, "p@ss")
        XCTAssertEqual(t.uri, "rtsp://192.168.2.153:554/live?ch=1")
        XCTAssertNil(RTSPTarget("http://192.168.2.154/1"))
        XCTAssertNil(RTSPTarget("rtsp://"))
    }

    func testReplyAndDigest() throws {
        let r = RTSPReply("RTSP/1.0 401 Unauthorized\r\nCSeq: 2\r\nWWW-Authenticate: Digest realm=\"cam\", nonce=\"abc\"\r\nWWW-Authenticate: Basic realm=\"cam\"\r\nContent-Length: 12")
        XCTAssertEqual(r.code, 401)
        XCTAssertEqual(r.contentLength, 12)
        let a = try XCTUnwrap(RTSPAuth(r.header("www-authenticate"), user: "u", password: "p"))
        XCTAssertTrue(a.digest)
        let t = try XCTUnwrap(RTSPTarget("rtsp://u:p@cam/1"))
        let h = try XCTUnwrap(a.header(method: "DESCRIBE", uri: t.uri, target: t))
        XCTAssertTrue(h.hasPrefix("Digest username=\"u\", realm=\"cam\", nonce=\"abc\", uri=\"rtsp://cam:554/1\", response=\""))
    }

    private func packet(seq: UInt16, ts: UInt32, marker: Bool, _ payload: [UInt8]) -> [UInt8] {
        [0x80, (marker ? 0x80 : 0) | 96, UInt8(seq >> 8), UInt8(seq & 0xff),
         UInt8(ts >> 24), UInt8(ts >> 16 & 0xff), UInt8(ts >> 8 & 0xff), UInt8(ts & 0xff), 0, 0, 0, 1] + payload
    }

    private func run(_ d: RTPDepacketizer, _ packets: [[UInt8]]) -> [AccessUnit] {
        var out: [AccessUnit] = []
        for p in packets { p.withUnsafeBufferPointer { d.push($0) { out.append($0) } } }
        return out
    }

    func testH264FragmentsAndAggregates() {
        let d = RTPDepacketizer(codec: .h264, payloadType: 96)
        let units = run(d, [
            // STAP-A carrying an SPS and a PPS
            packet(seq: 1, ts: 100, marker: false, [24, 0, 2, 0x67, 0xAA, 0, 2, 0x68, 0xBB]),
            // An IDR slice split into three FU-A pieces
            packet(seq: 2, ts: 100, marker: false, [0x7C, 0x85, 1, 2]),
            packet(seq: 3, ts: 100, marker: false, [0x7C, 0x05, 3, 4]),
            packet(seq: 4, ts: 100, marker: true, [0x7C, 0x45, 5]),
            // The next picture, one packet
            packet(seq: 5, ts: 3100, marker: true, [0x41, 9, 9]),
        ])
        XCTAssertEqual(units.count, 2)
        XCTAssertEqual(units[0].nals, [[0x67, 0xAA], [0x68, 0xBB], [0x65, 1, 2, 3, 4, 5]])
        XCTAssertEqual(units[1].nals, [[0x41, 9, 9]])
        XCTAssertEqual(units.map(\.timestamp), [100, 3100])
    }

    func testLostPacketDropsOnlyThatPicture() {
        let d = RTPDepacketizer(codec: .h264, payloadType: 96)
        let units = run(d, [
            packet(seq: 10, ts: 100, marker: false, [0x7C, 0x85, 1]),
            packet(seq: 12, ts: 100, marker: true, [0x7C, 0x45, 3]),   // 11 never came
            packet(seq: 13, ts: 3100, marker: true, [0x41, 7]),
        ])
        XCTAssertEqual(units.map(\.nals), [[[0x41, 7]]])
    }

    func testPictureEndsOnNewTimestampWithoutMarker() {
        let d = RTPDepacketizer(codec: .h264, payloadType: 96)
        let units = run(d, [
            packet(seq: 1, ts: 100, marker: false, [0x41, 1]),
            packet(seq: 2, ts: 200, marker: false, [0x41, 2]),
        ])
        XCTAssertEqual(units.map(\.nals), [[[0x41, 1]]])
    }

    func testH265Fragments() {
        let d = RTPDepacketizer(codec: .h265, payloadType: 96)
        // FU of an IDR_W_RADL (type 19): payload header type 49, FU header carries 19.
        let units = run(d, [
            packet(seq: 1, ts: 1, marker: false, [49 << 1, 1, 0x80 | 19, 0xA]),
            packet(seq: 2, ts: 1, marker: true, [49 << 1, 1, 0x40 | 19, 0xB]),
        ])
        XCTAssertEqual(units.map(\.nals), [[[19 << 1, 1, 0xA, 0xB]]])
    }

    func testOtherPayloadTypesIgnored() {
        let d = RTPDepacketizer(codec: .h264, payloadType: 96)
        var p = packet(seq: 1, ts: 1, marker: true, [0x41, 1])
        p[1] = 0x80 | 104  // audio
        XCTAssertTrue(run(d, [p]).isEmpty)
        XCTAssertTrue(run(d, [[0x80, 0x60]]).isEmpty)  // too short: ignored, no crash
    }

    func testCameraConfigKeepsOldBehaviourAndRoundTrips() throws {
        // A camera saved before RTSP existed has no video field.
        let old = try JSONDecoder().decode(PTZCamera.self, from: Data(#"{"name":"Cam 2","host":"192.168.2.154","proto":"rawTCP"}"#.utf8))
        XCTAssertNil(old.video)
        XCTAssertEqual(old.rtspURL(.main), "rtsp://192.168.2.154:554/1")
        XCTAssertEqual(old.rtspURL(.sub), "rtsp://192.168.2.154:554/2")

        var c = old
        c.video = .rtsp
        c.rtspSub = " rtsp://192.168.2.154:554/2?low "
        c.rtspTiles = .main
        let back = try JSONDecoder().decode(PTZCamera.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.video, .rtsp)
        XCTAssertEqual(back.rtspTiles, .main)
        XCTAssertNil(back.rtspMonitors)
        XCTAssertEqual(back.rtspURL(.sub), "rtsp://192.168.2.154:554/2?low")
        XCTAssertEqual(back.port, 5678)
    }

    func testStatusText() {
        XCTAssertEqual(RTSPStatus.live(width: 640, height: 360, fps: 30).text, "Live, 640×360 · 30 fps")
        XCTAssertEqual(RTSPStatus.live(width: 640, height: 360, fps: 0).liveText, "640×360")
        XCTAssertEqual(RTSPStatus.offline("No video for 5 seconds").text, "Offline: No video for 5 seconds")
    }
}

final class TrackMotionTests: XCTestCase {
    /// The camera's speed is worked out from what was sent, each speed held until the next.
    func testSentSpeedAveragesWhatWasSent() {
        let t0 = Date()
        let log = [(at: t0, pan: 0.0, tilt: 0.0), (at: t0.addingTimeInterval(1), pan: 1000.0, tilt: -200.0)]
        let v = AutoTracker.sentSpeed(log, from: t0.addingTimeInterval(0.5), to: t0.addingTimeInterval(1.5))
        XCTAssertEqual(v.pan, 500, accuracy: 0.001)
        XCTAssertEqual(v.tilt, -100, accuracy: 0.001)
        XCTAssertEqual(AutoTracker.sentSpeed([], from: t0, to: t0.addingTimeInterval(1)).pan, 0)
    }
}
