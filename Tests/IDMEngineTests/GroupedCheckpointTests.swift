import XCTest

@testable import IDMEngine

final class GroupedCheckpointTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "macidm-group-commit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try super.tearDownWithError()
    }

    func testDASHBatchMarkCompletedUpdatesContiguousUnitsAtomically() throws {
        let sidecarURL = tempDirectory.appendingPathComponent("test.dash.sidecar")
        let taskID = UUID()
        let units = [
            DASHResumeUnit(fingerprint: "f1", byteCount: nil),
            DASHResumeUnit(fingerprint: "f2", byteCount: nil),
            DASHResumeUnit(fingerprint: "f3", byteCount: nil),
        ]
        let record = DASHResumeRecord(
            formatVersion: 1,
            taskID: taskID,
            manifestFingerprint: "mfp",
            representations: [
                DASHResumeRepresentation(id: "video", units: units)
            ]
        )

        let tracker = try DASHResumeTracker(sidecarURL: sidecarURL, record: record)
        XCTAssertEqual(tracker.completedCount(for: "video"), 0)
        XCTAssertEqual(tracker.completedBytes(for: "video"), 0)

        // Batch mark units 0 and 1
        try tracker.markCompletedBatch(
            representationID: "video",
            units: [(0, 500), (1, 600)]
        )

        XCTAssertEqual(tracker.completedCount(for: "video"), 2)
        XCTAssertEqual(tracker.completedBytes(for: "video"), 1100)

        // Verify sidecar can be reloaded and matches
        let reloadedTracker = try DASHResumeTracker(sidecarURL: sidecarURL, expected: record)
        XCTAssertEqual(reloadedTracker.completedCount(for: "video"), 2)
        XCTAssertEqual(reloadedTracker.completedBytes(for: "video"), 1100)
    }

    func testDASHBatchMarkCompletedRejectsNonContiguousUnit() throws {
        let sidecarURL = tempDirectory.appendingPathComponent("test.dash.sidecar")
        let taskID = UUID()
        let units = [
            DASHResumeUnit(fingerprint: "f1", byteCount: nil),
            DASHResumeUnit(fingerprint: "f2", byteCount: nil),
            DASHResumeUnit(fingerprint: "f3", byteCount: nil),
        ]
        let record = DASHResumeRecord(
            formatVersion: 1,
            taskID: taskID,
            manifestFingerprint: "mfp",
            representations: [
                DASHResumeRepresentation(id: "video", units: units)
            ]
        )

        let tracker = try DASHResumeTracker(sidecarURL: sidecarURL, record: record)

        // Attempt to mark unit 1 without marking unit 0
        XCTAssertThrowsError(
            try tracker.markCompletedBatch(
                representationID: "video",
                units: [(1, 600)]
            )
        )

        XCTAssertEqual(tracker.completedCount(for: "video"), 0)
    }

    func testHLSSequenceCommitterCrossBatchThresholdAndSingleCommit() throws {
        let mainTempURL = tempDirectory.appendingPathComponent("main_cross.hls.download")
        let sidecarURL = tempDirectory.appendingPathComponent("main_cross.hls.sidecar")
        let sink = try RandomAccessSink(url: mainTempURL, totalSize: nil, create: true)

        let paths = HLSTemporaryPaths(
            directory: tempDirectory,
            unitPrefix: "unit-cross-",
            temporary: mainTempURL,
            sidecar: sidecarURL,
            baseName: "main_cross"
        )
        let fileID = try HLSResumeStore.fileIdentity(mainTempURL)
        let taskID = UUID()

        let totalUnits = 32
        let unitByteSize: Int64 = 256 * 1024  // 256 KiB each -> 32 units = 8 MiB
        let units = (0..<totalUnits).map { i in
            HLSDownloadUnit(
                index: i,
                kind: .media,
                url: URL(string: "https://example.com/seg\(i).ts")!,
                duration: 2.0
            )
        }
        let plan = HLSDownloadPlan(
            playlistURL: URL(string: "https://example.com/playlist.m3u8")!,
            mediaSequence: 0,
            isVideoOnDemand: true,
            totalDuration: Double(totalUnits) * 2.0,
            units: units
        )
        var mutableState = HLSResumeState(taskID: taskID, plan: plan)

        // 8 MiB threshold, 60s timeout
        let committer = HLSSequenceCommitter(
            initialExpectedIndex: 0,
            sink: sink,
            paths: paths,
            fileIdentity: fileID,
            initialOutputBytes: 0,
            groupCommitBytesThreshold: 8 * 1024 * 1024,
            groupCommitTimeThreshold: .seconds(60)
        )

        let dummyData = Data(repeating: 0x7E, count: Int(unitByteSize))

        // Phase 1: Feed 10 batches (1 unit per batch = 256 KiB each, total 2.5 MiB < 8 MiB)
        for i in 0..<10 {
            let uURL = paths.unitTemporary(index: i)
            try dummyData.write(to: uURL)
            let committed = try committer.accept(
                completedRef: HLSCompletedUnitDiskRef(index: i, tempURL: uURL, byteCount: unitByteSize),
                mutableState: &mutableState
            )
            XCTAssertEqual(committed.count, 0, "Below threshold must not trigger group commit")
            XCTAssertEqual(committer.stats.syncCount, 0, "No fsync before threshold")
            XCTAssertEqual(committer.stats.sidecarWriteCount, 0, "No sidecar write before threshold")
            XCTAssertEqual(committer.uncommittedStagedCount, i + 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: uURL.path))
        }

        // Phase 2: Feed next 21 units (units 10 to 30, total 31 units = 7.75 MiB < 8 MiB)
        for i in 10..<31 {
            let uURL = paths.unitTemporary(index: i)
            try dummyData.write(to: uURL)
            let committed = try committer.accept(
                completedRef: HLSCompletedUnitDiskRef(index: i, tempURL: uURL, byteCount: unitByteSize),
                mutableState: &mutableState
            )
            XCTAssertEqual(committed.count, 0)
            XCTAssertEqual(committer.stats.syncCount, 0)
            XCTAssertEqual(committer.stats.sidecarWriteCount, 0)
        }

        // Phase 3: Feed 32nd unit (unit 31) -> exactly 8 MiB -> Group Commit triggers!
        let lastURL = paths.unitTemporary(index: 31)
        try dummyData.write(to: lastURL)
        let committedAtThreshold = try committer.accept(
            completedRef: HLSCompletedUnitDiskRef(index: 31, tempURL: lastURL, byteCount: unitByteSize),
            mutableState: &mutableState
        )
        XCTAssertEqual(committedAtThreshold.count, 32, "Exactly 32 units committed at 8 MiB threshold")
        XCTAssertEqual(committer.stats.syncCount, 1, "Exactly 1 fsync executed")
        XCTAssertEqual(committer.stats.sidecarWriteCount, 1, "Exactly 1 sidecar write executed")
        XCTAssertEqual(committer.uncommittedStagedCount, 0)
        XCTAssertEqual(committer.committedOutputBytes, 8 * 1024 * 1024)

        // All 32 staged unit temporary files are batch-unlinked
        for i in 0..<32 {
            let uURL = paths.unitTemporary(index: i)
            XCTAssertFalse(FileManager.default.fileExists(atPath: uURL.path), "Unit temp \(i) should be deleted")
        }

        // Sidecar is valid on disk
        let diskRecord = try HLSResumeStore.read(from: sidecarURL)
        XCTAssertEqual(diskRecord.units.filter { $0.completed }.count, 32)
    }

    func testHLSSequenceCommitterControllableClockTimeThreshold() throws {
        let mainTempURL = tempDirectory.appendingPathComponent("main_cclock.hls.download")
        let sidecarURL = tempDirectory.appendingPathComponent("main_cclock.hls.sidecar")
        let sink = try RandomAccessSink(url: mainTempURL, totalSize: nil, create: true)

        let paths = HLSTemporaryPaths(
            directory: tempDirectory,
            unitPrefix: "unit-cclock-",
            temporary: mainTempURL,
            sidecar: sidecarURL,
            baseName: "main_cclock"
        )
        let fileID = try HLSResumeStore.fileIdentity(mainTempURL)
        let taskID = UUID()

        let units = (0..<4).map { i in
            HLSDownloadUnit(
                index: i,
                kind: .media,
                url: URL(string: "https://example.com/seg\(i).ts")!,
                duration: 2.0
            )
        }
        let plan = HLSDownloadPlan(
            playlistURL: URL(string: "https://example.com/playlist.m3u8")!,
            mediaSequence: 0,
            isVideoOnDemand: true,
            totalDuration: 8.0,
            units: units
        )
        var mutableState = HLSResumeState(taskID: taskID, plan: plan)

        final class MockClock: @unchecked Sendable {
            private let lock = NSLock()
            private var _now = ContinuousClock.now

            var now: ContinuousClock.Instant {
                lock.lock()
                defer { lock.unlock() }
                return _now
            }

            func advance(by duration: Duration) {
                lock.lock()
                defer { lock.unlock() }
                _now += duration
            }
        }

        let mockClock = MockClock()

        let committer = HLSSequenceCommitter(
            initialExpectedIndex: 0,
            sink: sink,
            paths: paths,
            fileIdentity: fileID,
            initialOutputBytes: 0,
            groupCommitBytesThreshold: 100 * 1024 * 1024,
            groupCommitTimeThreshold: .seconds(5),
            nowProvider: { mockClock.now }
        )

        let data100 = Data(repeating: 0x23, count: 100)
        let u0URL = paths.unitTemporary(index: 0)
        try data100.write(to: u0URL)

        // Step 1: Unit 0 accepted at t=0 -> elapsed 0s < 5s threshold -> no commit
        let c0 = try committer.accept(
            completedRef: HLSCompletedUnitDiskRef(index: 0, tempURL: u0URL, byteCount: 100),
            mutableState: &mutableState
        )
        XCTAssertEqual(c0.count, 0)
        XCTAssertEqual(committer.stats.syncCount, 0)

        // Step 2: Advance virtual clock by 6 seconds without any real sleep
        mockClock.advance(by: .seconds(6))

        let u1URL = paths.unitTemporary(index: 1)
        try data100.write(to: u1URL)

        // Step 3: Unit 1 accepted at t=6s -> threshold 5s exceeded -> Group Commit triggers!
        let c1 = try committer.accept(
            completedRef: HLSCompletedUnitDiskRef(index: 1, tempURL: u1URL, byteCount: 100),
            mutableState: &mutableState
        )
        XCTAssertEqual(c1.count, 2, "Both units committed due to virtual clock time threshold")
        XCTAssertEqual(committer.stats.syncCount, 1)
        XCTAssertEqual(committer.stats.sidecarWriteCount, 1)
    }

    func testHLSSequenceCommitterSinkSynchronizeFailureRollsBackAndExposesError() throws {
        let mainTempURL = tempDirectory.appendingPathComponent("main_sync_err.hls.download")
        let sidecarURL = tempDirectory.appendingPathComponent("main_sync_err.hls.sidecar")
        let sink = try RandomAccessSink(url: mainTempURL, totalSize: nil, create: true)

        let paths = HLSTemporaryPaths(
            directory: tempDirectory,
            unitPrefix: "unit-sync-err-",
            temporary: mainTempURL,
            sidecar: sidecarURL,
            baseName: "main_sync_err"
        )
        let fileID = try HLSResumeStore.fileIdentity(mainTempURL)
        let taskID = UUID()

        let units = (0..<2).map { i in
            HLSDownloadUnit(
                index: i,
                kind: .media,
                url: URL(string: "https://example.com/seg\(i).ts")!,
                duration: 2.0
            )
        }
        let plan = HLSDownloadPlan(
            playlistURL: URL(string: "https://example.com/playlist.m3u8")!,
            mediaSequence: 0,
            isVideoOnDemand: true,
            totalDuration: 4.0,
            units: units
        )
        var mutableState = HLSResumeState(taskID: taskID, plan: plan)

        let committer = HLSSequenceCommitter(
            initialExpectedIndex: 0,
            sink: sink,
            paths: paths,
            fileIdentity: fileID,
            initialOutputBytes: 0,
            groupCommitBytesThreshold: 100,  // Commit at 100 bytes
            groupCommitTimeThreshold: .seconds(60),
            sinkSynchronizer: { _ in
                throw IDMError.storageError("Injected fsync failure on disk")
            }
        )

        let data150 = Data(repeating: 0x55, count: 150)
        let u0URL = paths.unitTemporary(index: 0)
        try data150.write(to: u0URL)

        // Accepting unit 0 reaches 150B >= 100B threshold, triggering group commit which fails on fsync
        XCTAssertThrowsError(
            try committer.accept(
                completedRef: HLSCompletedUnitDiskRef(index: 0, tempURL: u0URL, byteCount: 150),
                mutableState: &mutableState
            )
        ) { error in
            guard let idm = error as? IDMError, case .storageError = idm else {
                XCTFail("Expected storageError, got \(error)")
                return
            }
        }

        // Verify state is safely rolled back
        XCTAssertEqual(committer.committedOutputBytes, 0)
        XCTAssertEqual(mutableState.units.filter(\.completed).count, 0)
        XCTAssertEqual(committer.stats.sidecarWriteCount, 0, "Sidecar must not be written if fsync failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path))

        // Physical file must be truncated back to committed 0 bytes
        let attributes = try FileManager.default.attributesOfItem(atPath: mainTempURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value
        XCTAssertEqual(fileSize, 0, "Sink file must be truncated back to committed 0 boundary")

        // Staged unit temporary file MUST be preserved on disk so it can be retried!
        XCTAssertTrue(FileManager.default.fileExists(atPath: u0URL.path), "Unit temp file must be preserved for retry")
    }

    func testHLSSequenceCommitterSidecarWriteFailureRollsBackAndExposesError() throws {
        let mainTempURL = tempDirectory.appendingPathComponent("main_sc_err.hls.download")
        let sidecarURL = tempDirectory.appendingPathComponent("main_sc_err.hls.sidecar")
        let sink = try RandomAccessSink(url: mainTempURL, totalSize: nil, create: true)

        let paths = HLSTemporaryPaths(
            directory: tempDirectory,
            unitPrefix: "unit-sc-err-",
            temporary: mainTempURL,
            sidecar: sidecarURL,
            baseName: "main_sc_err"
        )
        let fileID = try HLSResumeStore.fileIdentity(mainTempURL)
        let taskID = UUID()

        let units = (0..<2).map { i in
            HLSDownloadUnit(
                index: i,
                kind: .media,
                url: URL(string: "https://example.com/seg\(i).ts")!,
                duration: 2.0
            )
        }
        let plan = HLSDownloadPlan(
            playlistURL: URL(string: "https://example.com/playlist.m3u8")!,
            mediaSequence: 0,
            isVideoOnDemand: true,
            totalDuration: 4.0,
            units: units
        )
        var mutableState = HLSResumeState(taskID: taskID, plan: plan)

        let committer = HLSSequenceCommitter(
            initialExpectedIndex: 0,
            sink: sink,
            paths: paths,
            fileIdentity: fileID,
            initialOutputBytes: 0,
            groupCommitBytesThreshold: 100,
            groupCommitTimeThreshold: .seconds(60),
            sidecarWriter: { _, _ in
                throw IDMError.storageError("Injected sidecar write failure")
            }
        )

        let data150 = Data(repeating: 0x66, count: 150)
        let u0URL = paths.unitTemporary(index: 0)
        try data150.write(to: u0URL)

        XCTAssertThrowsError(
            try committer.accept(
                completedRef: HLSCompletedUnitDiskRef(index: 0, tempURL: u0URL, byteCount: 150),
                mutableState: &mutableState
            )
        ) { error in
            guard let idm = error as? IDMError, case .storageError = idm else {
                XCTFail("Expected storageError, got \(error)")
                return
            }
        }

        XCTAssertEqual(committer.committedOutputBytes, 0)
        XCTAssertEqual(mutableState.units.filter(\.completed).count, 0)
        XCTAssertEqual(committer.stats.sidecarWriteCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path))

        let attributes = try FileManager.default.attributesOfItem(atPath: mainTempURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value
        XCTAssertEqual(fileSize, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: u0URL.path))
    }

    func testHLSSequenceCommitterQuiesceFailureExposesStorageErrorWithoutRetrying() throws {
        let mainTempURL = tempDirectory.appendingPathComponent("main_q_err.hls.download")
        let sidecarURL = tempDirectory.appendingPathComponent("main_q_err.hls.sidecar")
        let sink = try RandomAccessSink(url: mainTempURL, totalSize: nil, create: true)

        let paths = HLSTemporaryPaths(
            directory: tempDirectory,
            unitPrefix: "unit-q-err-",
            temporary: mainTempURL,
            sidecar: sidecarURL,
            baseName: "main_q_err"
        )
        let fileID = try HLSResumeStore.fileIdentity(mainTempURL)
        let taskID = UUID()

        let units = (0..<2).map { i in
            HLSDownloadUnit(
                index: i,
                kind: .media,
                url: URL(string: "https://example.com/seg\(i).ts")!,
                duration: 2.0
            )
        }
        let plan = HLSDownloadPlan(
            playlistURL: URL(string: "https://example.com/playlist.m3u8")!,
            mediaSequence: 0,
            isVideoOnDemand: true,
            totalDuration: 4.0,
            units: units
        )
        var mutableState = HLSResumeState(taskID: taskID, plan: plan)

        let committer = HLSSequenceCommitter(
            initialExpectedIndex: 0,
            sink: sink,
            paths: paths,
            fileIdentity: fileID,
            initialOutputBytes: 0,
            groupCommitBytesThreshold: 100 * 1024 * 1024,
            groupCommitTimeThreshold: .seconds(600),
            sidecarWriter: { _, _ in
                throw IDMError.storageError("Quiesce atomic sidecar write failed")
            }
        )

        let data100 = Data(repeating: 0x77, count: 100)
        let u0URL = paths.unitTemporary(index: 0)
        try data100.write(to: u0URL)
        _ = try committer.accept(
            completedRef: HLSCompletedUnitDiskRef(index: 0, tempURL: u0URL, byteCount: 100),
            mutableState: &mutableState
        )
        XCTAssertEqual(committer.uncommittedStagedCount, 1)

        // Quiesce is called on pause/cancel: must propagate error without swallowed exception
        XCTAssertThrowsError(try committer.quiesce(mutableState: &mutableState)) { error in
            guard let idm = error as? IDMError, case .storageError = idm else {
                XCTFail("Expected storageError, got \(error)")
                return
            }
        }

        XCTAssertEqual(committer.committedOutputBytes, 0)
        XCTAssertEqual(mutableState.units.filter(\.completed).count, 0)
    }

    func testHLSSequenceCommitterQuiesceOnPauseCancel() throws {
        let mainTempURL = tempDirectory.appendingPathComponent("main_quiesce.hls.download")
        let sidecarURL = tempDirectory.appendingPathComponent("main_quiesce.hls.sidecar")
        let sink = try RandomAccessSink(url: mainTempURL, totalSize: nil, create: true)

        let paths = HLSTemporaryPaths(
            directory: tempDirectory,
            unitPrefix: "unit-q-",
            temporary: mainTempURL,
            sidecar: sidecarURL,
            baseName: "main_quiesce"
        )
        let fileID = try HLSResumeStore.fileIdentity(mainTempURL)
        let taskID = UUID()

        let units = (0..<3).map { i in
            HLSDownloadUnit(
                index: i,
                kind: .media,
                url: URL(string: "https://example.com/seg\(i).ts")!,
                duration: 2.0
            )
        }
        let plan = HLSDownloadPlan(
            playlistURL: URL(string: "https://example.com/playlist.m3u8")!,
            mediaSequence: 0,
            isVideoOnDemand: true,
            totalDuration: 6.0,
            units: units
        )
        var mutableState = HLSResumeState(taskID: taskID, plan: plan)

        // Huge 100MB threshold so it won't auto-commit
        let committer = HLSSequenceCommitter(
            initialExpectedIndex: 0,
            sink: sink,
            paths: paths,
            fileIdentity: fileID,
            initialOutputBytes: 0,
            groupCommitBytesThreshold: 100 * 1024 * 1024,
            groupCommitTimeThreshold: .seconds(600)
        )

        let data200 = Data(repeating: 0x4B, count: 200)
        for i in 0..<3 {
            let uURL = paths.unitTemporary(index: i)
            try data200.write(to: uURL)
            _ = try committer.accept(
                completedRef: HLSCompletedUnitDiskRef(index: i, tempURL: uURL, byteCount: 200),
                mutableState: &mutableState
            )
        }

        XCTAssertEqual(committer.uncommittedStagedCount, 3)
        XCTAssertEqual(committer.committedOutputBytes, 0)

        // User pauses/cancels: engine triggers quiesce
        let committedOnQuiesce = try committer.quiesce(mutableState: &mutableState)
        XCTAssertEqual(committedOnQuiesce.count, 3)
        XCTAssertEqual(committer.committedOutputBytes, 600)
        XCTAssertEqual(committer.uncommittedStagedCount, 0)

        // Verify sidecar record on disk
        let diskRecord = try HLSResumeStore.read(from: sidecarURL)
        XCTAssertEqual(diskRecord.units.filter { $0.completed }.count, 3)
    }

    func testHLSResumeBoundaryComponentTruncatesUnconfirmedTail() throws {
        let mainTempURL = tempDirectory.appendingPathComponent("main_crash.hls.download")
        let sidecarURL = tempDirectory.appendingPathComponent("main_crash.hls.sidecar")

        // Create main file with 1200 bytes
        let initialData = Data(repeating: 0xAA, count: 1200)
        try initialData.write(to: mainTempURL)

        // Create sidecar that only confirmed 600 bytes (units 0 and 1 completed, each 300B)
        let taskID = UUID()
        let units = (0..<4).map { i in
            HLSDownloadUnit(
                index: i,
                kind: .media,
                url: URL(string: "https://example.com/seg\(i).ts")!,
                duration: 2.0
            )
        }
        let plan = HLSDownloadPlan(
            playlistURL: URL(string: "https://example.com/playlist.m3u8")!,
            mediaSequence: 0,
            isVideoOnDemand: true,
            totalDuration: 8.0,
            units: units
        )
        var state = HLSResumeState(taskID: taskID, plan: plan)
        try state.markCompleted(unitIndex: 0, receivedBytes: 300)
        try state.markCompleted(unitIndex: 1, receivedBytes: 300)
        let fileID = try HLSResumeStore.fileIdentity(mainTempURL)
        try HLSResumeStore.write(state.record(fileIdentity: fileID), to: sidecarURL)

        // Open sink as downloadHLS does on resume
        let outputBytes: Int64 = state.units.filter(\.completed).compactMap(\.receivedBytes).reduce(0, +)
        XCTAssertEqual(outputBytes, 600)

        // Check file size before truncation
        let initialSize = try HLSResumeStore.fileSize(mainTempURL)
        XCTAssertEqual(initialSize, 1200)

        // Resume boundary logic: if actualSize > outputBytes, truncate to confirmed boundary
        let sink = try RandomAccessSink(url: mainTempURL, totalSize: nil, create: false)
        if initialSize > outputBytes {
            try sink.truncate(to: outputBytes)
            try sink.synchronize()
        }

        // Sink is physically truncated back to 600 bytes
        let finalSize = try HLSResumeStore.fileSize(mainTempURL)
        XCTAssertEqual(finalSize, 600)
    }

    func testDASHResumeTrackerAndFileBoundaryComponentRollback() throws {
        let sidecarURL = tempDirectory.appendingPathComponent("fault.dash.sidecar")
        let mainTempURL = tempDirectory.appendingPathComponent("fault.dash.download")
        let taskID = UUID()

        let units = (0..<4).map { i in
            DASHResumeUnit(fingerprint: "u\(i)", byteCount: nil)
        }
        let record = DASHResumeRecord(
            formatVersion: 1,
            taskID: taskID,
            manifestFingerprint: "dash_fp",
            representations: [
                DASHResumeRepresentation(id: "video", units: units)
            ]
        )

        let tracker = try DASHResumeTracker(sidecarURL: sidecarURL, record: record)

        // Unit 0 committed (400 bytes)
        let initialSink = try SafeFileDescriptor(creatingExclusiveAt: mainTempURL)
        try initialSink.closeFile()
        let handle = try FileHandle(forWritingTo: mainTempURL)
        try handle.write(contentsOf: Data(repeating: 0x11, count: 400))
        _ = fsync(handle.fileDescriptor)
        try tracker.markCompletedBatch(representationID: "video", units: [(0, 400)])

        XCTAssertEqual(tracker.completedCount(for: "video"), 1)
        XCTAssertEqual(tracker.completedBytes(for: "video"), 400)

        // Staging unit 1 (300 bytes) onto disk -> file has 700 bytes
        try handle.seek(toOffset: 400)
        try handle.write(contentsOf: Data(repeating: 0x22, count: 300))

        // Fault occurs during commit of unit 1 -> rollback truncate back to 400
        let committedBoundaryOffset: Int64 = 400
        try handle.truncate(atOffset: UInt64(committedBoundaryOffset))
        _ = fsync(handle.fileDescriptor)
        try handle.close()

        // Assert physical file on disk is strictly 400 bytes
        let attr = try FileManager.default.attributesOfItem(atPath: mainTempURL.path)
        XCTAssertEqual((attr[.size] as? NSNumber)?.int64Value, 400)

        // Assert sidecar still has only unit 0 confirmed
        let reloaded = try DASHResumeTracker(sidecarURL: sidecarURL, expected: record)
        XCTAssertEqual(reloaded.completedCount(for: "video"), 1)
        XCTAssertEqual(reloaded.completedBytes(for: "video"), 400)
    }
}
