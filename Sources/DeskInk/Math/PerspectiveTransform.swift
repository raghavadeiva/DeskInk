import CoreGraphics
import Foundation

struct PerspectiveTransform: Equatable, Sendable {
    private let values: [Double]

    var rowMajorValues: [Double] { values }

    private init(values: [Double]) {
        self.values = values
    }

    /// Builds a projective transform from four source points to four destination points.
    /// Points must correspond by index and use the same coordinate convention.
    init?(source: [NormalizedPoint], destination: [NormalizedPoint]) {
        guard source.count == 4,
              destination.count == 4,
              Self.isUsableQuadrilateral(source),
              Self.isUsableQuadrilateral(destination) else {
            return nil
        }

        var matrix = Array(repeating: Array(repeating: 0.0, count: 9), count: 8)

        for index in 0..<4 {
            let x = source[index].x
            let y = source[index].y
            let u = destination[index].x
            let v = destination[index].y

            matrix[index * 2] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            matrix[index * 2 + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }

        guard let solution = Self.solveAugmentedSystem(matrix) else {
            return nil
        }

        values = solution + [1]
    }

    static func paperTransform(sourceCorners: [NormalizedPoint]) -> PerspectiveTransform? {
        PerspectiveTransform(
            source: sourceCorners,
            destination: [
                NormalizedPoint(x: 0, y: 0),
                NormalizedPoint(x: 1, y: 0),
                NormalizedPoint(x: 1, y: 1),
                NormalizedPoint(x: 0, y: 1)
            ]
        )
    }

    func applying(to point: NormalizedPoint) -> NormalizedPoint? {
        let denominator = values[6] * point.x + values[7] * point.y + values[8]
        guard denominator.isFinite, abs(denominator) > 1e-10 else {
            return nil
        }

        let x = (values[0] * point.x + values[1] * point.y + values[2]) / denominator
        let y = (values[3] * point.x + values[4] * point.y + values[5]) / denominator
        let result = NormalizedPoint(x: x, y: y)
        return result.isFinite ? result : nil
    }

    private static func solveAugmentedSystem(_ input: [[Double]]) -> [Double]? {
        var matrix = input
        let count = matrix.count

        for column in 0..<count {
            var pivot = column
            for row in column..<count where abs(matrix[row][column]) > abs(matrix[pivot][column]) {
                pivot = row
            }

            guard abs(matrix[pivot][column]) > 1e-12 else {
                return nil
            }

            if pivot != column {
                matrix.swapAt(pivot, column)
            }

            let divisor = matrix[column][column]
            for item in column...count {
                matrix[column][item] /= divisor
            }

            for row in 0..<count where row != column {
                let factor = matrix[row][column]
                guard factor != 0 else { continue }
                for item in column...count {
                    matrix[row][item] -= factor * matrix[column][item]
                }
            }
        }

        return (0..<count).map { matrix[$0][count] }
    }

    private static func isUsableQuadrilateral(_ points: [NormalizedPoint]) -> Bool {
        guard points.count == 4, points.allSatisfy(\.isFinite) else {
            return false
        }

        var signedArea = 0.0
        var crossSigns: [Double] = []

        for index in 0..<4 {
            let current = points[index]
            let next = points[(index + 1) % 4]
            let after = points[(index + 2) % 4]
            signedArea += current.x * next.y - next.x * current.y
            let cross = (next.x - current.x) * (after.y - next.y)
                - (next.y - current.y) * (after.x - next.x)
            if abs(cross) < 1e-8 { return false }
            crossSigns.append(cross)
        }

        guard abs(signedArea) * 0.5 > 0.001 else {
            return false
        }

        let allPositive = crossSigns.allSatisfy { $0 > 0 }
        let allNegative = crossSigns.allSatisfy { $0 < 0 }
        return allPositive || allNegative
    }
}
