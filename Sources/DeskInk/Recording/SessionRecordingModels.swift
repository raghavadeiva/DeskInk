import CoreMedia
import CoreVideo
import Foundation

struct RecordedCMTime: Codable, Equatable, Sendable {
    let value: Int64
    let timescale: Int32
    let flags: UInt32
    let epoch: Int64

    init(_ time: CMTime) {
        value = time.value
        timescale = time.timescale
        flags = time.flags.rawValue
        epoch = time.epoch
    }

    var cmTime: CMTime {
        CMTime(
            value: value,
            timescale: timescale,
            flags: CMTimeFlags(rawValue: flags),
            epoch: epoch
        )
    }
}

struct RecordedNormalizedPoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double

    init(_ point: NormalizedPoint) {
        x = point.x
        y = point.y
    }

    var normalizedPoint: NormalizedPoint {
        NormalizedPoint(x: x, y: y)
    }
}

struct RecordedCaptureClockRelation: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case unverified
        case hostClock
        case convertedToHost
        case invalid
    }

    let kind: Kind
    let mightDrift: Bool?

    init(_ relation: CaptureClockRelation) {
        switch relation {
        case .unverified:
            kind = .unverified
            mightDrift = nil
        case .hostClock:
            kind = .hostClock
            mightDrift = nil
        case let .convertedToHost(mightDrift):
            kind = .convertedToHost
            self.mightDrift = mightDrift
        case .invalid:
            kind = .invalid
            mightDrift = nil
        }
    }
}

struct SessionUserMetadata: Codable, Equatable, Sendable {
    var penOrPencilType: String
    var paper: String
    var lighting: String
    var deskSurface: String
    var handedness: String
    var notes: String

    init(
        penOrPencilType: String = "",
        paper: String = "",
        lighting: String = "",
        deskSurface: String = "",
        handedness: String = "",
        notes: String = ""
    ) {
        self.penOrPencilType = penOrPencilType
        self.paper = paper
        self.lighting = lighting
        self.deskSurface = deskSurface
        self.handedness = handedness
        self.notes = notes
    }
}

struct SessionRecorderMetadata: Equatable, Sendable {
    var appVersion: String
    var gitHash: String
    var captureDevice: CaptureDeviceDescriptor?
    var user: SessionUserMetadata

    init(
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
        gitHash: String = "unknown",
        captureDevice: CaptureDeviceDescriptor? = nil,
        user: SessionUserMetadata = SessionUserMetadata()
    ) {
        self.appVersion = appVersion
        self.gitHash = gitHash
        self.captureDevice = captureDevice
        self.user = user
    }
}

struct SessionTrackerOutput: Equatable, Sendable {
    let rawCameraPoint: NormalizedPoint?
    let cameraPoint: NormalizedPoint?
    let confidence: Double
    let trackerKind: String

    init(
        rawCameraPoint: NormalizedPoint?,
        cameraPoint: NormalizedPoint?,
        confidence: Double,
        trackerKind: String
    ) {
        self.rawCameraPoint = rawCameraPoint
        self.cameraPoint = cameraPoint
        self.confidence = confidence
        self.trackerKind = trackerKind
    }
}

struct SessionFrameStage {
    let traceID: FrameTraceID
    let presentationTime: CMTime
    let callbackHostTimestamp: TimeInterval
    let presentationHostTimestamp: TimeInterval?
    let clockRelation: CaptureClockRelation
    let trackerOutput: SessionTrackerOutput
    let homography: [Double]?
    let calibrationCorners: [NormalizedPoint]
    let mappedPaperPoint: NormalizedPoint?
    let pixelBuffer: CVPixelBuffer?

