import AppKit
import CoreGraphics
import PDFKit
import Testing
@testable import DeskInk

@Suite("Accuracy fixture paper and PDF")
struct AccuracyPaperAndPDFTests {
    @Test("Letter and A4 retain exact physical dimensions")
    func exactPaperDimensions() {
        #expect(abs(PaperFormat.letter.widthMM - 215.9) < 1e-12)
        #expect(abs(PaperFormat.letter.heightMM - 279.4) < 1e-12)
        #expect(PaperFormat.a4.widthMM == 210)
        #expect(PaperFormat.a4.heightMM == 297)
        #expect(abs(PaperFormat.letter.widthPoints - 612) < 1e-10)
        #expect(abs(PaperFormat.letter.heightPoints - 792) < 1e-10)
    }

    @Test("Five by five targets are deterministic and row-major from top-left")
    func deterministicTargets() throws {
        let letter = AccuracyGrid.targets(for: .letter)
        #expect(letter.count == 25)
        #expect(letter[0] == GridTarget(
            index: 0,
            row: 0,
            column: 0,
            positionMM: PaperPointMM(x: 20, y: 20)
        ))
        #expect(abs(letter[1].positionMM.x - 63.975) < 1e-10)
        #expect(abs(letter[5].positionMM.y - 79.85) < 1e-10)
        #expect(abs(letter[24].positionMM.x - 195.9) < 1e-10)
        #expect(abs(letter[24].positionMM.y - 259.4) < 1e-10)

        let a4 = AccuracyGrid.targets(for: .a4)
        #expect(a4[0].positionMM == PaperPointMM(x: 20, y: 20))
        #expect(a4[2].positionMM == PaperPointMM(x: 105, y: 20))
        #expect(a4[12].positionMM == PaperPointMM(x: 105, y: 148.5))
        #expect(a4[24].positionMM == PaperPointMM(x: 190, y: 277))

        for (index, target) in letter.enumerated() {
            #expect(target.index == index)
            #expect(target.row == index / 5)
            #expect(target.column == index % 5)
        }
    }

    @Test("Generated PDFs use actual paper size and include print aids")
    func generatedPDFGeometryAndLabels() throws {
        for format in PaperFormat.allCases {
            let data = try GridTestPDFGenerator.makePDF(format: format)
            let document = try #require(PDFDocument(data: data))
            #expect(document.pageCount == 1)
            let page = try #require(document.page(at: 0))
            let bounds = page.bounds(for: .mediaBox)
            #expect(abs(bounds.width - format.widthPoints) < 0.01)
            #expect(abs(bounds.height - format.heightPoints) < 0.01)

            let text = page.string ?? ""
            #expect(text.contains("TOP"))
            #expect(text.contains("ACTUAL SIZE"))
            #expect(text.contains("100 mm reference ruler"))
            #expect(text.contains("25"))
        }
    }

    @Test("Rendered TOP marker is asymmetric across the horizontal axis")
    func topMarkerIsNotVerticallyMirrored() throws {
        let format = PaperFormat.a4
        let data = try GridTestPDFGenerator.makePDF(format: format)
        let document = try #require(PDFDocument(data: data))
        let page = try #require(document.page(at: 0))
        let raster = try render(page: page, pixelsPerMillimetre: 3)

        let xRange = millimetreRange(
            format.widthMM - 12,
            format.widthMM - 3,
            scale: raster.scale,
            limit: raster.width
        )
        let markerTopRange = topOriginMillimetreRange(
            2,
            13,
            scale: raster.scale,
            limit: raster.height
        )
        let mirroredBottomRange = topOriginMillimetreRange(
            format.heightMM - 13,
            format.heightMM - 2,
            scale: raster.scale,
            limit: raster.height
        )

        let topInk = countDarkPixels(
            raster.pixels,
            width: raster.width,
            xRange: xRange,
            yRange: markerTopRange
        )
        let mirroredInk = countDarkPixels(
            raster.pixels,
            width: raster.width,
            xRange: xRange,
            yRange: mirroredBottomRange
        )
        #expect(topInk > 100)
        #expect(topInk > mirroredInk * 4 + 20)
    }

    private func render(
        page: PDFPage,
        pixelsPerMillimetre scale: Double
    ) throws -> (pixels: [UInt8], width: Int, height: Int, scale: Double) {
        let bounds = page.bounds(for: .mediaBox)
        let paperWidthMM = Double(bounds.width) / PaperFormat.pointsPerMillimetre
        let paperHeightMM = Double(bounds.height) / PaperFormat.pointsPerMillimetre
        let width = Int(ceil(paperWidthMM * scale))
        let height = Int(ceil(paperHeightMM * scale))
        var pixels = Array(repeating: UInt8(255), count: width * height * 4)

        let created = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: Double(width) / bounds.width, y: Double(height) / bounds.height)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .mediaBox, to: context)
            return true
        }
        guard created else { throw RasterError.contextCreationFailed }
        return (pixels, width, height, scale)
    }

    /// PDFKit's bitmap output rows are top-origin, matching the fixture
    /// contract even though the PDF user space itself is bottom-origin.
    private func topOriginMillimetreRange(
        _ lower: Double,
        _ upper: Double,
        scale: Double,
        limit: Int
    ) -> Range<Int> {
        return millimetreRange(lower, upper, scale: scale, limit: limit)
    }

    private func millimetreRange(
        _ lower: Double,
        _ upper: Double,
        scale: Double,
        limit: Int
    ) -> Range<Int> {
        max(0, Int(floor(lower * scale)))..<min(limit, Int(ceil(upper * scale)))
    }

    private func countDarkPixels(
        _ pixels: [UInt8],
        width: Int,
        xRange: Range<Int>,
        yRange: Range<Int>
    ) -> Int {
        var count = 0
        for y in yRange {
            for x in xRange {
                let offset = (y * width + x) * 4
                if pixels[offset] < 100 && pixels[offset + 1] < 100 && pixels[offset + 2] < 100 {
                    count += 1
                }
            }
        }
        return count
    }

    private enum RasterError: Error {
        case contextCreationFailed
    }
}
