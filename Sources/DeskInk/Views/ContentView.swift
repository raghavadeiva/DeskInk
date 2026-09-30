import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isImporting = false

    var body: some View {
        VStack(spacing: 0) {
            workspaceToolbar
            Divider()

            HSplitView {
                pdfWorkspace
                    .frame(minWidth: 620)

                SetupSidebar(model: model)
                    .frame(minWidth: 340, idealWidth: 380, maxWidth: 430)
            }

            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                if let url = urls.first {
                    model.openPDF(at: url)
                }
            case let .failure(error):
                model.presentedError = "The PDF picker failed: \(error.localizedDescription)"
            }
        }
        .alert(
            "DeskInk",
            isPresented: Binding(
                get: { model.presentedError != nil },
                set: { if !$0 { model.presentedError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                model.presentedError = nil
            }
        } message: {
            Text(model.presentedError ?? "Unknown error")
        }
    }

    private var workspaceToolbar: some View {
        HStack(spacing: 12) {
            Button {
                isImporting = true
            } label: {
                Label("Open PDF", systemImage: "doc.badge.plus")
            }
            .keyboardShortcut("o", modifiers: .command)
            .accessibilityHint("Choose the PDF that will receive handwriting")

            Divider()
                .frame(height: 22)

            Button {
                model.moveToPreviousPage()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(model.currentPageIndex == 0)
            .accessibilityLabel("Previous PDF page")

            Text(model.pageCount == 0
                 ? "No page"
                 : "Page \(model.currentPageIndex + 1) of \(model.pageCount)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 92)

            Button {
                model.moveToNextPage()
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(model.currentPageIndex + 1 >= model.pageCount)
            .accessibilityLabel("Next PDF page")

            Spacer()

            Text(inkCountLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(model.hasRecordedInk ? .secondary : .tertiary)

            Picker("Ink", selection: $model.inkColor) {
                ForEach(InkColorChoice.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 105)

            Button {
                model.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(model.currentPageStrokes.isEmpty && model.activeStroke == nil)

            Button(role: .destructive) {
                model.clearCurrentPage()
            } label: {
                Label("Clear Page", systemImage: "eraser")
            }
            .disabled(model.currentPageStrokes.isEmpty && model.activeStroke == nil)

            Button {
                model.exportPDF()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .buttonStyle(.borderedProminent)
            .disabled(!model.hasDocument)
        }
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .frame(height: 54)
    }

    private var pdfWorkspace: some View {
        ZStack {
            PDFCanvasRepresentable(
                document: model.document,
                pageIndex: model.currentPageIndex,
                strokes: model.currentPageStrokes,
                activeStroke: model.activeStroke,
                isSimulatorEnabled: model.inputMode == .simulator,
                currentInkColor: model.inkColor,
                onCompletedStroke: model.commitSimulatorStroke
            )

            if !model.hasDocument {
                VStack(spacing: 14) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 42, weight: .regular))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Open a PDF")
                        .font(.title2.weight(.semibold))
                    Text("DeskInk keeps the original pages intact and adds vector ink on export.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    Button("Choose PDF…") {
                        isImporting = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(32)
            } else if model.inputMode == .simulator {
                VStack {
                    HStack {
                        Label("Simulator: drag anywhere on the page to write", systemImage: "cursorarrow.motionlines")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                        Spacer()
                    }
                    Spacer()
                }
                .padding(18)
                .allowsHitTesting(false)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text(model.documentName)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    private var statusIcon: String {
        switch model.inputMode {
        case .deskView: return "camera.viewfinder"
        case .simulator: return "cursorarrow"
        }
    }

    private var inkCountLabel: String {
        let count = model.strokes.count + (model.activeStroke == nil ? 0 : 1)
        return "\(count) stroke\(count == 1 ? "" : "s")"
    }
}

private struct SetupSidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var camera: CameraController

    init(model: AppModel) {
        self.model = model
        camera = model.camera
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sourceSection

                if model.inputMode == .deskView {
                    cameraPreview
                    calibrationSection
                    trackingSection
                } else {
                    simulatorSection
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var sourceSection: some View {
        GroupBox("Input") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Input source", selection: Binding(
                    get: { model.inputMode },
                    set: { model.setInputMode($0) }
                )) {
                    ForEach(InputMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if model.inputMode == .deskView {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(cameraStateColor)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(camera.state.shortLabel)
                            .font(.callout.weight(.medium))
                    }
                    Text(camera.state.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if case .unavailable = camera.state {
                        HStack {
                            Button("Retry") { camera.retry() }
                            Button("Use Simulator") { model.setInputMode(.simulator) }
                        }
                    } else if camera.state == .denied {
                        Button("Use Simulator") { model.setInputMode(.simulator) }
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private var cameraPreview: some View {
        GroupBox("Desk View") {
            CameraPreviewRepresentable(
                session: camera.session,
                calibrationCorners: model.calibrationCorners,
                suggestedCorners: camera.suggestedPaperCorners,
                trackedPoint: camera.trackedCameraPoint,
                interaction: model.cameraInteraction,
                onClick: model.handleCameraClick
            )
            .aspectRatio(camera.activeVideoAspectRatio, contentMode: .fit)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.12))
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 6) {
                    Image(systemName: trackingFeedbackIcon)
                        .accessibilityHidden(true)
                    Text(trackingFeedbackLabel)
                        .lineLimit(1)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(trackingFeedbackColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.ultraThickMaterial, in: Capsule())
                .padding(9)
            }
            .accessibilityLabel("Live Desk View camera preview")
        }
    }

    private var calibrationSection: some View {
        GroupBox("Paper calibration") {
            VStack(alignment: .leading, spacing: 10) {
                StepStatusRow(
                    title: model.isCalibrated ? "Calibrated" : "Four corners required",
                    detail: calibrationDetail,
                    complete: model.isCalibrated
                )

                HStack {
                    Button(model.cameraInteraction == .calibrating ? "Restart 4-Point" : "Manual 4-Point") {
                        model.beginCalibration()
                    }
                    Button("Use Detected Paper") {
                        model.useDetectedPaper()
                    }
                    .disabled(camera.suggestedPaperCorners.count != 4)
                }

                if model.isCalibrated {
                    Button("Clear Calibration", role: .destructive) {
                        model.resetCalibration()
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private var trackingSection: some View {
        GroupBox("Pen tracking") {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    model.beginPenSeed()
                } label: {
                    Label(
                        model.cameraInteraction == .seedingPen ? "Click Tip in Preview" : "Select Pen Tip",
                        systemImage: "scope"
                    )
                }
                .disabled(!model.isCalibrated)

                HStack(spacing: 8) {
                    Image(systemName: trackingStateIcon)
                        .foregroundStyle(trackingStateColor)
                        .accessibilityHidden(true)
                    Text(camera.penTrackingState.label)
                        .font(.callout.weight(.medium))
                }

                if camera.penTrackingState == .lost {
                    Text("Keep the pen still on the paper, then select its visible tip again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Text("Tracking confidence")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(camera.trackingConfidence * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: camera.trackingConfidence, total: 1)

                Picker("Pen-down", selection: $model.penDownMode) {
                    ForEach(PenDownMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }

                if model.penDownMode == .holdSpace {
                    HStack(spacing: 8) {
                        Text("SPACE")
                            .font(.caption2.monospaced().weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(
                                model.isSpacePressed
                                    ? Color.accentColor.opacity(0.22)
                                    : Color.secondary.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                        Text(model.isSpacePressed ? "Ink down" : "Hold while touching paper")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Auto mode infers contact from confidence, continuity, and motion. A single RGB camera cannot perfectly distinguish a hovering tip, so Hold Space is the reliable fallback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
        }
    }

    private var simulatorSection: some View {
        GroupBox("Simulator") {
            VStack(alignment: .leading, spacing: 10) {
                Label("No camera required", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Open a PDF and drag directly on its page. The simulator uses the same stroke store and PDF export path as Desk View, so you can test the complete document workflow without compatible hardware.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
        }
    }

    private var calibrationDetail: String {
        if model.isCalibrated {
            return "Perspective correction is active."
        }
        if model.cameraInteraction == .calibrating {
            return "\(model.calibrationCorners.count) of 4 corners selected."
        }
        return camera.suggestedPaperCorners.count == 4
            ? "A likely sheet was detected. Confirm it or calibrate manually."
            : "Place a bright sheet fully inside the preview."
    }

    private var cameraStateColor: Color {
        switch camera.state {
        case .running: return .green
        case .requestingPermission, .starting: return .orange
        case .denied, .unavailable: return .red
        case .idle: return .secondary
        }
    }

    private var trackingFeedbackLabel: String {
        if model.activeStroke != nil {
            return "Ink down"
        }
        switch camera.penTrackingState {
        case .notSeeded: return "Select pen tip"
        case .acquiring: return "Acquiring tip"
        case .tracking:
            return model.penDownMode == .holdSpace ? "Hold Space to ink" : "Tip tracked"
        case .outsidePaper: return "Outside paper"
        case .lost: return "Tracking lost"
        }
    }

    private var trackingFeedbackIcon: String {
        if model.activeStroke != nil { return "pencil.tip" }
        switch camera.penTrackingState {
        case .notSeeded: return "scope"
        case .acquiring: return "viewfinder"
        case .tracking: return "checkmark.circle.fill"
        case .outsidePaper: return "exclamationmark.triangle.fill"
        case .lost: return "xmark.circle.fill"
        }
    }

    private var trackingFeedbackColor: Color {
        if model.activeStroke != nil { return .green }
        switch camera.penTrackingState {
        case .tracking: return .green
        case .acquiring: return .orange
        case .outsidePaper, .lost: return .red
        case .notSeeded: return .secondary
        }
    }

    private var trackingStateIcon: String {
        switch camera.penTrackingState {
        case .notSeeded: return "circle.dashed"
        case .acquiring: return "viewfinder"
        case .tracking: return "checkmark.circle.fill"
        case .outsidePaper: return "exclamationmark.triangle.fill"
        case .lost: return "xmark.circle.fill"
        }
    }

    private var trackingStateColor: Color {
        switch camera.penTrackingState {
        case .tracking: return .green
        case .acquiring: return .orange
        case .outsidePaper, .lost: return .red
        case .notSeeded: return .secondary
        }
    }
}

private struct StepStatusRow: View {
    let title: String
    let detail: String
    let complete: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: complete ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(complete ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
