import CoreGraphics
import CoreVideo
import Foundation

/// A small, dependency-free image tracker used when Vision cannot keep a
/// `VNTrackObjectRequest` alive. It follows the appearance around the exact
/// point selected by the user instead of treating a large pen-sized rectangle
/// as one rigid object.
///
/// `LocalPatchTracker` is intentionally stateful and is expected to be called
/// from the camera's serial video queue.
final class LocalPatchTracker {
    struct Configuration: Sendable {
        /// Frames are sampled down to this size before matching. This keeps the
        /// amount of work bounded independently of the camera resolution.
        var maximumFrameDimension = 480
        /// A 13 x 13 patch at the default sampled resolution.
        var templateRadius = 6
        var normalSearchRadius = 32
        var maximumReacquisitionRadius = 112
        var coarseSearchStep = 2
        var globalSearchStep = 4
        var globalSearchAfterLostFrames = 6
        var minimumCorrelation = 0.48
        var minimumReacquisitionCorrelation = 0.56
        var minimumTemplateDeviation = 0.018
        var templateLearningRate = 0.06
    }

    enum MatchKind: Equatable, Sendable {
        case local
        case expanded
        case globalReacquisition
    }

    struct Match: Equatable, Sendable {
        let point: NormalizedPoint
        /// Confidence is normalized for the rest of DeskInk. A returned match
        /// always has at least enough confidence to be considered by the
        /// contact state machine.
        let confidence: Double
        /// Zero-mean normalized cross-correlation before confidence mapping.
        let correlation: Double
        let kind: MatchKind
    }

    private struct SampledFrame {
        let width: Int
        let height: Int
        let pixels: [Float]

        subscript(x: Int, y: Int) -> Float {
            pixels[y * width + x]
        }
    }

    private struct PixelPoint {
        var x: Double
        var y: Double

        func distance(to other: PixelPoint) -> Double {
            hypot(x - other.x, y - other.y)
        }
    }

    private struct Candidate {
        let center: PixelPoint
        let score: Double
    }

    private let configuration: Configuration
    private var referenceTemplate: [Float]?
    private var adaptiveTemplate: [Float]?
    private var currentPoint: PixelPoint?
    private var velocity = PixelPoint(x: 0, y: 0)
    private(set) var lostFrameCount = 0

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    var isSeeded: Bool {
        referenceTemplate != nil && currentPoint != nil
    }

    func reset() {
        referenceTemplate = nil
        adaptiveTemplate = nil
        currentPoint = nil
        velocity = PixelPoint(x: 0, y: 0)
        lostFrameCount = 0
    }

    /// Captures the local appearance around the selected camera point.
    @discardableResult
    func seed(in pixelBuffer: CVPixelBuffer, at point: NormalizedPoint) -> Bool {
        guard let frame = sampledFrame(from: pixelBuffer) else {
            reset()
            return false
        }
        return seed(in: frame, at: point)
    }

    /// Returns nil for a genuinely weak frame but preserves its template so a
    /// later frame can reacquire the tip without another user click.
    func update(
        in pixelBuffer: CVPixelBuffer,
        searchRegion: CGRect? = nil
    ) -> Match? {
        guard let frame = sampledFrame(from: pixelBuffer) else { return nil }
        return update(in: frame, searchRegion: searchRegion)
    }

    // MARK: - Array entry points used by deterministic tests

    @discardableResult
    func seed(
        lumaPixels: [UInt8],
        width: Int,
        height: Int,
        at point: NormalizedPoint
    ) -> Bool {
        guard let frame = sampledFrame(
            lumaPixels: lumaPixels,
            width: width,
            height: height
        ) else {
            reset()
            return false
        }
        return seed(in: frame, at: point)
    }

    func update(
        lumaPixels: [UInt8],
        width: Int,
        height: Int,
        searchRegion: CGRect? = nil
    ) -> Match? {
        guard let frame = sampledFrame(
            lumaPixels: lumaPixels,
            width: width,
            height: height
        ) else { return nil }
        return update(in: frame, searchRegion: searchRegion)
    }

