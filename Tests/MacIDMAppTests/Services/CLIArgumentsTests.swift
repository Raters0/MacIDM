import XCTest

@testable import MacIDMCLI

final class CLIArgumentsTests: XCTestCase {
    private func parse(_ arguments: [String]) throws -> CLIArguments.Command {
        try CLIArguments(arguments).command
    }

    func testAddMissingURLValueIsRejectedInsteadOfBecomingTheURL() {
        // URL(string: "--output") succeeds, so an option-looking token used to
        // be swallowed as the positional URL and produced a garbage task.
        XCTAssertThrowsError(try parse(["add", "--output"])) { error in
            guard case CLIError.usage(let message) = error else {
                return XCTFail("expected usage error")
            }
            XCTAssertTrue(message.contains("--output"))
        }
    }

    func testAddURLSwallowingForegroundFlagIsRejected() {
        XCTAssertThrowsError(try parse(["add", "--foreground"]))
    }

    func testInspectRejectsOptionTokenAsURL() {
        XCTAssertThrowsError(try parse(["inspect", "--media-kind"]))
    }

    func testAddDuplicateOutputOptionIsRejected() {
        XCTAssertThrowsError(
            try parse(["add", "https://example.com/file.iso", "--output", "/tmp/a", "--output", "/tmp/b"])
        ) { error in
            guard case CLIError.usage(let message) = error else {
                return XCTFail("expected usage error")
            }
            XCTAssertTrue(message.contains("Duplicate"))
        }
    }

    func testAddDuplicateForegroundFlagIsRejected() {
        XCTAssertThrowsError(try parse(["add", "https://example.com/file.iso", "--foreground", "--foreground"]))
    }

    func testAddMissingOutputValueIsReportedAsMissingValue() {
        // Used to surface as "Unknown add option: --output", which pointed at
        // the wrong problem.
        XCTAssertThrowsError(try parse(["add", "https://example.com/file.iso", "--output"])) { error in
            guard case CLIError.usage(let message) = error else {
                return XCTFail("expected usage error")
            }
            XCTAssertTrue(message.contains("requires a value"))
        }
    }

    func testWellFormedAddStillParses() throws {
        guard
            case .add(let url, let output, let parallel, let hash, let foreground) =
                try parse(["add", "https://example.com/file.iso", "--output", "/tmp/f.iso", "--parallel", "4"])
        else {
            return XCTFail("expected add command")
        }
        XCTAssertEqual(url, "https://example.com/file.iso")
        XCTAssertEqual(output?.path, "/tmp/f.iso")
        XCTAssertEqual(parallel, 4)
        XCTAssertNil(hash)
        XCTAssertFalse(foreground)
    }
}
