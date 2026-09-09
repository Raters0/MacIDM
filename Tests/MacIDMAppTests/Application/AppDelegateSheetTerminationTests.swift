import AppKit
import XCTest

@testable import MacIDMApp

@MainActor
final class AppDelegateSheetTerminationTests: XCTestCase {
    /// Windows are never shown; they only serve as identity tokens for the
    /// injectable parent map (real `sheetParent` relationships would need
    /// live sheet presentation inside the test process).
    private func makeWindow() -> NSWindow {
        NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
    }

    func testNoSheetsProduceEmptyEndingOrder() {
        XCTAssertTrue(AppDelegate.orderedForEnding([]).isEmpty)
    }

    func testSingleSheetKeepsSoloEntry() {
        let sheet = makeWindow()
        XCTAssertEqual(
            AppDelegate.orderedForEnding([sheet]).map(ObjectIdentifier.init),
            [ObjectIdentifier(sheet)]
        )
    }

    func testNestedSheetsEndDeepestFirst() {
        let main = makeWindow()
        let settingsSheet = makeWindow()
        let cookieSheet = makeWindow()
        let parents: [ObjectIdentifier: NSWindow] = [
            ObjectIdentifier(settingsSheet): main,
            ObjectIdentifier(cookieSheet): settingsSheet,
        ]
        // The settings sheet is listed first on purpose: the ordering must
        // come from depth, not from the input order.
        let ordered = AppDelegate.orderedForEnding([settingsSheet, cookieSheet]) {
            parents[ObjectIdentifier($0)]
        }
        XCTAssertEqual(
            ordered.map(ObjectIdentifier.init),
            [ObjectIdentifier(cookieSheet), ObjectIdentifier(settingsSheet)]
        )
    }

    func testSiblingSheetsKeepBothEntries() {
        let main = makeWindow()
        let first = makeWindow()
        let second = makeWindow()
        let parents: [ObjectIdentifier: NSWindow] = [
            ObjectIdentifier(first): main,
            ObjectIdentifier(second): main,
        ]
        let ordered = AppDelegate.orderedForEnding([first, second]) {
            parents[ObjectIdentifier($0)]
        }
        XCTAssertEqual(
            Set(ordered.map(ObjectIdentifier.init)),
            [ObjectIdentifier(first), ObjectIdentifier(second)]
        )
    }
}
