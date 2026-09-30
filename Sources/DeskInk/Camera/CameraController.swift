import AVFoundation
import Foundation
import Vision

final class CameraController: ObservableObject {
    var session: AVCaptureSession { frameSource.session }

    @Published private(set) var state: CameraRunState = .idle
    @Published private(set) var suggestedPaperCorners: [NormalizedPoint] = []
    @Published private(set) var trackedCameraPoint: NormalizedPoint?
    @Published private(set) var trackedPaperPoint: NormalizedPoint?
    @Published private(set) var trackingConfidence = 0.0
    @Published private(set) var penTrackingState: PenTrackingState = .notSeeded
    @Published private(set) var activeVideoAspectRatio = 4.0 / 3.0
    @Published private(set) var captureDescriptor: CaptureDeviceDescriptor?

    var onObservation: ((PenObservation) -> Void)?

    private let frameSource: FrameSource
    let latencyMonitor: LatencyMonitor

    private var sequenceHandler = VNSequenceRequestHandler()
    private var trackedObject: VNDetectedObjectObservation?
    private var pendingSeedPoint: NormalizedPoint?
    private var paperTransform: PerspectiveTransform?
    private var calibrationCorners: [NormalizedPoint] = []
    private var contactState = PenContactStateMachine()
    private var smoothedCameraPoint: NormalizedPoint?
    private var consecutiveLostFrames = 0

    init(
        frameSource: FrameSource = AVCaptureFrameSource(),
        latencyMonitor: LatencyMonitor = LatencyMonitor()
    ) {
        self.frameSource = frameSource
        self.latencyMonitor = latencyMonitor
        frameSource.onFrame = { [weak self] frame in
            self?.process(frame)
        }
        frameSource.onFrameDrop = { [weak latencyMonitor] in
            latencyMonitor?.markCaptureDrop()
        }
        frameSource.onStateChange = { [weak self] state in
            self?.state = state
        }
        frameSource.onConfigurationChange = { [weak self] descriptor in
            self?.captureDescriptor = descriptor
            self?.activeVideoAspectRatio = descriptor.aspectRatio
        }
    }

    func start() {
        frameSource.start()
    }

    func stop() {
        frameSource.stop()
        frameSource.performOnFrameQueue { [weak self] in
            self?.resetTrackingState()
        }
    }

    func retry() {
        frameSource.retry()
    }

    func setCalibration(_ corners: [NormalizedPoint]) {
        frameSource.performOnFrameQueue { [weak self] in
            guard let self else { return }
            self.calibrationCorners = corners
            self.paperTransform = PerspectiveTransform.paperTransform(sourceCorners: corners)
            self.contactState.reset()
        }
    }

    func clearCalibration() {
        frameSource.performOnFrameQueue { [weak self] in
            self?.calibrationCorners.removeAll()
            self?.paperTransform = nil
            self?.contactState.reset()
        }
    }

    func seedPen(at cameraPoint: NormalizedPoint) {
        frameSource.performOnFrameQueue { [weak self] in
            guard let self else { return }
            self.pendingSeedPoint = cameraPoint
            self.trackedObject = nil
            self.sequenceHandler = VNSequenceRequestHandler()
            self.smoothedCameraPoint = nil
            self.contactState.reset()
            self.consecutiveLostFrames = 0
            DispatchQueue.main.async {
                self.penTrackingState = .acquiring
            }
        }
    }

    func clearPenSeed() {
        frameSource.performOnFrameQueue { [weak self] in
            self?.resetTrackingState()
        }
    }

    private func process(_ frame: CapturedVideoFrame) {
        let pixelBuffer = frame.pixelBuffer
        let timestamp = frame.presentationTime.seconds
        latencyMonitor.markCapture(
            traceID: frame.traceID,
            callbackHostTimestamp: frame.callbackHostTimestamp,
            presentationHostTimestamp: frame.presentationHostTimestamp,
            clockRelation: frame.clockRelation
        )

        if paperTransform == nil, frame.traceID.frameIndex.isMultiple(of: 15) {
            detectPaper(in: pixelBuffer)
        }

        if let seed = pendingSeedPoint {
            let boxSize = 0.12
            let visionCenterY = 1 - seed.y
            let origin = CGPoint(
                x: max(0, min(1 - boxSize, seed.x - boxSize / 2)),
                y: max(0, min(1 - boxSize, visionCenterY - boxSize / 2))
            )
            trackedObject = VNDetectedObjectObservation(
                boundingBox: CGRect(x: origin.x, y: origin.y, width: boxSize, height: boxSize)
            )
            pendingSeedPoint = nil
            smoothedCameraPoint = seed
            consecutiveLostFrames = 0
        }

        guard let trackedObject else {
            latencyMonitor.markTrackerResult(traceID: frame.traceID)
            publishObservation(
                PenObservation(
                    traceID: frame.traceID,
                    rawCameraPoint: nil,
                    cameraPoint: nil,
                    rawPaperPoint: nil,
                    paperPoint: nil,
                    confidence: 0,
                    trackerKind: "vision",
                    inferredDown: contactState.update(point: nil, confidence: 0, timestamp: timestamp),
                    timestamp: timestamp
                )
            )
            return
        }

        let request = VNTrackObjectRequest(detectedObjectObservation: trackedObject)
        request.trackingLevel = .fast

        do {
            try sequenceHandler.perform([request], on: pixelBuffer, orientation: .up)
            guard let result = request.results?.first as? VNDetectedObjectObservation,
                  !request.isLastFrame,
                  result.confidence >= 0.15 else {
                handleWeakTracking(
                    result: request.results?.first as? VNDetectedObjectObservation,
                    frame: frame,
                    timestamp: timestamp
                )
                return
            }

            self.trackedObject = result
            consecutiveLostFrames = 0
            let rawPoint = NormalizedPoint(
                x: result.boundingBox.midX,
                y: 1 - result.boundingBox.midY
            )
            let filteredPoint = smooth(rawPoint)
            let rawMappedPoint = paperTransform?.applying(to: rawPoint)
            let mappedPoint = paperTransform?.applying(to: filteredPoint)
            let pointOnPaper: NormalizedPoint?
            if let mappedPoint,
               (-0.02...1.02).contains(mappedPoint.x),
               (-0.02...1.02).contains(mappedPoint.y) {
                pointOnPaper = NormalizedPoint(
                    x: min(1, max(0, mappedPoint.x)),
                    y: min(1, max(0, mappedPoint.y))
                )
            } else {
                pointOnPaper = nil
            }

            let confidence = Double(result.confidence)
            let isDown = contactState.update(
                point: pointOnPaper,
                confidence: confidence,
                timestamp: timestamp
            )

            latencyMonitor.markTrackerResult(traceID: frame.traceID)
            publishObservation(
                PenObservation(
                    traceID: frame.traceID,
                    rawCameraPoint: rawPoint,
                    cameraPoint: filteredPoint,
                    rawPaperPoint: rawMappedPoint,
                    paperPoint: pointOnPaper,
                    confidence: confidence,
                    trackerKind: "vision",
                    inferredDown: isDown,
                    timestamp: timestamp
                )
            )
        } catch {
            handleWeakTracking(result: nil, frame: frame, timestamp: timestamp)
        }
    }

