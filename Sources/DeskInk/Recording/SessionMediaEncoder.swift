import CoreImage
import CoreVideo
import Foundation
import ImageIO

enum SessionMediaRequest: Equatable {
    case tipCrop(center: NormalizedPoint, pixelSize: Int)
    case fullFrame
}

protocol SessionMediaEncoding: AnyObject {
    func jpegData(
        from pixelBuffer: CVPixelBuffer,
        request: SessionMediaRequest,
        quality: Double
    ) throws -> Data
}

enum SessionMediaEncodingError: LocalizedError {
    case frameTooSmall
    case jpegEncodingFailed

    var errorDescription: String? {
        switch self {
        case .frameTooSmall:
            return "The captured frame is smaller than the requested tip crop."
        case .jpegEncodingFailed:
            return "Core Image could not encode the camera frame as JPEG."
        }
    }
}

final class CoreImageSessionMediaEncoder: SessionMediaEncoding {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    func jpegData(
        from pixelBuffer: CVPixelBuffer,
        request: SessionMediaRequest,
        quality: Double
    ) throws -> Data {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        switch request {
        case .fullFrame:
            break
        case let .tipCrop(center, pixelSize):
            let width = image.extent.width
            let height = image.extent.height
            guard width >= CGFloat(pixelSize), height >= CGFloat(pixelSize), pixelSize > 0 else {
                throw SessionMediaEncodingError.frameTooSmall
            }

            let size = CGFloat(pixelSize)
            let centerX = CGFloat(center.x) * width
            // Camera/preview points use a top-left origin; Core Image uses bottom-left.
            let centerY = (1 - CGFloat(center.y)) * height
            let originX = min(max(0, centerX - size / 2), width - size)
            let originY = min(max(0, centerY - size / 2), height - size)
            image = image.cropped(to: CGRect(x: originX, y: originY, width: size, height: size))
        }

        let qualityKey = CIImageRepresentationOption(
            rawValue: kCGImageDestinationLossyCompressionQuality as String
        )
        let options: [CIImageRepresentationOption: Any] = [
            qualityKey: min(max(quality, 0), 1)
        ]
        guard let data = context.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: options
        ) else {
            throw SessionMediaEncodingError.jpegEncodingFailed
        }
        return data
    }
}
