import AppKit
import SwiftUI

struct SessionReviewView: View {
    @ObservedObject var store: SessionReviewStore
    @State private var presentedError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if !store.warnings.isEmpty {
                warningPanel
            }

            if let frame = store.selectedFrame {
                scrubber
                HSplitView {
                    tipCropPanel(frame)
                        .frame(minWidth: 300, idealWidth: 440)
                    metadataPanel(frame)
                        .frame(minWidth: 310, idealWidth: 380)
                }
                labelControls(frame)
            } else {
                emptyState
            }
        }
        .padding(18)
        .frame(minWidth: 760, minHeight: 560)
        .alert(
            "Session Review",
            isPresented: Binding(
                get: { presentedError != nil },
                set: { if !$0 { presentedError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                presentedError = nil
            }
        } message: {
            Text(presentedError ?? "Unknown error")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Contact Label Review")
                .font(.title2.weight(.semibold))
            Text(store.sessionURL.lastPathComponent)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(store.sessionURL.path)
        }
    }

    private var warningPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "Loaded with \(store.warnings.count) warning\(store.warnings.count == 1 ? "" : "s")",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout.weight(.semibold))
            .foregroundStyle(.orange)

            ForEach(store.warnings.prefix(4)) { warning in
                Text(warning.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.warnings.count > 4 {
                Text("\(store.warnings.count - 4) more warnings")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }

    private var scrubber: some View {
        HStack(spacing: 12) {
            Button {
                store.selectFrame(at: store.selectedFrameIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(store.selectedFrameIndex == 0)
            .accessibilityLabel("Previous frame")

            Slider(
                value: Binding(
                    get: { Double(store.selectedFrameIndex) },
                    set: { store.selectFrame(at: Int($0.rounded())) }
                ),
                in: 0...Double(max(0, store.frames.count - 1)),
                step: 1
            )
            .disabled(store.frames.count < 2)
            .accessibilityLabel("Session frame")

            Button {
                store.selectFrame(at: store.selectedFrameIndex + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(store.selectedFrameIndex + 1 >= store.frames.count)
            .accessibilityLabel("Next frame")

            Text("\(store.selectedFrameIndex + 1) / \(store.frames.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 78, alignment: .trailing)
        }
    }

    private func tipCropPanel(_ frame: SessionReviewFrame) -> some View {
        GroupBox("Tip crop") {
            VStack(spacing: 10) {
                if let url = frame.tipCropURL,
                   let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.82))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 38))
                            .foregroundStyle(.secondary)
                        Text(missingCropMessage(frame))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }

                if let path = frame.tipCropRelativePath {
                    Text(path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help(path)
                }
            }
            .padding(.top, 4)
        }
    }

    private func metadataPanel(_ frame: SessionReviewFrame) -> some View {
        GroupBox("Frame metadata") {
            VStack(alignment: .leading, spacing: 9) {
                metadataRow("Frame", value: String(frame.traceID.frameIndex))
                metadataRow("Capture", value: shortSessionID(frame.traceID.captureSessionID))
                metadataRow("Tracker", value: frame.trackerKind ?? "Unavailable")
                metadataRow("Confidence", value: confidenceLabel(frame.confidence))
                metadataRow("Raw Space", value: booleanContactLabel(frame.rawSpaceDown))
                metadataRow("Inferred", value: booleanContactLabel(frame.inferredContact))
                metadataRow("App effective", value: booleanContactLabel(frame.recordedEffectiveContact))

                Divider()

                HStack {
                    Text("Reviewed effective")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(frame.effectiveContact.displayName)
                        .fontWeight(.semibold)
                        .foregroundStyle(contactColor(frame.effectiveContact))
                }
                metadataRow(
                    "Latest correction",
                    value: frame.latestCorrection?.displayName ?? "None"
                )
                if let timestamp = frame.decisionHostTimestamp ?? frame.callbackHostTimestamp {
                    metadataRow("Host time", value: String(format: "%.6f s", timestamp))
                }

                Spacer(minLength: 0)
            }
            .padding(.top, 4)
        }
    }

    private func labelControls(_ frame: SessionReviewFrame) -> some View {
        GroupBox("Correct contact label") {
            HStack(spacing: 10) {
                correctionButton(.contact, systemImage: "pencil.tip.crop.circle.fill", tint: .green, frame: frame)
                correctionButton(.hover, systemImage: "arrow.up.circle.fill", tint: .blue, frame: frame)
                correctionButton(.uncertain, systemImage: "questionmark.circle.fill", tint: .orange, frame: frame)

                Spacer()

                Button {
                    apply(.revert, to: frame)
                } label: {
                    Label("Revert", systemImage: "arrow.uturn.backward.circle")
                }
                .disabled(!frame.hasManualOverride)
                .help("Append a Revert row and use the original recorded contact decision")
            }
            .padding(.top, 4)
        }
    }

    private func correctionButton(
        _ label: SessionReviewLabel,
        systemImage: String,
        tint: Color,
        frame: SessionReviewFrame
    ) -> some View {
        Button {
            apply(label, to: frame)
        } label: {
            Label(label.displayName, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .disabled(frame.latestCorrection == label)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No recorded frames")
                .font(.headline)
            Text("This session has no readable frame rows in events.jsonl.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    private func apply(_ label: SessionReviewLabel, to frame: SessionReviewFrame) {
        do {
            try store.appendCorrection(label, for: frame.traceID)
        } catch {
            presentedError = error.localizedDescription
        }
    }

    private func missingCropMessage(_ frame: SessionReviewFrame) -> String {
        guard let path = frame.tipCropRelativePath else {
            return "No tip crop was requested for this frame."
        }
        if let status = frame.tipCropStatus, status != .written {
            return "Tip crop unavailable: \(status.displayName.lowercased())."
        }
        return "The recorded crop could not be opened.\n\(path)"
    }

    private func confidenceLabel(_ confidence: Double?) -> String {
        guard let confidence, confidence.isFinite else { return "Unavailable" }
        return String(format: "%.1f%%", confidence * 100)
    }

    private func booleanContactLabel(_ value: Bool?) -> String {
        guard let value else { return "Unknown" }
        return value ? "Contact" : "Hover"
    }

    private func shortSessionID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).uppercased()
    }

    private func contactColor(_ contact: SessionReviewedContact) -> Color {
        switch contact {
        case .contact: return .green
        case .hover: return .blue
        case .uncertain: return .orange
        }
    }
}
