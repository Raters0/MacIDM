import XCTest

@testable import MacIDMApp

final class SystemCompletionActionTests: XCTestCase {
    func testCountdownDurationsByAction() {
        XCTAssertEqual(SystemCompletionAction.none.countdownSeconds, 0)
        XCTAssertEqual(SystemCompletionAction.quitApp.countdownSeconds, 30)
        XCTAssertEqual(SystemCompletionAction.sleep.countdownSeconds, 60)
        XCTAssertEqual(SystemCompletionAction.shutDown.countdownSeconds, 60)
    }

    func testRawValueRoundTripForPersistence() {
        for action in SystemCompletionAction.allCases {
            XCTAssertEqual(
                SystemCompletionAction(rawValue: action.rawValue), action)
        }
        XCTAssertNil(SystemCompletionAction(rawValue: "hibernate"))
    }
}