    // MARK: - Tracking

    private func seed(in frame: SampledFrame, at point: NormalizedPoint) -> Bool {
        guard point.isFinite,
              (0...1).contains(point.x),
              (0...1).contains(point.y) else {
            reset()
            return false
        }

        let center = PixelPoint(
            x: point.x * Double(frame.width - 1),
            y: point.y * Double(frame.height - 1)
        )
        guard let template = normalizedPatch(in: frame, centeredAt: center) else {
            reset()
            return false
        }

        referenceTemplate = template
        adaptiveTemplate = template
        currentPoint = center
        velocity = PixelPoint(x: 0, y: 0)
        lostFrameCount = 0
        return true
    }

    private func update(in frame: SampledFrame, searchRegion: CGRect?) -> Match? {
        guard let referenceTemplate,
              let adaptiveTemplate,
              let currentPoint else { return nil }

        let predicted = PixelPoint(
            x: currentPoint.x + velocity.x,
            y: currentPoint.y + velocity.y
        )
        let expandedRadius = min(
            configuration.maximumReacquisitionRadius,
            configuration.normalSearchRadius + lostFrameCount * 16
        )
        let matchKind: MatchKind = lostFrameCount == 0 ? .local : .expanded

        var best = search(
            frame: frame,
            around: predicted,
            radius: expandedRadius,
            step: configuration.coarseSearchStep,
            region: searchRegion,
            referenceTemplate: referenceTemplate,
            adaptiveTemplate: adaptiveTemplate
        )

        if lostFrameCount >= configuration.globalSearchAfterLostFrames {
            let global = search(
                frame: frame,
                around: PixelPoint(
                    x: Double(frame.width - 1) / 2,
                    y: Double(frame.height - 1) / 2
                ),
                radius: max(frame.width, frame.height),
                step: configuration.globalSearchStep,
                region: searchRegion,
                referenceTemplate: referenceTemplate,
                adaptiveTemplate: adaptiveTemplate
            )
            if let global, best == nil || global.score > best!.score {
                best = global
            }
        }

        let isReacquiring = lostFrameCount > 0
        let threshold = isReacquiring
            ? configuration.minimumReacquisitionCorrelation
            : configuration.minimumCorrelation
        guard let best, best.score >= threshold else {
            lostFrameCount += 1
            velocity.x *= 0.45
            velocity.y *= 0.45
            return nil
        }

        let wasGlobal = isReacquiring && best.center.distance(to: predicted) > Double(expandedRadius + 2)
        let kind: MatchKind = wasGlobal ? .globalReacquisition : matchKind
        let displacement = PixelPoint(
            x: best.center.x - currentPoint.x,
            y: best.center.y - currentPoint.y
        )
        velocity = PixelPoint(
            x: velocity.x * 0.55 + displacement.x * 0.45,
            y: velocity.y * 0.55 + displacement.y * 0.45
        )
        self.currentPoint = best.center
        lostFrameCount = 0

        if best.score >= 0.72,
           kind != .globalReacquisition,
           let newTemplate = normalizedPatch(in: frame, centeredAt: best.center) {
            self.adaptiveTemplate = blend(
                old: adaptiveTemplate,
                new: newTemplate,
                rate: configuration.templateLearningRate
            )
        }

        let confidenceProgress = max(0, min(1, (best.score - threshold) / (1 - threshold)))
        let confidence = 0.18 + confidenceProgress * 0.77
        return Match(
            point: NormalizedPoint(
                x: best.center.x / Double(frame.width - 1),
                y: best.center.y / Double(frame.height - 1)
            ),
            confidence: confidence,
            correlation: best.score,
            kind: kind
        )
    }

