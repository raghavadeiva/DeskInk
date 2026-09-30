import AppKit
import PDFKit

enum PDFExporter {
    static func annotatedCopy(of document: PDFDocument, strokes: [InkStroke]) -> PDFDocument? {
        guard let sourceData = document.dataRepresentation(),
              let exported = PDFDocument(data: sourceData) else {
            return nil
        }

        for stroke in strokes {
            guard !stroke.points.isEmpty,
                  let page = exported.page(at: stroke.pageIndex) else {
                continue
            }

            let pageBounds = page.bounds(for: .mediaBox)
            let annotation = PDFAnnotation(
                bounds: pageBounds,
                forType: .ink,
                withProperties: nil
            )
            annotation.color = stroke.color.nsColor
            let border = PDFBorder()
            border.lineWidth = stroke.widthInPDFPoints
            annotation.border = border

            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            for (index, point) in stroke.points.enumerated() {
                let localPoint = NSPoint(
                    x: point.x * pageBounds.width,
                    y: (1 - point.y) * pageBounds.height
                )
                if index == 0 {
                    path.move(to: localPoint)
                } else {
                    path.line(to: localPoint)
                }
            }
            if stroke.points.count == 1, let point = stroke.points.first {
                let localPoint = NSPoint(
                    x: point.x * pageBounds.width,
                    y: (1 - point.y) * pageBounds.height
                )
                path.line(to: NSPoint(x: localPoint.x + 0.5, y: localPoint.y))
            }
            annotation.add(path)
            page.addAnnotation(annotation)
        }

        return exported
    }
}
