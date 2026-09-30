import CoreMedia
import Foundation
import OSLog

struct FrameTraceID: Hashable, Codable, Sendable {
    let captureSessionID: UUID
    let frameIndex: Int
}

enum CaptureClockRelation: Equatable, Sendable {
    case unverified
    case hostClock
    case convertedToHost(mightDrift: Bool)
    case invalid

    var label: String {
        switch self {
        case .unverified: return "Unverified"
        case .hostClock: return "Host clock"
        case .convertedToHost(false): return "Converted to host"
        case .convertedToHost(true): return "Converted to host — drift possible"
        case .invalid: return "Invalid timestamp"
        }
    }
}

enum LatencyStage: String, CaseIterable, Hashable, Sendable {
    case captureToTracker = "Track"
    case trackerToRenderHandoff = "UI handoff"
    case renderHandoffToOverlayCommit = "Draw / commit"
    case captureToOverlayCommit = "Software total"
    case presentationToCaptureCallback = "Capture delivery"
}

struct LatencyPercentiles: Equatable, Sendable {
    var sampleCount = 0
    var p50Milliseconds: Double?
    var p95Milliseconds: Double?
    var p99Milliseconds: Double?
}

struct LatencySnapshot: Equatable, Sendable {
    var stages: [LatencyStage: LatencyPercentiles] = [:]
    var clockRelation: CaptureClockRelation = .unverified
    var capturedFrames = 0
    var trackedFrames = 0
    var renderCandidates = 0
    var committedFrames = 0
    var coalescedFrames = 0
    var captureDrops = 0
    var invalidTraces = 0

    static let empty = LatencySnapshot()
}

/// Thread-safe software timing collector. Callers capture host timestamps at
/// the actual pipeline boundary; work on this queue is therefore excluded from
/// the measured interval.
final class LatencyMonitor: ObservableObject {
    @Published private(set) var snapshot: LatencySnapshot = .empty

    private let queue = DispatchQueue(label: "com.example.DeskInk.latency")
    private let logger = Logger(subsystem: "com.example.DeskInk", category: "Latency")
    private var accumulator = LatencyAccumulator()
    private var lastPublishTimestamp: TimeInterval = 0
    private var lastLogTimestamp: TimeInterval = 0

