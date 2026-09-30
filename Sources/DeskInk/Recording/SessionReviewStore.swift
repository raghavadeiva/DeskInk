import Foundation

enum SessionReviewLabel: String, CaseIterable, Codable, Sendable {
    case contact
    case hover
    case uncertain
    case revert

    var displayName: String {
        rawValue.capitalized
    }
}

enum SessionReviewedContact: String, Equatable, Sendable {
    case contact
    case hover
    case uncertain

    var displayName: String {
        rawValue.capitalized
    }
}

enum SessionReviewMediaStatus: String, Equatable, Sendable {
    case requested
    case written
    case failed
    case droppedBackpressure
    case droppedDiskCap

    var displayName: String {
        switch self {
        case .requested: return "Requested"
        case .written: return "Written"
        case .failed: return "Failed"
        case .droppedBackpressure: return "Dropped (backpressure)"
        case .droppedDiskCap: return "Dropped (disk cap)"
        }
    }
}

struct SessionReviewFrame: Identifiable, Equatable, Sendable {
    let traceID: FrameTraceID
    let eventSequence: Int
    let callbackHostTimestamp: TimeInterval?
    let decisionHostTimestamp: TimeInterval?
    let trackerKind: String?
    let confidence: Double?
    let rawSpaceDown: Bool?
    let inferredContact: Bool?
    let recordedEffectiveContact: Bool?
    let tipCropRelativePath: String?
    let tipCropURL: URL?
    let tipCropStatus: SessionReviewMediaStatus?
    var latestCorrection: SessionReviewLabel?

    var id: FrameTraceID { traceID }

    var baseContact: SessionReviewedContact {
        if let recordedEffectiveContact {
            return recordedEffectiveContact ? .contact : .hover
        }
        if let inferredContact {
            return inferredContact ? .contact : .hover
        }
        if let rawSpaceDown {
            return rawSpaceDown ? .contact : .hover
        }
        return .uncertain
    }

    var effectiveContact: SessionReviewedContact {
        switch latestCorrection {
        case .contact: return .contact
        case .hover: return .hover
        case .uncertain: return .uncertain
        case .revert, .none: return baseContact
        }
    }

    var hasManualOverride: Bool {
        switch latestCorrection {
        case .contact, .hover, .uncertain: return true
        case .revert, .none: return false
        }
    }
}

enum SessionReviewWarning: Equatable, Identifiable, Sendable {
    case truncatedFinalLine(file: String, line: Int)
    case malformedLine(file: String, line: Int, message: String)
    case unsupportedSchemaVersion(file: String, line: Int, version: Int)
    case unsafeMediaPath(String)
    case missingWrittenMedia(String)

    var id: String { message }

    var message: String {
        switch self {
        case let .truncatedFinalLine(file, line):
            return "Ignored a truncated final line in \(file) at line \(line); all earlier rows were preserved."
        case let .malformedLine(file, line, message):
            return "Ignored malformed \(file) line \(line): \(message)"
        case let .unsupportedSchemaVersion(file, line, version):
            return "\(file) line \(line) uses unsupported schema version \(version); known fields were read where possible."
        case let .unsafeMediaPath(path):
            return "Ignored an unsafe media path outside the session folder: \(path)"
        case let .missingWrittenMedia(path):
            return "The event log says this crop was written, but it is missing: \(path)"
        }
    }
}

enum SessionReviewStoreError: LocalizedError, Equatable {
    case sessionIsNotDirectory
    case eventsLogMissing
    case frameNotFound
    case couldNotCreateCorrectionsLog

    var errorDescription: String? {
        switch self {
        case .sessionIsNotDirectory:
            return "Choose a DeskInk recording session folder."
        case .eventsLogMissing:
            return "The selected session does not contain events.jsonl."
        case .frameNotFound:
            return "That frame is no longer present in the loaded session."
        case .couldNotCreateCorrectionsLog:
            return "DeskInk could not create label-corrections.jsonl in this session."
        }
    }
}

@MainActor
final class SessionReviewStore: ObservableObject {
    nonisolated static let eventLogFilename = "events.jsonl"
    nonisolated static let correctionsFilename = "label-corrections.jsonl"

    let sessionURL: URL
    let eventsURL: URL
    let correctionsURL: URL

    @Published private(set) var frames: [SessionReviewFrame] = []
    @Published private(set) var warnings: [SessionReviewWarning] = []
    @Published var selectedFrameIndex = 0

    private let fileManager: FileManager
    private let now: () -> Date
    private var nextCorrectionSequence = 0

