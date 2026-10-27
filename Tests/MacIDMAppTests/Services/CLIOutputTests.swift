import Foundation
import IDMEngine
import XCTest

@testable import MacIDMCLI

final class CLIOutputTests: XCTestCase {
    func testTransportFailureIsNetworkErrorNotUsageError() {
        // A permanent connection reset surfaces as URLError after the retry
        // budget is spent. It must be reported as a network failure, not as
        // a mistake in the command the user typed.
        XCTAssertEqual(CLIOutput.errorCode(URLError(.networkConnectionLost)), "NETWORK_ERROR")
        XCTAssertEqual(CLIOutput.errorCode(URLError(.timedOut)), "NETWORK_ERROR")
    }

    func testEngineAndUsageErrorsKeepTheirStableCodes() {
        XCTAssertEqual(CLIOutput.errorCode(IDMError.invalidURL), "INVALID_URL")
        XCTAssertEqual(CLIOutput.errorCode(CLIError.usage("missing url")), "USAGE_ERROR")
        XCTAssertEqual(CLIOutput.errorCode(CLIError.taskNotFound), "TASK_NOT_FOUND")
        XCTAssertEqual(CLIOutput.errorCode(IDMError.storageError("No space left on device", ENOSPC)), "STORAGE_ERROR")
    }
}
