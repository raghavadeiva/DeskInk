import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

@MainActor
final class SessionReviewPresentation: Identifiable {
    let id = UUID()
    let sessionURL: URL
    let store: SessionReviewStore
    let usesSecurityScope: Bool

    init(sessionURL: URL, usesSecurityScope: Bool) throws {
        self.sessionURL = sessionURL
        self.usesSecurityScope = usesSecurityScope
        store = try SessionReviewStore(sessionURL: sessionURL)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var document: PDFDocument?
    @Published private(set) var documentName = "No PDF open"
    @Published private(set) var currentPageIndex = 0
    @Published private(set) var strokes: [InkStroke] = []
    @Published private(set) var activeStroke: InkStroke?
    @Published private(set) var renderTicket: FrameTraceID?

    @Published var inputMode: InputMode = .simulator
    @Published var penDownMode: PenDownMode = .holdSpace
    @Published var inkColor: InkColorChoice = .blue
    @Published var calibrationCorners: [NormalizedPoint] = []
    @Published var cameraInteraction: CameraInteraction = .idle
    @Published var accuracyPaperFormat: PaperFormat = .letter
    @Published var recordingUserMetadata = SessionUserMetadata()
    @Published private(set) var gridAccuracySession: GridAccuracySession?
    @Published private(set) var gridAccuracyStatus = "Print a grid, calibrate the sheet, then start."
    @Published private(set) var isSessionRecording = false
    @Published private(set) var recordingStatus = "Recording is off."
    @Published private(set) var lastRecordingSummary: SessionRecordingSummary?
    @Published private(set) var sessionReviewPresentation: SessionReviewPresentation?
    @Published private(set) var isSpacePressed = false
    @Published var presentedError: String?
    @Published private(set) var statusMessage = "Open a PDF to begin."

    let latencyMonitor: LatencyMonitor
    let camera: CameraController
    let sessionRecorder: SessionRecorder

    private var spaceKeyMonitor: SpaceKeyMonitor?
    private var automaticPreRoll: [NormalizedPoint] = []
    private var gridCalibrationMetadata = GridCalibrationMetadata()
    private var recordingParentURL: URL?
    private var recordingUsesSecurityScope = false

    init() {
        let latencyMonitor = LatencyMonitor()
        let sessionRecorder = SessionRecorder()
        self.latencyMonitor = latencyMonitor
        self.sessionRecorder = sessionRecorder
        camera = CameraController(
            latencyMonitor: latencyMonitor,
            sessionRecorder: sessionRecorder
        )
        camera.onObservation = { [weak self] observation in
            self?.consume(observation)
        }
        spaceKeyMonitor = SpaceKeyMonitor { [weak self] isPressed, eventTimestamp, hostTimestamp, source in
            let shouldConsume = self?.inputMode == .deskView && self?.penDownMode == .holdSpace
            self?.spaceKeyChanged(
                isPressed,
                eventTimestamp: eventTimestamp,
                hostTimestamp: hostTimestamp,
                source: source
            )
            return shouldConsume
        }
    }

    var pageCount: Int {
        document?.pageCount ?? 0
    }

    var hasDocument: Bool {
        document != nil
    }

    var isCalibrated: Bool {
        calibrationCorners.count == 4
            && PerspectiveTransform.paperTransform(sourceCorners: calibrationCorners) != nil
    }

    var currentPageStrokes: [InkStroke] {
        strokes.filter { $0.pageIndex == currentPageIndex }
    }

    var hasRecordedInk: Bool {
        !strokes.isEmpty || activeStroke != nil
    }

    var isGridAccuracyTestActive: Bool {
        guard let gridAccuracySession else { return false }
        return !gridAccuracySession.isComplete
    }

    func openPDF(at url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let data = try Data(contentsOf: url)
            guard let loadedDocument = PDFDocument(data: data), loadedDocument.pageCount > 0 else {
                throw DeskInkError.invalidPDF
            }

            finishActiveStroke()
            document = loadedDocument
            documentName = url.lastPathComponent
            currentPageIndex = 0
            strokes.removeAll()
            activeStroke = nil
            automaticPreRoll.removeAll()
            statusMessage = inputMode == .simulator
                ? "Drag on the PDF to test vector ink."
                : "Start Desk View, then calibrate the sheet."
        } catch {
            presentedError = "Could not open that PDF. \(error.localizedDescription)"
        }
    }

