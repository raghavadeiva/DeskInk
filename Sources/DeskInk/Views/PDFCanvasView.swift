import AppKit
import PDFKit
import SwiftUI

struct PDFCanvasRepresentable: NSViewRepresentable {
    let document: PDFDocument?
    let pageIndex: Int
    let strokes: [InkStroke]
    let activeStroke: InkStroke?
    let isSimulatorEnabled: Bool
    let currentInkColor: InkColorChoice
    let onCompletedStroke: ([NormalizedPoint]) -> Void

    func makeNSView(context: Context) -> PDFInkCanvasView {
        let view = PDFInkCanvasView()
        view.onCompletedStroke = onCompletedStroke
        return view
    }

    func updateNSView(_ view: PDFInkCanvasView, context: Context) {
        view.document = document
        view.pageIndex = pageIndex
        view.strokes = strokes
        view.activeStroke = activeStroke
        view.isSimulatorEnabled = isSimulatorEnabled
        view.currentInkColor = currentInkColor
        view.onCompletedStroke = onCompletedStroke
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }
}

final class PDFInkCanvasView: NSView {
    var document: PDFDocument?
    var pageIndex = 0
    var strokes: [InkStroke] = []
    var activeStroke: InkStroke?
    var isSimulatorEnabled = false
    var currentInkColor: InkColorChoice = .blue
    var onCompletedStroke: (([NormalizedPoint]) -> Void)?

    private var draftPoints: [NormalizedPoint] = []

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()

        guard let page = document?.page(at: pageIndex),
              let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        let pageBounds = page.bounds(for: .mediaBox)
        let targetRect = fittedPageRect(for: pageBounds.size)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 12, color: NSColor.black.withAlphaComponent(0.18).cgColor)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(targetRect)
        context.restoreGState()

        context.saveGState()
        context.translateBy(x: targetRect.minX, y: targetRect.minY)
        context.scaleBy(
            x: targetRect.width / pageBounds.width,
            y: targetRect.height / pageBounds.height
        )
        context.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        for stroke in strokes {
            draw(stroke: stroke, in: targetRect, pageSize: pageBounds.size)
        }
        if let activeStroke, activeStroke.pageIndex == pageIndex {
            draw(stroke: activeStroke, in: targetRect, pageSize: pageBounds.size)
        }
        if !draftPoints.isEmpty {
            draw(
                stroke: InkStroke(
                    pageIndex: pageIndex,
                    points: draftPoints,
                    color: currentInkColor
                ),
                in: targetRect,
                pageSize: pageBounds.size
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isSimulatorEnabled,
              let normalized = normalizedPoint(for: event) else {
            return
        }
        window?.makeFirstResponder(self)
        draftPoints = [normalized]
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isSimulatorEnabled,
              let normalized = normalizedPoint(for: event) else {
            return
        }
        if let last = draftPoints.last, last.distance(to: normalized) < 0.0007 {
            return
        }
        draftPoints.append(normalized)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isSimulatorEnabled else { return }
        if let normalized = normalizedPoint(for: event),
           draftPoints.last?.distance(to: normalized) ?? 1 > 0.0007 {
            draftPoints.append(normalized)
        }
        let completed = draftPoints
        draftPoints.removeAll()
        if !completed.isEmpty {
            onCompletedStroke?(completed)
        }
        needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: isSimulatorEnabled ? .crosshair : .arrow)
    }

    private func draw(stroke: InkStroke, in pageRect: CGRect, pageSize: CGSize) {
        guard !stroke.points.isEmpty else { return }
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = max(1, stroke.widthInPDFPoints * pageRect.width / pageSize.width)

        for (index, point) in stroke.points.enumerated() {
            let displayPoint = NSPoint(
                x: pageRect.minX + point.x * pageRect.width,
                y: pageRect.minY + (1 - point.y) * pageRect.height
            )
            if index == 0 {
                path.move(to: displayPoint)
            } else {
                path.line(to: displayPoint)
            }
        }

        stroke.color.nsColor.setStroke()
        if stroke.points.count == 1, let point = stroke.points.first {
            let displayPoint = NSPoint(
                x: pageRect.minX + point.x * pageRect.width,
                y: pageRect.minY + (1 - point.y) * pageRect.height
            )
            let radius = max(1, path.lineWidth / 2)
            stroke.color.nsColor.setFill()
            NSBezierPath(
                ovalIn: CGRect(
                    x: displayPoint.x - radius,
                    y: displayPoint.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            ).fill()
        } else {
            path.stroke()
        }
    }

    private func normalizedPoint(for event: NSEvent) -> NormalizedPoint? {
        guard let page = document?.page(at: pageIndex) else { return nil }
        let location = convert(event.locationInWindow, from: nil)
        let pageRect = fittedPageRect(for: page.bounds(for: .mediaBox).size)
        guard pageRect.contains(location) else { return nil }
        return NormalizedPoint(
            x: (location.x - pageRect.minX) / pageRect.width,
            y: 1 - (location.y - pageRect.minY) / pageRect.height
        )
    }

    private func fittedPageRect(for pageSize: CGSize) -> CGRect {
        let available = bounds.insetBy(dx: 30, dy: 30)
        guard pageSize.width > 0, pageSize.height > 0,
              available.width > 0, available.height > 0 else {
            return .zero
        }
        let scale = min(available.width / pageSize.width, available.height / pageSize.height)
        let size = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
