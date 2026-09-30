import AppKit
import CoreGraphics
import PDFKit
import Testing
@testable import DeskInk

@Suite("PDF export")
struct PDFExporterTests {
    @Test("Export preserves the page and adds vector ink")
    func exportPreservesPageAndAddsVectorInk() throws {
        let source = try makeBlankDocument()
        let stroke = InkStroke(
            pageIndex: 0,
            points: [
                NormalizedPoint(x: 0.1, y: 0.2),
                NormalizedPoint(x: 0.5, y: 0.6),
                NormalizedPoint(x: 0.9, y: 0.8)
            ],
            color: .blue
        )

        let exported = try #require(PDFExporter.annotatedCopy(of: source, strokes: [stroke]))
        #expect(exported.pageCount == 1)
        let page = try #require(exported.page(at: 0))
        #expect(page.annotations.count == 1)
        #expect(page.annotations.first?.type == "Ink")

        let serialized = try #require(exported.dataRepresentation())
        let reopened = try #require(PDFDocument(data: serialized))
        #expect(reopened.page(at: 0)?.annotations.count == 1)
        let reopenedPage = try #require(reopened.page(at: 0))
        #expect(countVisibleInkPixels(on: reopenedPage) > 40)
    }

    @Test("Black remains dark and visible under Dark Aqua")
    func blackInkIsAppearanceIndependent() throws {
        let appearance = try #require(NSAppearance(named: .darkAqua))
        var resolvedColor: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolvedColor = InkColorChoice.black.nsColor.usingColorSpace(.sRGB)
        }
        let color = try #require(resolvedColor)
        #expect(color.redComponent < 0.2)
        #expect(color.greenComponent < 0.2)
        #expect(color.blueComponent < 0.2)

        let source = try makeBlankDocument()
        let stroke = InkStroke(
            pageIndex: 0,
            points: [
                NormalizedPoint(x: 0.2, y: 0.5),
                NormalizedPoint(x: 0.8, y: 0.5)
            ],
            widthInPDFPoints: 4,
            color: .black
        )
        let exported = try #require(PDFExporter.annotatedCopy(of: source, strokes: [stroke]))
        let serialized = try #require(exported.dataRepresentation())
        let reopened = try #require(PDFDocument(data: serialized))
        let page = try #require(reopened.page(at: 0))
        #expect(countVisibleInkPixels(on: page) > 100)
    }

    private func makeBlankDocument() throws -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(mediaBox)
        context.endPDFPage()
        context.closePDF()
        return try #require(PDFDocument(data: data as Data))
    }

    private func countVisibleInkPixels(on page: PDFPage) -> Int {
        let width = 306
        let height = 396
        var pixels = Array(repeating: UInt8(255), count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
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
            let bounds = page.bounds(for: .mediaBox)
            context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .mediaBox, to: context)
            return true
        }
        guard rendered else { return 0 }

        var visible = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            if red < 220 || green < 220 || blue < 220 {
                visible += 1
            }
        }
        return visible
    }
}
