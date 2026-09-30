# DeskInk MVP

DeskInk is a native macOS prototype that turns a calibrated sheet of paper and a normal pen or pencil into vector ink on a PDF. The MVP stays deliberately narrow:

1. Open a PDF.
2. Capture Apple's Desk View camera.
3. Detect a likely sheet and confirm it with four corner points.
4. Click once on the pen tip to seed tracking.
5. Map the tracked point through a projective transform and render ink on the PDF.
6. Export an annotated PDF.

If Desk View is missing or camera access is denied, **Simulator** mode lets you draw with the pointer and exercise the same document, stroke, undo, and PDF-export pipeline.

## Version 0.1.1 ink fix

This build fixes an issue in 0.1 where the yellow pen marker could track correctly but no stroke was recorded. Camera observations and pen-down inference now use compatible confidence thresholds, brief Vision dropouts no longer discard the selected tip immediately, and a short tap is preserved as a visible dot. Black ink is also a fixed near-black color, so it remains visible when the app is running in Dark Mode.

The Desk View preview now reports **Tip tracked**, **Tracking on paper**, **Ink down**, **Outside paper**, or **Tracking lost**. Export refuses to create a misleading clean copy when no ink has actually been recorded.

## Stack

- SwiftUI and AppKit for the macOS interface
- AVFoundation for `.deskViewCamera` discovery, preview, and low-latency frames
- Vision for rectangle suggestions and user-seeded pen-tip object tracking
- PDFKit for rendering and vector ink annotations
- A small in-project homography solver; no OpenCV, Core ML model, or third-party package

The deployment target is native macOS 13 or later. This is not a Mac Catalyst app.

## Build and run

You need macOS 13+ and the Apple Swift toolchain. Full Xcode is recommended but is not required for the included build script.

```sh
./Scripts/build_app.sh
open build/DeskInk.app
```

Use `./Scripts/build_app.sh release` for an optimized local build. The script creates an app bundle, installs the required camera usage description, and ad-hoc signs it with the sandbox/camera/file-picker entitlements.

For development:

```sh
swift build
./Scripts/test.sh
```

You can also open `Package.swift` in Xcode for editing. Run the bundled app made by the script when testing camera permission, because it contains the intended `Info.plist` and entitlements.

`Scripts/test.sh` also supports Command Line Tools-only installations whose default SDK or Swift Testing macro path does not match the active compiler. Full Xcode remains recommended for real camera testing.

## First run without Desk View

1. Launch DeskInk; Simulator is selected by default.
2. Click **Open PDF**.
3. Drag on the displayed page to add ink.
4. Try page navigation, ink color, Undo, and Clear Page.
5. Click **Export** and open the result in Preview. The ink is stored as PDF ink annotations, not a screenshot.

This path is the fastest way to verify the app and does not ask for camera access.

## Desk View workflow

1. Switch Input to **Desk View** and approve the macOS camera prompt.
2. Put one bright sheet fully in view.
3. Use **Use Detected Paper** if the dashed rectangle is correct, or choose **Manual 4-Point** and click top-left → top-right → bottom-right → bottom-left.
4. Put the pen tip on the sheet, choose **Select Pen Tip**, then click the visible tip in the preview.
5. Start writing. The yellow marker shows the currently tracked point; confirm that the preview changes to **Tracking on paper** and then **Ink down** while a stroke is being recorded.
6. Begin with **Hold Space** pen-down mode for predictable tests: hold Space only while the pen touches the page. Then try **Auto (experimental)**.

For the cleanest tracking, use even lighting, a visually distinctive pen against plain paper, keep fingers a short distance behind the tip, and avoid covering the tip during the initial seed.

If the preview says **Outside paper**, recalibrate the sheet. If it says **Tracking lost**, click **Select Pen Tip** and seed the visible tip again. If **Auto (experimental)** does not reliably show **Ink down** with your lighting and pen, switch to **Hold Space**; the same calibrated tracking and export path are used, but Space explicitly controls contact.

## Measurement and recording tools

DeskInk now includes a local lab harness for collecting the real data needed to improve tracking:

- **Software latency** expands in the Desk View sidebar and reports p50/p95/p99 for the capture, tracking, render hand-off, and overlay-draw portions of the pipeline. These are software timings, not glass-to-glass display latency.
- **Session recording** is off by default. Fill in the setup fields, turn on Record session, and choose a folder. A red `REC` indicator remains visible while the app writes a capped, local-only `.deskink-session` folder. No recording is uploaded.
- **Review Recorded Session…** opens the captured tip crops and lets you append Contact, Hover, Uncertain, or Revert corrections. Corrections are written to a sidecar; the raw Space events and frame log are never overwritten.
- **Grid accuracy test** generates a printable Letter or A4 5 × 5 target. Print at Actual Size / 100%, verify the 100 mm ruler, calibrate the sheet, select the tip, then hold Space on each cross for at least one second. Exported CSVs report x/y/radial error in real millimetres plus mean, p95, and max.

