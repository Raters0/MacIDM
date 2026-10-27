import Foundation
import os

public struct URLSessionHLSResourceClient: HLSResourceClient, Sendable {
    let requestTimeout: TimeInterval
    let resourceTimeout: TimeInterval
    let unitSafetyCap: Int64
    let scopedSession: TaskScopedSession?

    public init(requestTimeout: TimeInterval = 30, resourceTimeout: TimeInterval = 24 * 60 * 60) {
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.unitSafetyCap = DownloadResourceLimits.maximumMediaUnitBytes
        self.scopedSession = nil
    }

    init(
        requestTimeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 24 * 60 * 60,
        unitSafetyCap: Int64 = DownloadResourceLimits.maximumMediaUnitBytes,
        scopedSession: TaskScopedSession? = nil
    ) {
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.unitSafetyCap = unitSafetyCap
        self.scopedSession = scopedSession
    }

    public func fetch(_ request: HLSFetchRequest) async throws -> HLSFetchResponse {
        let operation = HLSDataFetchOperation(
            request: request,
            requestTimeout: requestTimeout,
            resourceTimeout: resourceTimeout,
            scopedSession: scopedSession
        )
        return try await withTaskCancellationHandler {
            try await operation.run()
        } onCancel: {
            operation.cancel()
        }
    }

    public func streamToFile(
        _ request: HLSFetchRequest,
        to destinationURL: URL,
        budget: MediaBufferBudget,
        control: @escaping @Sendable () -> DownloadControl,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> HLSStreamToFileResult {
        let operation = HLSStreamToFileOperation(
            request: request,
            destinationURL: destinationURL,
            budget: budget,
            requestTimeout: requestTimeout,
            resourceTimeout: resourceTimeout,
            unitSafetyCap: unitSafetyCap,
            control: control,
            scopedSession: scopedSession,
            progress: progress
        )
        return try await withTaskCancellationHandler {
            try await operation.run()
        } onCancel: {
            operation.cancel()
        }
    }
}