    private func search(
        frame: SampledFrame,
        around predicted: PixelPoint,
        radius: Int,
        step: Int,
        region: CGRect?,
        referenceTemplate: [Float],
        adaptiveTemplate: [Float]
    ) -> Candidate? {
        let patchRadius = configuration.templateRadius
        let allowed = pixelBounds(
            for: frame,
            normalizedRegion: region,
            inset: patchRadius
        )
        guard allowed.minX <= allowed.maxX, allowed.minY <= allowed.maxY else {
            return nil
        }

        let minX = max(allowed.minX, Int(predicted.x.rounded()) - radius)
        let maxX = min(allowed.maxX, Int(predicted.x.rounded()) + radius)
        let minY = max(allowed.minY, Int(predicted.y.rounded()) - radius)
        let maxY = min(allowed.maxY, Int(predicted.y.rounded()) + radius)
        guard minX <= maxX, minY <= maxY else { return nil }

        let safeStep = max(1, step)
        var best: Candidate?
        var y = minY
        while y <= maxY {
            var x = minX
            while x <= maxX {
                let center = PixelPoint(x: Double(x), y: Double(y))
                if let score = correlation(
                    in: frame,
                    centeredAt: center,
                    referenceTemplate: referenceTemplate,
                    adaptiveTemplate: adaptiveTemplate
                ), best == nil || score > best!.score {
                    best = Candidate(center: center, score: score)
                }
                x += safeStep
            }
            y += safeStep
        }

        guard let coarseBest = best, safeStep > 1 else { return best }
        let refinementRadius = safeStep + 1
        let refineMinX = max(allowed.minX, Int(coarseBest.center.x) - refinementRadius)
        let refineMaxX = min(allowed.maxX, Int(coarseBest.center.x) + refinementRadius)
        let refineMinY = max(allowed.minY, Int(coarseBest.center.y) - refinementRadius)
        let refineMaxY = min(allowed.maxY, Int(coarseBest.center.y) + refinementRadius)

        for y in refineMinY...refineMaxY {
            for x in refineMinX...refineMaxX {
                let center = PixelPoint(x: Double(x), y: Double(y))
                if let score = correlation(
                    in: frame,
                    centeredAt: center,
                    referenceTemplate: referenceTemplate,
                    adaptiveTemplate: adaptiveTemplate
                ), score > best!.score {
                    best = Candidate(center: center, score: score)
                }
            }
        }
        return best
    }

    private func correlation(
        in frame: SampledFrame,
        centeredAt center: PixelPoint,
        referenceTemplate: [Float],
        adaptiveTemplate: [Float]
    ) -> Double? {
        guard let candidate = normalizedPatch(in: frame, centeredAt: center) else {
            return nil
        }
        let adaptiveScore = dot(candidate, adaptiveTemplate)
        // The original template prevents slow adaptive drift. The small offset
        // favors the recent appearance when both descriptions are plausible.
        let referenceScore = dot(candidate, referenceTemplate) - 0.025
        return max(adaptiveScore, referenceScore)
    }

    /// Extracts a zero-mean, unit-length patch. Uniform patches are rejected:
    /// a click on blank paper cannot be tracked safely.
    private func normalizedPatch(
        in frame: SampledFrame,
        centeredAt center: PixelPoint
    ) -> [Float]? {
        let radius = configuration.templateRadius
        let centerX = Int(center.x.rounded())
        let centerY = Int(center.y.rounded())
        guard centerX - radius >= 0,
              centerY - radius >= 0,
              centerX + radius < frame.width,
              centerY + radius < frame.height else { return nil }

        let side = radius * 2 + 1
        let count = side * side
        var values = [Float]()
        values.reserveCapacity(count)
        var sum: Float = 0
        for y in (centerY - radius)...(centerY + radius) {
            for x in (centerX - radius)...(centerX + radius) {
                let value = frame[x, y]
                values.append(value)
                sum += value
            }
        }

        let mean = sum / Float(count)
        var squaredLength: Float = 0
        for index in values.indices {
            values[index] -= mean
            squaredLength += values[index] * values[index]
        }
        let deviation = sqrt(squaredLength / Float(count))
        guard deviation >= Float(configuration.minimumTemplateDeviation),
              squaredLength > 1e-8 else { return nil }

        let inverseLength = 1 / sqrt(squaredLength)
        for index in values.indices {
            values[index] *= inverseLength
        }
        return values
    }

