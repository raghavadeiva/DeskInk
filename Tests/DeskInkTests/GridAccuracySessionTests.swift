import Foundation
import Testing
@testable import DeskInk

@Suite("Grid accuracy reducer")
struct GridAccuracySessionTests {
    @Test("A point requires at least one second and fifteen samples")
    func holdAndSampleThresholds() throws {
        var session = GridAccuracySession(paperFormat: .letter)
        #expect(session.reduce(.spaceDown(timestamp: 10)) == .holdStarted(targetIndex: 0))
        let target = try #require(session.currentTarget)
        let point = target.normalized(for: .letter)

        for sampleIndex in 0..<14 {
            let timestamp = 10 + Double(sampleIndex) * 0.06
            let result = session.reduce(.mappedPoint(point, timestamp: timestamp))
            #expect(result == .holdProgress(
                elapsed: timestamp - 10,
                sampleCount: sampleIndex + 1
            ))
        }
        #expect(session.measurements.isEmpty)

        let result = session.reduce(.mappedPoint(point, timestamp: 11))
        guard case let .measurementRecorded(measurement) = result else {
            Issue.record("The fifteenth sample at one second should record the target")
            return
        }
        #expect(measurement.sampleCount == 15)
        #expect(measurement.holdDuration == 1)
        #expect(abs(measurement.errorMM) < 1e-10)
        #expect(session.isAwaitingRelease)
        #expect(session.currentTargetIndex == 0)
    }

    @Test("An early release cancels the attempt")
    func earlyReleaseCancels() throws {
        var session = GridAccuracySession(paperFormat: .a4)
        _ = session.reduce(.spaceDown(timestamp: 0))
        let point = try #require(session.currentTarget?.normalized(for: .a4))
        for index in 0..<20 {
            _ = session.reduce(.mappedPoint(point, timestamp: Double(index) * 0.04))
        }

        #expect(session.reduce(.spaceUp(timestamp: 0.9)) == .attemptCancelled)
        #expect(session.measurements.isEmpty)
        #expect(!session.isSpaceDown)
        #expect(!session.isAwaitingRelease)
        #expect(session.currentTargetIndex == 0)
    }

    @Test("Component median rejects an outlier and error is measured in millimetres")
    func medianAndPhysicalError() throws {
        var session = GridAccuracySession(paperFormat: .letter)
        let target = try #require(session.currentTarget)
        let expected = PaperPointMM(
            x: target.positionMM.x + 1,
            y: target.positionMM.y + 2
        )
        let stablePoint = NormalizedPoint(
            x: expected.x / PaperFormat.letter.widthMM,
            y: expected.y / PaperFormat.letter.heightMM
        )

        _ = session.reduce(.spaceDown(timestamp: 2))
        for index in 0..<14 {
            _ = session.reduce(.mappedPoint(
                stablePoint,
                timestamp: 2 + Double(index) * 0.06
            ))
        }
        let outlier = NormalizedPoint(x: 0.95, y: 0.95)
        let result = session.reduce(.mappedPoint(outlier, timestamp: 3))
        guard case let .measurementRecorded(measurement) = result else {
            Issue.record("Expected a recorded median")
            return
        }

        #expect(abs(measurement.observedMM.x - expected.x) < 1e-10)
        #expect(abs(measurement.observedMM.y - expected.y) < 1e-10)
        #expect(abs(measurement.deltaXMM - 1) < 1e-10)
        #expect(abs(measurement.deltaYMM - 2) < 1e-10)
        #expect(abs(measurement.errorMM - sqrt(5)) < 1e-10)
    }

    @Test("Recorded targets cannot advance until Space is released")
    func releaseGating() throws {
        var session = GridAccuracySession(paperFormat: .a4)
        let first = try #require(session.currentTarget)
        _ = recordCurrentTarget(in: &session, timestamp: 0)
        #expect(session.measurements.count == 1)

        let ignoredPoint = try #require(session.currentTarget?.normalized(for: .a4))
        #expect(session.reduce(.mappedPoint(ignoredPoint, timestamp: 2)) == .ignored)
        #expect(session.reduce(.spaceDown(timestamp: 2)) == .ignored)
        #expect(session.measurements.count == 1)
        #expect(session.currentTarget == first)

        let release = session.reduce(.spaceUp(timestamp: 2.1))
        guard case let .readyForTarget(next) = release else {
            Issue.record("Release should reveal the next target")
            return
        }
        #expect(next.index == 1)
        #expect(session.currentTargetIndex == 1)
        #expect(!session.isAwaitingRelease)
    }

    @Test("Completion occurs only after the final release")
    func finalReleaseCompletes() throws {
        var session = GridAccuracySession(paperFormat: .letter)
        for index in 0..<25 {
            let start = Double(index) * 2
            let recorded = recordCurrentTarget(in: &session, timestamp: start)
            guard case .measurementRecorded = recorded else {
                Issue.record("Target \(index + 1) did not record")
                return
            }
            #expect(!session.isComplete)
            let release = session.reduce(.spaceUp(timestamp: start + 1.1))
            if index == 24 {
                #expect(release == .completed)
            } else if case .readyForTarget = release {
                // Expected intermediate transition.
            } else {
                Issue.record("Target \(index + 1) did not advance")
            }
        }
        #expect(session.isComplete)
        #expect(session.measurements.count == 25)
        #expect(session.currentTarget == nil)
    }

    @Test("Statistics use nearest-rank p95")
    func nearestRankStatistics() {
        let target = AccuracyGrid.targets(for: .a4)[0]
        let measurements = (1...20).map { error in
            GridAccuracyMeasurement(
                target: target,
                observedMM: PaperPointMM(
                    x: target.positionMM.x + Double(error),
                    y: target.positionMM.y
                ),
                sampleCount: 15,
                holdDuration: 1,
                recordedTimestamp: Double(error)
            )
        }

        let statistics = GridAccuracyStatistics.calculate(from: measurements)
        #expect(statistics.measurementCount == 20)
        #expect(statistics.meanErrorMM == 10.5)
        #expect(statistics.p95ErrorMM == 19)
        #expect(statistics.maxErrorMM == 20)
        #expect(GridAccuracyStatistics.calculate(from: []).p95ErrorMM == nil)

        let firstTwo = GridAccuracyStatistics.calculate(from: Array(measurements.prefix(2)))
        #expect(firstTwo.meanErrorMM == 1.5)
        #expect(firstTwo.p95ErrorMM == 2)
        #expect(firstTwo.maxErrorMM == 2)

        let first = GridAccuracyStatistics.calculate(from: [measurements[0]])
        #expect(first.meanErrorMM == 1)
        #expect(first.p95ErrorMM == 1)
        #expect(first.maxErrorMM == 1)
    }

    @Test("Invalid and out-of-order samples are ignored")
    func invalidSamplesIgnored() throws {
        var session = GridAccuracySession(paperFormat: .letter)
        _ = session.reduce(.spaceDown(timestamp: 5))
        let point = try #require(session.currentTarget?.normalized(for: .letter))
        #expect(session.reduce(.mappedPoint(point, timestamp: 4.9)) == .ignored)
        #expect(session.reduce(.mappedPoint(
            NormalizedPoint(x: .nan, y: 0),
            timestamp: 5.1
        )) == .ignored)
        _ = session.reduce(.mappedPoint(point, timestamp: 5.2))
        #expect(session.reduce(.mappedPoint(point, timestamp: 5.1)) == .ignored)
    }

    @discardableResult
    private func recordCurrentTarget(
        in session: inout GridAccuracySession,
        timestamp: TimeInterval
    ) -> GridAccuracyReduction {
        guard let point = session.currentTarget?.normalized(for: session.paperFormat) else {
            return .ignored
        }
        _ = session.reduce(.spaceDown(timestamp: timestamp))
        var result: GridAccuracyReduction = .ignored
        for sampleIndex in 0..<15 {
            let offset = sampleIndex == 14 ? 1 : Double(sampleIndex) / 20
            result = session.reduce(.mappedPoint(point, timestamp: timestamp + offset))
        }
        return result
    }
}
