import Foundation
import Testing
@testable import DeskInk

@Suite("Software latency instrumentation")
struct LatencyMonitorTests {
    @Test("All software stages use the expected host-clock boundaries")
    func intervalCalculation() throws {
        var accumulator = LatencyAccumulator()
        let traceID = FrameTraceID(captureSessionID: UUID(), frameIndex: 7)

        accumulator.markCapture(
            traceID: traceID,
            callbackHostTimestamp: 10.000,
            presentationHostTimestamp: 9.980,
            clockRelation: .hostClock
        )
        accumulator.markTrackerResult(traceID: traceID, hostTimestamp: 10.010)
        accumulator.markRenderHandoff(traceID: traceID, hostTimestamp: 10.030)
        accumulator.markOverlayCommit(traceID: traceID, hostTimestamp: 10.050)

        let snapshot = accumulator.snapshot()
        #expect(abs(try milliseconds(.captureToTracker, in: snapshot) - 10) < 0.0001)
        #expect(abs(try milliseconds(.trackerToRenderHandoff, in: snapshot) - 20) < 0.0001)
        #expect(abs(try milliseconds(.renderHandoffToOverlayCommit, in: snapshot) - 20) < 0.0001)
        #expect(abs(try milliseconds(.captureToOverlayCommit, in: snapshot) - 50) < 0.0001)
        #expect(abs(try milliseconds(.presentationToCaptureCallback, in: snapshot) - 20) < 0.0001)
        #expect(snapshot.committedFrames == 1)
        #expect(snapshot.clockRelation == .hostClock)
    }

    @Test("Nearest-rank percentiles are deterministic")
    func nearestRankPercentiles() throws {
        let values = (1...100).map(Double.init)
        let summary = LatencyAccumulator.summarize(values)
        #expect(summary.sampleCount == 100)
        #expect(summary.p50Milliseconds == 50)
        #expect(summary.p95Milliseconds == 95)
        #expect(summary.p99Milliseconds == 99)
    }

    @Test("Coalesced and invalid traces are counted without producing commits")
    func invalidAndCoalesced() {
        var accumulator = LatencyAccumulator()
        let sessionID = UUID()
        let coalesced = FrameTraceID(captureSessionID: sessionID, frameIndex: 1)
        accumulator.markCapture(
            traceID: coalesced,
            callbackHostTimestamp: 1,
            presentationHostTimestamp: nil,
            clockRelation: .unverified
        )
        accumulator.markTrackerResult(traceID: coalesced, hostTimestamp: 1.01)
        accumulator.markRenderHandoff(traceID: coalesced, hostTimestamp: 1.02)
        accumulator.markCoalesced(traceID: coalesced)

        let invalid = FrameTraceID(captureSessionID: sessionID, frameIndex: 2)
        accumulator.markCapture(
            traceID: invalid,
            callbackHostTimestamp: 2,
            presentationHostTimestamp: nil,
            clockRelation: .unverified
        )
        accumulator.markTrackerResult(traceID: invalid, hostTimestamp: 1.5)

        let snapshot = accumulator.snapshot()
        #expect(snapshot.coalescedFrames == 1)
        #expect(snapshot.invalidTraces == 1)
        #expect(snapshot.committedFrames == 0)
    }

    private func milliseconds(_ stage: LatencyStage, in snapshot: LatencySnapshot) throws -> Double {
        try #require(snapshot.stages[stage]?.p50Milliseconds)
    }
}
