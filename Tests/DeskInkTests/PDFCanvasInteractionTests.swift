import AppKit
import CoreGraphics
import PDFKit
import Testing
@testable import DeskInk

@Suite("Simulator input", .serialized)
struct PDFCanvasInteractionTests {
    @Test("A pointer drag commits normalized ink points")
    @MainActor
    func pointerDragCommitsStroke() throws {
        let document = try makeBlankDocument()
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 800),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let canvas = PDFInkCanvasView(frame: window.contentView?.bounds ?? .zero)
        canvas.autoresizingMask = [.width, .height]
        canvas.document = document
        canvas.isSimulatorEnabled = true
        window.contentView = canvas

        var committed: [NormalizedPoint] = []
        canvas.onCompletedStroke = { committed = $0 }

        canvas.mouseDown(with: try event(type: .leftMouseDown, at: CGPoint(x: 250, y: 250), window: window))
        canvas.mouseDragged(with: try event(type: .leftMouseDragged, at: CGPoint(x: 320, y: 330), window: window))
        canvas.mouseUp(with: try event(type: .leftMouseUp, at: CGPoint(x: 390, y: 410), window: window))

        #expect(committed.count == 3)
        #expect(committed.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
    }

    @Test("A pointer click commits a visible dot")
    @MainActor
    func pointerClickCommitsDot() throws {
        let document = try makeBlankDocument()
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 800),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let canvas = PDFInkCanvasView(frame: window.contentView?.bounds ?? .zero)
        canvas.document = document
        canvas.isSimulatorEnabled = true
        window.contentView = canvas

        var committed: [NormalizedPoint] = []
        canvas.onCompletedStroke = { committed = $0 }
        let location = CGPoint(x: 300, y: 300)
        canvas.mouseDown(with: try event(type: .leftMouseDown, at: location, window: window))
        canvas.mouseUp(with: try event(type: .leftMouseUp, at: location, window: window))

        #expect(committed.count == 1)
    }

    @MainActor
    private func event(type: NSEvent.EventType, at point: CGPoint, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
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
}