The current Vision tracker still follows the center of a seeded object box rather than a proven physical nib point. The new tools measure that limitation; they do not claim it is solved. Keep **Hold Space** selected until recorded evidence supports a safer automatic-contact mode.

The complete Phase 0 verification, implementation notes, current test numbers, and exact first hardware checkpoint are in [Docs/PHASE_0_1_REPORT.md](Docs/PHASE_0_1_REPORT.md).

## What “automatic pen-down” means here

The first version infers contact using tracking confidence, consecutive in-sheet samples, velocity, jump rejection, and hysteresis. A large jump or sustained tracking loss ends a stroke. This is useful for proving the interaction, but it is not a solved physical contact sensor.

A single RGB camera generally cannot distinguish a tip touching paper from the same tip hovering a few millimeters above it in every pose and lighting condition. Slow hovering can therefore create unwanted ink, and subtle lifts can join letters. **Hold Space** is included as the reliable control path while keeping camera-based XY tracking active. A production version needs a trained contact model, additional geometric cues, or a delayed “new ink appeared behind the tip” detector built from real usage data.

## Apple API and entitlement notes

- Desk View is a public `AVCaptureDevice.DeviceType.deskViewCamera` on macOS 13+. It is captured with an ordinary `AVCaptureSession`, `AVCaptureDeviceInput`, and `AVCaptureVideoDataOutput`.
- The app includes `NSCameraUsageDescription` and the `com.apple.security.device.camera` entitlement. macOS may terminate a camera app that omits the usage description.
- The sandbox includes `com.apple.security.files.user-selected.read-write` so the Open and Save panels can access user-selected PDFs.
- The app intentionally does **not** request microphone access.
- `NSCameraUseContinuityCameraDeviceType` is not included because the app discovers the Desk View device directly; it does not depend on the separate `.continuityCamera` device classification.
- `AVCaptureDeskViewApplication` launches Apple's separate Desk View interface. It is not the raw frame API and is not used here.
- Desk View availability is dynamic. A supported built-in camera or a correctly configured Continuity Camera may appear or disappear, so “unavailable” is treated as a normal state and Simulator remains accessible.

Official references:

- [Desk View camera device](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/deskviewcamera)
- [AVCaptureVideoDataOutput](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput)
- [Camera authorization](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media)
- [Camera usage description](https://developer.apple.com/documentation/bundleresources/information-property-list/nscamerausagedescription)
- [Camera entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.camera)
- [User-selected file entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.files.user-selected.read-write)
- [Apple Desk View hardware support](https://support.apple.com/en-us/121541)
- [Continuity Camera requirements](https://support.apple.com/en-us/102546)

## Project layout

```text
Sources/DeskInk/
  Accuracy/     printable fixture, grid reducer, and millimetre CSV export
  App/          app lifecycle and workspace state
  Camera/       Desk View capture, paper detection, Vision tracking
  Instrumentation/ software-latency trace aggregation
  Math/         projective transform / homography
  Models/       normalized points, strokes, workflow enums
  PDF/          vector-annotation export
  Recording/    local session recorder and append-only label review
  Tracking/     pen-down inference state machine
  Views/        SwiftUI workspace and AppKit camera/PDF surfaces
Tests/DeskInkTests/
Resources/      Info.plist and sandbox entitlements
Scripts/        local .app bundle builder
```

## Verification

The automated suite covers:

- identity and perspective mappings, including all corners and an interior point;
- rejection of repeated, collinear, and self-crossing calibration input;
- pen-down hysteresis, confidence loss, and lift/jump splitting;
- acceptance of the same low-confidence observations published by Vision tracking;
- pointer drag and single-click simulator input through the real AppKit view;
- PDF cloning, vector ink annotation creation, serialization, reopen, and rendered-pixel visibility in both Light and Dark appearance.
- bounded recorder cadence/disk behavior, frame telemetry, and immutable raw logs;
- append-only review corrections, truncated-log recovery, and timestamped Space projection;
- exact Letter/A4 fixture geometry, orientation, one-second sampling gates, robust medians, physical-millimetre errors, and CSV summaries;
- frame-source injection, host-clock latency stage aggregation, and Space-key transition deduplication.

Camera quality, physical accuracy, and end-to-end latency still require a physical Desk View-capable Mac. Follow Human Checkpoint 1 in the phase report rather than inferring results from synthetic tests.
