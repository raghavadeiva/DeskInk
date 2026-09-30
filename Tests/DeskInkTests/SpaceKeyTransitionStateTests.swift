import Testing
@testable import DeskInk

@Suite("Space key transitions")
struct SpaceKeyTransitionStateTests {
    @Test("Repeat events do not create duplicate transitions")
    func repeatFiltering() {
        var state = SpaceKeyTransitionState()
        let firstDown = state.keyDown(isRepeat: false)
        let repeatedDown = state.keyDown(isRepeat: true)
        let duplicateDown = state.keyDown(isRepeat: false)
        let firstUp = state.keyUp()
        let duplicateUp = state.keyUp()
        #expect(firstDown)
        #expect(!repeatedDown)
        #expect(!duplicateDown)
        #expect(firstUp)
        #expect(!duplicateUp)
    }

    @Test("Focus loss emits a reset only while Space is held")
    func focusLossReset() {
        var state = SpaceKeyTransitionState()
        let idleReset = state.resetForFocusLoss()
        let down = state.keyDown(isRepeat: false)
        let heldReset = state.resetForFocusLoss()
        #expect(!state.isPressed)
        let secondReset = state.resetForFocusLoss()
        #expect(!idleReset)
        #expect(down)
        #expect(heldReset)
        #expect(!secondReset)
    }
}