    init(
        traceID: FrameTraceID,
        presentationTime: CMTime,
        callbackHostTimestamp: TimeInterval,
        presentationHostTimestamp: TimeInterval?,
        clockRelation: CaptureClockRelation,
        trackerOutput: SessionTrackerOutput,
        homography: [Double]?,
        calibrationCorners: [NormalizedPoint],
        mappedPaperPoint: NormalizedPoint?,
        pixelBuffer: CVPixelBuffer?
    ) {
        self.traceID = traceID
        self.presentationTime = presentationTime
        self.callbackHostTimestamp = callbackHostTimestamp
        self.presentationHostTimestamp = presentationHostTimestamp
        self.clockRelation = clockRelation
        self.trackerOutput = trackerOutput
        self.homography = homography
        self.calibrationCorners = calibrationCorners
        self.mappedPaperPoint = mappedPaperPoint
        self.pixelBuffer = pixelBuffer
    }
}

struct SessionFrameDecision: Equatable, Sendable {
    let traceID: FrameTraceID
    let decisionHostTimestamp: TimeInterval
    let inferredPenDown: Bool
    let acceptedForInk: Bool
    let activeStrokeID: UUID?

    init(
        traceID: FrameTraceID,
        decisionHostTimestamp: TimeInterval,
        inferredPenDown: Bool,
        acceptedForInk: Bool,
        activeStrokeID: UUID? = nil
    ) {
        self.traceID = traceID
        self.decisionHostTimestamp = decisionHostTimestamp
        self.inferredPenDown = inferredPenDown
        self.acceptedForInk = acceptedForInk
        self.activeStrokeID = activeStrokeID
    }
}

enum SessionStrokeBoundary: String, Codable, Sendable {
    case began
    case ended
    case cancelled
}

struct SessionRecorderConfiguration: Equatable, Sendable {
    static let defaultMaximumDiskBytes: Int64 = 2 * 1_024 * 1_024 * 1_024

    var maximumDiskBytes: Int64
    var telemetryReserveBytes: Int64
    var maximumPendingMediaJobs: Int
    var maximumPendingFrames: Int
    var fullFrameInterval: TimeInterval
    var tipCropPixelSize: Int
    var jpegQuality: Double

    init(
        maximumDiskBytes: Int64 = Self.defaultMaximumDiskBytes,
        telemetryReserveBytes: Int64 = 8 * 1_024 * 1_024,
        maximumPendingMediaJobs: Int = 8,
        maximumPendingFrames: Int = 512,
        fullFrameInterval: TimeInterval = 0.5,
        tipCropPixelSize: Int = 128,
        jpegQuality: Double = 0.82
    ) {
        self.maximumDiskBytes = maximumDiskBytes
        self.telemetryReserveBytes = telemetryReserveBytes
        self.maximumPendingMediaJobs = maximumPendingMediaJobs
        self.maximumPendingFrames = maximumPendingFrames
        self.fullFrameInterval = fullFrameInterval
        self.tipCropPixelSize = tipCropPixelSize
        self.jpegQuality = jpegQuality
    }
}

struct SessionRecordingSummary: Equatable, Sendable {
    let sessionURL: URL
    let eventCount: Int
    let frameCount: Int
    let mediaFileCount: Int
    let droppedMediaCount: Int
    let issueCount: Int
    let bytesWritten: Int64
}

enum SessionRecorderError: LocalizedError, Equatable {
    case alreadyRecording
    case notRecording
    case invalidConfiguration(String)
    case parentIsNotDirectory
    case couldNotCreateEventLog
    case metadataExceedsDiskCap
    case eventLogReachedDiskCap

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A DeskInk recording is already active."
        case .notRecording:
            return "No DeskInk recording is active."
        case let .invalidConfiguration(message):
            return "The recorder configuration is invalid: \(message)"
        case .parentIsNotDirectory:
            return "Choose a folder in which DeskInk can create a recording session."
        case .couldNotCreateEventLog:
            return "DeskInk could not create the session event log."
        case .metadataExceedsDiskCap:
            return "The session metadata alone exceeds the configured recording size limit."
        case .eventLogReachedDiskCap:
            return "The recording stopped because the event log reached the configured size limit."
        }
    }
}
