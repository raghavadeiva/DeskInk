import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var document: PDFDocument?
    @Published private(set) var documentName = "No PDF open"
    @Published private(set) var currentPageIndex = 0
    @Published private(set) var strokes: [InkStroke] = []
    @Published private(set) var activeStroke: InkStroke?

    @Published var inputMode: InputMode = .simulator
    @Published var penDownMode: PenDownMode = .automatic
    @Published var inkColor: InkColorChoice = .blue
    @Published var calibrationCorners: [NormalizedPoint] = []
    @Published var cameraInteraction: CameraInteraction = .idle
    @Published private(set) var isSpacePressed = false
    @Published var presentedError: String?
    @Published private(set) var statusMessage = "Open a PDF to begin."

    let camera = CameraController()

    private var spaceKeyMonitor: SpaceKeyMonitor?
    private var automaticPreRoll: [NormalizedPoint] = []

    init() {
        camera.onObservation = { [weak self] observation in
            self?.consume(observation)
        }
        spaceKeyMonitor = SpaceKeyMonitor { [weak self] isPressed in
            let shouldConsume = self?.inputMode == .deskView && self?.penDownMode == .holdSpace
            self?.spaceKeyChanged(isPressed)
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
        finishActiveStroke()
        automaticPreRoll.removeAll()
        inputMode = mode
        cameraInteraction = .idle

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
            statusMessage = "Recorded \(strokes.count) stroke\(strokes.count == 1 ? "" : "s")."
        }
        self.activeStroke = nil
    }

    private func spaceKeyChanged(_ pressed: Bool) {
        isSpacePressed = pressed
        if !pressed, penDownMode == .holdSpace {
            finishActiveStroke()
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
    private let onChange: (Bool) -> Bool

    init(onChange: @escaping (Bool) -> Bool) {
        self.onChange = onChange
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 49 else { return event }
            let shouldConsume: Bool
            if !event.isARepeat {
                shouldConsume = self?.onChange(true) ?? false
            } else {
                shouldConsume = self?.onChange(true) ?? false
            }
            return shouldConsume ? nil : event
        }
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard event.keyCode == 49 else { return event }
            let shouldConsume = self?.onChange(false) ?? false
            return shouldConsume ? nil : event
        }
    }

    deinit {
        if let keyDownMonitor { NSEvent.removeMonitor(keyDownMonitor) }
        if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) }
    }
}
