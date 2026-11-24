import XCTest
@testable import CueVideo

final class ShotDeckTests: XCTestCase {
    let cell = CGSize(width: 100, height: 80)

    func testDraggingDownARowLandsFourSlotsOn() {
        var d = ShotDrag(camera: UUID(), page: 0, from: 1, range: 0...15, cell: cell)
        d.moved = CGSize(width: 10, height: 75)
        XCTAssertEqual(d.to, 5)
    }

    func testDraggingReachesTheFourthRow() {
        var d = ShotDrag(camera: UUID(), page: 0, from: 0, range: 0...15, cell: cell)
        d.moved = CGSize(width: 300, height: 240)
        XCTAssertEqual(d.to, 15)
    }

    func testADropStaysInsideItsRun() {
        var d = ShotDrag(camera: UUID(), page: 0, from: 0, range: 0...3, cell: cell)
        d.moved = CGSize(width: 400, height: 80)
        XCTAssertEqual(d.to, 3)
    }

    func testTilesItPassesStepBackAcrossTheRowEnd() {
        var d = ShotDrag(camera: UUID(), page: 0, from: 2, range: 0...15, cell: cell)
        d.moved = CGSize(width: 0, height: 80)  // to slot 6
        XCTAssertEqual(d.to, 6)
        // Slot 4 (second row, left) steps up to slot 3 (top right).
        XCTAssertEqual(d.shift(4), CGSize(width: 300, height: -80))
        XCTAssertEqual(d.shift(3), CGSize(width: -100, height: 0))
        XCTAssertEqual(d.shift(7), .zero)
    }

    func testEveryTileHasItsOwnKey() {
        XCTAssertEqual(ShotDeckState.letters.count, ShotDeckState.perPage)
        XCTAssertEqual(Set(ShotDeckState.keyCodes.values), Set(0..<ShotDeckState.perPage))
        XCTAssertEqual(ShotDeckState.columns * ShotDeckState.rows, ShotDeckState.perPage)
    }
}

final class HeadroomStepperTests: XCTestCase {
    func testStepsCountFromTheStandard() {
        XCTAssertEqual(HeadroomStepper.steps(eyeLine: 0.29, standard: 0.29), 0)
        XCTAssertEqual(HeadroomStepper.steps(eyeLine: 0.25, standard: 0.29), -2)
        XCTAssertEqual(HeadroomStepper.steps(eyeLine: 0.31, standard: 0.29), 1)
        XCTAssertEqual(HeadroomStepper.label(0), "Std")
        XCTAssertEqual(HeadroomStepper.label(1), "+1")
        XCTAssertEqual(HeadroomStepper.label(-2), "\u{2212}2")
    }
}
