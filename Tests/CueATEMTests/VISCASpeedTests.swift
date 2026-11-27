import XCTest
import CueATEM

/// Auto tracking's speeds on VISCA cameras: the speed table, and that a stop always lands.
final class VISCASpeedTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "ptzCameras")
    }

    private func wait(_ seconds: Double, until: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// The speed steps 0.1.3 sent for each tracking speed, worked out as it did.
    private func oldLevels(_ raw: Int) -> (pan: Int, tilt: Int) {
        func v(_ r: Int) -> Double { r == 0 ? 0 : min(1, (Double(abs(r)) / 10000).squareRoot() * 1.8) }
        let p = v(raw), t = v(raw)
        return (raw == 0 ? 0 : max(1, min(0x18, Int((p * p * 24).rounded()))),
                raw == 0 ? 0 : max(1, min(0x14, Int((t * t * 20).rounded()))))
    }

    /// Until a camera's speeds are measured, tracking sends exactly the speed steps it did before.
    func testStandardTableSendsTheSameStepsAsBefore() {
        let t = VISCASpeedTable.standard
        for raw in stride(from: -10000, through: 10000, by: 10) {
            let old = oldLevels(raw)
            XCTAssertEqual(t.panLevel(raw), old.pan, "pan at \(raw)")
            XCTAssertEqual(t.tiltLevel(raw), old.tilt, "tilt at \(raw)")
        }
        XCTAssertEqual(t.panLevel(0), 0)
    }

    /// A measured table picks the nearest real speed, and says how fast that really is.
    func testMeasuredTablePicksTheNearestRealSpeed() {
        var cam = PTZCamera(); cam.proto = .rawTCP
        cam.viscaPanSpeeds = (1...24).map { Double($0 * $0) * 0.2 }    // steep, like a real camera
        let t = VISCASpeedTable(cam)
        XCTAssertEqual(t.panLevel(300), 4)            // 3.0 °/s: nearest is step 4 (3.2)
        XCTAssertEqual(t.actualPan(300), 320)
        XCTAssertEqual(t.actualPan(-300), -320)
        XCTAssertEqual(t.panLevel(5), 1)              // anything that isn't 0 moves
        XCTAssertEqual(t.tilt, VISCASpeedTable.standardTilt, "tilt wasn't measured, so it stays standard")
        cam.viscaPanSpeeds = [1, 2, 3]                // not a full table: ignored
        XCTAssertEqual(VISCASpeedTable(cam).pan, VISCASpeedTable.standardPan)
    }

    /// A Canon runs the speed it's asked for, so nothing about Canon tracking changes.
    func testCanonSpeedIsWhatWasAsked() {
        var cam = PTZCamera(); cam.proto = .canonXC
        let ptz = PTZController(load: false)
        ptz.cameras = [cam]
        let r = ptz.trackSpeedActual(pan: 1234, tilt: -567, camera: cam.id)
        XCTAssertEqual(r.pan, 1234); XCTAssertEqual(r.tilt, -567)
        XCTAssertFalse(cam.tracksSmoothly, "Canon keeps its own drive until smooth drive is tried on one")
        var visca = PTZCamera(); visca.proto = .rawTCP
        XCTAssertTrue(visca.tracksSmoothly)
    }

    private func camera(_ fake: FakeVISCACamera) -> (PTZController, PTZCamera) {
        var cam = PTZCamera(); cam.host = "127.0.0.1"; cam.port = fake.port; cam.proto = .sonyUDP
        let ptz = PTZController(load: false)
        ptz.cameras = [cam]
        return (ptz, cam)
    }

    /// A VISCA camera keeps turning until it hears a stop, so each stop goes out twice.
    func testStopIsSentTwice() throws {
        let fake = try FakeVISCACamera()
        let (ptz, cam) = camera(fake)
        ptz.trackDriveRaw(pan: 500, tilt: 0, camera: cam.id)
        wait(1) { !fake.moves.isEmpty }
        ptz.trackDriveRaw(pan: 0, tilt: 0, camera: cam.id)
        wait(1) { fake.moves.filter(\.isStop).count >= 2 }
        XCTAssertEqual(fake.moves.filter(\.isStop).count, 2, "\(fake.moves)")
    }

    /// A stop repeated after a shot was recalled would cut the recall short: it isn't repeated then.
    func testStopIsNotRepeatedAfterARecall() throws {
        let fake = try FakeVISCACamera()
        let (ptz, cam) = camera(fake)
        ptz.drive(x: 1, y: 0, camera: cam.id)
        wait(1) { !fake.moves.isEmpty }
        ptz.stopDrive(camera: cam.id)
        ptz.recall(2, camera: cam.id)
        wait(0.8)
        XCTAssertEqual(fake.moves.filter(\.isStop).count, 1, "\(fake.moves)")
    }

    /// A speed change the camera turns down is sent again, so the camera isn't left on the old speed.
    func testRefusedDriveIsSentAgain() throws {
        let fake = try FakeVISCACamera()
        let (ptz, cam) = camera(fake)
        wait(0.3)
        fake.refuseDrives = 1
        ptz.trackDriveRaw(pan: 500, tilt: 0, camera: cam.id)
        wait(1) { fake.moves.count >= 2 }
        XCTAssertEqual(fake.moves.count, 2, "the refused drive wasn't sent again: \(fake.moves)")
        XCTAssertEqual(fake.moves.map(\.panSpeed), [4, 4])
    }

    /// A drive turned down after a shot was recalled isn't sent again: it would cut the recall short.
    func testRefusedDriveIsNotSentAfterARecall() throws {
        let fake = try FakeVISCACamera()
        let (ptz, cam) = camera(fake)
        wait(0.3)
        fake.refuseDrives = 1
        ptz.trackDriveRaw(pan: 500, tilt: 0, camera: cam.id)
        ptz.recall(3, camera: cam.id)
        wait(0.8)
        XCTAssertEqual(fake.moves.count, 1, "a refused drive was sent again after a recall: \(fake.moves)")
    }

    /// Tracking asks 30 times a second; a speed that comes out as the step already running isn't sent again.
    func testSameStepIsNotSentAgain() throws {
        let fake = try FakeVISCACamera()
        let (ptz, cam) = camera(fake)
        for raw in [500, 510, 520, 505] { ptz.trackDriveRaw(pan: raw, tilt: 0, camera: cam.id) }   // all step 4
        ptz.trackDriveRaw(pan: 900, tilt: 0, camera: cam.id)                                      // step 7
        wait(1) { fake.moves.count >= 2 }
        wait(0.2)
        XCTAssertEqual(fake.moves.map(\.panSpeed), [4, 7])
    }
}
