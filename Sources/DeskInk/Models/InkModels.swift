import AppKit
import CoreGraphics
import Foundation

struct NormalizedPoint: Hashable, Sendable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }

    var isFinite: Bool {
        x.isFinite && y.isFinite
    }

    func distance(to other: NormalizedPoint) -> Double {
        hypot(x - other.x, y - other.y)
    }
}

enum InkColorChoice: String, CaseIterable, Identifiable, Sendable {
    case blue = "Blue"
    case black = "Black"
    case red = "Red"

    var id: String { rawValue }

    var nsColor: NSColor {
        switch self {
        case .blue:
            return NSColor.systemBlue
        case .black:
            // PDF ink must not inherit the current UI appearance. labelColor becomes
            // white in Dark Mode and would serialize as invisible white ink.
            return NSColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 1)
        case .red:
            return NSColor.systemRed
        }
    }
}

struct InkStroke: Identifiable, Sendable {
    let id: UUID
    let pageIndex: Int
    var points: [NormalizedPoint]
    let widthInPDFPoints: Double
    let color: InkColorChoice

    init(
        id: UUID = UUID(),
        pageIndex: Int,
        points: [NormalizedPoint],
        widthInPDFPoints: Double = 2.25,
        color: InkColorChoice = .blue
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.points = points
        self.widthInPDFPoints = widthInPDFPoints
        self.color = color
    }
}

struct PenObservation: Sendable {
    let traceID: FrameTraceID
    let rawCameraPoint: NormalizedPoint?
    let cameraPoint: NormalizedPoint?
    let rawPaperPoint: NormalizedPoint?
    let paperPoint: NormalizedPoint?
    let confidence: Double
    let trackerKind: String
    let inferredDown: Bool
    let timestamp: TimeInterval
}

enum InputMode: String, CaseIterable, Identifiable {
    case deskView = "Desk View"
    case simulator = "Simulator"

    var id: String { rawValue }
}

enum PenDownMode: String, CaseIterable, Identifiable {
    case automatic = "Auto (experimental)"
    case holdSpace = "Hold Space"

    var id: String { rawValue }
}

enum SpaceKeyEventSource: String, Codable, Sendable {
    case keyDown
    case keyUp
    case focusLossReset
}

enum CameraInteraction: Equatable {
    case idle
    case calibrating
    case seedingPen
}

enum PenTrackingState: Equatable {
    case notSeeded
    case acquiring
    case tracking
    case outsidePaper
    case lost

    var label: String {
        switch self {
        case .notSeeded: return "Pen not selected"
        case .acquiring: return "Locking onto pen"
        case .tracking: return "Tracking on paper"
        case .outsidePaper: return "Tip outside calibrated paper"
        case .lost: return "Tracking lost—select the tip again"
        }
    }
}
