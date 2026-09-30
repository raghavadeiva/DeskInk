import CoreMedia
import Foundation

/// Local-only, opt-in recording core. It owns no UI state and remains idle until
/// `start(in:metadata:)` is called with a user-selected parent folder.
final class SessionRecorder {
    private static let schemaVersion = 1

    private let configuration: SessionRecorderConfiguration
    private let mediaEncoder: SessionMediaEncoding
    private let fileManager: FileManager
    private let now: () -> Date
    private let makeUUID: () -> UUID
    private let stateQueue = DispatchQueue(label: "com.example.DeskInk.recording.state")
    private let mediaQueue = DispatchQueue(label: "com.example.DeskInk.recording.media")
    private let eventEncoder = JSONEncoder()
    private let metadataEncoder = JSONEncoder()

    private var activeSession: ActiveSession?

    init(
        configuration: SessionRecorderConfiguration = SessionRecorderConfiguration(),
        mediaEncoder: SessionMediaEncoding = CoreImageSessionMediaEncoder(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        makeUUID: @escaping () -> UUID = UUID.init
    ) {
        self.configuration = configuration
        self.mediaEncoder = mediaEncoder
        self.fileManager = fileManager
        self.now = now
        self.makeUUID = makeUUID

        eventEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        eventEncoder.dateEncodingStrategy = .iso8601
        eventEncoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        metadataEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        metadataEncoder.dateEncodingStrategy = .iso8601
    }

    var isRecording: Bool {
        stateQueue.sync {
            guard let activeSession else { return false }
            return !activeSession.isStopping
        }
    }

    var sessionURL: URL? {
        stateQueue.sync { activeSession?.directoryURL }
    }

    @discardableResult
    func start(in parentDirectoryURL: URL, metadata: SessionRecorderMetadata) throws -> URL {
        try stateQueue.sync {
            guard activeSession == nil else { throw SessionRecorderError.alreadyRecording }
            try validateConfiguration()

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: parentDirectoryURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw SessionRecorderError.parentIsNotDirectory
            }

            let sessionID = makeUUID()
            let directoryURL = parentDirectoryURL.appendingPathComponent(
                sessionDirectoryName(date: now(), id: sessionID),
                isDirectory: true
            )
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: false)
                try fileManager.createDirectory(
                    at: directoryURL.appendingPathComponent("tip-crops", isDirectory: true),
                    withIntermediateDirectories: false
                )
                try fileManager.createDirectory(
                    at: directoryURL.appendingPathComponent("full-frames", isDirectory: true),
                    withIntermediateDirectories: false
                )

                let metadataDocument = MetadataDocument(
                    schemaVersion: Self.schemaVersion,
                    sessionID: sessionID,
                    startedAt: now(),
                    appVersion: metadata.appVersion,
                    gitHash: metadata.gitHash,
                    captureDevice: metadata.captureDevice,
                    user: metadata.user,
                    recordingPolicy: RecordingPolicy(
                        localOnly: true,
                        maximumDiskBytes: configuration.maximumDiskBytes,
                        tipCropPixelSize: configuration.tipCropPixelSize,
                        fullFrameIntervalSeconds: configuration.fullFrameInterval,
                        jpegQuality: configuration.jpegQuality
                    )
                )
                var metadataData = try metadataEncoder.encode(metadataDocument)
                metadataData.append(0x0A)
                guard Int64(metadataData.count) <= configuration.maximumDiskBytes else {
                    throw SessionRecorderError.metadataExceedsDiskCap
                }
                let metadataURL = directoryURL.appendingPathComponent("metadata.json")
                try metadataData.write(to: metadataURL, options: .withoutOverwriting)
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o444))],
                    ofItemAtPath: metadataURL.path
                )

                let eventLogURL = directoryURL.appendingPathComponent("events.jsonl")
                guard fileManager.createFile(atPath: eventLogURL.path, contents: nil),
                      let eventHandle = try? FileHandle(forWritingTo: eventLogURL) else {
                    throw SessionRecorderError.couldNotCreateEventLog
                }

                let session = ActiveSession(
                    id: sessionID,
                    directoryURL: directoryURL,
                    metadataURL: metadataURL,
                    eventLogURL: eventLogURL,
                    eventHandle: eventHandle,
                    bytesWritten: Int64(metadataData.count)
                )
                activeSession = session
                let didAppendStart = appendEvent(
                    type: "sessionStarted",
                    hostTimestamp: nil,
                    payload: SessionLifecyclePayload(reason: nil),
                    to: session
                )
                guard didAppendStart else {
                    try? eventHandle.close()
                    activeSession = nil
                    throw SessionRecorderError.eventLogReachedDiskCap
                }
                return directoryURL
            } catch {
                activeSession = nil
                try? fileManager.removeItem(at: directoryURL)
                throw error
            }
        }
    }

    func stageFrame(_ frame: SessionFrameStage) {
        stateQueue.async { [weak self] in
            guard let self, let session = self.activeSession, !session.isStopping else { return }

            let cameraRecord = FrameCameraRecord(frame)
            let pending = session.pendingFrames[frame.traceID] ?? PendingFrame(
                insertionOrder: session.nextPendingOrder
            )
            if session.pendingFrames[frame.traceID] == nil {
                session.nextPendingOrder += 1
            }
            if pending.camera != nil {
                session.issueCount += 1
                self.appendIssue(
                    code: "duplicateCameraStage",
                    message: "The first camera stage for this trace was retained.",
                    traceID: frame.traceID,
                    to: session
                )
            } else {
                pending.camera = cameraRecord
                pending.media = self.requestMedia(for: frame, in: session)
            }
            session.pendingFrames[frame.traceID] = pending
            self.finishFrameIfReady(traceID: frame.traceID, in: session)
            self.flushOldestPendingFramesIfNeeded(in: session)
        }
    }

    func finalizeFrame(_ decision: SessionFrameDecision) {
        stateQueue.async { [weak self] in
            guard let self, let session = self.activeSession, !session.isStopping else { return }
            let pending = session.pendingFrames[decision.traceID] ?? PendingFrame(
                insertionOrder: session.nextPendingOrder
            )
            if session.pendingFrames[decision.traceID] == nil {
                session.nextPendingOrder += 1
            }
            if pending.application != nil {
                session.issueCount += 1
                self.appendIssue(
                    code: "duplicateApplicationDecision",
                    message: "The first application decision for this trace was retained.",
                    traceID: decision.traceID,
                    to: session
                )
            } else {
                pending.application = FrameApplicationRecord(decision)
            }
            session.pendingFrames[decision.traceID] = pending
            self.finishFrameIfReady(traceID: decision.traceID, in: session)
            self.flushOldestPendingFramesIfNeeded(in: session)
        }
    }

    func recordSpaceState(
        isDown: Bool,
        eventTimestamp: TimeInterval? = nil,
        hostTimestamp: TimeInterval,
        source: SpaceKeyEventSource? = nil
    ) {
        stateQueue.async { [weak self] in
            guard let self, let session = self.activeSession, !session.isStopping else { return }
            _ = self.appendEvent(
                type: "spaceState",
                hostTimestamp: hostTimestamp,
                payload: SpaceStatePayload(
                    isDown: isDown,
                    eventTimestamp: eventTimestamp,
                    source: source
                ),
                to: session
            )
        }
    }

    func recordStrokeBoundary(
        _ boundary: SessionStrokeBoundary,
        strokeID: UUID,
        pageIndex: Int,
        hostTimestamp: TimeInterval
    ) {
        stateQueue.async { [weak self] in
            guard let self, let session = self.activeSession, !session.isStopping else { return }
            _ = self.appendEvent(
                type: "strokeBoundary",
                hostTimestamp: hostTimestamp,
                payload: StrokeBoundaryPayload(
                    boundary: boundary,
                    strokeID: strokeID,
                    pageIndex: pageIndex
                ),
                to: session
            )
        }
    }

    @discardableResult
    func stop(reason: String? = nil) throws -> SessionRecordingSummary {
        let sessionID: UUID = try stateQueue.sync {
            guard let session = activeSession else { throw SessionRecorderError.notRecording }
            session.isStopping = true
            return session.id
        }

        // Drain media outside the state queue. Each media job is then guaranteed
        // to have enqueued its outcome before the final state-queue barrier.
        mediaQueue.sync {}

        return try stateQueue.sync {
            guard let session = activeSession, session.id == sessionID else {
                throw SessionRecorderError.notRecording
            }

            flushAllPendingFrames(in: session)
            _ = appendEvent(
                type: "sessionStopped",
                hostTimestamp: nil,
                payload: SessionLifecyclePayload(reason: reason),
                to: session
            )
            try session.eventHandle.synchronize()
            try session.eventHandle.close()
            try? fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o444))],
                ofItemAtPath: session.eventLogURL.path
            )

            let summary = SessionRecordingSummary(
                sessionURL: session.directoryURL,
                eventCount: session.eventCount,
                frameCount: session.frameCount,
                mediaFileCount: session.mediaFileCount,
                droppedMediaCount: session.droppedMediaCount,
                issueCount: session.issueCount,
                bytesWritten: session.bytesWritten
            )
            activeSession = nil
            return summary
        }
    }

    private func validateConfiguration() throws {
        guard configuration.maximumDiskBytes > 0 else {
            throw SessionRecorderError.invalidConfiguration("maximumDiskBytes must be positive")
        }
        guard configuration.telemetryReserveBytes >= 0 else {
            throw SessionRecorderError.invalidConfiguration("telemetryReserveBytes cannot be negative")
        }
        guard configuration.maximumPendingMediaJobs >= 0 else {
            throw SessionRecorderError.invalidConfiguration("maximumPendingMediaJobs cannot be negative")
        }
        guard configuration.maximumPendingFrames > 0 else {
            throw SessionRecorderError.invalidConfiguration("maximumPendingFrames must be positive")
        }
        guard configuration.fullFrameInterval > 0 else {
            throw SessionRecorderError.invalidConfiguration("fullFrameInterval must be positive")
        }
        guard configuration.tipCropPixelSize > 0 else {
            throw SessionRecorderError.invalidConfiguration("tipCropPixelSize must be positive")
        }
        guard configuration.jpegQuality.isFinite,
              (0...1).contains(configuration.jpegQuality) else {
            throw SessionRecorderError.invalidConfiguration("jpegQuality must be between zero and one")
        }
    }

    private func sessionDirectoryName(date: Date, id: UUID) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "DeskInk-\(formatter.string(from: date))-\(id.uuidString.prefix(8)).deskink-session"
    }

    private func finishFrameIfReady(traceID: FrameTraceID, in session: ActiveSession) {
        guard let pending = session.pendingFrames[traceID],
              pending.camera != nil,
              pending.application != nil else { return }
        writeFrame(traceID: traceID, pending: pending, completion: .complete, to: session)
        session.pendingFrames.removeValue(forKey: traceID)
    }

    private func flushOldestPendingFramesIfNeeded(in session: ActiveSession) {
        while session.pendingFrames.count > configuration.maximumPendingFrames,
              let oldest = session.pendingFrames.min(by: {
                  $0.value.insertionOrder < $1.value.insertionOrder
              }) {
            let completion: FrameCompletionStatus = oldest.value.camera == nil
                ? .missingCameraStage
                : .missingApplicationDecision
            writeFrame(
                traceID: oldest.key,
                pending: oldest.value,
                completion: completion,
                to: session
            )
            session.pendingFrames.removeValue(forKey: oldest.key)
            session.issueCount += 1
        }
    }

    private func flushAllPendingFrames(in session: ActiveSession) {
        let ordered = session.pendingFrames.sorted {
            $0.value.insertionOrder < $1.value.insertionOrder
        }
        for (traceID, pending) in ordered {
            let completion: FrameCompletionStatus = pending.camera == nil
                ? .missingCameraStage
                : .missingApplicationDecision
            writeFrame(traceID: traceID, pending: pending, completion: completion, to: session)
            session.issueCount += 1
        }
        session.pendingFrames.removeAll()
    }

    private func writeFrame(
        traceID: FrameTraceID,
        pending: PendingFrame,
        completion: FrameCompletionStatus,
        to session: ActiveSession
    ) {
        if appendEvent(
            type: "frame",
            hostTimestamp: pending.camera?.callbackHostTimestamp,
            payload: FramePayload(
                traceID: traceID,
                completion: completion,
                camera: pending.camera,
                application: pending.application,
                requestedMedia: pending.media
            ),
            to: session
        ) {
            session.frameCount += 1
        }
    }

    private func requestMedia(
        for frame: SessionFrameStage,
        in session: ActiveSession
    ) -> [MediaReference] {
        guard let pixelBuffer = frame.pixelBuffer else { return [] }
        var references: [MediaReference] = []
        if let tip = frame.trackerOutput.rawCameraPoint ?? frame.trackerOutput.cameraPoint {
            let reference = mediaReference(for: frame.traceID, kind: .tipCrop)
            references.append(reference)
            enqueueMedia(
                reference: reference,
                request: .tipCrop(center: tip, pixelSize: configuration.tipCropPixelSize),
                pixelBuffer: pixelBuffer,
                traceID: frame.traceID,
                in: session
            )
        }

        let timestamp = frame.callbackHostTimestamp
        if timestamp.isFinite,
           session.lastFullFrameHostTimestamp == nil ||
           timestamp - (session.lastFullFrameHostTimestamp ?? timestamp) >= configuration.fullFrameInterval {
            session.lastFullFrameHostTimestamp = timestamp
            let reference = mediaReference(for: frame.traceID, kind: .fullFrame)
            references.append(reference)
            enqueueMedia(
                reference: reference,
                request: .fullFrame,
                pixelBuffer: pixelBuffer,
                traceID: frame.traceID,
                in: session
            )
        }
        return references
    }

    private func mediaReference(for traceID: FrameTraceID, kind: MediaKind) -> MediaReference {
        let stem = "\(traceID.captureSessionID.uuidString.lowercased())-\(String(format: "%010d", traceID.frameIndex)).jpg"
        switch kind {
        case .tipCrop:
            return MediaReference(kind: kind, relativePath: "tip-crops/\(stem)")
        case .fullFrame:
            return MediaReference(kind: kind, relativePath: "full-frames/\(stem)")
        }
    }

    private func enqueueMedia(
        reference: MediaReference,
        request: SessionMediaRequest,
        pixelBuffer: CVPixelBuffer,
        traceID: FrameTraceID,
        in session: ActiveSession
    ) {
        guard session.pendingMediaJobs < configuration.maximumPendingMediaJobs else {
            session.droppedMediaCount += 1
            appendMediaOutcome(
                reference: reference,
                traceID: traceID,
                status: .droppedBackpressure,
                message: "The bounded media queue was full; telemetry was retained.",
                to: session
            )
            return
        }

        session.pendingMediaJobs += 1
        let sessionID = session.id
        let destinationURL = session.directoryURL.appendingPathComponent(reference.relativePath)
        let encoder = mediaEncoder
        let quality = configuration.jpegQuality
        mediaQueue.async { [weak self] in
            guard let self else { return }
            do {
                let data = try encoder.jpegData(
                    from: pixelBuffer,
                    request: request,
                    quality: quality
                )
                let reserved = self.stateQueue.sync {
                    self.reserveMediaBytes(
                        Int64(data.count),
                        sessionID: sessionID
                    )
                }
                guard reserved else {
                    self.stateQueue.async {
                        self.finishMediaJob(
                            sessionID: sessionID,
                            traceID: traceID,
                            reference: reference,
                            reservedBytes: 0,
                            status: .droppedDiskCap,
                            message: "The media portion of the recording reached its disk budget."
                        )
                    }
                    return
                }

                do {
                    try data.write(to: destinationURL, options: .withoutOverwriting)
                    self.stateQueue.async {
                        self.finishMediaJob(
                            sessionID: sessionID,
                            traceID: traceID,
                            reference: reference,
                            reservedBytes: Int64(data.count),
                            status: .written,
                            message: nil
                        )
                    }
                } catch {
                    self.stateQueue.async {
                        self.finishMediaJob(
                            sessionID: sessionID,
                            traceID: traceID,
                            reference: reference,
                            reservedBytes: Int64(data.count),
                            status: .failed,
                            message: error.localizedDescription
                        )
                    }
                }
            } catch {
                self.stateQueue.async {
                    self.finishMediaJob(
                        sessionID: sessionID,
                        traceID: traceID,
                        reference: reference,
                        reservedBytes: 0,
                        status: .failed,
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func reserveMediaBytes(_ byteCount: Int64, sessionID: UUID) -> Bool {
        guard byteCount >= 0,
              let session = activeSession,
              session.id == sessionID else { return false }
        let reserve = min(configuration.telemetryReserveBytes, configuration.maximumDiskBytes / 2)
        let mediaCeiling = configuration.maximumDiskBytes - reserve
        let projected = session.bytesWritten + session.reservedMediaBytes + byteCount
        guard projected <= mediaCeiling else { return false }
        session.reservedMediaBytes += byteCount
        return true
    }

    private func finishMediaJob(
        sessionID: UUID,
        traceID: FrameTraceID,
        reference: MediaReference,
        reservedBytes: Int64,
        status: MediaStatus,
        message: String?
    ) {
        guard let session = activeSession, session.id == sessionID else { return }
        session.pendingMediaJobs = max(0, session.pendingMediaJobs - 1)
        if reservedBytes > 0 {
            session.reservedMediaBytes = max(0, session.reservedMediaBytes - reservedBytes)
        }
        switch status {
        case .written:
            session.bytesWritten += reservedBytes
            session.mediaFileCount += 1
        case .droppedBackpressure, .droppedDiskCap:
            session.droppedMediaCount += 1
        case .failed:
            session.issueCount += 1
        }
        appendMediaOutcome(
            reference: reference,
            traceID: traceID,
            status: status,
            message: message,
            to: session
        )
    }

    private func appendMediaOutcome(
        reference: MediaReference,
        traceID: FrameTraceID,
        status: MediaStatus,
        message: String?,
        to session: ActiveSession
    ) {
        _ = appendEvent(
            type: "mediaOutcome",
            hostTimestamp: Self.hostTimestampNow(),
            payload: MediaOutcomePayload(
                traceID: traceID,
                media: reference,
                status: status,
                message: message
            ),
            to: session
        )
    }

    private func appendIssue(
        code: String,
        message: String,
        traceID: FrameTraceID?,
        to session: ActiveSession
    ) {
        _ = appendEvent(
            type: "recorderIssue",
            hostTimestamp: Self.hostTimestampNow(),
            payload: RecorderIssuePayload(code: code, message: message, traceID: traceID),
            to: session
        )
    }

    @discardableResult
    private func appendEvent<Payload: Encodable>(
        type: String,
        hostTimestamp: TimeInterval?,
        payload: Payload,
        to session: ActiveSession
    ) -> Bool {
        guard !session.telemetryClosed else { return false }
        do {
            let envelope = EventEnvelope(
                schemaVersion: Self.schemaVersion,
                sequence: session.nextEventSequence,
                type: type,
                recordedAt: now(),
                hostTimestamp: hostTimestamp,
                payload: payload
            )
            var data = try eventEncoder.encode(envelope)
            data.append(0x0A)
            let projected = session.bytesWritten + session.reservedMediaBytes + Int64(data.count)
            guard projected <= configuration.maximumDiskBytes else {
                session.telemetryClosed = true
                session.issueCount += 1
                return false
            }
            try session.eventHandle.seekToEnd()
            try session.eventHandle.write(contentsOf: data)
            session.bytesWritten += Int64(data.count)
            session.nextEventSequence += 1
            session.eventCount += 1
            return true
        } catch {
            session.issueCount += 1
            return false
        }
    }

    private static func hostTimestampNow() -> TimeInterval {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }
}

private final class ActiveSession {
    let id: UUID
    let directoryURL: URL
    let metadataURL: URL
    let eventLogURL: URL
    let eventHandle: FileHandle

    var bytesWritten: Int64
    var reservedMediaBytes: Int64 = 0
    var nextEventSequence = 0
    var nextPendingOrder = 0
    var pendingFrames: [FrameTraceID: PendingFrame] = [:]
    var lastFullFrameHostTimestamp: TimeInterval?
    var pendingMediaJobs = 0
    var eventCount = 0
    var frameCount = 0
    var mediaFileCount = 0
    var droppedMediaCount = 0
    var issueCount = 0
    var telemetryClosed = false
    var isStopping = false

    init(
        id: UUID,
        directoryURL: URL,
        metadataURL: URL,
        eventLogURL: URL,
        eventHandle: FileHandle,
        bytesWritten: Int64
    ) {
        self.id = id
        self.directoryURL = directoryURL
        self.metadataURL = metadataURL
        self.eventLogURL = eventLogURL
        self.eventHandle = eventHandle
        self.bytesWritten = bytesWritten
    }
}

private final class PendingFrame {
    let insertionOrder: Int
    var camera: FrameCameraRecord?
    var application: FrameApplicationRecord?
    var media: [MediaReference] = []

    init(insertionOrder: Int) {
        self.insertionOrder = insertionOrder
    }
}

private struct MetadataDocument: Encodable {
    let schemaVersion: Int
    let sessionID: UUID
    let startedAt: Date
    let appVersion: String
    let gitHash: String
    let captureDevice: CaptureDeviceDescriptor?
    let user: SessionUserMetadata
    let recordingPolicy: RecordingPolicy
}

private struct RecordingPolicy: Encodable {
    let localOnly: Bool
    let maximumDiskBytes: Int64
    let tipCropPixelSize: Int
    let fullFrameIntervalSeconds: TimeInterval
    let jpegQuality: Double
}

private struct EventEnvelope<Payload: Encodable>: Encodable {
    let schemaVersion: Int
    let sequence: Int
    let type: String
    let recordedAt: Date
    let hostTimestamp: TimeInterval?
    let payload: Payload
}

private struct SessionLifecyclePayload: Encodable {
    let reason: String?
}

private struct SpaceStatePayload: Encodable {
    let isDown: Bool
    let eventTimestamp: TimeInterval?
    let source: SpaceKeyEventSource?
}

private struct StrokeBoundaryPayload: Encodable {
    let boundary: SessionStrokeBoundary
    let strokeID: UUID
    let pageIndex: Int
}

private struct RecorderIssuePayload: Encodable {
    let code: String
    let message: String
    let traceID: FrameTraceID?
}

private enum FrameCompletionStatus: String, Encodable {
    case complete
    case missingCameraStage
    case missingApplicationDecision
}

private struct FramePayload: Encodable {
    let traceID: FrameTraceID
    let completion: FrameCompletionStatus
    let camera: FrameCameraRecord?
    let application: FrameApplicationRecord?
    let requestedMedia: [MediaReference]
}

private struct FrameCameraRecord: Encodable {
    let presentationTime: RecordedCMTime
    let callbackHostTimestamp: TimeInterval
    let presentationHostTimestamp: TimeInterval?
    let clockRelation: RecordedCaptureClockRelation
    let trackerOutput: TrackerOutputRecord
    let homography: [Double]?
    let calibrationCorners: [RecordedNormalizedPoint]
    let mappedPaperPoint: RecordedNormalizedPoint?

    init(_ frame: SessionFrameStage) {
        presentationTime = RecordedCMTime(frame.presentationTime)
        callbackHostTimestamp = frame.callbackHostTimestamp
        presentationHostTimestamp = frame.presentationHostTimestamp
        clockRelation = RecordedCaptureClockRelation(frame.clockRelation)
        trackerOutput = TrackerOutputRecord(frame.trackerOutput)
        homography = frame.homography
        calibrationCorners = frame.calibrationCorners.map(RecordedNormalizedPoint.init)
        mappedPaperPoint = frame.mappedPaperPoint.map(RecordedNormalizedPoint.init)
    }
}

private struct TrackerOutputRecord: Encodable {
    let rawCameraPoint: RecordedNormalizedPoint?
    let cameraPoint: RecordedNormalizedPoint?
    let confidence: Double
    let trackerKind: String

    init(_ output: SessionTrackerOutput) {
        rawCameraPoint = output.rawCameraPoint.map(RecordedNormalizedPoint.init)
        cameraPoint = output.cameraPoint.map(RecordedNormalizedPoint.init)
        confidence = output.confidence
        trackerKind = output.trackerKind
    }
}

private struct FrameApplicationRecord: Encodable {
    let decisionHostTimestamp: TimeInterval
    let inferredPenDown: Bool
    let effectivePenDown: Bool
    let acceptedForInk: Bool
    let activeStrokeID: UUID?

    init(_ decision: SessionFrameDecision) {
        decisionHostTimestamp = decision.decisionHostTimestamp
        inferredPenDown = decision.inferredPenDown
        effectivePenDown = decision.effectivePenDown
        acceptedForInk = decision.acceptedForInk
        activeStrokeID = decision.activeStrokeID
    }
}

private enum MediaKind: String, Encodable {
    case tipCrop
    case fullFrame
}

private struct MediaReference: Encodable {
    let kind: MediaKind
    let relativePath: String
}

private enum MediaStatus: String, Encodable {
    case written
    case failed
    case droppedBackpressure
    case droppedDiskCap
}

private struct MediaOutcomePayload: Encodable {
    let traceID: FrameTraceID
    let media: MediaReference
    let status: MediaStatus
    let message: String?
}
