import Foundation

actor HLSKeyCache {
    private var values: [String: Data] = [:]

    func value(
        for key: HLSEncryptionKey,
        client: any HLSResourceClient,
        requestContext: DownloadRequestContext?,
        contextOriginURL: URL,
        control: @escaping @Sendable () -> DownloadControl
    ) async throws -> Data {
        let identity = "\(key.url.absoluteString)|\(key.iv ?? "")"
        if let value = values[identity] { return value }
        let response = try await client.fetch(
            HLSFetchRequest(
                url: key.url,
                requestContext: requestContext,
                contextOriginURL: contextOriginURL,
                control: control
            ))
        guard response.statusCode == 200, response.data.count == 16 else {
            throw HLSAES128Error.invalidKeyLength
        }
        values[identity] = response.data
        return response.data
    }
}
