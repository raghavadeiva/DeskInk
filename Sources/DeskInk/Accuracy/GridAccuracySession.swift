import Foundation

struct GridAccuracyMeasurement: Equatable, Sendable {
    let target: GridTarget
    let observedMM: PaperPointMM
    let deltaXMM: Double
    let deltaYMM: Double
    let errorMM: Double
    let sampleCount: Int
    let holdDuration: TimeInterval
    let recordedTimestamp: TimeInterval

    init(
        target: GridTarget,
        observedMM: PaperPointMM,
        sampleCount: Int,
        holdDuration: TimeInterval,
        recordedTimestamp: TimeInterval
    ) {
        self.target = target
        self.observedMM = observedMM
        deltaXMM = observedMM.x - target.positionMM.x
        deltaYMM = observedMM.y - target.positionMM.y
        errorMM = hypot(deltaXMM, deltaYMM)
        self.sampleCount = sampleCount
        self.holdDuration = holdDuration
        self.recordedTimestamp = recordedTimestamp
    }
}

struct GridAccuracyStatistics: Equatable, Sendable {
    let measurementCount: Int
    let meanErrorMM: Double?
    let p95ErrorMM: Double?
    let maxErrorMM: Double?

    static func calculate(from measurements: [GridAccuracyMeasurement]) -> Self {
        let errors = measurements.map(\.errorMM).filter(\.isFinite)
        guard !errors.isEmpty else {
            return GridAccuracyStatistics(
                measurementCount: 0,
                meanErrorMM: nil,
                p95ErrorMM: nil,
                maxErrorMM: nil
            )
        }

        let sorted = errors.sorted()
        let p95Index = min(sorted.count - 1, max(0, Int(ceil(0.95 * Double(sorted.count))) - 1))
        return GridAccuracyStatistics(
            measurementCount: errors.count,
            meanErrorMM: errors.reduce(0, +) / Double(errors.count),
            p95ErrorMM: sorted[p95Index],
            maxErrorMM: sorted.last
        )
    }
}

enum GridAccuracyEvent: Equatable, Sendable {
    case spaceDown(timestamp: TimeInterval)
    case spaceUp(timestamp: TimeInterval)
    case mappedPoint(NormalizedPoint, timestamp: TimeInterval)
}

enum GridAccuracyReduction: Equatable, Sendable {
    case ignored
    case holdStarted(targetIndex: Int)
    case holdProgress(elapsed: TimeInterval, sampleCount: Int)
    case attemptCancelled
    case measurementRecorded(GridAccuracyMeasurement)
    case readyForTarget(GridTarget)
    case completed
}

/// Pure reducer for the 25-point test. A successful hold is committed as soon
/// as it reaches both one second and 15 mapped samples. The next target cannot
/// become active until Space is released, preventing one long hold from
/// recording several targets.
struct GridAccuracySession: Sendable {
    static let minimumHoldDuration: TimeInterval = 1
    static let minimumSampleCount = 15

    let paperFormat: PaperFormat
    let targets: [GridTarget]

    private(set) var measurements: [GridAccuracyMeasurement] = []
    private(set) var currentTargetIndex = 0
    private(set) var isSpaceDown = false
    private(set) var isAwaitingRelease = false

    private var holdStartTimestamp: TimeInterval?
    private var samples: [(point: NormalizedPoint, timestamp: TimeInterval)] = []
    private var lastSampleTimestamp: TimeInterval?

    init(paperFormat: PaperFormat) {
        self.paperFormat = paperFormat
        targets = AccuracyGrid.targets(for: paperFormat)
    }

    var currentTarget: GridTarget? {
        guard targets.indices.contains(currentTargetIndex) else { return nil }
        return targets[currentTargetIndex]
    }

    var isComplete: Bool {
        currentTargetIndex == targets.count && !isAwaitingRelease
    }

    var statistics: GridAccuracyStatistics {
        GridAccuracyStatistics.calculate(from: measurements)
    }

    mutating func reduce(_ event: GridAccuracyEvent) -> GridAccuracyReduction {
        switch event {
        case let .spaceDown(timestamp):
            return handleSpaceDown(timestamp: timestamp)
        case let .spaceUp(timestamp):
            return handleSpaceUp(timestamp: timestamp)
        case let .mappedPoint(point, timestamp):
            return handleMappedPoint(point, timestamp: timestamp)
        }
    }

    private mutating func handleSpaceDown(timestamp: TimeInterval) -> GridAccuracyReduction {
        guard timestamp.isFinite,
              currentTarget != nil,
              !isSpaceDown,
              !isAwaitingRelease else {
            return .ignored
        }

        isSpaceDown = true
        holdStartTimestamp = timestamp
        samples.removeAll(keepingCapacity: true)
        lastSampleTimestamp = nil
        return .holdStarted(targetIndex: currentTargetIndex)
    }

    private mutating func handleSpaceUp(timestamp: TimeInterval) -> GridAccuracyReduction {
        guard timestamp.isFinite, isSpaceDown else { return .ignored }
        if let start = holdStartTimestamp, timestamp < start {
            return .ignored
        }

        isSpaceDown = false
        holdStartTimestamp = nil
        samples.removeAll(keepingCapacity: true)
        lastSampleTimestamp = nil

        if isAwaitingRelease {
            isAwaitingRelease = false
            currentTargetIndex += 1
            if currentTargetIndex == targets.count {
                return .completed
            }
            return .readyForTarget(targets[currentTargetIndex])
        }

        return .attemptCancelled
    }

    private mutating func handleMappedPoint(
        _ point: NormalizedPoint,
        timestamp: TimeInterval
    ) -> GridAccuracyReduction {
        guard point.isFinite,
              timestamp.isFinite,
              isSpaceDown,
              !isAwaitingRelease,
              let target = currentTarget,
              let holdStartTimestamp,
              timestamp >= holdStartTimestamp else {
            return .ignored
        }
        if let lastSampleTimestamp, timestamp < lastSampleTimestamp {
            return .ignored
        }

        samples.append((point, timestamp))
        lastSampleTimestamp = timestamp
        let elapsed = timestamp - holdStartTimestamp
        guard elapsed >= Self.minimumHoldDuration,
              samples.count >= Self.minimumSampleCount else {
            return .holdProgress(elapsed: elapsed, sampleCount: samples.count)
        }

        let medianPoint = componentMedian(samples.map(\.point))
        let observedMM = PaperPointMM(
            x: medianPoint.x * paperFormat.widthMM,
            y: medianPoint.y * paperFormat.heightMM
        )
        let measurement = GridAccuracyMeasurement(
            target: target,
            observedMM: observedMM,
            sampleCount: samples.count,
            holdDuration: elapsed,
            recordedTimestamp: timestamp
        )
        measurements.append(measurement)
        isAwaitingRelease = true
        return .measurementRecorded(measurement)
    }

    private func componentMedian(_ points: [NormalizedPoint]) -> NormalizedPoint {
        NormalizedPoint(
            x: median(points.map(\.x)),
            y: median(points.map(\.y))
        )
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
