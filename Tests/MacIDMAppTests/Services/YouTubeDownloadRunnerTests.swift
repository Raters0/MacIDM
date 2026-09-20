import IDMEngine
import XCTest

@testable import MacIDMApp

final class YouTubeDownloadRunnerTests: XCTestCase {
    func testProgressIsPublishedBeforeYouTubeProcessExits() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMYouTubeRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fake-yt-dlp")
        let script =
            [
                "#!/bin/sh",
                "simulate=0",
                "for a in \"$@\"; do if [ \"$a\" = \"--simulate\" ]; then simulate=1; fi; done",
                "if [ \"$simulate\" = \"1\" ]; then printf '%s\\n' '{\"live_status\": \"not_live\"}'; exit 0; fi",
                "output=\"\"",
                "while [ \"$#\" -gt 0 ]; do",
                "  if [ \"$1\" = \"--output\" ]; then",
                "    shift",
                "    output=\"$1\"",
                "  fi",
                "  shift",
                "done",
                "base=$(printf '%s' \"$output\" | sed 's/%(ext)s$//')",
                "printf 'download:1|10|10\\n'",
                "sleep 1",
                "printf 'download:10|10|10\\n'",
                "if [ -n \"$output\" ]; then printf 'fixture-media' > \"${base}mp4\"; fi",
            ].joined(separator: "\n") + "\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let destination = directory.appendingPathComponent("video.mp4")
        let request = DownloadRequest(
            url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
            destination: destination,
            backend: .youtubeExtractor
        )
        let captured = ProgressCapture()
        let runner = YouTubeDownloadRunner(
            executableURL: executable,
            ffmpegRemuxer: FixtureYouTubeRemuxer()
        )

        let result = try await runner.run(
            request,
            control: { .continue },
            progress: { captured.append($0) }
        )

        XCTAssertEqual(result.destination, destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("fixture-media".utf8))
        XCTAssertEqual(captured.values.first?.receivedBytes, 1)
        XCTAssertEqual(captured.values.first?.totalBytes, 10)

        // The yt-dlp download completion progress (receivedBytes == totalBytes)
        // is followed by an FFmpeg remux progress entry carrying the produced
        // file size. Verify both: the download completion must exist somewhere
        // in the stream, and the last entry is the remux-phase progress.
        let downloadComplete = captured.values.contains { $0.receivedBytes == 10 && $0.totalBytes == 10 }
        XCTAssertTrue(downloadComplete, "Expected a progress entry with receivedBytes=10, totalBytes=10")

