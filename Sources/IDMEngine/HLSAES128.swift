import CommonCrypto
import Darwin
import Foundation

public enum HLSAES128Error: Error, Equatable, Sendable {
    case invalidKeyLength
    case invalidIVLength
    case invalidIV
    case decryptionFailed(Int32)
}

extension HLSAES128Error: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidKeyLength: "HLS AES-128 keys must be 16 bytes"
        case .invalidIVLength: "HLS AES-128 IVs must be 16 bytes"
        case .invalidIV: "HLS AES-128 IV is not a 128-bit hexadecimal value"
        case .decryptionFailed(let status): "HLS AES-128 decryption failed: \(status)"
        }
    }
}

public enum HLSAES128 {
    public static func decrypt(ciphertext: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128 else { throw HLSAES128Error.invalidKeyLength }
        guard iv.count == kCCBlockSizeAES128 else { throw HLSAES128Error.invalidIVLength }
        let outputCapacity = ciphertext.count + kCCBlockSizeAES128
        var output = Data(repeating: 0, count: outputCapacity)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            ciphertext.withUnsafeBytes { ciphertextBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            ciphertextBytes.baseAddress,
                            ciphertext.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw HLSAES128Error.decryptionFailed(status)
        }
        output.removeSubrange(outputLength..<output.count)
        return output
    }

    /// Decrypts a ciphertext file into a plaintext file by streaming with bounded buffers.
    /// The reserved budget covers the App-managed input ciphertext read chunk, the output
    /// plaintext write chunk, and conservative overhead (2 * chunkSize + 64).
    /// Note: CCCryptor's internal system state cannot be measured directly and is outside
    /// the MediaBufferBudget.
    /// Dynamically clamps to 16-byte alignment from the current budget.capacity to prevent
    /// deadlocks under small capacities.
    public static func decrypt(
        sourceURL: URL,
        destinationURL: URL,
        key: Data,
        iv: Data,
        budget: MediaBufferBudget? = nil,
        chunkSize: Int = 64 * 1024
    ) async throws -> Int64 {
        guard key.count == kCCKeySizeAES128 else { throw HLSAES128Error.invalidKeyLength }
        guard iv.count == kCCBlockSizeAES128 else { throw HLSAES128Error.invalidIVLength }

        var cryptorRef: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreate(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding),
                    keyBytes.baseAddress,
                    key.count,
                    ivBytes.baseAddress,
                    &cryptorRef
                )
            }
        }
        guard createStatus == kCCSuccess, let cryptor = cryptorRef else {
            throw HLSAES128Error.decryptionFailed(createStatus)
        }
        defer { CCCryptorRelease(cryptor) }

        let readHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? readHandle.close() }

        var isSuccess = false
        var createdSink: SafeFileDescriptor? = nil
        var destinationCreatedBySelf = false
        defer {
            if !isSuccess {
                try? createdSink?.closeFile()
                if destinationCreatedBySelf {
                    try? FileManager.default.removeItem(at: destinationURL)
                }
            }
        }

        // Dynamically compute a safe effective chunk size so 2*chunk + 64 stays within
        // budget capacity and remains 16-byte aligned
        let effectiveChunkSize: Int
        let maxAccountedBytes: Int64
        if let budget {
            let maxAllowedChunk = max(16, Int((budget.capacity - 64) / 2) & ~15)
            effectiveChunkSize = min(max(16, chunkSize & ~15), maxAllowedChunk)
            maxAccountedBytes = min(budget.capacity, Int64(effectiveChunkSize * 2 + 64))
        } else {
            effectiveChunkSize = max(16, chunkSize & ~15)
            maxAccountedBytes = Int64(effectiveChunkSize * 2 + 64)
        }

        // Critical: acquire the full-pipeline reservation before allocating any memory
        // buffer or reading data
        let reservation: MediaBufferReservation?
        if let budget {
            reservation = try await budget.reserve(bytes: maxAccountedBytes)
        } else {
            reservation = nil
        }
        defer { reservation?.release() }

        let sink = try SafeFileDescriptor(creatingExclusiveAt: destinationURL)
        createdSink = sink
        destinationCreatedBySelf = true
        var totalDecryptedBytes: Int64 = 0

        let outChunkCapacity = effectiveChunkSize + kCCBlockSizeAES128
        var outBuffer = Data(repeating: 0, count: outChunkCapacity)

        do {
            while true {
                try Task.checkCancellation()
                let inData = try readHandle.read(upToCount: effectiveChunkSize) ?? Data()
                if inData.isEmpty { break }

                var dataOutMoved = 0
                let status = outBuffer.withUnsafeMutableBytes { outBytes in
                    inData.withUnsafeBytes { inBytes in
                        CCCryptorUpdate(
                            cryptor,
                            inBytes.baseAddress,
                            inData.count,
                            outBytes.baseAddress,
                            outChunkCapacity,
                            &dataOutMoved
                        )
                    }
                }
                guard status == kCCSuccess else {
                    throw HLSAES128Error.decryptionFailed(status)
                }
                if dataOutMoved > 0 {
                    let chunkToWrite = outBuffer.prefix(dataOutMoved)
                    try sink.writeAll(chunkToWrite)
                    totalDecryptedBytes += Int64(dataOutMoved)
                }
            }

            var finalOutMoved = 0
            let finalStatus = outBuffer.withUnsafeMutableBytes { outBytes in
                CCCryptorFinal(
                    cryptor,
                    outBytes.baseAddress,
                    outChunkCapacity,
                    &finalOutMoved
                )
            }
            guard finalStatus == kCCSuccess else {
                throw HLSAES128Error.decryptionFailed(finalStatus)
            }
            if finalOutMoved > 0 {
                let finalChunk = outBuffer.prefix(finalOutMoved)
                try sink.writeAll(finalChunk)
                totalDecryptedBytes += Int64(finalOutMoved)
            }

            try sink.synchronize()
            try sink.closeFile()
            isSuccess = true
        } catch {
            throw error
        }

        return totalDecryptedBytes
    }

    public static func data(fromIV value: String) throws -> Data {
        let normalized = value.lowercased()
        guard normalized.hasPrefix("0x"), normalized.dropFirst(2).count == 32 else {
            throw HLSAES128Error.invalidIV
        }
        let hex = String(normalized.dropFirst(2))
        var data = Data(capacity: 16)
        var index = hex.startIndex
        for _ in 0..<16 {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw HLSAES128Error.invalidIV
            }
            data.append(byte)
            index = next
        }
        return data
    }

    public static func defaultIV(mediaSequence: Int64) throws -> Data {
        guard mediaSequence >= 0 else { throw HLSAES128Error.invalidIV }
        var value = UInt64(mediaSequence).bigEndian
        var data = Data(repeating: 0, count: 16)
        withUnsafeBytes(of: &value) { bytes in
            data.replaceSubrange(8..<16, with: bytes)
        }
        return data
    }

    public static func iv(
        for unit: HLSDownloadUnit,
        key: HLSEncryptionKey
    ) throws -> Data {
        if let explicit = key.iv {
            return try data(fromIV: explicit)
        }
        guard let sequence = unit.mediaSequence else {
            throw HLSAES128Error.invalidIV
        }
        return try defaultIV(mediaSequence: sequence)
    }
}
