import AVFoundation
import AppKit
import QuartzCore
import SwiftUI

struct CameraPreviewRepresentable: NSViewRepresentable {
    let session: AVCaptureSession
    let calibrationCorners: [NormalizedPoint]
    let suggestedCorners: [NormalizedPoint]
    let trackedPoint: NormalizedPoint?
    let interaction: CameraInteraction
    let onClick: (NormalizedPoint) -> Void

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView(session: session)
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: CameraPreviewNSView, context: Context) {
        view.calibrationCorners = calibrationCorners
        view.suggestedCorners = suggestedCorners
        view.trackedPoint = trackedPoint
        view.interaction = interaction
        view.onClick = onClick
        view.updateOverlay()
    }
}

final class CameraPreviewNSView: NSView {
    var calibrationCorners: [NormalizedPoint] = []
    var suggestedCorners: [NormalizedPoint] = []
    var trackedPoint: NormalizedPoint?
    var interaction: CameraInteraction = .idle
    var onClick: ((NormalizedPoint) -> Void)?

    private let previewLayer: AVCaptureVideoPreviewLayer
    private let suggestionLayer = CAShapeLayer()
    private let calibrationLayer = CAShapeLayer()
    private let trackedPointLayer = CAShapeLayer()
    private var numberLayers: [CATextLayer] = []

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspect
        layer?.addSublayer(previewLayer)

        suggestionLayer.fillColor = NSColor.clear.cgColor
        suggestionLayer.strokeColor = NSColor.systemTeal.withAlphaComponent(0.9).cgColor
        suggestionLayer.lineWidth = 2
        suggestionLayer.lineDashPattern = [7, 5]
        layer?.addSublayer(suggestionLayer)

        calibrationLayer.fillColor = NSColor.systemBlue.withAlphaComponent(0.10).cgColor
        calibrationLayer.strokeColor = NSColor.systemBlue.cgColor
        calibrationLayer.lineWidth = 2.5
        layer?.addSublayer(calibrationLayer)

        trackedPointLayer.fillColor = NSColor.systemYellow.cgColor
        trackedPointLayer.strokeColor = NSColor.black.withAlphaComponent(0.7).cgColor
        trackedPointLayer.lineWidth = 1.5
        layer?.addSublayer(trackedPointLayer)

        setAccessibilityElement(true)
        setAccessibilityLabel("Live Desk View camera preview")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        suggestionLayer.frame = bounds
        calibrationLayer.frame = bounds
        trackedPointLayer.frame = bounds
        updateOverlay()
    }

    override func mouseDown(with event: NSEvent) {
        guard interaction != .idle else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)
        guard (0...1).contains(devicePoint.x), (0...1).contains(devicePoint.y) else {
            return
        }
        onClick?(NormalizedPoint(devicePoint))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func updateOverlay() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        suggestionLayer.path = path(for: suggestedCorners, close: true)
        calibrationLayer.path = path(for: calibrationCorners, close: calibrationCorners.count == 4)

        if let trackedPoint {
            let center = layerPoint(for: trackedPoint)
            trackedPointLayer.path = CGPath(
                ellipseIn: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12),
                transform: nil
            )
        } else {
            trackedPointLayer.path = nil
        }

        numberLayers.forEach { $0.removeFromSuperlayer() }
        numberLayers.removeAll()
        for (index, point) in calibrationCorners.enumerated() {
            let center = layerPoint(for: point)
            let textLayer = CATextLayer()
            textLayer.string = "\(index + 1)"
            textLayer.fontSize = 11
            textLayer.alignmentMode = .center
            textLayer.foregroundColor = NSColor.white.cgColor
            textLayer.backgroundColor = NSColor.systemBlue.cgColor
            textLayer.cornerRadius = 9
            textLayer.contentsScale = window?.backingScaleFactor ?? 2
            textLayer.frame = CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)
            layer?.addSublayer(textLayer)
            numberLayers.append(textLayer)
        }

        CATransaction.commit()
    }

    private func path(for points: [NormalizedPoint], close: Bool) -> CGPath? {
        guard !points.isEmpty else { return nil }
        let path = CGMutablePath()
        path.move(to: layerPoint(for: points[0]))
        for point in points.dropFirst() {
            path.addLine(to: layerPoint(for: point))
        }
        if close { path.closeSubpath() }
        return path
    }

    private func layerPoint(for normalized: NormalizedPoint) -> CGPoint {
        previewLayer.layerPointConverted(
            fromCaptureDevicePoint: CGPoint(x: normalized.x, y: normalized.y)
        )
    }
}