        let fixtureSize = Int64(Data("fixture-media".utf8).count)
        XCTAssertEqual(captured.values.last?.receivedBytes, fixtureSize)
        XCTAssertEqual(captured.values.last?.totalBytes, fixtureSize)
    }

    func testDefaultProgressFormatStreamsIncrementallyWithSpeed() async throws {
        // Regression: yt-dlp_macos release builds silently suppress the
        // custom --progress-template output, so the runner must obtain
        // incremental progress from the default "[download] X% of Y at Z"
        // format. Without it the UI progress bar jumps 0% -> 100%.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMYouTubeRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fake-yt-dlp")
        let script =
            [
                "#!/bin/sh",
                "simulate=0",
                "for a in \"$@\"; do if [ \"$a\" = \"--simulate\" ]; then simulate=1; fi; done",
                "if [ \"$simulate\" = \"1\" ]; then printf '%s\\n' '{\"live_status\": \"not_live\"}'; exit 0; fi",
                "output=\"\"",
                "while [ \"$#\" -gt 0 ]; do",
                "  if [ \"$1\" = \"--output\" ]; then",
                "    shift",
                "    output=\"$1\"",
                "  fi",
                "  shift",
                "done",
                "base=$(printf '%s' \"$output\" | sed 's/%(ext)s$//')",
                "printf '[download] Destination: video.f136.mp4\\n'",
                "printf '[download]  25.0%% of 20.00MiB at 1.00MiB/s ETA 00:15\\n'",
                "printf '[download]  50.0%% of 20.00MiB at 1.00MiB/s ETA 00:10\\n'",
                "printf '[download] 100.0%% of 20.00MiB at 1.00MiB/s ETA 00:00\\n'",
                "printf '[download] Destination: video.f140.m4a\\n'",
                "printf '[download]  50.0%% of 10.00MiB at 512.00KiB/s ETA 00:10\\n'",
                "printf '[download] 100.0%% of 10.00MiB at 512.00KiB/s ETA 00:00\\n'",
                "if [ -n \"$output\" ]; then printf 'fixture-media' > \"${base}mp4\"; fi",
            ].joined(separator: "\n") + "\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let destination = directory.appendingPathComponent("video.mp4")
        let request = DownloadRequest(
            url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
            destination: destination,
            backend: .youtubeExtractor
        )
        let captured = ProgressCapture()
        let runner = YouTubeDownloadRunner(
            executableURL: executable,
            ffmpegRemuxer: FixtureYouTubeRemuxer()
        )

        _ = try await runner.run(
            request,
            control: { .continue },
            progress: { captured.append($0) }
        )

        let videoTotal = Int64(20 * 1024 * 1024)
        let audioTotal = Int64(10 * 1024 * 1024)

        // Incremental entries must exist before completion (25%, 50%).
        let quarter = captured.values.first { $0.receivedBytes == videoTotal / 4 }
        XCTAssertNotNil(quarter, "Expected an incremental 25% progress entry")
        XCTAssertEqual(quarter?.totalBytes, videoTotal)
        // Speed parsed from "at 1.00MiB/s".
        XCTAssertEqual(quarter?.speed ?? 0, Double(1024 * 1024), accuracy: 1)

        // Audio format switch must accumulate, never move backwards.
        // The final entries belong to the FFmpeg remux phase (fixture
        // file size), which is intentionally excluded here.
        let downloadPhase = captured.values.filter {
            $0.totalBytes != $0.receivedBytes || $0.receivedBytes >= videoTotal
        }
        var maxSeen: Int64 = 0
        for value in downloadPhase {
            XCTAssertGreaterThanOrEqual(value.receivedBytes, maxSeen)
            maxSeen = value.receivedBytes
        }
        // Both formats fully aggregated.
        let aggregated = captured.values.contains {
            $0.receivedBytes == videoTotal + audioTotal
        }
        XCTAssertTrue(aggregated, "Expected aggregated video+audio total")

        // The video track's own 100% is not whole-task completion: yt-dlp
        // still has to download audio and FFmpeg still has to validate the
        // merged output. The stage-aware fraction must remain monotonic and
        // below 100% for every runner progress callback.
        let fractions = captured.values.compactMap(\.overallFraction)
        XCTAssertFalse(fractions.isEmpty)
        var previousFraction = 0.0
        for fraction in fractions {
            XCTAssertGreaterThanOrEqual(fraction, previousFraction)
            XCTAssertLessThan(fraction, 1)
            previousFraction = fraction
        }
        XCTAssertEqual(try XCTUnwrap(fractions.last), 0.99, accuracy: 0.0001)
    }

    func testProgressParsingToleratesEstimateSpacingVariants() async throws {
        // yt-dlp releases vary the spacing around the "~" estimate marker
        // ("~28.53MiB" vs "~ 28.53MiB"); the parser must accept both or
        // the progress bar freezes while speed keeps updating.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMYouTubeRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fake-yt-dlp")
        let script =
            [
                "#!/bin/sh",
                "simulate=0",
                "for a in \"$@\"; do if [ \"$a\" = \"--simulate\" ]; then simulate=1; fi; done",
                "if [ \"$simulate\" = \"1\" ]; then printf '%s\\n' '{\"live_status\": \"not_live\"}'; exit 0; fi",
                "output=\"\"",
                "while [ \"$#\" -gt 0 ]; do",
                "  if [ \"$1\" = \"--output\" ]; then",
                "    shift",
                "    output=\"$1\"",
                "  fi",
                "  shift",
                "done",
                "base=$(printf '%s' \"$output\" | sed 's/%(ext)s$//')",
                "printf '[download]  25.0%% of ~ 20.00MiB at 1.00MiB/s ETA 00:15\\n'",
                "printf '[download] 100.0%% of ~ 20.00MiB at 1.00MiB/s ETA 00:00\\n'",
                "if [ -n \"$output\" ]; then printf 'fixture-media' > \"${base}mp4\"; fi",
            ].joined(separator: "\n") + "\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let destination = directory.appendingPathComponent("video.mp4")
        let request = DownloadRequest(
            url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
            destination: destination,
            backend: .youtubeExtractor
        )
        let captured = ProgressCapture()
        let runner = YouTubeDownloadRunner(
            executableURL: executable,
            ffmpegRemuxer: FixtureYouTubeRemuxer()
        )

        _ = try await runner.run(
            request,
            control: { .continue },
            progress: { captured.append($0) }
        )

        let total = Int64(20 * 1024 * 1024)
        let quarter = captured.values.first { $0.receivedBytes == total / 4 }
        XCTAssertNotNil(quarter, "Expected the '~ 20.00MiB' line to parse into progress")
        XCTAssertEqual(quarter?.totalBytes, total)
        XCTAssertEqual(quarter?.speed ?? 0, Double(1024 * 1024), accuracy: 1)
    }

    func testFluctuatingEstimatesDoNotCorruptTotalSize() async throws {
        // Regression: yt-dlp's "~" estimated total fluctuates during a
        // download, and the derived received-byte count can dip within a
        // single format. Such dips used to be misread as a video→audio
        // format switch, spawning phantom formats whose totals inflated the
        // reported size ("the size keeps changing, progress is wrong").
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMYouTubeRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fake-yt-dlp")
        let script =
            [
                "#!/bin/sh",
                "simulate=0",
                "for a in \"$@\"; do if [ \"$a\" = \"--simulate\" ]; then simulate=1; fi; done",
                "if [ \"$simulate\" = \"1\" ]; then printf '%s\\n' '{\"live_status\": \"not_live\"}'; exit 0; fi",
                "output=\"\"",
                "while [ \"$#\" -gt 0 ]; do",
                "  if [ \"$1\" = \"--output\" ]; then",
                "    shift",
                "    output=\"$1\"",
                "  fi",
                "  shift",
                "done",
                "base=$(printf '%s' \"$output\" | sed 's/%(ext)s$//')",
                // Estimate jitter: the total estimate first grows, then
                // shrinks again — the derived received count dips from the
                // second to the third line within one single format.
                "printf '[download]  25.0%% of ~ 20.00MiB at 1.00MiB/s ETA 00:15\\n'",
                "printf '[download]  26.0%% of ~ 21.00MiB at 1.00MiB/s ETA 00:14\\n'",
                "printf '[download]  26.5%% of ~ 20.20MiB at 1.00MiB/s ETA 00:14\\n'",
                // The finished format reports its exact size (no "~").
                "printf '[download] 100.0%% of 20.50MiB at 1.00MiB/s ETA 00:00\\n'",
                "if [ -n \"$output\" ]; then printf 'fixture-media' > \"${base}mp4\"; fi",
            ].joined(separator: "\n") + "\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let destination = directory.appendingPathComponent("video.mp4")
        let request = DownloadRequest(
            url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
            destination: destination,
            backend: .youtubeExtractor
        )
        let captured = ProgressCapture()
        let runner = YouTubeDownloadRunner(
            executableURL: executable,
            ffmpegRemuxer: FixtureYouTubeRemuxer()
        )

        _ = try await runner.run(
            request,
            control: { .continue },
            progress: { captured.append($0) }
        )

        let exactFinal = Int64(20.5 * 1024 * 1024)
        // The reported total must never exceed the authoritative final size:
        // phantom formats from estimate jitter would inflate it well beyond.
        for value in captured.values {
            XCTAssertLessThanOrEqual(
                value.totalBytes ?? 0,
                exactFinal,
                "total size inflated by a phantom format switch"
            )
        }
        // The exact "100% of" line replaces the captured estimate. The
        // last entries belong to the FFmpeg remux phase (tiny fixture file),
        // so filter for the download-phase completion entry.
        let downloadCompletion = captured.values.last {
            $0.receivedBytes == $0.totalBytes && ($0.totalBytes ?? 0) > 1024
        }
        XCTAssertEqual(downloadCompletion?.totalBytes, exactFinal)
    }

    func testTinySideFileTotalDoesNotPinAggregateSize() async throws {
        // Regression: SABR-style downloads finish a tiny side file first
        // ("100% of 1.00KiB") and then stream the real media on the same
        // accounting slot. The capture-once rule used to keep the 1KiB
        // total forever, so a 30MB transfer rendered as >100% progress
        // with a "1 KB" size in the detail panel.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMYouTubeRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fake-yt-dlp")
        let script =
            [
                "#!/bin/sh",
                "simulate=0",
                "for a in \"$@\"; do if [ \"$a\" = \"--simulate\" ]; then simulate=1; fi; done",
                "if [ \"$simulate\" = \"1\" ]; then printf '%s\\n' '{\"live_status\": \"not_live\"}'; exit 0; fi",
                "output=\"\"",
                "while [ \"$#\" -gt 0 ]; do",
                "  if [ \"$1\" = \"--output\" ]; then",
                "    shift",
                "    output=\"$1\"",
                "  fi",
                "  shift",
                "done",
                "base=$(printf '%s' \"$output\" | sed 's/%(ext)s$//')",
                "printf '[download] 100.0%% of 1.00KiB at 1.00KiB/s ETA 00:00\\n'",
                "printf '[download]  25.0%% of ~ 20.00MiB at 1.00MiB/s ETA 00:15\\n'",
                "printf '[download]  50.0%% of ~ 20.00MiB at 1.00MiB/s ETA 00:10\\n'",
                "printf '[download] 100.0%% of 20.00MiB at 1.00MiB/s ETA 00:00\\n'",
                "if [ -n \"$output\" ]; then printf 'fixture-media' > \"${base}mp4\"; fi",
            ].joined(separator: "\n") + "\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let destination = directory.appendingPathComponent("video.mp4")
        let request = DownloadRequest(
            url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
            destination: destination,
            backend: .youtubeExtractor
        )
        let captured = ProgressCapture()
        let runner = YouTubeDownloadRunner(
            executableURL: executable,
            ffmpegRemuxer: FixtureYouTubeRemuxer()
        )

        _ = try await runner.run(
            request,
            control: { .continue },
            progress: { captured.append($0) }
        )

        let realTotal = Int64(20 * 1024 * 1024)
        // Once the transfer outgrows the side file, the tiny total must
        // never be reported again.
        for value in captured.values where value.receivedBytes > 1024 {
            XCTAssertNotEqual(
                value.totalBytes,
                1024,
                "the 1KiB side-file total stayed pinned over the real stream"
            )
        }
        // The much larger totals replace the wrong capture and the exact
        // final line settles the size.
        let completion = captured.values.last {
            $0.receivedBytes == $0.totalBytes && ($0.totalBytes ?? 0) > 1024
        }
        XCTAssertEqual(completion?.totalBytes, realTotal)
    }

    func testTinySideFileFractionDoesNotPinProgressBar() async throws {
        // Regression companion to the size test above: the SABR 1KiB side
        // file reports "100%" on the same accounting slot before the real
        // stream starts, which used to pin the monotonic stage-aware
        // fraction at the video-track ceiling — the progress bar showed
        // 82% from the first second and never moved while the video track
        // downloaded. After a substantial total correction the fraction
        // must be re-derived from the honest byte accounting.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMYouTubeRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fake-yt-dlp")
        let script =
            [
                "#!/bin/sh",
                "simulate=0",
                "for a in \"$@\"; do if [ \"$a\" = \"--simulate\" ]; then simulate=1; fi; done",
                "if [ \"$simulate\" = \"1\" ]; then printf '%s\\n' '{\"live_status\": \"not_live\"}'; exit 0; fi",
                "output=\"\"",
                "while [ \"$#\" -gt 0 ]; do",
                "  if [ \"$1\" = \"--output\" ]; then",
                "    shift",
                "    output=\"$1\"",
                "  fi",
                "  shift",
                "done",
                "base=$(printf '%s' \"$output\" | sed 's/%(ext)s$//')",
                // The side file "completes" instantly on the slot that the
                // real stream then takes over.
                "printf '[download] 100.0%% of 1.00KiB at 1.00KiB/s ETA 00:00\\n'",
                "printf '[download]  10.0%% of ~ 20.00MiB at 1.00MiB/s ETA 00:17\\n'",
                "printf '[download]  25.0%% of ~ 20.00MiB at 1.00MiB/s ETA 00:15\\n'",
                "printf '[download]  50.0%% of ~ 20.00MiB at 1.00MiB/s ETA 00:10\\n'",
                "printf '[download] 100.0%% of 20.00MiB at 1.00MiB/s ETA 00:00\\n'",
                "if [ -n \"$output\" ]; then printf 'fixture-media' > \"${base}mp4\"; fi",
            ].joined(separator: "\n") + "\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let destination = directory.appendingPathComponent("video.mp4")
        let request = DownloadRequest(
            url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
            destination: destination,
            backend: .youtubeExtractor
        )
        let captured = ProgressCapture()
        let runner = YouTubeDownloadRunner(
            executableURL: executable,
            ffmpegRemuxer: FixtureYouTubeRemuxer()
        )

        _ = try await runner.run(
            request,
            control: { .continue },
            progress: { captured.append($0) }
        )

        // Mid-stream samples must reflect the real byte ratio instead of
        // the poisoned 82% ceiling (allow the stage mapping's 0.82 scale
        // factor plus slack: 50% of the track maps to 0.41 overall).
        let midStream = captured.values.filter {
            $0.receivedBytes > 1024 * 1024 && $0.receivedBytes < ($0.totalBytes ?? Int64.max)
        }
        XCTAssertFalse(midStream.isEmpty, "expected incremental samples after the side file")
        for value in midStream {
            XCTAssertLessThan(
                value.overallFraction ?? 0,
                0.5,
                "the side file's 100% pinned the progress bar at the stage ceiling"
            )
        }
        // The finished track still reaches its honest stage ceiling.
        let trackCompletion = captured.values.last {
            $0.receivedBytes == $0.totalBytes && ($0.totalBytes ?? 0) > 1024
        }
        XCTAssertEqual(trackCompletion?.overallFraction ?? 0, 0.82, accuracy: 0.001)
    }

    func testUnknownTotalFormatKeepsAggregateTotalUnknown() async throws {
        // A format that never reports a size (SABR's "of Unknown") must
        // keep the overall total unknown instead of letting an earlier
        // tiny completed file stand in for the whole download.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMYouTubeRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fake-yt-dlp")
        let script =
            [
                "#!/bin/sh",
                "simulate=0",
                "for a in \"$@\"; do if [ \"$a\" = \"--simulate\" ]; then simulate=1; fi; done",
                "if [ \"$simulate\" = \"1\" ]; then printf '%s\\n' '{\"live_status\": \"not_live\"}'; exit 0; fi",
                "output=\"\"",
                "while [ \"$#\" -gt 0 ]; do",
                "  if [ \"$1\" = \"--output\" ]; then",
                "    shift",
                "    output=\"$1\"",
                "  fi",
                "  shift",
                "done",
                "base=$(printf '%s' \"$output\" | sed 's/%(ext)s$//')",
                "printf '[download] Destination: video.side\\n'",
                "printf '[download] 100.0%% of 1.00KiB at 1.00KiB/s ETA 00:00\\n'",
                "printf '[download] Destination: video.main.mp4\\n'",
                "printf '[download]  10.0%% of Unknown at 1.00MiB/s ETA 00:15\\n'",
                "printf '[download]  20.0%% of Unknown at 1.00MiB/s ETA 00:14\\n'",
                "if [ -n \"$output\" ]; then printf 'fixture-media' > \"${base}mp4\"; fi",
            ].joined(separator: "\n") + "\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let destination = directory.appendingPathComponent("video.mp4")
        let request = DownloadRequest(
            url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
            destination: destination,
            backend: .youtubeExtractor
        )
        let captured = ProgressCapture()
        let runner = YouTubeDownloadRunner(
            executableURL: executable,
            ffmpegRemuxer: FixtureYouTubeRemuxer()
        )

        _ = try await runner.run(
            request,
            control: { .continue },
            progress: { captured.append($0) }
        )

        // Download-phase samples carry the side file's byte count; once the
        // unknown-total format starts, the aggregate total must be nil so
        // the UI degrades to the byte counter instead of "1 KB / >100%".
        let downloadPhase = captured.values.filter { $0.receivedBytes >= 1024 }
        XCTAssertFalse(downloadPhase.isEmpty)
        XCTAssertNil(downloadPhase.last?.totalBytes)
        // The speed of the unknown format still flows through.
        XCTAssertGreaterThan(downloadPhase.last?.speed ?? 0, 0)
    }

    // MARK: - Format selection (itag fragment)

    func testParseMacIDMFragmentExtractsValidatedFields() {
        // Valid picks survive; malformed and unknown entries are dropped
        // so page strings can never reach the yt-dlp selector.
        XCTAssertEqual(
            YouTubeDownloadRunner.parseMacIDMFragment("height=1080&itag=248"),
            YouTubeDownloadRunner.FragmentSelection(height: 1080, itag: 248, hasAudio: false))
        XCTAssertEqual(
            YouTubeDownloadRunner.parseMacIDMFragment("height=360&itag=18&a=1"),
            YouTubeDownloadRunner.FragmentSelection(height: 360, itag: 18, hasAudio: true))
        XCTAssertEqual(
            YouTubeDownloadRunner.parseMacIDMFragment("t=90"),
            YouTubeDownloadRunner.FragmentSelection(height: nil, itag: nil, hasAudio: false))
        // Non-numeric / oversized / non-positive values are rejected.
        XCTAssertEqual(
            YouTubeDownloadRunner.parseMacIDMFragment("height=-1&itag=abc&a=0"),
            YouTubeDownloadRunner.FragmentSelection(height: nil, itag: nil, hasAudio: false))
        XCTAssertEqual(
            YouTubeDownloadRunner.parseMacIDMFragment("itag=123456"),
            YouTubeDownloadRunner.FragmentSelection(height: nil, itag: nil, hasAudio: false))
    }

    func testFormatSelectorDistinguishesSameHeightCodecs() {
        // 1080 H.264 (progressive-audio itag would be different; 137 is
        // video-only) vs 1080 VP9: the selectors must differ and each must
        // pin exactly the chosen itag (technical-spec §3.4 acceptance).
        let h264 = YouTubeDownloadRunner.formatSelector(
            itag: 137, hasAudio: false, heightConstraint: "[height<=1080]")
        let vp9 = YouTubeDownloadRunner.formatSelector(
            itag: 248, hasAudio: false, heightConstraint: "[height<=1080]")
        XCTAssertNotEqual(h264, vp9)
        XCTAssertEqual(h264, "137+ba[ext=m4a]/137")
        XCTAssertEqual(vp9, "248+ba[ext=m4a]/248")
        // A progressive pick (a=1) carries its own audio: bare itag.
        XCTAssertEqual(
            YouTubeDownloadRunner.formatSelector(
                itag: 18, hasAudio: true, heightConstraint: "[height<=360]"),
            "18")
        // Resolution-only compat path is unchanged.
        XCTAssertEqual(
            YouTubeDownloadRunner.formatSelector(itag: nil, hasAudio: false, heightConstraint: ""),
            "bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b")
        XCTAssertEqual(
            YouTubeDownloadRunner.formatSelector(
                itag: nil, hasAudio: false, heightConstraint: "[height<=720]"),
            "bv*[ext=mp4][height<=720]+ba[ext=m4a]/b[ext=mp4][height<=720]/bv*[height<=720]+ba/b")
    }

    func testRunnerPassesITagSelectionToYTDlpAndStripsFragment() async throws {
        // Same-height variants must reach yt-dlp as different --format
        // selectors, and the MacIDM fragment must be stripped from the URL
        // handed to the process.
        let directory = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let argsFile = directory.appendingPathComponent("args.txt")
        let executable = directory.appendingPathComponent("fake-yt-dlp-args")
        let script =
            [
                "#!/bin/sh",
                "simulate=0",
                "for a in \"$@\"; do if [ \"$a\" = \"--simulate\" ]; then simulate=1; fi; done",
                "if [ \"$simulate\" = \"1\" ]; then printf '%s\\n' '{\"live_status\": \"not_live\"}'; exit 0; fi",
                "printf '%s\\n' \"$@\" > '\(argsFile.path)'",
                "printf 'ERROR: [youtube] fixture: video unavailable\\n' >&2",
                "exit 1",
            ].joined(separator: "\n") + "\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let runner = YouTubeDownloadRunner(
            executableURL: executable,
            ffmpegRemuxer: FixtureYouTubeRemuxer(),
            diagnosticLog: YouTubeDiagnosticEventLog(enabled: false)
        )

        func capturedArguments(for url: String) async throws -> [String] {
            try? FileManager.default.removeItem(at: argsFile)
            let request = DownloadRequest(
                url: URL(string: url)!,
                destination: directory.appendingPathComponent("video.mp4"),
                backend: .youtubeExtractor
            )
            do {
                _ = try await runner.run(
                    request,
                    control: { .continue },
                    progress: { _ in }
                )
            } catch {
                // Expected: the fake process always exits 1.
            }
            let text = try String(contentsOf: argsFile, encoding: .utf8)
            return text.split(separator: "\n").map(String.init)
        }

        let h264Args = try await capturedArguments(
            for: "https://www.youtube.com/watch?v=fixture#height=1080&itag=137")
        let vp9Args = try await capturedArguments(
            for: "https://www.youtube.com/watch?v=fixture#height=1080&itag=248")
        let heightOnlyArgs = try await capturedArguments(
            for: "https://www.youtube.com/watch?v=fixture#height=720")

        func formatValue(of args: [String]) -> String {
            guard let index = args.firstIndex(of: "--format") else {
                return ""
            }
            return index + 1 < args.count ? args[index + 1] : ""
        }

        XCTAssertEqual(formatValue(of: h264Args), "137+ba[ext=m4a]/137")
        XCTAssertEqual(formatValue(of: vp9Args), "248+ba[ext=m4a]/248")
        XCTAssertEqual(
            formatValue(of: heightOnlyArgs),
            "bv*[ext=mp4][height<=720]+ba[ext=m4a]/b[ext=mp4][height<=720]/bv*[height<=720]+ba/b")
        // The selection fragment never reaches the process: yt-dlp gets
        // the bare page URL.
        XCTAssertEqual(
            h264Args.last, "https://www.youtube.com/watch?v=fixture",
            "fragment must be stripped from the URL passed to yt-dlp")
        XCTAssertEqual(vp9Args.last, "https://www.youtube.com/watch?v=fixture")
        XCTAssertEqual(heightOnlyArgs.last, "https://www.youtube.com/watch?v=fixture")
    }

    func testYouTubeVideoIDExtractionSupportsWatchShortsLiveAndYoutuBe() {
        func id(_ url: String) -> String? {
            YouTubeDownloadRunner.youTubeVideoID(from: URL(string: url)!)
        }
        XCTAssertEqual(id("https://www.youtube.com/watch?v=abc123"), "abc123")
        XCTAssertEqual(id("https://youtube.com/shorts/sh0rt1d"), "sh0rt1d")
        XCTAssertEqual(id("https://www.youtube.com/live/liv3id99"), "liv3id99")
        XCTAssertEqual(id("https://youtu.be/brief123"), "brief123")
        XCTAssertNil(id("https://www.youtube.com/"))
        XCTAssertNil(id("https://www.example.com/watch?v=abc123"))
    }

    // MARK: - Cookie context

    func testCookieFileUsesLeadingDotDomainForYouTubeAndGenericSites() async throws {
        // Regression（2026-08-26 真实环境复现）：Netscape 格式断言
        // domain_specified=TRUE 的域名必须以「.」开头，否则 yt-dlp 以
        // 「invalid Netscape format cookies file」拒绝整个 Cookie 文件。
        // YouTube 与走通用提取器的其他站点都必须写前导点域名。
        let directory = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let marker = directory.appendingPathComponent("cookie-rows")
        let executable = directory.appendingPathComponent("fake-yt-dlp-cookie")
        let script =
            [
                "#!/bin/sh",
                "simulate=0",
                "for a in \"$@\"; do if [ \"$a\" = \"--simulate\" ]; then simulate=1; fi; done",
                "if [ \"$simulate\" = \"1\" ]; then printf '%s\\n' '{\"live_status\": \"not_live\"}'; exit 0; fi",
                "prev=\"\"",
                "for arg in \"$@\"; do",
                "  if [ \"$prev\" = \"--cookies\" ] && [ -f \"$arg\" ]; then",
                "    sed -n '2p' \"$arg\" >> '\(marker.path)'",
                "  fi",
                "  prev=\"$arg\"",
                "done",
                "output=\"\"",
                "while [ \"$#\" -gt 0 ]; do",
                "  if [ \"$1\" = \"--output\" ]; then",
                "    shift",
                "    output=\"$1\"",
                "  fi",
                "  shift",
                "done",
                "base=$(printf '%s' \"$output\" | sed 's/%(ext)s$//')",
                "if [ -n \"$output\" ]; then printf 'fixture-media' > \"${base}mp4\"; fi",
            ].joined(separator: "\n") + "\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let runner = YouTubeDownloadRunner(
            executableURL: executable,
            ffmpegRemuxer: FixtureYouTubeRemuxer()
        )

        // YouTube 页面：固定 .youtube.com 域。
        let youTubeDestination = directory.appendingPathComponent("youtube.mp4")
        let youTubeRequest = DownloadRequest(
            url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
            destination: youTubeDestination,
            requestContext: DownloadRequestContext(cookie: "session=fixture"),
            backend: .youtubeExtractor
        )
        _ = try await runner.run(
            youTubeRequest,
            control: { .continue },
            progress: { _ in }
        )

        // 非 YouTube 站点（通用提取器兜底）：页面主机加前导点。
        let genericDestination = directory.appendingPathComponent("generic.mp4")
        let genericRequest = DownloadRequest(
            url: URL(string: "https://www.example.com/watch/fixture")!,
            destination: genericDestination,
            requestContext: DownloadRequestContext(cookie: "session=fixture"),
            backend: .youtubeExtractor
        )
        _ = try await runner.run(
            genericRequest,
            control: { .continue },
            progress: { _ in }
        )

        let recorded = try String(contentsOf: marker, encoding: .utf8)
        let rows = recorded.split(separator: "\n").map(String.init)
        // YouTube 运行的直播探测与主下载共用同一 Cookie 文件，会重复观察到；
        // 按唯一行断言每次运行的域名规则。
        let uniqueRows = Array(Set(rows)).sorted()
        XCTAssertEqual(uniqueRows.count, 2, "expected one unique cookie row per run")
        XCTAssertTrue(
            uniqueRows.contains { $0.hasPrefix(".youtube.com\tTRUE\t/\tTRUE\t") },
            "YouTube cookie row must use .youtube.com, got: \(uniqueRows)"
        )
        XCTAssertTrue(
            uniqueRows.contains { $0.hasPrefix(".www.example.com\tTRUE\t/\tTRUE\t") },
            "generic cookie row must use a leading-dot host, got: \(uniqueRows)"
        )
    }

    // MARK: - Executable resolution lifecycle

    private func writeWorkingFakeYTDlp(to url: URL) throws {
        let script =
            [
                "#!/bin/sh",
                "simulate=0",
                "for a in \"$@\"; do if [ \"$a\" = \"--simulate\" ]; then simulate=1; fi; done",
                "if [ \"$simulate\" = \"1\" ]; then printf '%s\\n' '{\"live_status\": \"not_live\"}'; exit 0; fi",
                "output=\"\"",
                "while [ \"$#\" -gt 0 ]; do",
                "  if [ \"$1\" = \"--output\" ]; then",
                "    shift",
                "    output=\"$1\"",
                "  fi",
                "  shift",
                "done",
                "base=$(printf '%s' \"$output\" | sed 's/%(ext)s$//')",
                "if [ -n \"$output\" ]; then printf 'fixture-media' > \"${base}mp4\"; fi",
            ].joined(separator: "\n") + "\n"
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func makeRunnerDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMYouTubeRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeYouTubeRequest(destination: URL) -> DownloadRequest {
        DownloadRequest(
            url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
            destination: destination,
            backend: .youtubeExtractor
        )
    }

    func testRunnerDiscoversBinaryCreatedAfterRunnerConstruction() async throws {
        // Regression (2026-08-25 incident): the runner captured the
        // executable path in init and kept it for the app's whole
        // lifetime, so a yt-dlp installed while the app was running was
        // never picked up. Resolution must happen at task start.
        let directory = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let executableB = directory.appendingPathComponent("yt-dlp-B")
        let resolver = ExecutableResolverBox()
        let runner = YouTubeDownloadRunner(
            ffmpegRemuxer: FixtureYouTubeRemuxer(),
            defaultExecutableResolver: { resolver.url }
        )

        // The binary appears only AFTER the runner was constructed.
        try writeWorkingFakeYTDlp(to: executableB)
        resolver.set(executableB)

        let destination = directory.appendingPathComponent("video.mp4")
        let result = try await runner.run(
            makeYouTubeRequest(destination: destination),
            control: { .continue },
            progress: { _ in }
        )
        XCTAssertEqual(result.destination, destination)
    }

    func testRunnerUsesReplacementPathWhenResolvedPathDisappears() async throws {
        // Regression companion: a path that was valid at some earlier point
        // but is gone by task start must not be launched — the runner has
        // to re-resolve and use whatever is available now.
        let directory = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let executableA = directory.appendingPathComponent("yt-dlp-A")
        let executableB = directory.appendingPathComponent("yt-dlp-B")
        try writeWorkingFakeYTDlp(to: executableA)

        let resolver = ExecutableResolverBox()
        resolver.set(executableA)
        let runner = YouTubeDownloadRunner(
            ffmpegRemuxer: FixtureYouTubeRemuxer(),
            defaultExecutableResolver: { resolver.url }
        )

        // A disappears (like a managed binary replaced by an update) and B
        // takes over the resolution.
        try FileManager.default.removeItem(at: executableA)
        try writeWorkingFakeYTDlp(to: executableB)
        resolver.set(executableB)

        let destination = directory.appendingPathComponent("video.mp4")
        let result = try await runner.run(
            makeYouTubeRequest(destination: destination),
            control: { .continue },
            progress: { _ in }
        )
        XCTAssertEqual(result.destination, destination)
    }

    func testExplicitlyInjectedExecutableStaysPinned() async throws {
        // The injection seam keeps existing behavior: an explicit
        // executableURL is used as-is and the resolver is not consulted.
        let directory = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("yt-dlp-fake")
        try writeWorkingFakeYTDlp(to: executable)

        let resolver = ExecutableResolverBox()
        resolver.set(directory.appendingPathComponent("does-not-exist"))
        let runner = YouTubeDownloadRunner(
            executableURL: executable,
            ffmpegRemuxer: FixtureYouTubeRemuxer(),
            defaultExecutableResolver: { resolver.url }
        )

        let destination = directory.appendingPathComponent("video.mp4")
        let result = try await runner.run(
            makeYouTubeRequest(destination: destination),
            control: { .continue },
            progress: { _ in }
        )
        XCTAssertEqual(result.destination, destination)
    }

    func testLaunchFailureOfCorruptBinaryIsNotReportedAsMissing() async throws {
        // Regression: every Process.run() error used to map to
        // toolUnavailable ("install yt-dlp"), even when the binary existed
        // and was executable — a corrupt file made users run
        // `brew install yt-dlp` on machines where it was already present.
        let directory = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let corrupt = directory.appendingPathComponent("corrupt-yt-dlp")
        try Data("definitely not a mach-o binary or script".utf8).write(to: corrupt)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: corrupt.path
        )

        let runner = YouTubeDownloadRunner(
            executableURL: corrupt,
            ffmpegRemuxer: FixtureYouTubeRemuxer()
        )
        let destination = directory.appendingPathComponent("video.mp4")
        do {
            _ = try await runner.run(
                makeYouTubeRequest(destination: destination),
                control: { .continue },
                progress: { _ in }
            )
            XCTFail("expected the corrupt binary to fail the launch")
        } catch let error as YouTubeDownloadError {
            XCTAssertEqual(error, .toolLaunchFailed)
        }
    }

    func testMissingExecutableReportsToolUnavailable() async throws {
        let directory = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let runner = YouTubeDownloadRunner(
            ffmpegRemuxer: FixtureYouTubeRemuxer(),
            defaultExecutableResolver: { nil }
        )
        let destination = directory.appendingPathComponent("video.mp4")
        do {
            _ = try await runner.run(
                makeYouTubeRequest(destination: destination),
                control: { .continue },
                progress: { _ in }
            )
            XCTFail("expected a missing executable to fail")
        } catch let error as YouTubeDownloadError {
            XCTAssertEqual(error, .toolUnavailable)
        }
    }

    func testStalledDownloadKillsProcessTreeBeforeNextAttempt() async throws {
        // technical-spec §3.4：停滞重试前上一轮进程树必须已经真正退出；
        // 每次尝试派生长寿命后代，结束后不得残留，且尝试次数不得重叠。
        let directory = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let attemptsFile = directory.appendingPathComponent("attempts")
        let executable = directory.appendingPathComponent("stall-fake-yt-dlp")
        let probeJSON = #"{"live_status": "not_live", "formats": []}"#
        let script =
            [
                "#!/bin/sh",
                "simulate=0",
                "for arg in \"$@\"; do [ \"$arg\" = \"--simulate\" ] && simulate=1; done",
                "if [ \"$simulate\" = \"1\" ]; then",
                "  printf '%s' '\(probeJSON)'",
                "  exit 0",
                "fi",
                "n=$(cat \"\(attemptsFile.path)\" 2>/dev/null || echo 0)",
                "n=$((n+1))",
                "echo $n > \"\(attemptsFile.path)\"",
                "sleep 300 &",
                "echo $! > \"\(directory.path)/desc-$n.pid\"",
                // 不产生任何输出：停滞检测会在预算后强杀整棵进程树。
                "sleep 60",
            ].joined(separator: "\n") + "\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let runner = YouTubeDownloadRunner(
            executableURL: executable,
            ffmpegRemuxer: FixtureYouTubeRemuxer(),
            downloadAttemptTimeout: 1.5
        )
        let destination = directory.appendingPathComponent("video.mp4")
        let runStart = Date()
        do {
            _ = try await runner.run(
                makeYouTubeRequest(destination: destination),
                control: { .continue },
                progress: { _ in }
            )
            XCTFail("expected the stalled download to fail")
        } catch let error as YouTubeDownloadError {
            XCTAssertEqual(error, .stalled)
        }
        // run() 恰好结束一次（未重叠）且没有无故拖长。
        XCTAssertLessThan(Date().timeIntervalSince(runStart), 60)

        let attempts = Int(
            (try String(contentsOf: attemptsFile, encoding: .utf8))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        XCTAssertEqual(attempts, 3, "expected exactly maxAttempts stall retries")
        for attempt in 1...3 {
            let pidRaw = try String(
                contentsOf: directory.appendingPathComponent("desc-\(attempt).pid"),
                encoding: .utf8
            )
            let pid = try XCTUnwrap(pid_t(pidRaw.trimmingCharacters(in: .whitespacesAndNewlines)))
            XCTAssertFalse(
                ProcessTree.isRunning(pid),
                "attempt \(attempt) descendant must be reaped before the task fails"
            )
        }
    }

    /// 构造按 `--simulate` 分流的假 yt-dlp：探测（直播语义）输出指定 JSON，
    /// 下载分支写入媒体文件并留下 marker（technical-spec §3.4）。
    private func makeLiveBranchingExecutable(
        directory: URL,
        probeJSON: String,
        marker: URL
    ) throws -> URL {
        let executable = directory.appendingPathComponent("fake-yt-dlp")
        let script =
            [
                "#!/bin/sh",
                "simulate=0",
                "output=\"\"",
                "for arg in \"$@\"; do",
                "  if [ \"$arg\" = \"--simulate\" ]; then simulate=1; fi",
                "  if [ \"$prev\" = \"--output\" ]; then output=\"$arg\"; fi",
                "  prev=\"$arg\"",
                "done",
                "if [ \"$simulate\" = \"1\" ]; then",
                "  cat <<'EOF'",
                probeJSON,
                "EOF",
                "  exit 0",
                "fi",
                "touch \"\(marker.path)\"",
                "base=$(printf '%s' \"$output\" | sed 's/%(ext)s$//')",
                "if [ -n \"$output\" ]; then printf 'fixture-media' > \"${base}mp4\"; fi",
            ].joined(separator: "\n") + "\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func makeIsolatedDiagnosticLog(directory: URL) -> YouTubeDiagnosticEventLog {
        YouTubeDiagnosticEventLog(
            privateLogURL: directory.appendingPathComponent("macidm-private.log"),
            regularSink: { _ in },
            enabled: true
        )
    }

    func testRunnerBlocksCurrentlyLiveStreamBeforeDownload() async throws {
        // 执行层防御：绕过检查或旧任务直接入队时，正在直播的内容不得被
        // 当 VOD 无限下载；判定与检查层一致（YouTubeLiveClassifier）。
        let directory = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("download-started")
        let executable = try makeLiveBranchingExecutable(
            directory: directory,
            probeJSON: #"{"is_live": true, "live_status": "is_live"}"#,
            marker: marker
        )
        let runner = YouTubeDownloadRunner(
            executableURL: executable,
            ffmpegRemuxer: FixtureYouTubeRemuxer(),
            diagnosticLog: makeIsolatedDiagnosticLog(directory: directory)
        )
        let destination = directory.appendingPathComponent("video.mp4")
        do {
            _ = try await runner.run(
                makeYouTubeRequest(destination: destination),
                control: { .continue },
                progress: { _ in }
            )
            XCTFail("expected a live stream to be blocked")
        } catch let error as YouTubeDownloadError {
            XCTAssertEqual(error, .liveStreamUnsupported)
        }
        // 下载分支从未启动。
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testRunnerBlocksUpcomingLiveStreamBeforeDownload() async throws {
        let directory = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("download-started")
        let executable = try makeLiveBranchingExecutable(
            directory: directory,
            probeJSON: #"{"live_status": "is_upcoming"}"#,
            marker: marker
        )
        let runner = YouTubeDownloadRunner(
            executableURL: executable,
            ffmpegRemuxer: FixtureYouTubeRemuxer(),
            diagnosticLog: makeIsolatedDiagnosticLog(directory: directory)
        )
        let destination = directory.appendingPathComponent("video.mp4")
        do {
            _ = try await runner.run(
                makeYouTubeRequest(destination: destination),
                control: { .continue },
                progress: { _ in }
            )
            XCTFail("expected an upcoming stream to be blocked")
        } catch let error as YouTubeDownloadError {
            XCTAssertEqual(error, .liveStreamUnsupported)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// 输出容器契约（technical-spec §3.4）：选择 VP9（源容器 webm）变体
    /// 时，yt-dlp 选择器仍精确锁定 itag，而最终输出容器统一为 MP4：
    /// `--merge-output-format mp4`、`--remux-video mp4` 与 FFmpeg outputKind。
    func testOutputContractSelectsItagButAlwaysPublishesMP4() async throws {
        let directory = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("ytdlp-args")
        let executable = directory.appendingPathComponent("fake-yt-dlp")
        let script =
            [
                "#!/bin/sh",
                "simulate=0",
                "for a in \"$@\"; do if [ \"$a\" = \"--simulate\" ]; then simulate=1; fi; done",
                "if [ \"$simulate\" = \"1\" ]; then printf '%s\\n' '{\"live_status\": \"not_live\"}'; exit 0; fi",
                "prev=\"\"",
                "format=\"\"",
                "merge=\"\"",
                "remux=\"\"",
                "output=\"\"",
                "for arg in \"$@\"; do",
                "  if [ \"$prev\" = \"--format\" ]; then format=\"$arg\"; fi",
                "  if [ \"$prev\" = \"--merge-output-format\" ]; then merge=\"$arg\"; fi",
                "  if [ \"$prev\" = \"--remux-video\" ]; then remux=\"$arg\"; fi",
                "  if [ \"$prev\" = \"--output\" ]; then output=\"$arg\"; fi",
                "  prev=\"$arg\"",
                "done",
                "if [ -n \"$format\" ]; then",
                "  printf 'format=%s merge=%s remux=%s\\n' \"$format\" \"$merge\" \"$remux\" >> '\(marker.path)'",
                "fi",
                "base=$(printf '%s' \"$output\" | sed 's/%(ext)s$//')",
                "if [ -n \"$output\" ]; then printf 'fixture-media' > \"${base}mp4\"; fi",
            ].joined(separator: "\n") + "\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let remuxer = RecordingYouTubeRemuxer()
        let runner = YouTubeDownloadRunner(
            executableURL: executable,
            ffmpegRemuxer: remuxer,
            diagnosticLog: makeIsolatedDiagnosticLog(directory: directory)
        )
        let destination = directory.appendingPathComponent("video.mp4")
        // 用户选了 itag 248（VP9，源容器 webm）的变体。
        let request = DownloadRequest(
            url: URL(string: "https://www.youtube.com/watch?v=fixture#height=1080&itag=248")!,
            destination: destination,
            backend: .youtubeExtractor
        )
        let result = try await runner.run(request, control: { .continue }, progress: { _ in })

        // 选中的编码/itag：精确选择器锁定 248，不退化为仅按高度。
        let recorded = try String(contentsOf: marker, encoding: .utf8)
        XCTAssertTrue(
            recorded.contains("format=248+ba[ext=m4a]/248"),
            "expected the exact itag selector, got: \(recorded)"
        )
        // 最终输出容器：yt-dlp 合并/重封装与 FFmpeg 输出统一为 mp4，
        // 与源变体的 webm 容器无关。
        XCTAssertTrue(recorded.contains("merge=mp4"))
        XCTAssertTrue(recorded.contains("remux=mp4"))
        let remuxRequest = try XCTUnwrap(remuxer.recorded.first)
        XCTAssertEqual(remuxRequest.outputKind, .mp4)
        XCTAssertEqual(remuxRequest.outputURL.pathExtension, "mp4")
        XCTAssertEqual(result.destination.pathExtension, "mp4")
    }

    /// §3.2：直播探测结果不可解析（未知态）时，即使伪造的主下载能正常启动，
    /// 也不得进入正式下载（fail-closed 为可重试的检查错误）。
    func testLiveProbeUnknownFailsClosedEvenIfDownloadWouldStart() async throws {
        let directory = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("download-started")
        let executable = directory.appendingPathComponent("fake-yt-dlp")
        let script =
            [
                "#!/bin/sh",
                "simulate=0",
                "output=\"\"",
                "for arg in \"$@\"; do",
                "  if [ \"$arg\" = \"--simulate\" ]; then simulate=1; fi",
                "  if [ \"$prev\" = \"--output\" ]; then output=\"$arg\"; fi",
                "  prev=\"$arg\"",
                "done",
                // 探测退出成功但输出不是 JSON → 直播状态不可知。
                "if [ \"$simulate\" = \"1\" ]; then",
                "  printf 'this is not json\\n'",
                "  exit 0",
                "fi",
                // 主下载分支完全可用：若被放行会写出媒体并留 marker。
                "touch \"\(marker.path)\"",
                "base=$(printf '%s' \"$output\" | sed 's/%(ext)s$//')",
                "if [ -n \"$output\" ]; then printf 'fixture-media' > \"${base}mp4\"; fi",
            ].joined(separator: "\n") + "\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let runner = YouTubeDownloadRunner(
            executableURL: executable,
            ffmpegRemuxer: FixtureYouTubeRemuxer(),
            diagnosticLog: makeIsolatedDiagnosticLog(directory: directory)
        )
        let destination = directory.appendingPathComponent("video.mp4")
        do {
            _ = try await runner.run(
                makeYouTubeRequest(destination: destination),
                control: { .continue },
                progress: { _ in }
            )
            XCTFail("expected an unknown live status to fail closed")
        } catch let error as YouTubeDownloadError {
            XCTAssertEqual(error, .liveStatusUnknown)
        }
        // 主下载分支从未启动。
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// §3.2：探测拿到 yt-dlp 真实错误时，保留网络/认证等各自诊断类别，
    /// 不误报为直播不支持。
    func testLiveProbeProcessFailureKeepsNetworkClassification() async throws {
        let directory = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("download-started")
        let executable = directory.appendingPathComponent("fake-yt-dlp")
        let script =
            [
                "#!/bin/sh",
                "simulate=0",
                "output=\"\"",
                "for arg in \"$@\"; do",
                "  if [ \"$arg\" = \"--simulate\" ]; then simulate=1; fi",
                "  if [ \"$prev\" = \"--output\" ]; then output=\"$arg\"; fi",
                "  prev=\"$arg\"",
                "done",
                "if [ \"$simulate\" = \"1\" ]; then",
                "  echo 'ERROR: Unable to download webpage: Connection refused' >&2",
                "  exit 1",
                "fi",
                "touch \"\(marker.path)\"",
                "base=$(printf '%s' \"$output\" | sed 's/%(ext)s$//')",
                "if [ -n \"$output\" ]; then printf 'fixture-media' > \"${base}mp4\"; fi",
            ].joined(separator: "\n") + "\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let runner = YouTubeDownloadRunner(
            executableURL: executable,
            ffmpegRemuxer: FixtureYouTubeRemuxer(),
            diagnosticLog: makeIsolatedDiagnosticLog(directory: directory)
        )
        let destination = directory.appendingPathComponent("video.mp4")
        do {
            _ = try await runner.run(
                makeYouTubeRequest(destination: destination),
                control: { .continue },
                progress: { _ in }
            )
            XCTFail("expected the probe network failure to surface")
        } catch let error as YouTubeDownloadError {
            // 网络类别保留，而不是直播不支持/未知。
            XCTAssertEqual(error, .networkFailure)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// 第二轮 §P1-1：成功分支只解析 stdout——合法 not_live JSON + 非空 stderr
    /// （Cookie 加载/运行提示）必须被放行并进入下载分支；第四轮 R3：非空 stderr 进私密诊断，
    /// 常规行只有结构化标记。
    func testLiveProbeAllowsVODWithNonEmptyStderr() async throws {
        let directory = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("download-started")
        let executable = try makeStdoutStderrBranchingExecutable(
            directory: directory,
            probeStdout: #"{"live_status": "not_live"}"#,
            probeStderr: "WARNING: [youtube] Falling back to generic extractor config",
            marker: marker
        )
        let captured = makeCapturedDiagnosticLog(directory: directory)
        let runner = YouTubeDownloadRunner(
            executableURL: executable,
            ffmpegRemuxer: FixtureYouTubeRemuxer(),
            diagnosticLog: captured.log
        )
        let destination = directory.appendingPathComponent("video.mp4")
        let result = try await runner.run(
            makeYouTubeRequest(destination: destination),
            control: { .continue },
            progress: { _ in }
        )
        XCTAssertEqual(result.destination, destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        // 第四轮 R3：成功探测的非空 stderr 不得被丢弃——私密日志保留原文，
        // 常规行只含结构化标记，不泄露原始文本。
        let privateText = try String(contentsOf: captured.privateURL, encoding: .utf8)
        XCTAssertTrue(privateText.contains("event=ytdlp.liveProbeNote"))
        XCTAssertTrue(privateText.contains("Falling back to generic extractor config"))
        let note = try XCTUnwrap(captured.regular.values.last(where: { $0.contains("liveProbeNote") }))
        XCTAssertTrue(note.contains("excerpt=stderrPresent=true"))
        XCTAssertFalse(note.contains("generic extractor"))
    }

    /// 第二轮 §P1-1：活动直播 JSON 在 stdout、stderr 非空时仍须拦截；第四轮 R3：
    /// 拦截现场的 stderr 一并进私密诊断。
    func testLiveProbeBlocksLiveEvenWithNonEmptyStderr() async throws {
        let directory = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("download-started")
        let executable = try makeStdoutStderrBranchingExecutable(
            directory: directory,
            probeStdout: #"{"is_live": true, "live_status": "is_live"}"#,
            probeStderr: "WARNING: [youtube] cookie loading note",
            marker: marker
        )
        let captured = makeCapturedDiagnosticLog(directory: directory)
        let runner = YouTubeDownloadRunner(
            executableURL: executable,
            ffmpegRemuxer: FixtureYouTubeRemuxer(),
            diagnosticLog: captured.log
        )
        let destination = directory.appendingPathComponent("video.mp4")
        do {
            _ = try await runner.run(
                makeYouTubeRequest(destination: destination),
                control: { .continue },
                progress: { _ in }
            )
            XCTFail("expected the live stream to be blocked")
        } catch let error as YouTubeDownloadError {
            XCTAssertEqual(error, .liveStreamUnsupported)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        // 私密记录保留 stderr 现场；常规行只有安全的阶段标记。
        let privateText = try String(contentsOf: captured.privateURL, encoding: .utf8)
        XCTAssertTrue(privateText.contains("event=ytdlp.liveBlocked"))
        XCTAssertTrue(privateText.contains("cookie loading note"))
        let regular = try XCTUnwrap(captured.regular.values.last)
        XCTAssertTrue(regular.contains("excerpt=livePhase=currentlyLive"))
        XCTAssertFalse(regular.contains("cookie loading note"))
    }

    /// 第二轮 §P1-1/P2-1：stdout 非法但 stderr 有文字时 fail-closed 为
    /// YTDLP_LIVE_STATUS_UNKNOWN；常规行只含 reason code，私密日志保留两路原始上下文。
    func testLiveProbeInvalidJSONFailsClosedAndKeepsDiagnostics() async throws {
        let directory = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("download-started")
        let executable = try makeStdoutStderrBranchingExecutable(
            directory: directory,
            probeStdout: "this is not json",
            probeStderr: "WARNING: unable to extract initial data; retrying player",
            marker: marker
        )
        let captured = makeCapturedDiagnosticLog(directory: directory)
        let runner = YouTubeDownloadRunner(
            executableURL: executable,
            ffmpegRemuxer: FixtureYouTubeRemuxer(),
            diagnosticLog: captured.log
        )
        let destination = directory.appendingPathComponent("video.mp4")
        do {
            _ = try await runner.run(
                makeYouTubeRequest(destination: destination),
                control: { .continue },
                progress: { _ in }
            )
            XCTFail("expected an unknown live status to fail closed")
        } catch let error as YouTubeDownloadError {
            XCTAssertEqual(error, .liveStatusUnknown)
            XCTAssertEqual(error.code, "YTDLP_LIVE_STATUS_UNKNOWN")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        // 常规行：只有 reason code 与结构化字段，不含原始内容。
        let regular = try XCTUnwrap(captured.regular.values.last)
        XCTAssertTrue(regular.contains("event=ytdlp.liveProbeUnknown"))
        XCTAssertTrue(regular.contains("excerpt=reason=invalidJSON"))
        XCTAssertFalse(regular.contains("this is not json"))
        XCTAssertFalse(regular.contains("unable to extract initial data"))

        // 私密记录：同一 event ID 下保留足以定位原因的原始上下文。
        let privateText = try String(contentsOf: captured.privateURL, encoding: .utf8)
        let eventID = try XCTUnwrap(
            regular.range(of: #"eventId=[0-9A-Fa-f-]+"#, options: .regularExpression)
                .map { String(regular[$0].dropFirst("eventId=".count)) })
        XCTAssertTrue(privateText.contains("eventId=\(eventID)"))
        XCTAssertTrue(privateText.contains("reason=invalidJSON"))
        XCTAssertTrue(privateText.contains("this is not json"))
        XCTAssertTrue(privateText.contains("unable to extract initial data"))
    }

    /// 第二轮 §P2-1：退出成功但 stdout 为空 → reason=emptyStdout，同样不得放行。
    func testLiveProbeEmptyStdoutFailsClosed() async throws {
        let directory = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("download-started")
        let executable = try makeStdoutStderrBranchingExecutable(
            directory: directory,
            probeStdout: "",
            probeStderr: "WARNING: no player response",
            marker: marker
        )
        let captured = makeCapturedDiagnosticLog(directory: directory)
        let runner = YouTubeDownloadRunner(
            executableURL: executable,
            ffmpegRemuxer: FixtureYouTubeRemuxer(),
            diagnosticLog: captured.log
        )
        let destination = directory.appendingPathComponent("video.mp4")
        do {
            _ = try await runner.run(
                makeYouTubeRequest(destination: destination),
                control: { .continue },
                progress: { _ in }
            )
            XCTFail("expected an empty stdout to fail closed")
        } catch let error as YouTubeDownloadError {
            XCTAssertEqual(error, .liveStatusUnknown)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let privateText = try String(contentsOf: captured.privateURL, encoding: .utf8)
        XCTAssertTrue(privateText.contains("reason=emptyStdout"))
    }

    /// 第二轮 §P2-1：探测超时 → reason=timeout，不得进入正式下载。
    func testLiveProbeTimeoutFailsClosed() async throws {
        let directory = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("download-started")
        let executable = directory.appendingPathComponent("fake-yt-dlp")
        let script =
            [
                "#!/bin/sh",
                "simulate=0",
                "output=\"\"",
                "for arg in \"$@\"; do",
                "  if [ \"$arg\" = \"--simulate\" ]; then simulate=1; fi",
                "  if [ \"$prev\" = \"--output\" ]; then output=\"$arg\"; fi",
                "  prev=\"$arg\"",
                "done",
                // 探测分支挂起，等待被超时终止（退出码 -1）。
                "if [ \"$simulate\" = \"1\" ]; then",
                "  sleep 30",
                "  exit 0",
                "fi",
                "touch \"\(marker.path)\"",
                "base=$(printf '%s' \"$output\" | sed 's/%(ext)s$//')",
                "if [ -n \"$output\" ]; then printf 'fixture-media' > \"${base}mp4\"; fi",
            ].joined(separator: "\n") + "\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let captured = makeCapturedDiagnosticLog(directory: directory)
        let runner = YouTubeDownloadRunner(
            executableURL: executable,
            ffmpegRemuxer: FixtureYouTubeRemuxer(),
            diagnosticLog: captured.log,
            liveProbeTimeout: 1
        )
        let destination = directory.appendingPathComponent("video.mp4")
        do {
            _ = try await runner.run(
                makeYouTubeRequest(destination: destination),
                control: { .continue },
                progress: { _ in }
            )
            XCTFail("expected a probe timeout to fail closed")
        } catch let error as YouTubeDownloadError {
            XCTAssertEqual(error, .liveStatusUnknown)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let privateText = try String(contentsOf: captured.privateURL, encoding: .utf8)
        XCTAssertTrue(privateText.contains("reason=timeout"))
    }

    /// 第二轮 §P2-1：进程异常类未知结果同样携带 reason 与上下文；取消不在此列（传播）。
    func testLiveProbeUnknownReasonsCarryContext() {
        let processError = YouTubeDownloadRunner.LiveProbeUnknown(
            reason: .processError,
            stdout: nil,
            stderr: nil,
            errorDescription: "The operation couldn’t be completed"
        )
        XCTAssertTrue(processError.combinedContext.contains("reason=processError"))
        XCTAssertTrue(processError.combinedContext.contains("error:"))

        let invalidJSON = YouTubeDownloadRunner.LiveProbeUnknown(
            reason: .invalidJSON,
            stdout: "{ truncated",
            stderr: "WARNING: partial",
            errorDescription: nil
        )
        XCTAssertTrue(invalidJSON.combinedContext.contains("reason=invalidJSON"))
        XCTAssertTrue(invalidJSON.combinedContext.contains("stdout: |"))
        XCTAssertTrue(invalidJSON.combinedContext.contains("stderr: |"))
    }

    /// 探测分支分别控制 stdout 与 stderr 的伪造 yt-dlp。
    private func makeStdoutStderrBranchingExecutable(
        directory: URL,
        probeStdout: String,
        probeStderr: String,
        marker: URL
    ) throws -> URL {
        let executable = directory.appendingPathComponent("fake-yt-dlp")
        var lines = [
            "#!/bin/sh",
            "simulate=0",
            "output=\"\"",
            "for arg in \"$@\"; do",
            "  if [ \"$arg\" = \"--simulate\" ]; then simulate=1; fi",
            "  if [ \"$prev\" = \"--output\" ]; then output=\"$arg\"; fi",
            "  prev=\"$arg\"",
            "done",
            "if [ \"$simulate\" = \"1\" ]; then",
        ]
        if !probeStdout.isEmpty {
            lines.append("  cat <<'EOF'")
            lines.append(probeStdout)
            lines.append("EOF")
        }
        if !probeStderr.isEmpty {
            lines.append("  cat >&2 <<'EOF'")
            lines.append(probeStderr)
            lines.append("EOF")
        }
        lines += [
            "  exit 0",
            "fi",
            "touch \"\(marker.path)\"",
            "base=$(printf '%s' \"$output\" | sed 's/%(ext)s$//')",
            "if [ -n \"$output\" ]; then printf 'fixture-media' > \"${base}mp4\"; fi",
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    /// 双通道诊断日志：常规行捕获 + 隔离私密文件。
    private func makeCapturedDiagnosticLog(directory: URL) -> (
        log: YouTubeDiagnosticEventLog, privateURL: URL, regular: RunnerRegularSinkCapture
    ) {
        let capture = RunnerRegularSinkCapture()
        let privateURL = directory.appendingPathComponent("macidm-private.log")
        let log = YouTubeDiagnosticEventLog(
            privateLogURL: privateURL,
            regularSink: { capture.append($0) },
            enabled: true
        )
        return (log, privateURL, capture)
    }

    func testRunnerAllowsEndedReplayAndDownloadsNormally() async throws {
        // 已结束回放与普通 VOD 同样放行：探测通过后下载分支正常执行。
        let directory = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("download-started")
        let executable = try makeLiveBranchingExecutable(
            directory: directory,
            probeJSON: #"{"was_live": true, "live_status": "was_live"}"#,
            marker: marker
        )
        let runner = YouTubeDownloadRunner(
            executableURL: executable,
            ffmpegRemuxer: FixtureYouTubeRemuxer(),
            diagnosticLog: makeIsolatedDiagnosticLog(directory: directory)
        )
        let destination = directory.appendingPathComponent("video.mp4")
        let result = try await runner.run(
            makeYouTubeRequest(destination: destination),
            control: { .continue },
            progress: { _ in }
        )
        XCTAssertEqual(result.destination, destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }
}

/// Thread-safe mutable URL box for injecting the "current" yt-dlp path
/// into a runner under test.
private final class ExecutableResolverBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?

    var url: URL? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ url: URL?) {
        lock.lock()
        stored = url
        lock.unlock()
    }
}

private struct FixtureYouTubeRemuxer: FFmpegRemuxing {
    func remux(_ request: FFmpegRemuxRequest) async throws -> FFmpegRemuxResult {
        let bytes = try Data(contentsOf: request.inputURL)
        try bytes.write(to: request.outputURL, options: .atomic)
        return FFmpegRemuxResult(
            destination: request.outputURL,
            byteCount: Int64(bytes.count),
            sha256: "fixture",
            probe: FFmpegProbeResult(
                formatName: "mov,mp4",
                duration: 1,
                streams: [
                    FFmpegStreamInfo(
                        index: 0,
                        codecName: "h264",
                        codecType: "video",
                        width: 32,
                        height: 32,
                        duration: 1
                    )
                ]
            )
        )
    }
}

/// 记录收到的 remux 请求，用于断言输出容器契约（§4.4）。
private final class RecordingYouTubeRemuxer: FFmpegRemuxing, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FFmpegRemuxRequest] = []

    var recorded: [FFmpegRemuxRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    private func append(_ request: FFmpegRemuxRequest) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }

    func remux(_ request: FFmpegRemuxRequest) async throws -> FFmpegRemuxResult {
        append(request)
        let bytes = try Data(contentsOf: request.inputURL)
        try bytes.write(to: request.outputURL, options: .atomic)
        return FFmpegRemuxResult(
            destination: request.outputURL,
            byteCount: Int64(bytes.count),
            sha256: "fixture",
            probe: FFmpegProbeResult(
                formatName: "mov,mp4",
                duration: 1,
                streams: [
                    FFmpegStreamInfo(
                        index: 0,
                        codecName: "vp9",
                        codecType: "video",
                        width: 32,
                        height: 32,
                        duration: 1
                    )
                ]
            )
        )
    }
}

private final class RunnerRegularSinkCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }
}

private final class ProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DownloadProgress] = []

    var values: [DownloadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: DownloadProgress) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
