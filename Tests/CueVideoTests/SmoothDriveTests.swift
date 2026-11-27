import XCTest
@testable import CueVideo

/// The smooth drive's speed ramp: every start, stop and change eases in and out (an S-curve),
/// and lands without going past the speed it's heading for.
final class SmoothDriveTests: XCTestCase {
    let dt = 1.0 / 30

    private func run(from v0: Double, to want: Double, seconds: Double, maxAcc: Double = 1.5) -> [(v: Double, a: Double)] {
        var v = v0, a = 0.0, out: [(Double, Double)] = []
        for _ in 0..<Int(seconds / dt) {
            let r = AutoTracker.smoothStep(v: v, a: a, want: want, dt: dt, maxAcc: maxAcc)
            v = r.v; a = r.a; out.append((v, a))
        }
        return out
    }

    func testStartEasesInAndLandsWithoutOvershoot() {
        let path = run(from: 0, to: 0.3, seconds: 3)
        let v = path.map(\.v), a = path.map(\.a)
        XCTAssertLessThan(a[0], 0.6, "the first step shouldn't jump to full acceleration")
        for i in 1..<v.count { XCTAssertGreaterThanOrEqual(v[i], v[i - 1] - 1e-9, "speed went backwards at step \(i)") }
        XCTAssertLessThanOrEqual(v.max()!, 0.3 * 1.02, "went past the speed it was heading for")
        let reached = v.firstIndex { $0 > 0.285 }.map { Double($0) * dt } ?? 99
        XCTAssertLessThan(reached, 1.5, "too slow to pick up a walk: \(reached) s")
        for i in 1..<a.count { XCTAssertLessThanOrEqual(abs(a[i] - a[i - 1]), 10 * dt + 1e-9, "acceleration jumped at step \(i)") }
    }

    func testStopEasesOutAndNeverReverses() {
        let path = run(from: 0.3, to: 0, seconds: 3, maxAcc: 3)
        let v = path.map(\.v)
        XCTAssertGreaterThan(v[0], 0.28, "the stop shouldn't be sudden")
        XCTAssertGreaterThanOrEqual(v.min()!, -0.006, "it swung back the other way after stopping")
        XCTAssertLessThan(abs(v.last!), 0.005)
        let stopped = v.firstIndex { abs($0) < 0.015 }.map { Double($0) * dt } ?? 99
        XCTAssertLessThan(stopped, 1.5, "takes too long to stop: \(stopped) s")
    }

    func testAccelerationIsCapped() {
        let path = run(from: 0, to: 5, seconds: 1)
        XCTAssertLessThanOrEqual(path.map { abs($0.a) }.max()!, 1.5 + 1e-9)
    }
}
