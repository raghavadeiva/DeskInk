import Foundation
import Testing
@testable import DeskInk

@MainActor
@Suite("Session contact-label review")
struct SessionReviewStoreTests {
    @Test("Frames project tracker, Space, decision, and tip-crop data")
    func loadsFrameProjection() throws {
        let fixture = try ReviewSessionFixture()
        defer { fixture.remove() }

        let firstTrace = fixture.trace(frameIndex: 1)
        let secondTrace = fixture.trace(frameIndex: 2)
        let firstCrop = "tip-crops/first.jpg"
        let secondCrop = "tip-crops/second.jpg"
        try fixture.createMediaFile(firstCrop)
        try fixture.createMediaFile(secondCrop)
        try fixture.writeEvents([
            fixture.spaceEvent(sequence: 0, hostTimestamp: 1.0, isDown: false),
            fixture.frameEvent(
                sequence: 1,
                traceID: firstTrace,
                callbackHostTimestamp: 1.2,
                decisionHostTimestamp: 1.3,
                confidence: 0.72,
                inferredPenDown: false,
                acceptedForInk: false,
                tipCropPath: firstCrop
            ),
            fixture.mediaOutcome(
                sequence: 2,
                traceID: firstTrace,
                path: firstCrop,
                status: "written"
            ),
            fixture.spaceEvent(sequence: 3, hostTimestamp: 2.0, isDown: true),
            fixture.frameEvent(
                sequence: 4,
                traceID: secondTrace,
                callbackHostTimestamp: 2.1,
                decisionHostTimestamp: 2.2,
                confidence: 0.91,
                inferredPenDown: true,
                acceptedForInk: true,
                tipCropPath: secondCrop
            ),
            fixture.mediaOutcome(
                sequence: 5,
                traceID: secondTrace,
                path: secondCrop,
                status: "written"
            )
        ])

        let store = try SessionReviewStore(sessionURL: fixture.directoryURL)
        #expect(store.frames.count == 2)

        let first = try #require(store.frames.first)
        #expect(first.traceID == firstTrace)
        #expect(first.confidence == 0.72)
        #expect(first.trackerKind == "vision")
        #expect(first.rawSpaceDown == false)
        #expect(first.inferredContact == false)
        #expect(first.recordedEffectiveContact == false)
        #expect(first.effectiveContact == .hover)
        #expect(first.tipCropRelativePath == firstCrop)
        #expect(first.tipCropStatus == .written)
        #expect(first.tipCropURL == fixture.directoryURL.appendingPathComponent(firstCrop))

        let second = try #require(store.frames.last)
        #expect(second.traceID == secondTrace)
        #expect(second.rawSpaceDown == true)
        #expect(second.inferredContact == true)
        #expect(second.recordedEffectiveContact == true)
        #expect(second.effectiveContact == .contact)
        #expect(store.warnings.isEmpty)
    }