    init(
        sessionURL: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) throws {
        self.sessionURL = sessionURL.standardizedFileURL
        eventsURL = self.sessionURL.appendingPathComponent(Self.eventLogFilename)
        correctionsURL = self.sessionURL.appendingPathComponent(Self.correctionsFilename)
        self.fileManager = fileManager
        self.now = now
        try reload()
    }

    var selectedFrame: SessionReviewFrame? {
        guard frames.indices.contains(selectedFrameIndex) else { return nil }
        return frames[selectedFrameIndex]
    }

    func selectFrame(at index: Int) {
        guard !frames.isEmpty else {
            selectedFrameIndex = 0
            return
        }
        selectedFrameIndex = min(max(index, 0), frames.count - 1)
    }

    func reload() throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sessionURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SessionReviewStoreError.sessionIsNotDirectory
        }
        guard fileManager.fileExists(atPath: eventsURL.path) else {
            throw SessionReviewStoreError.eventsLogMissing
        }

        let eventData = try Data(contentsOf: eventsURL, options: .mappedIfSafe)
        var loadedWarnings: [SessionReviewWarning] = []
        let eventRows = Self.decodeLines(
            from: eventData,
            filename: Self.eventLogFilename,
            warnings: &loadedWarnings
        )
        let projection = buildFrameProjection(from: eventRows, warnings: &loadedWarnings)

        var correctionsByFrame: [FrameTraceID: SessionReviewLabel] = [:]
        nextCorrectionSequence = 0
        if fileManager.fileExists(atPath: correctionsURL.path) {
            let correctionData = try Data(contentsOf: correctionsURL, options: .mappedIfSafe)
            let correctionRows = Self.decodeLines(
                from: correctionData,
                filename: Self.correctionsFilename,
                warnings: &loadedWarnings
            )
            for row in correctionRows {
                do {
                    let record = try Self.makeDecoder().decode(LabelCorrectionRecord.self, from: row.data)
                    if record.schemaVersion != 1 {
                        loadedWarnings.append(.unsupportedSchemaVersion(
                            file: Self.correctionsFilename,
                            line: row.lineNumber,
                            version: record.schemaVersion
                        ))
                    }
                    correctionsByFrame[record.traceID] = record.label
                    nextCorrectionSequence = max(nextCorrectionSequence, record.sequence + 1)
                } catch {
                    do {
                        // Phase 1 recorder builds may already contain the original
                        // Boolean correction envelope. Preserve and project those
                        // rows while writing the richer four-state review schema.
                        let legacy = try Self.makeDecoder().decode(
                            LegacyCorrectionEnvelope.self,
                            from: row.data
                        )
                        correctionsByFrame[legacy.correction.traceID] = legacy.correction.correctedPenDown
                            ? .contact
                            : .hover
                        nextCorrectionSequence = max(nextCorrectionSequence, row.lineNumber)
                    } catch let legacyError {
                        loadedWarnings.append(.malformedLine(
                            file: Self.correctionsFilename,
                            line: row.lineNumber,
                            message: legacyError.localizedDescription
                        ))
                    }
                }
            }
        }

        frames = projection.map { frame in
            var frame = frame
            frame.latestCorrection = correctionsByFrame[frame.traceID]
            return frame
        }
        warnings = loadedWarnings
        selectFrame(at: selectedFrameIndex)
    }

    func appendCorrection(_ label: SessionReviewLabel, for traceID: FrameTraceID) throws {
        guard let frameIndex = frames.firstIndex(where: { $0.traceID == traceID }) else {
            throw SessionReviewStoreError.frameNotFound
        }

        let record = LabelCorrectionRecord(
            schemaVersion: 1,
            sequence: nextCorrectionSequence,
            recordedAt: now(),
            traceID: traceID,
            label: label
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var recordData = try encoder.encode(record)
        recordData.append(0x0A)

        let existingData: Data
        if fileManager.fileExists(atPath: correctionsURL.path) {
            existingData = try Data(contentsOf: correctionsURL, options: .mappedIfSafe)
        } else {
            guard fileManager.createFile(atPath: correctionsURL.path, contents: nil) else {
                throw SessionReviewStoreError.couldNotCreateCorrectionsLog
            }
            existingData = Data()
        }

        let handle = try FileHandle(forWritingTo: correctionsURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        if !existingData.isEmpty, existingData.last != 0x0A {
            // Preserve a truncated correction row byte-for-byte, terminate it, and
            // append the new valid row rather than rewriting prior review history.
            try handle.write(contentsOf: Data([0x0A]))
        }
        try handle.write(contentsOf: recordData)
        try handle.synchronize()

        nextCorrectionSequence += 1
        frames[frameIndex].latestCorrection = label
    }

    private func buildFrameProjection(
        from rows: [DecodedLine],
        warnings: inout [SessionReviewWarning]
    ) -> [SessionReviewFrame] {
        let decoder = Self.makeDecoder()
        var frameEvents: [FrameProjectionRecord] = []
        var spaceEvents: [SpaceProjectionRecord] = []
        var mediaOutcomes: [MediaOutcomeKey: SessionReviewMediaStatus] = [:]

        for row in rows {
            do {
                let header = try decoder.decode(EventHeader.self, from: row.data)
                if header.schemaVersion != 1 {
                    warnings.append(.unsupportedSchemaVersion(
                        file: Self.eventLogFilename,
                        line: row.lineNumber,
                        version: header.schemaVersion
                    ))
                }
                switch header.type {
                case "frame":
                    let envelope = try decoder.decode(FrameEnvelope.self, from: row.data)
                    frameEvents.append(FrameProjectionRecord(
                        sequence: envelope.sequence,
                        envelopeHostTimestamp: envelope.hostTimestamp,
                        payload: envelope.payload
                    ))
                case "spaceState":
                    let envelope = try decoder.decode(SpaceEnvelope.self, from: row.data)
                    if let timestamp = envelope.hostTimestamp {
                        spaceEvents.append(SpaceProjectionRecord(
                            sequence: envelope.sequence,
                            hostTimestamp: timestamp,
                            isDown: envelope.payload.isDown
                        ))
                    }
                case "mediaOutcome":
                    let envelope = try decoder.decode(MediaOutcomeEnvelope.self, from: row.data)
                    if envelope.payload.media.kind == "tipCrop",
                       let status = SessionReviewMediaStatus(rawValue: envelope.payload.status) {
                        mediaOutcomes[MediaOutcomeKey(
                            traceID: envelope.payload.traceID,
                            relativePath: envelope.payload.media.relativePath
                        )] = status
                    }
                default:
                    break
                }
            } catch {
                warnings.append(.malformedLine(
                    file: Self.eventLogFilename,
                    line: row.lineNumber,
                    message: error.localizedDescription
                ))
            }
        }

        spaceEvents.sort {
            if $0.hostTimestamp != $1.hostTimestamp {
                return $0.hostTimestamp < $1.hostTimestamp
            }
            return $0.sequence < $1.sequence
        }
        frameEvents.sort { $0.sequence < $1.sequence }

        return frameEvents.map { frame in
            let timestamp = frame.payload.application?.decisionHostTimestamp
                ?? frame.payload.camera?.callbackHostTimestamp
                ?? frame.envelopeHostTimestamp
            let spaceState = rawSpaceState(
                at: timestamp,
                frameSequence: frame.sequence,
                events: spaceEvents
            )
            let cropReference = frame.payload.requestedMedia.first { $0.kind == "tipCrop" }
            var cropURL: URL?
            var cropStatus: SessionReviewMediaStatus?
            if let cropReference {
                cropStatus = mediaOutcomes[MediaOutcomeKey(
                    traceID: frame.payload.traceID,
                    relativePath: cropReference.relativePath
                )] ?? .requested
                cropURL = safeSessionFileURL(relativePath: cropReference.relativePath)
                if cropURL == nil {
                    warnings.append(.unsafeMediaPath(cropReference.relativePath))
                } else if cropStatus == .written,
                          !fileManager.fileExists(atPath: cropURL?.path ?? "") {
                    warnings.append(.missingWrittenMedia(cropReference.relativePath))
                }
            }

            return SessionReviewFrame(
                traceID: frame.payload.traceID,
                eventSequence: frame.sequence,
                callbackHostTimestamp: frame.payload.camera?.callbackHostTimestamp
                    ?? frame.envelopeHostTimestamp,
                decisionHostTimestamp: frame.payload.application?.decisionHostTimestamp,
                trackerKind: frame.payload.camera?.trackerOutput.trackerKind,
                confidence: frame.payload.camera?.trackerOutput.confidence,
                rawSpaceDown: spaceState,
                inferredContact: frame.payload.application?.inferredPenDown,
                recordedEffectiveContact: frame.payload.application?.acceptedForInk,
                tipCropRelativePath: cropReference?.relativePath,
                tipCropURL: cropURL,
                tipCropStatus: cropStatus,
                latestCorrection: nil
            )
        }
    }

    private func rawSpaceState(
        at timestamp: TimeInterval?,
        frameSequence: Int,
        events: [SpaceProjectionRecord]
    ) -> Bool? {
        if let timestamp {
            return events.last(where: {
                $0.hostTimestamp < timestamp ||
                    ($0.hostTimestamp == timestamp && $0.sequence <= frameSequence)
            })?.isDown
        }
        return events.last(where: { $0.sequence <= frameSequence })?.isDown
    }

    private func safeSessionFileURL(relativePath: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let root = sessionURL.resolvingSymlinksInPath().standardizedFileURL
        let candidate = root
            .appendingPathComponent(relativePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else { return nil }
        return candidate
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return decoder
    }

    private static func decodeLines(
        from data: Data,
        filename: String,
        warnings: inout [SessionReviewWarning]
    ) -> [DecodedLine] {
        guard !data.isEmpty else { return [] }
        let endsWithNewline = data.last == 0x0A
        let pieces = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        var rows: [DecodedLine] = []

        for (index, piece) in pieces.enumerated() {
            var line = Data(piece)
            if line.last == 0x0D {
                line.removeLast()
            }
            if line.allSatisfy({ byte in
                byte == 0x20 || byte == 0x09 || byte == 0x0D
            }) {
                continue
            }
            do {
                let object = try JSONSerialization.jsonObject(with: line)
                guard object is [String: Any] else {
                    throw SessionReviewLineError.notJSONObject
                }
                rows.append(DecodedLine(lineNumber: index + 1, data: line))
            } catch {
                let isTruncatedFinalLine = index == pieces.count - 1 && !endsWithNewline
                if isTruncatedFinalLine {
                    warnings.append(.truncatedFinalLine(file: filename, line: index + 1))
                } else {
                    warnings.append(.malformedLine(
                        file: filename,
                        line: index + 1,
                        message: error.localizedDescription
                    ))
                }
            }
        }
        return rows
    }
}

private enum SessionReviewLineError: LocalizedError {
    case notJSONObject

    var errorDescription: String? {
        "The JSON value is not an object."
    }
}

private struct DecodedLine {
    let lineNumber: Int
    let data: Data
}

private struct EventHeader: Decodable {
    let schemaVersion: Int
    let sequence: Int
    let type: String
}

private struct FrameEnvelope: Decodable {
    let sequence: Int
    let hostTimestamp: TimeInterval?
    let payload: ReviewFramePayload
}

private struct ReviewFramePayload: Decodable {
    let traceID: FrameTraceID
    let camera: ReviewCameraRecord?
    let application: ReviewApplicationRecord?
    let requestedMedia: [ReviewMediaReference]
}

private struct ReviewCameraRecord: Decodable {
    let callbackHostTimestamp: TimeInterval
    let trackerOutput: ReviewTrackerOutput
}

private struct ReviewTrackerOutput: Decodable {
    let confidence: Double
    let trackerKind: String
}

private struct ReviewApplicationRecord: Decodable {
    let decisionHostTimestamp: TimeInterval
    let inferredPenDown: Bool
    let acceptedForInk: Bool
}

private struct ReviewMediaReference: Decodable {
    let kind: String
    let relativePath: String
}

private struct SpaceEnvelope: Decodable {
    let sequence: Int
    let hostTimestamp: TimeInterval?
    let payload: ReviewSpacePayload
}

private struct ReviewSpacePayload: Decodable {
    let isDown: Bool
}

private struct MediaOutcomeEnvelope: Decodable {
    let payload: ReviewMediaOutcomePayload
}

private struct ReviewMediaOutcomePayload: Decodable {
    let traceID: FrameTraceID
    let media: ReviewMediaReference
    let status: String
}

private struct FrameProjectionRecord {
    let sequence: Int
    let envelopeHostTimestamp: TimeInterval?
    let payload: ReviewFramePayload
}

private struct SpaceProjectionRecord {
    let sequence: Int
    let hostTimestamp: TimeInterval
    let isDown: Bool
}

private struct MediaOutcomeKey: Hashable {
    let traceID: FrameTraceID
    let relativePath: String
}

private struct LabelCorrectionRecord: Codable {
    let schemaVersion: Int
    let sequence: Int
    let recordedAt: Date
    let traceID: FrameTraceID
    let label: SessionReviewLabel
}

private struct LegacyCorrectionEnvelope: Decodable {
    let schemaVersion: Int
    let correction: LegacyCorrection
}

private struct LegacyCorrection: Decodable {
    let traceID: FrameTraceID
    let correctedPenDown: Bool
}
