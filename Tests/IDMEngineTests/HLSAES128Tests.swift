import Foundation
import XCTest

@testable import IDMEngine

final class HLSAES128Tests: XCTestCase {
    func testDecryptsAES128CBCWithPKCS7Padding() throws {
        let key = try Data(hex: "2b7e151628aed2a6abf7158809cf4f3c")
        let iv = try Data(hex: "000102030405060708090a0b0c0d0e0f")
        let ciphertext = try Data(hex: "e40d57c71a722616a61cbb2988b693cf")

        let plaintext = try HLSAES128.decrypt(ciphertext: ciphertext, key: key, iv: iv)

        XCTAssertEqual(plaintext, Data("MacIDM AES test".utf8))
    }

    func testParsesExplicitAndDefaultIVs() throws {
        XCTAssertEqual(
            try HLSAES128.data(fromIV: "0X0000000000000000000000000000002A"),
            try Data(hex: "0000000000000000000000000000002a")
        )
        XCTAssertEqual(
            try HLSAES128.defaultIV(mediaSequence: 42),
            try Data(hex: "0000000000000000000000000000002a")
        )

        let unit = HLSDownloadUnit(
            index: 1,
            kind: .media,
            url: URL(string: "https://cdn.example.test/1.ts")!,
            duration: 4,
            mediaSequence: 42
        )
        let key = HLSEncryptionKey(url: URL(string: "https://cdn.example.test/key.bin")!)
        XCTAssertEqual(try HLSAES128.iv(for: unit, key: key), try Data(hex: "0000000000000000000000000000002a"))
    }

    func testRejectsInvalidKeyAndIVInputs() throws {
        XCTAssertThrowsError(
            try HLSAES128.decrypt(
                ciphertext: Data([0]),
                key: Data(repeating: 0, count: 15),
                iv: Data(repeating: 0, count: 16)
            )
        ) { error in
            XCTAssertEqual(error as? HLSAES128Error, .invalidKeyLength)
        }
        XCTAssertThrowsError(try HLSAES128.data(fromIV: "0x1234")) { error in
            XCTAssertEqual(error as? HLSAES128Error, .invalidIV)
        }
        XCTAssertThrowsError(try HLSAES128.defaultIV(mediaSequence: -1)) { error in
            XCTAssertEqual(error as? HLSAES128Error, .invalidIV)
        }
    }
}

private extension Data {
    init(hex: String) throws {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count.isMultiple(of: 2) else {
            throw HLSAES128Error.invalidIV
        }
        var data = Data(capacity: normalized.count / 2)
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            guard let byte = UInt8(normalized[index..<next], radix: 16) else {
                throw HLSAES128Error.invalidIV
            }
            data.append(byte)
            index = next
        }
        self = data
    }
}
