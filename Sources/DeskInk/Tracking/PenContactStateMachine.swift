import Foundation

struct PenContactStateMachine: Sendable {
    // Vision observations are usable from roughly 0.15 upward. Keeping this in
    // sync with CameraController prevents a visible marker with permanently gated ink.
    var minimumConfidenceToBegin = 0.17
    var minimumConfidenceToContinue = 0.15
    var maximumJump = 0.11
    var maximumSpeed = 3.6
    var stableSamplesToBegin = 2
    var missingSamplesToEnd = 2

    private(set) var isDown = false
    private var stableSampleCount = 0
    private var missingSampleCount = 0
    private var previousPoint: NormalizedPoint?
    private var previousTimestamp: TimeInterval?

    mutating func update(
        point: NormalizedPoint?,
        confidence: Double,
        timestamp: TimeInterval
    ) -> Bool {
        let requiredConfidence = isDown ? minimumConfidenceToContinue : minimumConfidenceToBegin
        guard let point,
              point.isFinite,
              confidence >= requiredConfidence else {
            missingSampleCount += 1
            stableSampleCount = 0
            if missingSampleCount >= missingSamplesToEnd {
                isDown = false
                previousPoint = nil
                previousTimestamp = nil
            }
            return isDown
        }

        missingSampleCount = 0

        if let previousPoint, let previousTimestamp {
            let distance = point.distance(to: previousPoint)
            let elapsed = max(timestamp - previousTimestamp, 1.0 / 120.0)
            let speed = distance / elapsed

            if distance > maximumJump || speed > maximumSpeed {
                isDown = false
                stableSampleCount = 1
                self.previousPoint = point
                self.previousTimestamp = timestamp
                return false
            }
        }

        stableSampleCount += 1
        if stableSampleCount >= stableSamplesToBegin {
            isDown = true
        }

        previousPoint = point
        previousTimestamp = timestamp
        return isDown
    }

    mutating func reset() {
        isDown = false
        stableSampleCount = 0
        missingSampleCount = 0
        previousPoint = nil
        previousTimestamp = nil
    }
}