    @Test("A truncated final event row is ignored without losing earlier frames")
    func truncatedFinalLine() throws {
        let fixture = try ReviewSessionFixture()
        defer { fixture.remove() }
        let trace = fixture.trace(frameIndex: 4)
        try fixture.writeEvents(
            [fixture.frameEvent(
                sequence: 0,
                traceID: trace,
                callbackHostTimestamp: 10,
                decisionHostTimestamp: 10.01,
                confidence: 0.4,
                inferredPenDown: false,
                acceptedForInk: false,
                tipCropPath: nil
            )],
            trailingFragment: #"{"schemaVersion":1,"sequence":1,"type":"frame","payload":{"traceID""#
        )

        let originalEvents = try Data(contentsOf: fixture.eventsURL)
        let store = try SessionReviewStore(sessionURL: fixture.directoryURL)

        #expect(store.frames.map(\.traceID) == [trace])
        #expect(store.warnings.contains { warning in
            if case let .truncatedFinalLine(file, line) = warning {
                return file == SessionReviewStore.eventLogFilename && line == 2
            }
            return false
        })
        #expect(try Data(contentsOf: fixture.eventsURL) == originalEvents)
    }

    @Test("Corrections append, latest wins, and Revert restores the raw decision")
    func appendOnlyCorrectionsAndRevert() throws {
        let fixture = try ReviewSessionFixture()
        defer { fixture.remove() }
        let trace = fixture.trace(frameIndex: 8)
        try fixture.writeEvents([
            fixture.frameEvent(
                sequence: 0,
                traceID: trace,
                callbackHostTimestamp: 20,
                decisionHostTimestamp: 20.01,
                confidence: 0.83,
                inferredPenDown: false,
                acceptedForInk: false,
                tipCropPath: nil
            )
        ])
        let originalEvents = try Data(contentsOf: fixture.eventsURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o444))],
            ofItemAtPath: fixture.eventsURL.path
        )

        let store = try SessionReviewStore(
            sessionURL: fixture.directoryURL,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        try store.appendCorrection(.contact, for: trace)
        #expect(store.frames[0].effectiveContact == .contact)
        let firstAppend = try Data(contentsOf: store.correctionsURL)

        try store.appendCorrection(.uncertain, for: trace)
        #expect(store.frames[0].effectiveContact == .uncertain)
        let secondAppend = try Data(contentsOf: store.correctionsURL)
        #expect(secondAppend.starts(with: firstAppend))

        try store.appendCorrection(.revert, for: trace)
        #expect(store.frames[0].latestCorrection == .revert)
        #expect(store.frames[0].effectiveContact == .hover)
        #expect(!store.frames[0].hasManualOverride)
        let thirdAppend = try Data(contentsOf: store.correctionsURL)
        #expect(thirdAppend.starts(with: secondAppend))
        #expect(String(decoding: thirdAppend, as: UTF8.self).split(separator: "\n").count == 3)

        #expect(try Data(contentsOf: fixture.eventsURL) == originalEvents)

        let reloaded = try SessionReviewStore(sessionURL: fixture.directoryURL)
        #expect(reloaded.frames[0].latestCorrection == .revert)
        #expect(reloaded.frames[0].effectiveContact == .hover)
    }

    @Test("A valid final row does not require a trailing newline")
    func validFinalRowWithoutNewline() throws {
        let fixture = try ReviewSessionFixture()
        defer { fixture.remove() }
        let trace = fixture.trace(frameIndex: 11)
        try fixture.writeEvents(
            [fixture.frameEvent(
                sequence: 0,
                traceID: trace,
                callbackHostTimestamp: 30,
                decisionHostTimestamp: 30.01,
                confidence: 0.67,
                inferredPenDown: true,
                acceptedForInk: true,
                tipCropPath: nil
            )],
            terminateLastRow: false
        )

        let store = try SessionReviewStore(sessionURL: fixture.directoryURL)
        #expect(store.frames.count == 1)
        #expect(!store.warnings.contains { warning in
            if case .truncatedFinalLine = warning { return true }
            return false
        })
    }

    @Test("Boolean correction rows from the recorder remain readable")
    func legacyBooleanCorrection() throws {
        let fixture = try ReviewSessionFixture()
        defer { fixture.remove() }
        let trace = fixture.trace(frameIndex: 12)
        try fixture.writeEvents([
            fixture.frameEvent(
                sequence: 0,
                traceID: trace,
                callbackHostTimestamp: 40,
                decisionHostTimestamp: 40.01,
                confidence: 0.75,
                inferredPenDown: false,
                acceptedForInk: false,
                tipCropPath: nil
            )
        ])
        let legacy: [String: Any] = [
            "schemaVersion": 1,
            "correction": [
                "correctionID": UUID().uuidString,
                "traceID": fixture.traceObject(trace),
                "correctedPenDown": true,
                "correctedAt": "2026-09-29T12:00:00Z"
            ]
        ]
        var data = try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])
        data.append(0x0A)
        try data.write(
            to: fixture.directoryURL.appendingPathComponent(SessionReviewStore.correctionsFilename)
        )

        let store = try SessionReviewStore(sessionURL: fixture.directoryURL)
        #expect(store.frames[0].latestCorrection == .contact)
        #expect(store.frames[0].effectiveContact == .contact)
    }
}

