import Foundation

struct GridCalibrationMetadata: Equatable, Sendable {
    var calibrationTimestamp: Date?
    var cameraCorners: [NormalizedPoint]
    var homography: [Double]
    var additionalFields: [String: String]

    init(
        calibrationTimestamp: Date? = nil,
        cameraCorners: [NormalizedPoint] = [],
        homography: [Double] = [],
        additionalFields: [String: String] = [:]
    ) {
        self.calibrationTimestamp = calibrationTimestamp
        self.cameraCorners = cameraCorners
        self.homography = homography
        self.additionalFields = additionalFields
    }
}

/// Writes one rectangular CSV containing metadata, per-target measurements,
/// and aggregate statistics. Metadata keys are rows rather than comments so
/// the result remains machine-readable by ordinary CSV tools.
enum GridAccuracyCSVExporter {
    private static let header = [
        "record_type", "key", "value", "target_number", "row", "column",
        "target_x_mm", "target_y_mm", "observed_x_mm", "observed_y_mm",
        "dx_mm", "dy_mm", "error_mm", "sample_count", "hold_duration_s",
        "recorded_timestamp"
    ]

    static func csv(
        paperFormat: PaperFormat,
        measurements: [GridAccuracyMeasurement],
        calibration: GridCalibrationMetadata
    ) -> String {
        var rows: [[String]] = [header]
        appendMetadataRows(to: &rows, paperFormat: paperFormat, calibration: calibration)

        for measurement in measurements {
            rows.append([
                "point", "", "", String(measurement.target.index + 1),
                String(measurement.target.row + 1), String(measurement.target.column + 1),
                number(measurement.target.positionMM.x),
                number(measurement.target.positionMM.y),
                number(measurement.observedMM.x), number(measurement.observedMM.y),
                number(measurement.deltaXMM), number(measurement.deltaYMM),
                number(measurement.errorMM), String(measurement.sampleCount),
                number(measurement.holdDuration), number(measurement.recordedTimestamp)
            ])
        }

        let statistics = GridAccuracyStatistics.calculate(from: measurements)
        appendSummaryRow("measurement_count", String(statistics.measurementCount), to: &rows)
        appendSummaryRow("mean_error_mm", optionalNumber(statistics.meanErrorMM), to: &rows)
        appendSummaryRow("p95_error_mm", optionalNumber(statistics.p95ErrorMM), to: &rows)
        appendSummaryRow("max_error_mm", optionalNumber(statistics.maxErrorMM), to: &rows)

        return rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    static func data(
        paperFormat: PaperFormat,
        measurements: [GridAccuracyMeasurement],
        calibration: GridCalibrationMetadata
    ) -> Data {
        Data(csv(
            paperFormat: paperFormat,
            measurements: measurements,
            calibration: calibration
        ).utf8)
    }

    private static func appendMetadataRows(
        to rows: inout [[String]],
        paperFormat: PaperFormat,
        calibration: GridCalibrationMetadata
    ) {
        appendKeyValueRow("paper_format", paperFormat.displayName, type: "metadata", to: &rows)
        appendKeyValueRow("paper_width_mm", number(paperFormat.widthMM), type: "metadata", to: &rows)
        appendKeyValueRow("paper_height_mm", number(paperFormat.heightMM), type: "metadata", to: &rows)
        appendKeyValueRow("coordinate_origin", "top-left", type: "metadata", to: &rows)
        appendKeyValueRow("positive_x_direction", "right", type: "metadata", to: &rows)
        appendKeyValueRow("positive_y_direction", "down", type: "metadata", to: &rows)
        if let timestamp = calibration.calibrationTimestamp {
            appendKeyValueRow(
                "calibration_timestamp",
                ISO8601DateFormatter().string(from: timestamp),
                type: "metadata",
                to: &rows
            )
        }
        for (index, corner) in calibration.cameraCorners.enumerated() {
            appendKeyValueRow(
                "calibration_corner_\(index + 1)_x",
                number(corner.x),
                type: "metadata",
                to: &rows
            )
            appendKeyValueRow(
                "calibration_corner_\(index + 1)_y",
                number(corner.y),
                type: "metadata",
                to: &rows
            )
        }
        for (index, coefficient) in calibration.homography.enumerated() {
            appendKeyValueRow(
                "homography_\(index)",
                number(coefficient),
                type: "metadata",
                to: &rows
            )
        }
        for key in calibration.additionalFields.keys.sorted() {
            appendKeyValueRow(
                key,
                calibration.additionalFields[key] ?? "",
                type: "metadata",
                to: &rows
            )
        }
    }

    private static func appendSummaryRow(
        _ key: String,
        _ value: String,
        to rows: inout [[String]]
    ) {
        appendKeyValueRow(key, value, type: "summary", to: &rows)
    }

    private static func appendKeyValueRow(
        _ key: String,
        _ value: String,
        type: String,
        to rows: inout [[String]]
    ) {
        rows.append([type, key, value] + Array(repeating: "", count: header.count - 3))
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func optionalNumber(_ value: Double?) -> String {
        value.map(number) ?? ""
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
