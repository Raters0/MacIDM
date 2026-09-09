import Foundation

public enum NativeMessagingFraming {
    public static func readMessage(from handle: FileHandle) throws -> Data? {
        let header = try read(upTo: 4, from: handle)
        if header.isEmpty { return nil }
        guard header.count == 4 else { throw BridgeError.connectionClosed }
        let length = header.withUnsafeBytes { rawBuffer -> UInt32 in
            UInt32(littleEndian: rawBuffer.loadUnaligned(as: UInt32.self))
        }
        guard length <= MacIDMProtocol.maximumMessageSize else {
            throw BridgeError.messageTooLarge
        }
        let body = try read(upTo: Int(length), from: handle)
        guard body.count == Int(length) else { throw BridgeError.connectionClosed }
        return body
    }

    public static func writeMessage(_ data: Data, to handle: FileHandle) throws {
        guard data.count <= MacIDMProtocol.maximumMessageSize else {
            throw BridgeError.messageTooLarge
        }
        var length = UInt32(data.count).littleEndian
        try withUnsafeBytes(of: &length) { bytes in
            try handle.write(contentsOf: Data(bytes))
        }
        try handle.write(contentsOf: data)
    }

    private static func read(upTo count: Int, from handle: FileHandle) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let chunk = try handle.read(upToCount: count - result.count), !chunk.isEmpty else {
                break
            }
            result.append(chunk)
        }
        return result
    }
}