    private func dot(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count else { return -1 }
        var sum: Float = 0
        for index in lhs.indices {
            sum += lhs[index] * rhs[index]
        }
        return Double(sum)
    }

    private func blend(old: [Float], new: [Float], rate: Double) -> [Float] {
        guard old.count == new.count else { return old }
        let alpha = Float(max(0, min(1, rate)))
        var blended = zip(old, new).map { (1 - alpha) * $0 + alpha * $1 }
        let length = sqrt(blended.reduce(Float(0)) { $0 + $1 * $1 })
        guard length > 1e-8 else { return old }
        for index in blended.indices {
            blended[index] /= length
        }
        return blended
    }

    // MARK: - Frame sampling

    private func sampledFrame(from pixelBuffer: CVPixelBuffer) -> SampledFrame? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let scale = min(
            1,
            Double(configuration.maximumFrameDimension) / Double(max(sourceWidth, sourceHeight))
        )
        let width = max(1, Int((Double(sourceWidth) * scale).rounded()))
        let height = max(1, Int((Double(sourceHeight) * scale).rounded()))
        var pixels = [Float](repeating: 0, count: width * height)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)

        for y in 0..<height {
            let sourceY = min(sourceHeight - 1, Int(Double(y) / scale))
            let row = bytes.advanced(by: sourceY * bytesPerRow)
            for x in 0..<width {
                let sourceX = min(sourceWidth - 1, Int(Double(x) / scale))
                let offset = sourceX * 4
                let blue = Float(row[offset])
                let green = Float(row[offset + 1])
                let red = Float(row[offset + 2])
                pixels[y * width + x] = (0.0722 * blue + 0.7152 * green + 0.2126 * red) / 255
            }
        }
        return SampledFrame(width: width, height: height, pixels: pixels)
    }

    private func sampledFrame(
        lumaPixels: [UInt8],
        width sourceWidth: Int,
        height sourceHeight: Int
    ) -> SampledFrame? {
        guard sourceWidth > 0,
              sourceHeight > 0,
              lumaPixels.count == sourceWidth * sourceHeight else { return nil }

        let scale = min(
            1,
            Double(configuration.maximumFrameDimension) / Double(max(sourceWidth, sourceHeight))
        )
        let width = max(1, Int((Double(sourceWidth) * scale).rounded()))
        let height = max(1, Int((Double(sourceHeight) * scale).rounded()))
        var pixels = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let sourceY = min(sourceHeight - 1, Int(Double(y) / scale))
            for x in 0..<width {
                let sourceX = min(sourceWidth - 1, Int(Double(x) / scale))
                pixels[y * width + x] = Float(lumaPixels[sourceY * sourceWidth + sourceX]) / 255
            }
        }
        return SampledFrame(width: width, height: height, pixels: pixels)
    }

    private func pixelBounds(
        for frame: SampledFrame,
        normalizedRegion: CGRect?,
        inset: Int
    ) -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
        guard let region = normalizedRegion else {
            return (
                inset,
                frame.width - inset - 1,
                inset,
                frame.height - inset - 1
            )
        }

        let clipped = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull, !clipped.isEmpty else {
            return (1, 0, 1, 0)
        }
        return (
            max(inset, Int((clipped.minX * Double(frame.width - 1)).rounded(.down))),
            min(frame.width - inset - 1, Int((clipped.maxX * Double(frame.width - 1)).rounded(.up))),
            max(inset, Int((clipped.minY * Double(frame.height - 1)).rounded(.down))),
            min(frame.height - inset - 1, Int((clipped.maxY * Double(frame.height - 1)).rounded(.up)))
        )
    }
}
