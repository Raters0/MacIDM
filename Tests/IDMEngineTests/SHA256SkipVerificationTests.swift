import CryptoKit
import XCTest

@testable import IDMEngine

private final class HashCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var val = 0

    func increment() {
        lock.lock()
        val += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return val
    }
}

final class SHA256SkipVerificationTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "macidm-verifier-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try super.tearDownWithError()
    }

    func testConstantTimeEquals() {
        let h1 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let h2 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let h3 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b854"  // last char differs
        let h4 = "e3b0c44298fc1c14"  // shorter

        XCTAssertTrue(FileSupport.constantTimeEquals(h1, h2))
        XCTAssertFalse(FileSupport.constantTimeEquals(h1, h3))
        XCTAssertFalse(FileSupport.constantTimeEquals(h1, h4))
    }

    func testArtifactVerifierZeroHasherCallsWhenExpectedNil() throws {
        let tempFile = tempDirectory.appendingPathComponent("temp_payload.bin")
        let destFile = tempDirectory.appendingPathComponent("final_output.bin")
        let sidecarFile = tempDirectory.appendingPathComponent("temp_payload.macidm")

        let payloadData = Data("macidm zero hash test".utf8)
        try payloadData.write(to: tempFile)
        try Data("sidecar".utf8).write(to: sidecarFile)

        let counter = HashCallCounter()
        let verifier = ArtifactVerifier(hasher: { url in
            counter.increment()
            return try FileSupport.sha256(url: url)
        })

        let result = try verifier.verifyAndPublish(
            temporary: tempFile,
            destination: destFile,
            expectedSHA256: nil,
            sidecar: sidecarFile,
            byteCount: Int64(payloadData.count),
            usedParallelRequests: 4,
            resumed: false,
            defaultVerification: "range-and-size"
        )

        XCTAssertEqual(counter.count, 0, "Hasher must be called 0 times when expectedSHA256 is nil")
        XCTAssertNil(result.sha256)
        XCTAssertEqual(result.verification, "range-and-size")
        XCTAssertEqual(result.byteCount, Int64(payloadData.count))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarFile.path))
    }

    func testArtifactVerifierSingleHasherCallWhenExpectedProvided() throws {
        let tempFile = tempDirectory.appendingPathComponent("temp_payload_exp.bin")
        let destFile = tempDirectory.appendingPathComponent("final_output_exp.bin")

        let payloadData = Data("macidm expected hash test".utf8)
        try payloadData.write(to: tempFile)

        let realHash = try FileSupport.sha256(url: tempFile)
        let counter = HashCallCounter()
        let verifier = ArtifactVerifier(hasher: { url in
            counter.increment()
            return try FileSupport.sha256(url: url)
        })

        let result = try verifier.verifyAndPublish(
            temporary: tempFile,
            destination: destFile,
            expectedSHA256: realHash,
            byteCount: Int64(payloadData.count),
            usedParallelRequests: 2,
            resumed: false
        )

        XCTAssertEqual(counter.count, 1, "Hasher must be called exactly 1 time when expectedSHA256 is non-nil")
        XCTAssertEqual(result.sha256, realHash)
        XCTAssertEqual(result.verification, "sha256")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFile.path))
    }

    func testArtifactVerifierFailClosedAndTemporaryCleanupOnMismatch() throws {
        let tempFile = tempDirectory.appendingPathComponent("temp_payload_mismatch.bin")
        let destFile = tempDirectory.appendingPathComponent("final_output_mismatch.bin")

        let payloadData = Data("malicious or corrupted bytes".utf8)
        try payloadData.write(to: tempFile)

        let expectedBadHash = "0000000000000000000000000000000000000000000000000000000000000000"
        let counter = HashCallCounter()
        let verifier = ArtifactVerifier(hasher: { url in
            counter.increment()
            return try FileSupport.sha256(url: url)
        })

        XCTAssertThrowsError(
            try verifier.verifyAndPublish(
                temporary: tempFile,
                destination: destFile,
                expectedSHA256: expectedBadHash,
                byteCount: Int64(payloadData.count),
                usedParallelRequests: 1,
                resumed: false
            )
        ) { error in
            guard case IDMError.verificationFailed = error else {
                XCTFail("Expected verificationFailed error, got \(error)")
                return
            }
        }

        XCTAssertEqual(counter.count, 1, "Hasher was invoked once before rejecting")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destFile.path), "Destination must NOT be created")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFile.path), "Temporary file must be deleted")
    }

    func testDownloadResultRetainsProperties() {
        guard let url = URL(string: "file:///tmp/test.bin") else {
            XCTFail("Invalid URL")
            return
        }

        let result = DownloadResult(
            destination: url,
            byteCount: 1024,
            sha256: "some_sha",
            usedParallelRequests: 4,
            resumed: false,
            verification: "sha256"
        )

        XCTAssertEqual(result.sha256, "some_sha")
        XCTAssertEqual(result.verification, "sha256")
    }
}
