import AVFoundation
import CoreMedia
import Foundation
import OSLog

enum CameraRunState: Equatable {
    case idle
    case requestingPermission
    case starting
    case running(deviceName: String)
    case unavailable(message: String)
    case denied

    var shortLabel: String {
        switch self {
        case .idle: return "Off"
        case .requestingPermission: return "Waiting for permission"
        case .starting: return "Starting"
        case .running: return "Live"
        case .unavailable: return "Unavailable"
        case .denied: return "Permission denied"
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
            return "Receiving frames from \(deviceName)."
        case let .unavailable(message):
            return message
        case .denied:
            return "Enable Camera for DeskInk in System Settings → Privacy & Security."
        }
    }
}

struct CaptureDeviceDescriptor: Codable, Equatable, Sendable {
    let localizedName: String
    let modelID: String
    let uniqueID: String
    let width: Int
    let height: Int
    let targetFrameRate: Double
    let maximumFrameRate: Double

    var aspectRatio: Double {
        guard height > 0 else { return 4.0 / 3.0 }
        return Double(width) / Double(height)
    }
}

struct CapturedVideoFrame {
    let traceID: FrameTraceID
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
    let presentationHostTimestamp: TimeInterval?
    let clockRelation: CaptureClockRelation
    let callbackHostTimestamp: TimeInterval
}

/// Abstracts live AVFoundation capture so tracking and estimators can later be
/// driven by deterministic synthetic or recorded frame sources in tests.
protocol FrameSource: AnyObject {
    var session: AVCaptureSession { get }
    var onFrame: ((CapturedVideoFrame) -> Void)? { get set }
    var onFrameDrop: (() -> Void)? { get set }
    var onStateChange: ((CameraRunState) -> Void)? { get set }
    var onConfigurationChange: ((CaptureDeviceDescriptor) -> Void)? { get set }

    func start()
    func stop()
    func retry()
    func performOnFrameQueue(_ operation: @escaping () -> Void)
}