private final class ReviewSessionFixture {
    let directoryURL: URL
    let eventsURL: URL
    let captureSessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeskInk-ReviewTests-\(UUID().uuidString)", isDirectory: true)
        eventsURL = directoryURL.appendingPathComponent(SessionReviewStore.eventLogFilename)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func trace(frameIndex: Int) -> FrameTraceID {
        FrameTraceID(captureSessionID: captureSessionID, frameIndex: frameIndex)
    }

    func createMediaFile(_ relativePath: String) throws {
        let url = directoryURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)
    }

    func writeEvents(
        _ events: [[String: Any]],
        trailingFragment: String? = nil,
        terminateLastRow: Bool = true
    ) throws {
        var data = Data()
        for (index, event) in events.enumerated() {
            data.append(try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]))
            if terminateLastRow || index + 1 < events.count || trailingFragment != nil {
                data.append(0x0A)
            }
        }
        if let trailingFragment {
            data.append(Data(trailingFragment.utf8))
        }
        try data.write(to: eventsURL)
    }

    func spaceEvent(sequence: Int, hostTimestamp: Double, isDown: Bool) -> [String: Any] {
        envelope(
            sequence: sequence,
            type: "spaceState",
            hostTimestamp: hostTimestamp,
            payload: ["isDown": isDown]
        )
    }

    func frameEvent(
        sequence: Int,
        traceID: FrameTraceID,
        callbackHostTimestamp: Double,
        decisionHostTimestamp: Double,
        confidence: Double,
        inferredPenDown: Bool,
        acceptedForInk: Bool,
        tipCropPath: String?
    ) -> [String: Any] {
        let media: [[String: Any]] = tipCropPath.map {
            [["kind": "tipCrop", "relativePath": $0]]
        } ?? []
        return envelope(
            sequence: sequence,
            type: "frame",
            hostTimestamp: callbackHostTimestamp,
            payload: [
                "traceID": traceObject(traceID),
                "completion": "complete",
                "camera": [
                    "callbackHostTimestamp": callbackHostTimestamp,
                    "trackerOutput": [
                        "confidence": confidence,
                        "trackerKind": "vision"
                    ]
                ],
                "application": [
                    "decisionHostTimestamp": decisionHostTimestamp,
                    "inferredPenDown": inferredPenDown,
                    "acceptedForInk": acceptedForInk
                ],
                "requestedMedia": media
            ]
        )
    }

    func mediaOutcome(
        sequence: Int,
        traceID: FrameTraceID,
        path: String,
        status: String
    ) -> [String: Any] {
        envelope(
            sequence: sequence,
            type: "mediaOutcome",
            hostTimestamp: nil,
            payload: [
                "traceID": traceObject(traceID),
                "media": ["kind": "tipCrop", "relativePath": path],
                "status": status
            ]
        )
    }

    private func envelope(
        sequence: Int,
        type: String,
        hostTimestamp: Double?,
        payload: [String: Any]
    ) -> [String: Any] {
        var object: [String: Any] = [
            "schemaVersion": 1,
            "sequence": sequence,
            "type": type,
            "recordedAt": "2026-09-29T12:00:00Z",
            "payload": payload
        ]
        if let hostTimestamp {
            object["hostTimestamp"] = hostTimestamp
        }
        return object
    }

    func traceObject(_ traceID: FrameTraceID) -> [String: Any] {
        [
            "captureSessionID": traceID.captureSessionID.uuidString,
            "frameIndex": traceID.frameIndex
        ]
    }
}
