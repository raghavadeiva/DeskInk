import AppKit
import CoreGraphics
import CoreText
import Foundation

enum GridTestPDFGeneratorError: Error {
    case couldNotCreateConsumer
    case couldNotCreateContext
}

/// Creates a one-page, all-vector accuracy fixture at the selected paper's
/// physical size. PDF coordinates are bottom-left; fixture geometry is defined
/// from the paper's top-left and converted at the drawing boundary.
enum GridTestPDFGenerator {
    static func makePDF(format: PaperFormat) throws -> Data {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output) else {
            throw GridTestPDFGeneratorError.couldNotCreateConsumer
        }

        var mediaBox = CGRect(
            x: 0,
            y: 0,
            width: format.widthPoints,
            height: format.heightPoints
        )
        let metadata = [
            kCGPDFContextTitle as String: "DeskInk \(format.displayName) accuracy grid",
            kCGPDFContextCreator as String: "DeskInk"
        ] as CFDictionary
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, metadata) else {
            throw GridTestPDFGeneratorError.couldNotCreateContext
        }

        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(mediaBox)

        drawGrid(in: context, format: format)
        drawTopMarker(in: context, format: format)
        drawRuler(in: context)
        drawPrintWarning(in: context)

        context.endPDFPage()
        context.closePDF()
        return output as Data
    }

    private static func drawGrid(in context: CGContext, format: PaperFormat) {
        context.saveGState()
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(0.7)
        context.setLineCap(.square)

        let arm = points(3)
        for target in AccuracyGrid.targets(for: format) {
            let centre = pdfPoint(target.positionMM, format: format)
            context.move(to: CGPoint(x: centre.x - arm, y: centre.y))
            context.addLine(to: CGPoint(x: centre.x + arm, y: centre.y))
            context.move(to: CGPoint(x: centre.x, y: centre.y - arm))
            context.addLine(to: CGPoint(x: centre.x, y: centre.y + arm))
            context.strokePath()

            drawText(
                "\(target.index + 1)",
                at: CGPoint(x: centre.x + points(3.8), y: centre.y + points(1.6)),
                fontSize: 6,
                context: context
            )
        }
        context.restoreGState()
    }

    private static func drawTopMarker(in context: CGContext, format: PaperFormat) {
        let centreX = points(format.widthMM - 8)
        let topY = points(6)
        let markerHalfWidth = points(2.5)
        let markerHeight = points(5)

        context.saveGState()
        context.setFillColor(NSColor.black.cgColor)
        context.beginPath()
        context.move(to: CGPoint(x: centreX, y: format.heightPoints - topY))
        context.addLine(to: CGPoint(
            x: centreX - markerHalfWidth,
            y: format.heightPoints - topY - markerHeight
        ))
        context.addLine(to: CGPoint(
            x: centreX + markerHalfWidth,
            y: format.heightPoints - topY - markerHeight
        ))
        context.closePath()
        context.fillPath()
        context.restoreGState()

        drawText(
            "TOP",
            at: CGPoint(
                x: points(format.widthMM - 29),
                y: format.heightPoints - points(9.5)
            ),
            fontSize: 10,
            weight: .bold,
            context: context
        )
    }

    private static func drawRuler(in context: CGContext) {
        let startX = points(20)
        let endX = points(120)
        let baselineY = points(5)

        context.saveGState()
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: startX, y: baselineY))
        context.addLine(to: CGPoint(x: endX, y: baselineY))
        for tick in 0...10 {
            let x = startX + points(Double(tick) * 10)
            let tickHeight = points(tick == 0 || tick == 10 ? 3 : 1.8)
            context.move(to: CGPoint(x: x, y: baselineY - tickHeight / 2))
            context.addLine(to: CGPoint(x: x, y: baselineY + tickHeight / 2))
        }
        context.strokePath()
        context.restoreGState()

        drawText(
            "100 mm reference ruler",
            at: CGPoint(x: startX, y: baselineY + points(2.2)),
            fontSize: 6,
            context: context
        )
    }

    private static func drawPrintWarning(in context: CGContext) {
        drawText(
            "PRINT AT 100% / ACTUAL SIZE — disable Fit to Page",
            at: CGPoint(x: points(20), y: points(10.5)),
            fontSize: 7,
            weight: .bold,
            context: context
        )
    }

    private static func pdfPoint(_ point: PaperPointMM, format: PaperFormat) -> CGPoint {
        CGPoint(
            x: points(point.x),
            y: format.heightPoints - points(point.y)
        )
    }

    private static func points(_ millimetres: Double) -> Double {
        millimetres * PaperFormat.pointsPerMillimetre
    }

    private static func drawText(
        _ text: String,
        at position: CGPoint,
        fontSize: CGFloat,
        weight: NSFont.Weight = .regular,
        context: CGContext
    ) {
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
                .foregroundColor: NSColor.black
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = position
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
