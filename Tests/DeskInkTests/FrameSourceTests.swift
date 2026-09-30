import AVFoundation
import Testing
@testable import DeskInk

@Suite("Frame source abstraction")
struct FrameSourceTests {
    @Test("Camera controller delegates lifecycle to an injected frame source")
    func injectedLifecycle() {
        let source = StubFrameSource()
        let controller = CameraController(frameSource: source)

        #expect(controller.session === source.session)
        controller.start()
        controller.retry()
        controller.stop()

        #expect(source.startCount == 1)
        #expect(source.retryCount == 1)
        #expect(source.stopCount == 1)
        #expect(source.frameQueueOperationCount == 1)
    }
}

private final class StubFrameSource: FrameSource {
    let session = AVCaptureSession()
    var onFrame: ((CapturedVideoFrame) -> Void)?
    var onFrameDrop: (() -> Void)?
    var onStateChange: ((CameraRunState) -> Void)?
    var onConfigurationChange: ((CaptureDeviceDescriptor) -> Void)?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var retryCount = 0
    private(set) var frameQueueOperationCount = 0

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func retry() {
        retryCount += 1
    }

    func performOnFrameQueue(_ operation: @escaping () -> Void) {
        frameQueueOperationCount += 1
        operation()
    }
}