    func setInputMode(_ mode: InputMode) {
        guard inputMode != mode else { return }
        if mode != .deskView, isSessionRecording {
            stopSessionRecording(reason: "inputModeChanged")
        }
        finishActiveStroke()
        automaticPreRoll.removeAll()
        inputMode = mode
        cameraInteraction = .idle
        if mode != .deskView {
            cancelGridAccuracyTest()
        }

        switch mode {
        case .deskView:
            statusMessage = "Starting Desk View…"
            camera.start()
        case .simulator:
            camera.stop()
            statusMessage = hasDocument
                ? "Simulator ready. Drag on the PDF to draw."
                : "Open a PDF, then drag on it to draw."
        }
    }

    func beginCalibration() {
        cancelGridAccuracyTest()
        finishActiveStroke()
        automaticPreRoll.removeAll()
        calibrationCorners.removeAll()
        camera.clearCalibration()
        camera.clearPenSeed()
        cameraInteraction = .calibrating
        statusMessage = "Click paper corners: top-left, top-right, bottom-right, bottom-left."
    }

    func useDetectedPaper() {
        applyCalibration(camera.suggestedPaperCorners)
    }

    func resetCalibration() {
        cancelGridAccuracyTest()
        finishActiveStroke()
        automaticPreRoll.removeAll()
        calibrationCorners.removeAll()
        camera.clearCalibration()
        camera.clearPenSeed()
        cameraInteraction = .idle
        statusMessage = "Calibration cleared. Detect the page or enter four corners again."
    }

    func beginPenSeed() {
        guard isCalibrated else {
            presentedError = "Calibrate the paper before selecting the pen tip."
            return
        }
        finishActiveStroke()
        automaticPreRoll.removeAll()
        cameraInteraction = .seedingPen
        statusMessage = "Place the pen on the paper and click directly on its visible tip."
    }

    func handleCameraClick(_ point: NormalizedPoint) {
        switch cameraInteraction {
        case .calibrating:
            calibrationCorners.append(point)
            if calibrationCorners.count == 4 {
                applyCalibration(calibrationCorners)
            } else {
                let names = ["top-right", "bottom-right", "bottom-left"]
                statusMessage = "Now click the \(names[calibrationCorners.count - 1]) corner."
            }
        case .seedingPen:
            camera.seedPen(at: point)
            cameraInteraction = .idle
            statusMessage = penDownMode == .automatic
                ? "Tracking. Auto pen-down is experimental; large jumps split strokes."
                : "Tracking. Hold Space whenever the pen touches the paper."
        case .idle:
            break
        }
    }

    func moveToPreviousPage() {
        guard currentPageIndex > 0 else { return }
        finishActiveStroke()
        automaticPreRoll.removeAll()
        currentPageIndex -= 1
    }

    func moveToNextPage() {
        guard currentPageIndex + 1 < pageCount else { return }
        finishActiveStroke()
        automaticPreRoll.removeAll()
        currentPageIndex += 1
    }

    func commitSimulatorStroke(_ points: [NormalizedPoint]) {
        guard inputMode == .simulator, hasDocument else { return }
        let cleaned = deduplicated(points)
        guard !cleaned.isEmpty else { return }
        strokes.append(
            InkStroke(
                pageIndex: currentPageIndex,
                points: cleaned,
                color: inkColor
            )
        )
        statusMessage = "Stroke added. Export preserves it as vector PDF ink."
    }

    func undo() {
        finishActiveStroke()
        guard let index = strokes.lastIndex(where: { $0.pageIndex == currentPageIndex }) else {
            return
        }
        strokes.remove(at: index)
        statusMessage = "Removed the last stroke on this page."
    }

    func clearCurrentPage() {
        finishActiveStroke()
        strokes.removeAll { $0.pageIndex == currentPageIndex }
        statusMessage = "Cleared ink from page \(currentPageIndex + 1)."
    }

