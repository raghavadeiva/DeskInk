import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import DeskInk

@Suite("Local session recorder")
struct SessionRecorderTests {
    @Test("Recording is opt-in and a finalized frame preserves camera and app telemetry")
    func mergedFrameAndInputEvents() throws {
        let fixture = try TemporaryRecordingDirectory()
        defer { fixture.remove() }
        let sessionID = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let captureID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let recorder = SessionRecorder(
            configuration: SessionRecorderConfiguration(maximumDiskBytes: 1_000_000),
            mediaEncoder: StubMediaEncoder(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            makeUUID: { sessionID }
        )

        #expect(!recorder.isRecording)
        #expect(recorder.sessionURL == nil)

        let sessionURL = try recorder.start(
            in: fixture.url,
            metadata: SessionRecorderMetadata(
                appVersion: "1.2.3",
                gitHash: "abc123",
                captureDevice: CaptureDeviceDescriptor(
                    localizedName: "Test Camera",
                    modelID: "model",
                    uniqueID: "device-id",
                    width: 1920,
                    height: 1080,
                    targetFrameRate: 30,
                    maximumFrameRate: 60,
                    pixelFormat: "32BGRA"
                ),
                user: SessionUserMetadata(
                    penOrPencilType: "0.5 mm pencil",
                    paper: "Letter copy paper",
                    lighting: "Desk lamp",
                    deskSurface: "Oak",
                    handedness: "Right",
                    notes: "test"
                )
            )
        )
        #expect(recorder.isRecording)
        #expect(recorder.sessionURL == sessionURL)

        let traceID = FrameTraceID(captureSessionID: captureID, frameIndex: 42)
        let rawTime = CMTime(
            value: 12_345,
            timescale: 600,
            flags: [.valid, .hasBeenRounded],
            epoch: 7
        )
        recorder.stageFrame(
            SessionFrameStage(
                traceID: traceID,
                presentationTime: rawTime,
                callbackHostTimestamp: 100.25,
                presentationHostTimestamp: 100.20,
                clockRelation: .convertedToHost(mightDrift: true),
                trackerOutput: SessionTrackerOutput(
                    rawCameraPoint: NormalizedPoint(x: 0.25, y: 0.75),
                    cameraPoint: NormalizedPoint(x: 0.26, y: 0.74),
                    confidence: 0.91,
                    trackerKind: "vision"
                ),
                homography: [1, 0, 0, 0, 1, 0, 0, 0, 1],
                calibrationCorners: [
                    NormalizedPoint(x: 0.1, y: 0.1),
                    NormalizedPoint(x: 0.9, y: 0.1),
                    NormalizedPoint(x: 0.9, y: 0.9),
                    NormalizedPoint(x: 0.1, y: 0.9)
                ],
                mappedPaperPoint: NormalizedPoint(x: 0.2, y: 0.8),
                pixelBuffer: nil
            )
        )
        let strokeID = UUID()
        recorder.finalizeFrame(
            SessionFrameDecision(
                traceID: traceID,
                decisionHostTimestamp: 100.28,
                inferredPenDown: true,
                acceptedForInk: true,
                activeStrokeID: strokeID
            )
        )
        recorder.recordSpaceState(
            isDown: true,
            eventTimestamp: 9.75,
            hostTimestamp: 100.10,
            source: .keyDown
        )
        recorder.recordSpaceState(
            isDown: false,
            eventTimestamp: 10.55,
            hostTimestamp: 100.90,
            source: .keyUp
        )
        recorder.recordStrokeBoundary(.began, strokeID: strokeID, pageIndex: 0, hostTimestamp: 100.28)
        recorder.recordStrokeBoundary(.ended, strokeID: strokeID, pageIndex: 0, hostTimestamp: 100.88)

        let summary = try recorder.stop(reason: "test complete")
        #expect(!recorder.isRecording)
        #expect(summary.frameCount == 1)
        #expect(summary.mediaFileCount == 0)

        let metadata = try jsonObject(at: sessionURL.appendingPathComponent("metadata.json"))
        #expect(metadata["appVersion"] as? String == "1.2.3")
        #expect(metadata["gitHash"] as? String == "abc123")
        let user = try #require(metadata["user"] as? [String: Any])
        #expect(user["penOrPencilType"] as? String == "0.5 mm pencil")

        let events = try jsonLines(at: sessionURL.appendingPathComponent("events.jsonl"))
        let frame = try #require(events.first { $0["type"] as? String == "frame" })
        let framePayload = try #require(frame["payload"] as? [String: Any])
        #expect(framePayload["completion"] as? String == "complete")
        let camera = try #require(framePayload["camera"] as? [String: Any])
        let presentationTime = try #require(camera["presentationTime"] as? [String: Any])
        #expect(presentationTime["value"] as? Int == 12_345)
        #expect(presentationTime["timescale"] as? Int == 600)
        #expect(presentationTime["flags"] as? Int == Int(rawTime.flags.rawValue))
        #expect(presentationTime["epoch"] as? Int == 7)
        let application = try #require(framePayload["application"] as? [String: Any])
        #expect(application["inferredPenDown"] as? Bool == true)
        #expect(application["acceptedForInk"] as? Bool == true)

        let spaces = events.filter { $0["type"] as? String == "spaceState" }
        #expect(spaces.count == 2)
        #expect(spaces.compactMap { $0["hostTimestamp"] as? Double } == [100.10, 100.90])
        let spacePayloads = spaces.compactMap { $0["payload"] as? [String: Any] }
        #expect(spacePayloads.compactMap { $0["eventTimestamp"] as? Double } == [9.75, 10.55])
        #expect(spacePayloads.compactMap { $0["source"] as? String } == ["keyDown", "keyUp"])
        let boundaries = events.filter { $0["type"] as? String == "strokeBoundary" }
        #expect(boundaries.count == 2)

        let metadataPermissions = try filePermissions(
            at: sessionURL.appendingPathComponent("metadata.json")
        )
        let eventPermissions = try filePermissions(
            at: sessionURL.appendingPathComponent("events.jsonl")
        )
        #expect(metadataPermissions & 0o222 == 0)
        #expect(eventPermissions & 0o222 == 0)
    }

    @Test("Tracked frames request 128-pixel crops and full frames are throttled to two FPS")
    func mediaCadenceAndCropSize() throws {
        let fixture = try TemporaryRecordingDirectory()
        defer { fixture.remove() }
        let encoder = StubMediaEncoder(result: .success(Data(repeating: 0xAB, count: 128)))
        let recorder = SessionRecorder(
            configuration: SessionRecorderConfiguration(
                maximumDiskBytes: 1_000_000,
                maximumPendingMediaJobs: 16,
                fullFrameInterval: 0.5,
                tipCropPixelSize: 128
            ),
            mediaEncoder: encoder
        )
        _ = try recorder.start(in: fixture.url, metadata: SessionRecorderMetadata())
        let captureID = UUID()
        let pixelBuffer = try syntheticPixelBuffer(width: 320, height: 240)

        for (index, hostTimestamp) in [1.0, 1.1, 1.6].enumerated() {
            let traceID = FrameTraceID(captureSessionID: captureID, frameIndex: index)
            recorder.stageFrame(
                basicStage(
                    traceID: traceID,
                    hostTimestamp: hostTimestamp,
                    trackedPoint: NormalizedPoint(x: 0.4, y: 0.6),
                    pixelBuffer: pixelBuffer
                )
            )
            recorder.finalizeFrame(
                SessionFrameDecision(
                    traceID: traceID,
                    decisionHostTimestamp: hostTimestamp + 0.01,
                    inferredPenDown: false,
                    acceptedForInk: false
                )
            )
        }

        let summary = try recorder.stop()
        let requests = encoder.requests
        let tipRequests = requests.compactMap { request -> Int? in
            guard case let .tipCrop(_, pixelSize) = request else { return nil }
            return pixelSize
        }
        let fullFrameCount = requests.filter {
            if case .fullFrame = $0 { return true }
            return false
        }.count
        #expect(tipRequests == [128, 128, 128])
        #expect(fullFrameCount == 2)
        #expect(summary.mediaFileCount == 5)
        #expect(summary.droppedMediaCount == 0)
    }

    @Test("Media failure and backpressure do not discard frame telemetry")
    func mediaFailureKeepsTelemetry() throws {
        let fixture = try TemporaryRecordingDirectory()
        defer { fixture.remove() }
        let encoder = StubMediaEncoder(result: .failure(StubMediaError.failed))
        let recorder = SessionRecorder(
            configuration: SessionRecorderConfiguration(
                maximumDiskBytes: 1_000_000,
                maximumPendingMediaJobs: 1
            ),
            mediaEncoder: encoder
        )
        let sessionURL = try recorder.start(in: fixture.url, metadata: SessionRecorderMetadata())
        let traceID = FrameTraceID(captureSessionID: UUID(), frameIndex: 1)
        recorder.stageFrame(
            basicStage(
                traceID: traceID,
                hostTimestamp: 4,
                trackedPoint: NormalizedPoint(x: 0.5, y: 0.5),
                pixelBuffer: try syntheticPixelBuffer(width: 320, height: 240)
            )
        )
        recorder.finalizeFrame(
            SessionFrameDecision(
                traceID: traceID,
                decisionHostTimestamp: 4.01,
                inferredPenDown: true,
                acceptedForInk: true
            )
        )

        let summary = try recorder.stop()
        let events = try jsonLines(at: sessionURL.appendingPathComponent("events.jsonl"))
        #expect(events.contains { $0["type"] as? String == "frame" })
        let statuses = events
            .filter { $0["type"] as? String == "mediaOutcome" }
            .compactMap { event in
                (event["payload"] as? [String: Any])?["status"] as? String
            }
        #expect(statuses.contains("failed"))
        #expect(statuses.contains("droppedBackpressure"))
        #expect(summary.frameCount == 1)
        #expect(summary.issueCount >= 1)
        #expect(summary.droppedMediaCount >= 1)
    }

    @Test("An injected disk cap drops media without exceeding the session limit")
    func diskCap() throws {
        let fixture = try TemporaryRecordingDirectory()
        defer { fixture.remove() }
        let maximumBytes: Int64 = 32_000
        let encoder = StubMediaEncoder(result: .success(Data(repeating: 0xCD, count: 25_000)))
        let recorder = SessionRecorder(
            configuration: SessionRecorderConfiguration(
                maximumDiskBytes: maximumBytes,
                telemetryReserveBytes: 8_000,
                maximumPendingMediaJobs: 4
            ),
            mediaEncoder: encoder
        )
        let sessionURL = try recorder.start(in: fixture.url, metadata: SessionRecorderMetadata())
        let traceID = FrameTraceID(captureSessionID: UUID(), frameIndex: 9)
        recorder.stageFrame(
            basicStage(
                traceID: traceID,
                hostTimestamp: 10,
                trackedPoint: NormalizedPoint(x: 0.5, y: 0.5),
                pixelBuffer: try syntheticPixelBuffer(width: 320, height: 240)
            )
        )
        recorder.finalizeFrame(
            SessionFrameDecision(
                traceID: traceID,
                decisionHostTimestamp: 10.01,
                inferredPenDown: false,
                acceptedForInk: false
            )
        )

        let summary = try recorder.stop()
        let events = try jsonLines(at: sessionURL.appendingPathComponent("events.jsonl"))
        let statuses = events
            .filter { $0["type"] as? String == "mediaOutcome" }
            .compactMap { event in
                (event["payload"] as? [String: Any])?["status"] as? String
            }
        #expect(statuses.contains("droppedDiskCap"))
        #expect(summary.mediaFileCount == 0)
        #expect(try recursiveFileSize(at: sessionURL) <= maximumBytes)
    }

    @Test("Label corrections append to a sidecar without changing the raw log")
    func correctionsAreAppendOnlySidecar() throws {
        let fixture = try TemporaryRecordingDirectory()
        defer { fixture.remove() }
        let recorder = SessionRecorder(
            configuration: SessionRecorderConfiguration(maximumDiskBytes: 1_000_000),
            mediaEncoder: StubMediaEncoder()
        )
        let sessionURL = try recorder.start(in: fixture.url, metadata: SessionRecorderMetadata())
        _ = try recorder.stop()
        let eventURL = sessionURL.appendingPathComponent("events.jsonl")
        let rawBefore = try Data(contentsOf: eventURL)
        let traceID = FrameTraceID(captureSessionID: UUID(), frameIndex: 3)
        let store = try SessionLabelCorrectionStore(sessionURL: sessionURL)
        try store.append(
            SessionLabelCorrection(
                traceID: traceID,
                correctedPenDown: true,
                correctedAt: Date(timeIntervalSince1970: 100),
                note: "contact begins"
            )
        )
        try store.append(
            SessionLabelCorrection(
                traceID: traceID,
                correctedPenDown: false,
                correctedAt: Date(timeIntervalSince1970: 101),
                note: "contact ends"
            )
        )

        #expect(try Data(contentsOf: eventURL) == rawBefore)
        let corrections = try jsonLines(
            at: sessionURL.appendingPathComponent(SessionLabelCorrectionStore.fileName)
        )
        #expect(corrections.count == 2)
    }

    private func basicStage(
        traceID: FrameTraceID,
        hostTimestamp: TimeInterval,
        trackedPoint: NormalizedPoint?,
        pixelBuffer: CVPixelBuffer?
    ) -> SessionFrameStage {
        SessionFrameStage(
            traceID: traceID,
            presentationTime: CMTime(seconds: hostTimestamp, preferredTimescale: 600),
            callbackHostTimestamp: hostTimestamp,
            presentationHostTimestamp: hostTimestamp - 0.01,
            clockRelation: .hostClock,
            trackerOutput: SessionTrackerOutput(
                rawCameraPoint: trackedPoint,
                cameraPoint: trackedPoint,
                confidence: trackedPoint == nil ? 0 : 0.95,
                trackerKind: "test"
            ),
            homography: nil,
            calibrationCorners: [],
            mappedPaperPoint: trackedPoint,
            pixelBuffer: pixelBuffer
        )
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func jsonLines(at url: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        return try data.split(separator: 0x0A).map { line in
            try #require(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
        }
    }

    private func filePermissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
    }

    private func syntheticPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        return try #require(pixelBuffer)
    }

    private func recursiveFileSize(at directoryURL: URL) throws -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: keys
            )
        )
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}

private final class StubMediaEncoder: SessionMediaEncoding {
    private let lock = NSLock()
    private let result: Result<Data, Error>
    private var storedRequests: [SessionMediaRequest] = []

    init(result: Result<Data, Error> = .success(Data())) {
        self.result = result
    }

    var requests: [SessionMediaRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    func jpegData(
        from pixelBuffer: CVPixelBuffer,
        request: SessionMediaRequest,
        quality: Double
    ) throws -> Data {
        lock.lock()
        storedRequests.append(request)
        lock.unlock()
        return try result.get()
    }
}

private enum StubMediaError: Error {
    case failed
}

private final class TemporaryRecordingDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DeskInkRecorderTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
