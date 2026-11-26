import XCTest
@testable import CueVideo

/// The control server only answers requests that carry this Mac's key.
final class ControlServerTests: XCTestCase {
    let key = String(repeating: "ab", count: 24)

    func testRightKeyPasses() {
        XCTAssertTrue(ControlServer.sameKey(key, key))
    }

    func testWrongMissingOrShortKeyFails() {
        XCTAssertFalse(ControlServer.sameKey(nil, key))
        XCTAssertFalse(ControlServer.sameKey("", key))
        XCTAssertFalse(ControlServer.sameKey(String(key.dropLast()), key))
        XCTAssertFalse(ControlServer.sameKey(String(key.dropLast()) + "c", key))
    }

    func testNoKeySetMeansNothingPasses() {
        XCTAssertFalse(ControlServer.sameKey("", ""))
    }
}
