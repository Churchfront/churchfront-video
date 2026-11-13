import XCTest
@testable import CueVideo

/// A saved NDI source still connects when its computer announces itself under another name.
final class NDINameTests: XCTestCase {
    let onNetwork = ["PRODUCTN01SMINI (CueScreens Side Screens)", "PRODUCTN01SMINI (CueScreens Stage)",
                     "PTZOPTICS (Chan 1, 192.168.1.178)", "N5-A (Channel-NDI)", "N5-B (Channel-NDI)"]

    func testExactNameIsKept() {
        XCTAssertEqual(NDIFeed.match("PTZOPTICS (Chan 1, 192.168.1.178)", in: onNetwork), "PTZOPTICS (Chan 1, 192.168.1.178)")
    }

    func testSameChannelUnderAnotherComputerName() {
        XCTAssertEqual(NDIFeed.match("PRODUCTION-01S-MAC-MINI.LOCAL (CueScreens Side Screens)", in: onNetwork),
                       "PRODUCTN01SMINI (CueScreens Side Screens)")
    }

    func testTwoSendersWithTheChannelIsNotAGuess() {
        XCTAssertEqual(NDIFeed.match("N5-C (Channel-NDI)", in: onNetwork), "N5-C (Channel-NDI)")
    }

    func testNothingLikeItStaysAsSaved() {
        XCTAssertEqual(NDIFeed.match("OTHER (Lobby)", in: onNetwork), "OTHER (Lobby)")
        XCTAssertEqual(NDIFeed.match("No brackets", in: onNetwork), "No brackets")
    }
}
