import AVFoundation
import CoreMedia
import Foundation
import Vision

enum CameraRunState: Equatable {
    case idle
    case requestingPermission
    case starting
    case running(deviceName: String)
    case unavailable(message: String)
    case denied

    var shortLabel: String {
        switch self {
        case .idle:
            return "Off"
        case .requestingPermission:
            return "Waiting for permission"
        case .starting:
            return "Starting"
        case .running:
            return "Live"
        case .unavailable:
            return "Unavailable"
        case .denied:
            return "Permission denied"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            return "Choose Desk View to start the camera."
        case .requestingPermission:
            return "Approve camera access in the macOS prompt."
        case .starting:
            return "Looking for Apple's Desk View camera device…"
        case let .running(deviceName):
            return "Receiving \(deviceName) at up to 30 frames per second."
        case let .unavailable(message):
            return message
        case .denied:
            return "Enable Camera for DeskInk in System Settings → Privacy & Security."
        }
    }
}

final class CameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()

    @Published private(set) var state: CameraRunState = .idle
    @Published private(set) var suggestedPaperCorners: [NormalizedPoint] = []
    @Published private(set) var trackedCameraPoint: NormalizedPoint?
    @Published private(set) var trackedPaperPoint: NormalizedPoint?
    @Published private(set) var trackingConfidence = 0.0
    @Published private(set) var penTrackingState: PenTrackingState = .notSeeded

    var onObservation: ((PenObservation) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.example.DeskInk.capture.session")
    private let videoQueue = DispatchQueue(label: "com.example.DeskInk.capture.frames")
    private let output = AVCaptureVideoDataOutput()

    private var sequenceHandler = VNSequenceRequestHandler()
    private var trackedObject: VNDetectedObjectObservation?
    private var pendingSeedPoint: NormalizedPoint?
    private var paperTransform: PerspectiveTransform?
    private var contactState = PenContactStateMachine()
    private var smoothedCameraPoint: NormalizedPoint?
    private var frameNumber = 0
    private var consecutiveLostFrames = 0
    private var configured = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            publishState(.requestingPermission)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                guard let self else { return }
                if allowed {
                    self.configureAndStart()
                } else {
                    self.publishState(.denied)
                }
            }
        case .denied, .restricted:
            publishState(.denied)
        @unknown default:
            publishState(.unavailable(message: "macOS returned an unknown camera authorization state."))
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.videoQueue.async {
                self.resetTrackingState()
            }
            self.publishState(.idle)
        }
    }

    func retry() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.configured = false
            self.session.beginConfiguration()
            self.session.inputs.forEach(self.session.removeInput)
            self.session.outputs.forEach(self.session.removeOutput)
            self.session.commitConfiguration()
            self.configureAndStart()
        }
    }

    func setCalibration(_ corners: [NormalizedPoint]) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.paperTransform = PerspectiveTransform.paperTransform(sourceCorners: corners)
            self.contactState.reset()
        }
    }

    func clearCalibration() {
        videoQueue.async { [weak self] in
            self?.paperTransform = nil
            self?.contactState.reset()
        }
    }

    func seedPen(at cameraPoint: NormalizedPoint) {
        videoQueue.async { [weak self] in
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
        videoQueue.async { [weak self] in
            self?.resetTrackingState()
        }
    }

    private func configureAndStart() {
        publishState(.starting)
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if self.configured {
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                if let device = (self.session.inputs.first as? AVCaptureDeviceInput)?.device {
                    self.publishState(.running(deviceName: device.localizedName))
                }
                return
            }

            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.deskViewCamera],
                mediaType: .video,
                position: .unspecified
            )

            guard let device = discovery.devices.first else {
                self.publishState(.unavailable(
                    message: "No Desk View device is currently available. Connect a supported iPhone or use a supported built-in Mac camera, then retry—or switch to Simulator."
                ))
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration()
                self.session.sessionPreset = .high

                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    self.publishState(.unavailable(message: "Desk View is present, but AVFoundation could not add it to the capture session."))
                    return
                }
                self.session.addInput(input)

                self.output.alwaysDiscardsLateVideoFrames = true
                self.output.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                self.output.setSampleBufferDelegate(self, queue: self.videoQueue)

                guard self.session.canAddOutput(self.output) else {
                    self.session.commitConfiguration()
                    self.publishState(.unavailable(message: "Desk View is present, but its video frames could not be opened."))
                    return
                }
                self.session.addOutput(self.output)
                self.session.commitConfiguration()
                self.configured = true
                self.session.startRunning()
                self.publishState(.running(deviceName: device.localizedName))
            } catch {
                self.publishState(.unavailable(message: "Desk View could not start: \(error.localizedDescription)"))
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        frameNumber += 1
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

        if paperTransform == nil, frameNumber.isMultiple(of: 15) {
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
            publishObservation(
                PenObservation(
                    cameraPoint: nil,
                    paperPoint: nil,
                    confidence: 0,
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
                handleWeakTracking(result: request.results?.first as? VNDetectedObjectObservation, timestamp: timestamp)
                return
            }

            self.trackedObject = result
            consecutiveLostFrames = 0
            let rawPoint = NormalizedPoint(
                x: result.boundingBox.midX,
                y: 1 - result.boundingBox.midY
            )
            let filteredPoint = smooth(rawPoint)
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

            publishObservation(
                PenObservation(
                    cameraPoint: filteredPoint,
                    paperPoint: pointOnPaper,
                    confidence: confidence,
                    inferredDown: isDown,
                    timestamp: timestamp
                )
            )
        } catch {
            handleWeakTracking(result: nil, timestamp: timestamp)
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

    private func handleWeakTracking(result: VNDetectedObjectObservation?, timestamp: TimeInterval) {
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
        publishObservation(
            PenObservation(
                cameraPoint: nil,
                paperPoint: nil,
                confidence: 0,
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

    private func publishState(_ newState: CameraRunState) {
        DispatchQueue.main.async { [weak self] in
            self?.state = newState
        }
    }
}