    private func detectPaper(in pixelBuffer: CVPixelBuffer) {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 1
        request.minimumConfidence = 0.55
        request.minimumAspectRatio = 0.35
        request.minimumSize = 0.2
        request.quadratureTolerance = 30

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do {
            try handler.perform([request])
            guard let rectangle = request.results?.first else { return }
            let corners = [
                NormalizedPoint(x: rectangle.topLeft.x, y: 1 - rectangle.topLeft.y),
                NormalizedPoint(x: rectangle.topRight.x, y: 1 - rectangle.topRight.y),
                NormalizedPoint(x: rectangle.bottomRight.x, y: 1 - rectangle.bottomRight.y),
                NormalizedPoint(x: rectangle.bottomLeft.x, y: 1 - rectangle.bottomLeft.y)
            ]
            DispatchQueue.main.async { [weak self] in
                self?.suggestedPaperCorners = corners
            }
        } catch {
            // Rectangle detection is an optional convenience; manual calibration remains available.
        }
    }

    private func smooth(_ newPoint: NormalizedPoint) -> NormalizedPoint {
        guard let oldPoint = smoothedCameraPoint else {
            smoothedCameraPoint = newPoint
            return newPoint
        }

        let distance = newPoint.distance(to: oldPoint)
        let alpha = min(0.82, max(0.38, 0.38 + distance * 5.5))
        let filtered = NormalizedPoint(
            x: oldPoint.x + (newPoint.x - oldPoint.x) * alpha,
            y: oldPoint.y + (newPoint.y - oldPoint.y) * alpha
        )
        smoothedCameraPoint = filtered
        return filtered
    }

    private func handleWeakTracking(
        result: VNDetectedObjectObservation?,
        frame: CapturedVideoFrame,
        timestamp: TimeInterval
    ) {
        consecutiveLostFrames += 1
        if let result {
            trackedObject = result
        }
        let down = contactState.update(point: nil, confidence: 0, timestamp: timestamp)
        if consecutiveLostFrames >= 5 {
            trackedObject = nil
            sequenceHandler = VNSequenceRequestHandler()
            smoothedCameraPoint = nil
        }
        let rawPoint = result.map {
            NormalizedPoint(x: $0.boundingBox.midX, y: 1 - $0.boundingBox.midY)
        }
        latencyMonitor.markTrackerResult(traceID: frame.traceID)
        publishObservation(
            PenObservation(
                traceID: frame.traceID,
                rawCameraPoint: rawPoint,
                cameraPoint: nil,
                rawPaperPoint: rawPoint.flatMap { paperTransform?.applying(to: $0) },
                paperPoint: nil,
                confidence: Double(result?.confidence ?? 0),
                trackerKind: "vision",
                inferredDown: down,
                timestamp: timestamp
            )
        )
    }

    private func resetTrackingState() {
        trackedObject = nil
        pendingSeedPoint = nil
        sequenceHandler = VNSequenceRequestHandler()
        smoothedCameraPoint = nil
        consecutiveLostFrames = 0
        contactState.reset()
        DispatchQueue.main.async { [weak self] in
            self?.trackedCameraPoint = nil
            self?.trackedPaperPoint = nil
            self?.trackingConfidence = 0
            self?.penTrackingState = .notSeeded
        }
    }

    private func publishObservation(_ observation: PenObservation) {
        let trackingIsLost = consecutiveLostFrames >= 5
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.trackedCameraPoint = observation.cameraPoint
            self.trackedPaperPoint = observation.paperPoint
            self.trackingConfidence = observation.confidence
            if observation.cameraPoint != nil {
                self.penTrackingState = observation.paperPoint == nil ? .outsidePaper : .tracking
            } else if trackingIsLost {
                self.penTrackingState = .lost
            }
            self.onObservation?(observation)
        }
    }

}