    func markCapture(
        traceID: FrameTraceID,
        callbackHostTimestamp: TimeInterval,
        presentationHostTimestamp: TimeInterval?,
        clockRelation: CaptureClockRelation
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.accumulator.markCapture(
                traceID: traceID,
                callbackHostTimestamp: callbackHostTimestamp,
                presentationHostTimestamp: presentationHostTimestamp,
                clockRelation: clockRelation
            )
            self.publishIfNeeded(at: callbackHostTimestamp)
        }
    }

    func markTrackerResult(traceID: FrameTraceID, hostTimestamp: TimeInterval = hostTimestampNow()) {
        queue.async { [weak self] in
            guard let self else { return }
            self.accumulator.markTrackerResult(traceID: traceID, hostTimestamp: hostTimestamp)
            self.publishIfNeeded(at: hostTimestamp)
        }
    }

    func markRenderHandoff(traceID: FrameTraceID, hostTimestamp: TimeInterval = hostTimestampNow()) {
        queue.async { [weak self] in
            guard let self else { return }
            self.accumulator.markRenderHandoff(traceID: traceID, hostTimestamp: hostTimestamp)
            self.publishIfNeeded(at: hostTimestamp)
        }
    }

    func markOverlayCommit(traceID: FrameTraceID, hostTimestamp: TimeInterval = hostTimestampNow()) {
        queue.async { [weak self] in
            guard let self else { return }
            self.accumulator.markOverlayCommit(traceID: traceID, hostTimestamp: hostTimestamp)
            self.publishIfNeeded(at: hostTimestamp)
        }
    }

    func markNotRendered(traceID: FrameTraceID) {
        queue.async { [weak self] in
            self?.accumulator.markNotRendered(traceID: traceID)
        }
    }

    func markCoalesced(traceID: FrameTraceID) {
        queue.async { [weak self] in
            self?.accumulator.markCoalesced(traceID: traceID)
        }
    }

    func markCaptureDrop() {
        let now = Self.hostTimestampNow()
        queue.async { [weak self] in
            guard let self else { return }
            self.accumulator.markCaptureDrop()
            self.publishIfNeeded(at: now)
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.accumulator = LatencyAccumulator()
            self.lastPublishTimestamp = 0
            self.lastLogTimestamp = 0
            DispatchQueue.main.async { [weak self] in
                self?.snapshot = .empty
            }
        }
    }

    static func hostTimestampNow() -> TimeInterval {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    private func publishIfNeeded(at hostTimestamp: TimeInterval) {
        accumulator.reapStaleTraces(now: hostTimestamp)
        guard lastPublishTimestamp == 0 || hostTimestamp - lastPublishTimestamp >= 1 else { return }
        lastPublishTimestamp = hostTimestamp
        let newSnapshot = accumulator.snapshot()
        DispatchQueue.main.async { [weak self] in
            self?.snapshot = newSnapshot
        }

        guard lastLogTimestamp == 0 || hostTimestamp - lastLogTimestamp >= 5 else { return }
        lastLogTimestamp = hostTimestamp
        logger.info("Software latency \(Self.logDescription(for: newSnapshot), privacy: .public)")
    }

    private static func logDescription(for snapshot: LatencySnapshot) -> String {
        LatencyStage.allCases.map { stage in
            let values = snapshot.stages[stage] ?? LatencyPercentiles()
            return "\(stage.rawValue)=\(format(values.p50Milliseconds))/\(format(values.p95Milliseconds))/\(format(values.p99Milliseconds))ms n=\(values.sampleCount)"
        }.joined(separator: " ")
    }

    private static func format(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.1f", value)
    }
}

struct LatencyAccumulator {
    private struct Trace {
        let captureHostTimestamp: TimeInterval
        var trackerHostTimestamp: TimeInterval?
        var renderHandoffHostTimestamp: TimeInterval?
    }

    private let maximumSamples = 1_024
    private let maximumPendingTraces = 512
    private let staleTraceAge: TimeInterval = 2

    private var traces: [FrameTraceID: Trace] = [:]
    private var samples: [LatencyStage: [Double]] = [:]
    private var clockRelation: CaptureClockRelation = .unverified
    private var capturedFrames = 0
    private var trackedFrames = 0
    private var renderCandidates = 0
    private var committedFrames = 0
    private var coalescedFrames = 0
    private var captureDrops = 0
    private var invalidTraces = 0

    mutating func markCapture(
        traceID: FrameTraceID,
        callbackHostTimestamp: TimeInterval,
        presentationHostTimestamp: TimeInterval?,
        clockRelation: CaptureClockRelation
    ) {
        guard callbackHostTimestamp.isFinite else {
            invalidTraces += 1
            return
        }
        capturedFrames += 1
        self.clockRelation = clockRelation
        traces[traceID] = Trace(captureHostTimestamp: callbackHostTimestamp)
        if let presentationHostTimestamp {
            append(
                milliseconds: (callbackHostTimestamp - presentationHostTimestamp) * 1_000,
                for: .presentationToCaptureCallback
            )
        }
        if traces.count > maximumPendingTraces,
           let oldest = traces.min(by: { $0.value.captureHostTimestamp < $1.value.captureHostTimestamp })?.key {
            traces.removeValue(forKey: oldest)
            invalidTraces += 1
        }
    }

    mutating func markTrackerResult(traceID: FrameTraceID, hostTimestamp: TimeInterval) {
        guard var trace = traces[traceID], hostTimestamp >= trace.captureHostTimestamp else {
            invalidTraces += 1
            return
        }
        trackedFrames += 1
        trace.trackerHostTimestamp = hostTimestamp
        traces[traceID] = trace
        append(milliseconds: (hostTimestamp - trace.captureHostTimestamp) * 1_000, for: .captureToTracker)
    }