    func exportPDF() {
        finishActiveStroke()
        guard let document else {
            presentedError = "Open a PDF before exporting."
            return
        }

        guard !strokes.isEmpty else {
            presentedError = "No ink has been recorded yet. Draw in Simulator, or make sure Desk View says “Tracking on paper” and “Ink down” before exporting."
            return
        }

        guard let exported = PDFExporter.annotatedCopy(of: document, strokes: strokes) else {
            presentedError = "The PDF could not be prepared for export."
            return
        }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = suggestedExportName
        savePanel.title = "Export Annotated PDF"

        savePanel.begin { [weak self] response in
            guard response == .OK, let destination = savePanel.url else { return }
            do {
                guard exported.write(to: destination) else {
                    throw DeskInkError.exportFailed
                }
                Task { @MainActor in
                    self?.statusMessage = "Exported \(destination.lastPathComponent)."
                }
            } catch {
                Task { @MainActor in
                    self?.presentedError = "The annotated PDF could not be saved. \(error.localizedDescription)"
                }
            }
        }
    }

    func generateAccuracyGrid(_ format: PaperFormat) {
        do {
            let data = try GridTestPDFGenerator.makePDF(format: format)
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.pdf]
            savePanel.canCreateDirectories = true
            savePanel.nameFieldStringValue = "DeskInk-Accuracy-Grid-\(format.displayName).pdf"
            savePanel.title = "Save Printable Accuracy Grid"
            savePanel.begin { [weak self] response in
                guard response == .OK, let destination = savePanel.url else { return }
                do {
                    try data.write(to: destination, options: .atomic)
                    Task { @MainActor in
                        self?.statusMessage = "Saved \(format.displayName) accuracy grid. Print at 100% / Actual Size."
                    }
                } catch {
                    Task { @MainActor in
                        self?.presentedError = "The accuracy grid could not be saved. \(error.localizedDescription)"
                    }
                }
            }
        } catch {
            presentedError = "The accuracy grid could not be generated. \(error.localizedDescription)"
        }
    }

    func startGridAccuracyTest() {
        guard inputMode == .deskView else {
            presentedError = "Switch to Desk View before starting the grid accuracy test."
            return
        }
        guard isCalibrated else {
            presentedError = "Calibrate the printed grid sheet before starting the test."
            return
        }
        guard camera.penTrackingState == .tracking else {
            presentedError = "Select the pen tip and wait for Tracking on paper before starting the test."
            return
        }

        finishActiveStroke()
        penDownMode = .holdSpace
        gridAccuracySession = GridAccuracySession(paperFormat: accuracyPaperFormat)
        let transform = PerspectiveTransform.paperTransform(sourceCorners: calibrationCorners)
        gridCalibrationMetadata = GridCalibrationMetadata(
            calibrationTimestamp: Date(),
            cameraCorners: calibrationCorners,
            homography: transform?.rowMajorValues ?? [],
            additionalFields: [
                "camera_name": camera.captureDescriptor?.localizedName ?? "unknown",
                "capture_format": camera.captureDescriptor.map { "\($0.width)x\($0.height) @ \($0.targetFrameRate) fps" } ?? "unknown"
            ]
        )
        gridAccuracyStatus = "Touch cross 1 and hold Space for one second."
        statusMessage = "Accuracy test active—normal PDF ink is paused."
    }

    func cancelGridAccuracyTest() {
        guard gridAccuracySession != nil else { return }
        gridAccuracySession = nil
        gridAccuracyStatus = "Test cancelled. Recalibrate before the next run."
        statusMessage = hasDocument ? "Grid test cancelled. PDF ink is active again." : "Grid test cancelled."
    }

    func exportGridAccuracyCSV() {
        guard let session = gridAccuracySession, !session.measurements.isEmpty else {
            presentedError = "Record at least one grid point before exporting results."
            return
        }
        let data = GridAccuracyCSVExporter.data(
            paperFormat: session.paperFormat,
            measurements: session.measurements,
            calibration: gridCalibrationMetadata
        )
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.commaSeparatedText]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = "DeskInk-Accuracy-\(session.paperFormat.displayName).csv"
        savePanel.title = "Export Grid Accuracy Results"
        savePanel.begin { [weak self] response in
            guard response == .OK, let destination = savePanel.url else { return }
            do {
                try data.write(to: destination, options: .atomic)
                Task { @MainActor in
                    self?.statusMessage = "Exported grid accuracy results."
                }
            } catch {
                Task { @MainActor in
                    self?.presentedError = "The grid accuracy CSV could not be saved. \(error.localizedDescription)"
                }
            }
        }
    }

    func setSessionRecordingEnabled(_ enabled: Bool) {
        if enabled {
            chooseRecordingFolderAndStart()
        } else {
            stopSessionRecording(reason: "userStopped")
        }
    }

    private func chooseRecordingFolderAndStart() {
        guard !isSessionRecording else { return }
        guard inputMode == .deskView else {
            presentedError = "Switch to Desk View before recording a camera session."
            return
        }
        guard let captureDescriptor = camera.captureDescriptor else {
            presentedError = "Wait until Desk View is live before starting a recording."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Choose a Folder for the Local Recording"
        panel.prompt = "Start Recording"
        panel.message = "DeskInk will create one local .deskink-session folder here. Nothing is uploaded."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let parentURL = panel.url else { return }
            Task { @MainActor in
                self?.startSessionRecording(in: parentURL, captureDescriptor: captureDescriptor)
            }
        }
    }

    private func startSessionRecording(
        in parentURL: URL,
        captureDescriptor: CaptureDeviceDescriptor
    ) {
        let accessed = parentURL.startAccessingSecurityScopedResource()
        do {
            let metadata = SessionRecorderMetadata(
                appVersion: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "development",
                gitHash: Bundle.main.object(forInfoDictionaryKey: "DeskInkGitCommit") as? String
                    ?? "unknown",
                captureDevice: captureDescriptor,
                user: recordingUserMetadata
            )
            let sessionURL = try sessionRecorder.start(in: parentURL, metadata: metadata)
            recordingParentURL = parentURL
            recordingUsesSecurityScope = accessed
            isSessionRecording = true
            lastRecordingSummary = nil
            recordingStatus = "Recording locally to \(sessionURL.lastPathComponent)."
            statusMessage = "Session recording started."
        } catch {
            if accessed {
                parentURL.stopAccessingSecurityScopedResource()
            }
            presentedError = "The session recording could not start. \(error.localizedDescription)"
        }
    }

    func stopSessionRecording(reason: String = "userStopped") {
        guard isSessionRecording || sessionRecorder.isRecording else { return }
        finishActiveStroke()
        defer {
            if recordingUsesSecurityScope {
                recordingParentURL?.stopAccessingSecurityScopedResource()
            }
            recordingParentURL = nil
            recordingUsesSecurityScope = false
            isSessionRecording = false
        }

        do {
            let summary = try sessionRecorder.stop(reason: reason)
            lastRecordingSummary = summary
            recordingStatus = "Saved \(summary.frameCount) frames to \(summary.sessionURL.lastPathComponent)."
            statusMessage = "Session recording saved locally."
        } catch {
            recordingStatus = "Recording stopped with an error."
            presentedError = "The session recording could not be finalized. \(error.localizedDescription)"
        }
    }

    func chooseSessionForReview() {
        let panel = NSOpenPanel()
        panel.title = "Choose a DeskInk Session"
        panel.prompt = "Review Session"
        panel.message = "Choose a .deskink-session folder. Corrections are appended to a separate local file."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let sessionURL = panel.url else { return }
            Task { @MainActor in
                let accessed = sessionURL.startAccessingSecurityScopedResource()
                do {
                    self?.sessionReviewPresentation = try SessionReviewPresentation(
                        sessionURL: sessionURL,
                        usesSecurityScope: accessed
                    )
                } catch {
                    if accessed {
                        sessionURL.stopAccessingSecurityScopedResource()
                    }
                    self?.presentedError = "That session could not be opened. \(error.localizedDescription)"
                }
            }
        }
    }

    func closeSessionReview() {
        guard let presentation = sessionReviewPresentation else { return }
        if presentation.usesSecurityScope {
            presentation.sessionURL.stopAccessingSecurityScopedResource()
        }
        sessionReviewPresentation = nil
    }

    private var suggestedExportName: String {
        let base = (documentName as NSString).deletingPathExtension
        return base.isEmpty ? "Annotated.pdf" : "\(base)-annotated.pdf"
    }

    private func applyCalibration(_ points: [NormalizedPoint]) {
        guard points.count == 4,
              PerspectiveTransform.paperTransform(sourceCorners: points) != nil else {
            calibrationCorners.removeAll()
            camera.clearCalibration()
            cameraInteraction = .calibrating
            presentedError = "Those points do not form a valid paper rectangle. Try again in clockwise order."
            statusMessage = "Click paper corners: top-left, top-right, bottom-right, bottom-left."
            return
        }

        calibrationCorners = points
        camera.setCalibration(points)
        cameraInteraction = .idle
        statusMessage = "Paper calibrated. Next, click Select Pen Tip."
    }

    private func consume(_ observation: PenObservation) {
        let visiblePointCountBefore = currentVisibleInkPointCount
        defer {
            let acceptedForInk = currentVisibleInkPointCount > visiblePointCountBefore
            sessionRecorder.finalizeFrame(
                SessionFrameDecision(
                    traceID: observation.traceID,
                    decisionHostTimestamp: LatencyMonitor.hostTimestampNow(),
                    inferredPenDown: observation.inferredDown,
                    acceptedForInk: acceptedForInk,
                    activeStrokeID: activeStroke?.id
                )
            )
            if acceptedForInk {
                renderTicket = observation.traceID
            } else {
                latencyMonitor.markNotRendered(traceID: observation.traceID)
            }
        }
        if var gridSession = gridAccuracySession, !gridSession.isComplete {
            if let point = observation.rawPaperPoint {
                let reduction = gridSession.reduce(
                    .mappedPoint(point, timestamp: LatencyMonitor.hostTimestampNow())
                )
                gridAccuracySession = gridSession
                handleGridAccuracyReduction(reduction)
            }
            return
        }

        guard inputMode == .deskView, hasDocument else { return }

        guard let point = observation.paperPoint else {
            finishActiveStroke()
            automaticPreRoll.removeAll()
            return
        }

        let shouldInk: Bool
        if penDownMode == .automatic {
            shouldInk = observation.inferredDown
            if !shouldInk {
                finishActiveStroke()
                automaticPreRoll = [point]
                return
            }
        } else {
            shouldInk = isSpacePressed
            automaticPreRoll.removeAll()
            if !shouldInk {
                finishActiveStroke()
                return
            }
        }

        if activeStroke == nil {
            let startingPoints: [NormalizedPoint]
            if penDownMode == .automatic {
                startingPoints = deduplicated(automaticPreRoll + [point])
                automaticPreRoll.removeAll()
            } else {
                startingPoints = [point]
            }
            activeStroke = InkStroke(
                pageIndex: currentPageIndex,
                points: startingPoints,
                color: inkColor
            )
            recordActiveStrokeBoundary(.began)
            statusMessage = "Ink down—recording on page \(currentPageIndex + 1)."
            return
        }

        guard activeStroke?.pageIndex == currentPageIndex else {
            finishActiveStroke()
            activeStroke = InkStroke(
                pageIndex: currentPageIndex,
                points: [point],
                color: inkColor
            )
            recordActiveStrokeBoundary(.began)
            return
        }

        guard let last = activeStroke?.points.last,
              last.distance(to: point) >= 0.0007 else {
            return
        }
        activeStroke?.points.append(point)
    }

    private func finishActiveStroke() {
        guard let activeStroke else { return }
        if !activeStroke.points.isEmpty {
            strokes.append(activeStroke)
            sessionRecorder.recordStrokeBoundary(
                .ended,
                strokeID: activeStroke.id,
                pageIndex: activeStroke.pageIndex,
                hostTimestamp: LatencyMonitor.hostTimestampNow()
            )
            statusMessage = "Recorded \(strokes.count) stroke\(strokes.count == 1 ? "" : "s")."
        }
        self.activeStroke = nil
    }

    private func recordActiveStrokeBoundary(_ boundary: SessionStrokeBoundary) {
        guard let activeStroke else { return }
        sessionRecorder.recordStrokeBoundary(
            boundary,
            strokeID: activeStroke.id,
            pageIndex: activeStroke.pageIndex,
            hostTimestamp: LatencyMonitor.hostTimestampNow()
        )
    }

    private func spaceKeyChanged(
        _ pressed: Bool,
        eventTimestamp: TimeInterval,
        hostTimestamp: TimeInterval,
        source: SpaceKeyEventSource
    ) {
        isSpacePressed = pressed
        sessionRecorder.recordSpaceState(
            isDown: pressed,
            eventTimestamp: eventTimestamp,
            hostTimestamp: hostTimestamp,
            source: source
        )
        if var gridSession = gridAccuracySession, !gridSession.isComplete {
            let reduction = gridSession.reduce(
                pressed ? .spaceDown(timestamp: hostTimestamp) : .spaceUp(timestamp: hostTimestamp)
            )
            gridAccuracySession = gridSession
            handleGridAccuracyReduction(reduction)
        }
        if !pressed, penDownMode == .holdSpace {
            finishActiveStroke()
        }
    }

    private func handleGridAccuracyReduction(_ reduction: GridAccuracyReduction) {
        switch reduction {
        case .ignored:
            break
        case let .holdStarted(targetIndex):
            gridAccuracyStatus = "Holding on cross \(targetIndex + 1)…"
        case let .holdProgress(elapsed, sampleCount):
            gridAccuracyStatus = String(
                format: "Hold still… %.1f s · %d samples",
                min(elapsed, GridAccuracySession.minimumHoldDuration),
                sampleCount
            )
        case let .measurementRecorded(measurement):
            gridAccuracyStatus = "Captured cross \(measurement.target.index + 1). Release Space."
        case .attemptCancelled:
            let targetNumber = (gridAccuracySession?.currentTarget?.index ?? 0) + 1
            gridAccuracyStatus = "Hold was too short. Retry cross \(targetNumber)."
        case let .readyForTarget(target):
            gridAccuracyStatus = "Touch cross \(target.index + 1) and hold Space for one second."
        case .completed:
            guard let statistics = gridAccuracySession?.statistics,
                  let mean = statistics.meanErrorMM,
                  let p95 = statistics.p95ErrorMM,
                  let maximum = statistics.maxErrorMM else {
                gridAccuracyStatus = "Accuracy test complete."
                return
            }
            gridAccuracyStatus = String(
                format: "Complete — mean %.2f mm · p95 %.2f mm · max %.2f mm",
                mean,
                p95,
                maximum
            )
            statusMessage = "Accuracy test complete. Export the CSV before recalibrating."
        }
    }

    private func deduplicated(_ points: [NormalizedPoint]) -> [NormalizedPoint] {
        var result: [NormalizedPoint] = []
        for point in points where point.isFinite {
            if let last = result.last, last.distance(to: point) < 0.0007 {
                continue
            }
            result.append(point)
        }
        return result
    }

    private var currentVisibleInkPointCount: Int {
        let committed = currentPageStrokes.reduce(into: 0) { count, stroke in
            count += stroke.points.count
        }
        let active = activeStroke?.pageIndex == currentPageIndex ? activeStroke?.points.count ?? 0 : 0
        return committed + active
    }
}

