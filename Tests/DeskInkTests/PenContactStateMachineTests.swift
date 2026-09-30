import Testing
@testable import DeskInk

@Suite("Pen contact inference")
struct PenContactStateMachineTests {
    @Test("Stable samples begin ink and sustained loss ends it")
    func stableSamplesBeginInkAndSustainedLossEndsIt() {
        var machine = PenContactStateMachine()
        let first = NormalizedPoint(x: 0.2, y: 0.2)
        let second = NormalizedPoint(x: 0.205, y: 0.205)

        let frame1 = machine.update(point: first, confidence: 0.9, timestamp: 0)
        let frame2 = machine.update(point: second, confidence: 0.9, timestamp: 1.0 / 30.0)
        let frame3 = machine.update(point: nil, confidence: 0, timestamp: 2.0 / 30.0)
        let frame4 = machine.update(point: nil, confidence: 0, timestamp: 3.0 / 30.0)
        #expect(!frame1)
        #expect(frame2)
        #expect(frame3)
        #expect(!frame4)
    }

    @Test("A large jump splits a stroke")
    func largeJumpSplitsStroke() {
        var machine = PenContactStateMachine()
        let beforeContact = machine.update(
            point: NormalizedPoint(x: 0.2, y: 0.2),
            confidence: 0.9,
            timestamp: 0
        )
        let contact = machine.update(
            point: NormalizedPoint(x: 0.21, y: 0.2),
            confidence: 0.9,
            timestamp: 1.0 / 30.0
        )
        let afterJump = machine.update(
            point: NormalizedPoint(x: 0.7, y: 0.7),
            confidence: 0.9,
            timestamp: 2.0 / 30.0
        )
        #expect(!beforeContact)
        #expect(contact)
        #expect(!afterJump)
    }

    @Test("Low confidence never starts ink")
    func lowConfidenceDoesNotStartInk() {
        var machine = PenContactStateMachine()
        for frame in 0..<5 {
            let isDown = machine.update(
                point: NormalizedPoint(x: 0.3, y: 0.4),
                confidence: 0.1,
                timestamp: Double(frame) / 30.0
            )
            #expect(!isDown)
        }
    }

    @Test("A Vision observation accepted by the tracker can begin ink")
    func trackerConfidenceCanBeginInk() {
        var machine = PenContactStateMachine()
        let first = machine.update(
            point: NormalizedPoint(x: 0.4, y: 0.4),
            confidence: 0.2,
            timestamp: 0
        )
        let second = machine.update(
            point: NormalizedPoint(x: 0.405, y: 0.405),
            confidence: 0.2,
            timestamp: 1.0 / 30.0
        )
        #expect(!first)
        #expect(second)
    }
}