    mutating func markRenderHandoff(traceID: FrameTraceID, hostTimestamp: TimeInterval) {
        guard var trace = traces[traceID],
              let trackerTimestamp = trace.trackerHostTimestamp,
              hostTimestamp >= trackerTimestamp else {
            invalidTraces += 1
            return
        }
        renderCandidates += 1
        trace.renderHandoffHostTimestamp = hostTimestamp
        traces[traceID] = trace
        append(milliseconds: (hostTimestamp - trackerTimestamp) * 1_000, for: .trackerToRenderHandoff)
    }

    mutating func markOverlayCommit(traceID: FrameTraceID, hostTimestamp: TimeInterval) {
        guard let trace = traces.removeValue(forKey: traceID),
              let handoffTimestamp = trace.renderHandoffHostTimestamp,
              hostTimestamp >= handoffTimestamp else {
            invalidTraces += 1
            return
        }
        committedFrames += 1
        append(milliseconds: (hostTimestamp - handoffTimestamp) * 1_000, for: .renderHandoffToOverlayCommit)
        append(milliseconds: (hostTimestamp - trace.captureHostTimestamp) * 1_000, for: .captureToOverlayCommit)
    }

    mutating func markNotRendered(traceID: FrameTraceID) {
        traces.removeValue(forKey: traceID)
    }

    mutating func markCoalesced(traceID: FrameTraceID) {
        if traces.removeValue(forKey: traceID) != nil {
            coalescedFrames += 1
        }
    }

    mutating func markCaptureDrop() {
        captureDrops += 1
    }

    mutating func reapStaleTraces(now: TimeInterval) {
        let staleIDs = traces.compactMap { item in
            now - item.value.captureHostTimestamp > staleTraceAge ? item.key : nil
        }
        guard !staleIDs.isEmpty else { return }
        staleIDs.forEach { traces.removeValue(forKey: $0) }
        invalidTraces += staleIDs.count
    }

    func snapshot() -> LatencySnapshot {
        var summarized: [LatencyStage: LatencyPercentiles] = [:]
        for stage in LatencyStage.allCases {
            summarized[stage] = Self.summarize(samples[stage] ?? [])
        }
        return LatencySnapshot(
            stages: summarized,
            clockRelation: clockRelation,
            capturedFrames: capturedFrames,
            trackedFrames: trackedFrames,
            renderCandidates: renderCandidates,
            committedFrames: committedFrames,
            coalescedFrames: coalescedFrames,
            captureDrops: captureDrops,
            invalidTraces: invalidTraces
        )
    }

    static func summarize(_ values: [Double]) -> LatencyPercentiles {
        let sorted = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !sorted.isEmpty else { return LatencyPercentiles() }
        func percentile(_ fraction: Double) -> Double {
            let index = min(sorted.count - 1, max(0, Int(ceil(fraction * Double(sorted.count))) - 1))
            return sorted[index]
        }
        return LatencyPercentiles(
            sampleCount: sorted.count,
            p50Milliseconds: percentile(0.50),
            p95Milliseconds: percentile(0.95),
            p99Milliseconds: percentile(0.99)
        )
    }

    private mutating func append(milliseconds: Double, for stage: LatencyStage) {
        guard milliseconds.isFinite, milliseconds >= 0 else {
            invalidTraces += 1
            return
        }
        var stageSamples = samples[stage] ?? []
        stageSamples.append(milliseconds)
        if stageSamples.count > maximumSamples {
            stageSamples.removeFirst(stageSamples.count - maximumSamples)
        }
        samples[stage] = stageSamples
    }
}

private func hostTimestampNow() -> TimeInterval {
    LatencyMonitor.hostTimestampNow()
}