private enum DeskInkError: LocalizedError {
    case invalidPDF
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .invalidPDF:
            return "The file does not contain a readable PDF page."
        case .exportFailed:
            return "PDFKit reported that the write failed."
        }
    }
}

@MainActor
private final class SpaceKeyMonitor {
    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var transitionState = SpaceKeyTransitionState()
    private var consumesSpace = false
    private let onChange: (Bool, TimeInterval, TimeInterval, SpaceKeyEventSource) -> Bool

    init(onChange: @escaping (Bool, TimeInterval, TimeInterval, SpaceKeyEventSource) -> Bool) {
        self.onChange = onChange
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 49 else { return event }
            guard let self else { return event }
            guard self.transitionState.keyDown(isRepeat: event.isARepeat) else {
                return self.consumesSpace ? nil : event
            }
            let shouldConsume = self.onChange(
                true,
                event.timestamp,
                LatencyMonitor.hostTimestampNow(),
                .keyDown
            )
            self.consumesSpace = shouldConsume
            return shouldConsume ? nil : event
        }
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard event.keyCode == 49 else { return event }
            guard let self else { return event }
            guard self.transitionState.keyUp() else {
                return self.consumesSpace ? nil : event
            }
            let shouldConsume = self.onChange(
                false,
                event.timestamp,
                LatencyMonitor.hostTimestampNow(),
                .keyUp
            )
            self.consumesSpace = false
            return shouldConsume ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.transitionState.resetForFocusLoss() else { return }
                self.consumesSpace = false
                let hostTimestamp = LatencyMonitor.hostTimestampNow()
                _ = self.onChange(false, hostTimestamp, hostTimestamp, .focusLossReset)
            }
        }
    }

    deinit {
        if let keyDownMonitor { NSEvent.removeMonitor(keyDownMonitor) }
        if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}
