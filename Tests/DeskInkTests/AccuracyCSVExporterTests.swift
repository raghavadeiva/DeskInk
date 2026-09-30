import Foundation
import Testing
@testable import DeskInk

@Suite("Grid accuracy CSV")
struct AccuracyCSVExporterTests {
    @Test("CSV includes calibration metadata, per-point error, and summaries")
    func completeExport() {
        let target = AccuracyGrid.targets(for: .letter)[0]
        let measurement = GridAccuracyMeasurement(
            target: target,
            observedMM: PaperPointMM(x: 21, y: 22),
            sampleCount: 17,
            holdDuration: 1.2,
            recordedTimestamp: 42.5
        )
        let metadata = GridCalibrationMetadata(
            calibrationTimestamp: Date(timeIntervalSince1970: 0),
            cameraCorners: [
                NormalizedPoint(x: 0.1, y: 0.2),
                NormalizedPoint(x: 0.9, y: 0.2),
                NormalizedPoint(x: 0.9, y: 0.8),
                NormalizedPoint(x: 0.1, y: 0.8)
            ],
            homography: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            additionalFields: ["desk_surface": "wood, dark \"oak\""]
        )

        let csv = GridAccuracyCSVExporter.csv(
            paperFormat: .letter,
            measurements: [measurement],
            calibration: metadata
        )

        #expect(csv.hasPrefix("record_type,key,value,target_number"))
        #expect(csv.contains("metadata,paper_format,Letter"))
        #expect(csv.contains("metadata,paper_width_mm,215.900000"))
        #expect(csv.contains("metadata,coordinate_origin,top-left"))
        #expect(csv.contains("metadata,positive_y_direction,down"))
        #expect(csv.contains("metadata,calibration_timestamp,1970-01-01T00:00:00Z"))
        #expect(csv.contains("metadata,calibration_corner_4_y,0.800000"))
        #expect(csv.contains("metadata,homography_8,1.000000"))
        #expect(csv.contains("metadata,desk_surface,\"wood, dark \"\"oak\"\"\""))
        #expect(csv.contains("point,,,1,1,1,20.000000,20.000000,21.000000,22.000000,1.000000,2.000000,2.236068,17,1.200000,42.500000"))
        #expect(csv.contains("summary,measurement_count,1"))
        #expect(csv.contains("summary,mean_error_mm,2.236068"))
        #expect(csv.contains("summary,p95_error_mm,2.236068"))
        #expect(csv.contains("summary,max_error_mm,2.236068"))
        #expect(GridAccuracyCSVExporter.data(
            paperFormat: .letter,
            measurements: [measurement],
            calibration: metadata
        ) == Data(csv.utf8))
    }

    @Test("Additional metadata is ordered for deterministic exports")
    func metadataOrdering() {
        let csv = GridAccuracyCSVExporter.csv(
            paperFormat: .a4,
            measurements: [],
            calibration: GridCalibrationMetadata(additionalFields: [
                "z_field": "last",
                "a_field": "first"
            ])
        )
        let aRange = csv.range(of: "metadata,a_field,first")
        let zRange = csv.range(of: "metadata,z_field,last")
        #expect(aRange != nil)
        #expect(zRange != nil)
        if let aRange, let zRange {
            #expect(aRange.lowerBound < zRange.lowerBound)
        }
        #expect(csv.contains("summary,measurement_count,0"))
        #expect(csv.contains("summary,mean_error_mm,"))
    }
}
