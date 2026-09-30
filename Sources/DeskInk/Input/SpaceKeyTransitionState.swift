import Foundation

struct SpaceKeyTransitionState: Sendable {
    private(set) var isPressed = false

    mutating func keyDown(isRepeat: Bool) -> Bool {
        guard !isRepeat, !isPressed else { return false }
        isPressed = true
        return true
    }

    mutating func keyUp() -> Bool {
        guard isPressed else { return false }
        isPressed = false
        return true
    }

    mutating func resetForFocusLoss() -> Bool {
        keyUp()
    }
}
