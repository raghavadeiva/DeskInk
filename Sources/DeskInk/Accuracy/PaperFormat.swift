import Foundation

/// Physical paper sizes used by the accuracy fixture. Measurements are exact
/// dimensions in millimetres, in portrait orientation.
enum PaperFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case letter
    case a4

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .letter: return "Letter"
        case .a4: return "A4"
        }
    }

    var widthMM: Double {
        switch self {
        case .letter: return 215.9
        case .a4: return 210
        }
    }

    var heightMM: Double {
        switch self {
        case .letter: return 279.4
        case .a4: return 297
        }
    }

    var widthPoints: Double { widthMM * Self.pointsPerMillimetre }
    var heightPoints: Double { heightMM * Self.pointsPerMillimetre }

    static let pointsPerMillimetre = 72.0 / 25.4
}

/// A physical point on the sheet, measured from its top-left corner.
struct PaperPointMM: Equatable, Sendable {
    let x: Double
    let y: Double
}

struct GridTarget: Identifiable, Equatable, Sendable {
    let index: Int
    let row: Int
    let column: Int
    let positionMM: PaperPointMM

    var id: Int { index }

    func normalized(for format: PaperFormat) -> NormalizedPoint {
        NormalizedPoint(
            x: positionMM.x / format.widthMM,
            y: positionMM.y / format.heightMM
        )
    }
}

enum AccuracyGrid {
    static let rowCount = 5
    static let columnCount = 5
    static let marginMM = 20.0

    /// Targets are row-major, beginning at the top-left cross. The first and
    /// last centres are exactly 20 mm from the corresponding paper edges.
    static func targets(for format: PaperFormat) -> [GridTarget] {
        let horizontalStep = (format.widthMM - 2 * marginMM) / Double(columnCount - 1)
        let verticalStep = (format.heightMM - 2 * marginMM) / Double(rowCount - 1)

        return (0..<rowCount).flatMap { row in
            (0..<columnCount).map { column in
                GridTarget(
                    index: row * columnCount + column,
                    row: row,
                    column: column,
                    positionMM: PaperPointMM(
                        x: marginMM + Double(column) * horizontalStep,
                        y: marginMM + Double(row) * verticalStep
                    )
                )
            }
        }
    }
}
