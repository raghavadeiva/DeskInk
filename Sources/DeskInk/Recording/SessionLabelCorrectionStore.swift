import Foundation

struct SessionLabelCorrection: Codable, Equatable, Sendable {
    let correctionID: UUID
    let traceID: FrameTraceID
    let correctedPenDown: Bool
    let correctedAt: Date
    let note: String?

    init(
        correctionID: UUID = UUID(),
        traceID: FrameTraceID,
        correctedPenDown: Bool,
        correctedAt: Date = Date(),
        note: String? = nil
    ) {
        self.correctionID = correctionID
        self.traceID = traceID
        self.correctedPenDown = correctedPenDown
        self.correctedAt = correctedAt
        self.note = note
    }
}

/// Appends reviewer corrections to a sidecar. It never opens or changes the
/// immutable raw `events.jsonl` log.
final class SessionLabelCorrectionStore {
    static let fileName = "label-corrections.jsonl"

    private let queue = DispatchQueue(label: "com.example.DeskInk.recording.label-corrections")
    private let handle: FileHandle
    private let encoder: JSONEncoder

    init(sessionURL: URL, fileManager: FileManager = .default) throws {
        let url = sessionURL.appendingPathComponent(Self.fileName)
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        handle = try FileHandle(forWritingTo: url)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
    }

    deinit {
        try? handle.close()
    }

    func append(_ correction: SessionLabelCorrection) throws {
        try queue.sync {
            let record = CorrectionEnvelope(schemaVersion: 1, correction: correction)
            var data = try encoder.encode(record)
            data.append(0x0A)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        }
    }
}

private struct CorrectionEnvelope: Codable {
    let schemaVersion: Int
    let correction: SessionLabelCorrection
}