final class AVCaptureFrameSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()

    var onFrame: ((CapturedVideoFrame) -> Void)?
    var onFrameDrop: (() -> Void)?
    var onStateChange: ((CameraRunState) -> Void)?
    var onConfigurationChange: ((CaptureDeviceDescriptor) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.example.DeskInk.capture.session")
    private let videoQueue = DispatchQueue(label: "com.example.DeskInk.capture.frames")
    private let output = AVCaptureVideoDataOutput()
    private let logger = Logger(subsystem: "com.example.DeskInk", category: "Camera")
    private var configured = false
    private var frameIndex = 0
    private var captureSessionID = UUID()

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

    func performOnFrameQueue(_ operation: @escaping () -> Void) {
        videoQueue.async(execute: operation)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameIndex += 1
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let clockMapping = mappedPresentationTimeToHost(presentationTime)
        onFrame?(
            CapturedVideoFrame(
                traceID: FrameTraceID(captureSessionID: captureSessionID, frameIndex: frameIndex),
                pixelBuffer: pixelBuffer,
                presentationTime: presentationTime,
                presentationHostTimestamp: clockMapping.timestamp,
                clockRelation: clockMapping.relation,
                callbackHostTimestamp: Self.hostTimestamp()
            )
        )
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onFrameDrop?()
    }

    private func configureAndStart() {
        publishState(.starting)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.captureSessionID = UUID()
            self.frameIndex = 0

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
            self.logDiscoveredDevice(device)

            do {
                let input = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration()

                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    self.publishState(.unavailable(message: "Desk View is present, but AVFoundation could not add it to the capture session."))
                    return
                }
                self.session.addInput(input)

                let selection: CaptureFormatSelection
                do {
                    selection = try self.selectCaptureFormat(for: device)
                } catch {
                    self.session.commitConfiguration()
                    throw error
                }

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

                let descriptor = CaptureDeviceDescriptor(
                    localizedName: device.localizedName,
                    modelID: device.modelID,
                    uniqueID: device.uniqueID,
                    width: Int(selection.dimensions.width),
                    height: Int(selection.dimensions.height),
                    targetFrameRate: selection.targetFrameRate,
                    maximumFrameRate: selection.maximumFrameRate
                )
                self.publishConfiguration(descriptor)
                self.session.startRunning()
                self.publishState(.running(deviceName: device.localizedName))
            } catch {
                self.publishState(.unavailable(message: "Desk View could not start: \(error.localizedDescription)"))
            }
        }
    }

    private func logDiscoveredDevice(_ device: AVCaptureDevice) {
        logger.info("Discovered camera name=\(device.localizedName, privacy: .public) modelID=\(device.modelID, privacy: .public) uniqueID=\(device.uniqueID, privacy: .public)")
        for (index, format) in device.formats.enumerated() {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let maximumFrameRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            logger.info("Available format[\(index)] \(dimensions.width)x\(dimensions.height) maxFPS=\(maximumFrameRate, format: .fixed(precision: 2))")
        }
    }

    private func selectCaptureFormat(for device: AVCaptureDevice) throws -> CaptureFormatSelection {
        let candidates = device.formats.compactMap { format -> CaptureFormatSelection? in
            let eligibleRanges = format.videoSupportedFrameRateRanges.filter { $0.maxFrameRate >= 30 }
            guard !eligibleRanges.isEmpty else { return nil }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let maximumFrameRate = eligibleRanges.map(\.maxFrameRate).max() ?? 0
            if eligibleRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                return CaptureFormatSelection(
                    format: format,
                    dimensions: dimensions,
                    maximumFrameRate: maximumFrameRate,
                    targetFrameRate: 30,
                    targetDuration: CMTime(value: 1, timescale: 30)
                )
            }
            guard let slowestRange = eligibleRanges.min(by: { $0.minFrameRate < $1.minFrameRate }) else {
                return nil
            }
            return CaptureFormatSelection(
                format: format,
                dimensions: dimensions,
                maximumFrameRate: maximumFrameRate,
                targetFrameRate: slowestRange.minFrameRate,
                targetDuration: slowestRange.maxFrameDuration
            )
        }

        guard let selection = candidates.max(by: { lhs, rhs in
            let lhsPixels = Double(lhs.dimensions.width) * Double(lhs.dimensions.height)
            let rhsPixels = Double(rhs.dimensions.width) * Double(rhs.dimensions.height)
            if lhsPixels != rhsPixels { return lhsPixels < rhsPixels }
            return lhs.maximumFrameRate < rhs.maximumFrameRate
        }) else {
            throw FrameSourceError.noThirtyFPSFormat
        }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = selection.format
        device.activeVideoMinFrameDuration = selection.targetDuration
        device.activeVideoMaxFrameDuration = selection.targetDuration
        logger.info("Selected format \(selection.dimensions.width)x\(selection.dimensions.height) targetFPS=\(selection.targetFrameRate, format: .fixed(precision: 2)) maxFPS=\(selection.maximumFrameRate, format: .fixed(precision: 2))")
        return selection
    }

    private func publishState(_ state: CameraRunState) {
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) }
    }

    private func publishConfiguration(_ descriptor: CaptureDeviceDescriptor) {
        DispatchQueue.main.async { [weak self] in self?.onConfigurationChange?(descriptor) }
    }

    private static func hostTimestamp() -> TimeInterval {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    private func mappedPresentationTimeToHost(_ presentationTime: CMTime) -> (
        timestamp: TimeInterval?,
        relation: CaptureClockRelation
    ) {
        guard presentationTime.isValid, presentationTime.isNumeric else {
            return (nil, .invalid)
        }
        guard let synchronizationClock = session.synchronizationClock else {
            return (nil, .unverified)
        }
        let hostClock = CMClockGetHostTimeClock()
        if CFEqual(synchronizationClock, hostClock) {
            return (presentationTime.seconds, .hostClock)
        }
        let converted = CMSyncConvertTime(presentationTime, from: synchronizationClock, to: hostClock)
        guard converted.isValid, converted.isNumeric else {
            return (nil, .invalid)
        }
        return (
            converted.seconds,
            .convertedToHost(mightDrift: CMSyncMightDrift(synchronizationClock, hostClock))
        )
    }
}

private struct CaptureFormatSelection {
    let format: AVCaptureDevice.Format
    let dimensions: CMVideoDimensions
    let maximumFrameRate: Double
    let targetFrameRate: Double
    let targetDuration: CMTime
}

private enum FrameSourceError: LocalizedError {
    case noThirtyFPSFormat

    var errorDescription: String? {
        switch self {
        case .noThirtyFPSFormat:
            return "The Desk View camera did not report a video format capable of 30 frames per second."
        }
    }
}
