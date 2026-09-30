# DeskInk Phase 0–1 verification report

This report covers the review of baseline commit `3498a79`, the cheap Phase 0 fixes, and the Phase 1 measurement harness. It deliberately contains no claimed camera accuracy or physical latency measurements: those require a person using a real Desk View setup at Human Checkpoint 1.

## Phase 0: review claims checked against the baseline

| Claim | Result | Baseline evidence |
|---|---|---|
| `LocalPatchTracker` is unused | Confirmed | A repository-wide search found only its declaration in `LocalPatchTracker.swift:10–12`; app code and tests had no references. |
| Vision starts from a `0.12 × 0.12` observation and reports its midpoint | Confirmed | `CameraController.swift:238–247` creates the seed box; `CameraController.swift:280–283` uses `boundingBox.midX/midY`. |
| Paper detection stops after calibration | Partly true | Automatic rectangle detection was gated by `paperTransform == nil` at `CameraController.swift:234–236`. A user could still clear or manually replace calibration through `setCalibration`/`clearCalibration` at lines 124–136. |
| Automatic pen-down was the default | Confirmed | `AppModel.swift:15` initialized `penDownMode` to `.automatic`. |
| Each observation redraws the page and all ink | Confirmed with qualification | `PDFCanvasView.swift:20–29` marked the view dirty on every SwiftUI update; `draw` rendered the PDF page and iterated all strokes at lines 50–95. This occurred for observation-driven published updates, not for frames that never reached the view. |
| Export uses `.mediaBox` without rotation/crop handling | Confirmed | `PDFExporter.swift:17–20` uses `.mediaBox`; the exporter had no `rotation` or `.cropBox` logic. |
| No latency or accuracy instrumentation existed | Confirmed | Repository-wide searches found no timing percentiles, frame trace IDs, millimetre accuracy fixtures, or accuracy exports. |
| A developer-facing tracking-loss sentence existed | Confirmed | `ContentView.swift:370–374` contained “The previous build failed silently here.” |
| Normalized distance is physically anisotropic | Confirmed | `InkModels.swift:27–29` computes Euclidean distance in the unit square; `PenContactStateMachine.swift:8–9, 40–45` applies normalized jump/speed thresholds. The same normalized delta represents different millimetres on the two axes of a non-square sheet. |
| Capture relied on `.high` without an explicit format/FPS | Confirmed | `CameraController.swift:188–214` set `sessionPreset = .high` and did not choose `activeFormat` or frame duration. |

Line numbers above refer to baseline commit `3498a79`, not the later phase branches.

## Phase 0 baseline and cheap fixes

- Toolchain: Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), targeting `arm64-apple-macosx26.0`.
- Active developer directory: Command Line Tools, not full Xcode.
- A plain `swift build`/`swift test` initially selected the default macOS 27 SDK, which is incompatible with this compiler. Selecting the installed `MacOSX26.5.sdk`, using workspace-local module caches, and loading the Command Line Tools copy of the Swift Testing macro plugin made the build and tests pass. `Scripts/build_app.sh` now chooses a matching SDK automatically for Command Line Tools-only setups.
- Phase 0 ended with the original 12 tests passing and a successfully built, ad-hoc-signed `build/DeskInk.app`.

Phase 0 commits:

- `44b2ba8` — default contact control to Hold Space.
- `d16fb51` — replace the developer tracking-loss note with recovery guidance.
- `6a698d8` — derive preview aspect ratio from the selected camera format.
- `095647f` — log discovered device identifiers and every advertised format.
- `dd7435d` — select the highest-resolution format that sustains at least 30 fps, targeting 30 fps when the device supports it.

## Phase 1 implementation

### Software latency

Each captured frame has a session UUID plus monotonically increasing frame index. The pipeline records host-clock timestamps at:

1. capture callback entry;
2. tracker result;
3. render-layer hand-off; and
4. the end of the overlay draw, used explicitly as a software commit proxy.

The debug panel reports p50, p95, and p99 for capture-to-tracker, tracker-to-render hand-off, hand-off-to-draw, and capture-to-draw. It also reports dropped capture frames, coalesced/non-rendered traces, sample counts, and presentation-timestamp delivery when a safe host-clock conversion exists. It does not claim display scan-out or glass-to-glass latency.

The capture source converts the sample presentation timestamp through the capture session's synchronization clock with Core Media clock conversion APIs. The panel labels the relationship as host clock, converted with or without possible drift, unverified, or invalid. Whether this particular Desk View device shares or drifts from the host clock remains a hardware check.

### Local session recorder and review

Recording is off by default. Starting it requires a user-selected folder and displays a persistent red `REC` indicator. The UI states that recordings remain local and are never uploaded. A session contains:

- immutable `metadata.json` with app/git version, selected device/format, the 2 GiB policy, and user-entered setup notes;
- append-only `events.jsonl` with raw capture time, host-clock conversion, tracker output, calibration/homography, mapped point, independently timestamped Space transitions, app decisions, and stroke boundaries;
- a roughly 128 × 128 native-frame JPEG tip crop for tracked frames;
- a native-resolution full-frame JPEG at approximately 2 fps;
- optional append-only `label-corrections.jsonl`, created by the review tool without altering the raw event log.

Media encoding uses a bounded queue. If encoding falls behind or the disk budget is reached, media is dropped and the outcome is logged while telemetry is retained. The review sheet scrubs frames, displays crops and recorded labels, and appends Contact, Hover, Uncertain, or Revert corrections.

### Grid accuracy fixture

The Accuracy Test menu generates vector Letter or A4 PDFs with a 5 × 5 grid, orientation cues, a 100 mm ruler, and an explicit “Actual Size / 100%” print warning. Test mode pauses normal PDF ink. For each target it requires Space to remain down for at least 1.0 second and at least 15 mapped samples, uses the component median to reduce jitter/outliers, and requires release before advancing. The CSV includes target and measured coordinates, x/y/radial error in millimetres, calibration corners, the homography, setup metadata, and mean/p95/max summaries.

## Verified baseline numbers

| Measurement | Result | Source |
|---|---:|---|
| Automated tests | 41 passed, 0 failed, 12 suites | Local Swift Testing run after Phase 1 integration |
| Original regression tests retained | 12 of 12 passing | Baseline suite extended, not replaced |
| Recorder disk cap default | 2 GiB | Deterministic recorder configuration and disk-cap test |
| Tip crop request | 128 × 128 pixels | Deterministic media-request test |
| Full-frame request rate | about 2 fps (0.5 s interval) | Deterministic media-cadence test |
| Accuracy grid | 25 targets | Deterministic Letter/A4 geometry tests |
| Required hold | at least 1.0 s and 15 samples | Deterministic reducer tests |
| Hardware latency percentiles | Pending | Requires Desk View frames and physical pen video |
| Physical mean/p95/max error | Pending | Requires three printed-grid runs |
| Tracking-loss/false-contact rates | Pending | Requires recorded physical sessions |

The local linker emits non-fatal warnings because Command Line Tools lacks two Xcode-only search directories and its Swift Testing framework is built for macOS 14 while the app deployment target is macOS 13. The app and all tests still link and pass. A full Xcode installation is the recommended camera-test environment.

## Human Checkpoint 1

Do not begin tracker selection or threshold tuning until these artifacts exist.

### A. Three accuracy runs

1. Build and open the signed app with `./Scripts/build_app.sh debug`, then open `build/DeskInk.app`.
2. In **Accuracy Test**, generate the PDF for the paper you will use.
3. Print with **Actual Size / 100%**. Disable Fit, Shrink, or Scale to Page.
4. Measure the printed ruler. It must be 100 mm; if it is not, fix print scaling before continuing.
5. Switch to Desk View, manually calibrate in this order: top-left → top-right → bottom-right → bottom-left, and select the visible pen tip.
6. Start the grid test. For each of the 25 crosses, place the physical nib on the cross, hold Space for at least one second until the app records it, then release Space before moving to the next cross.
7. Export the CSV.
8. Clear and redo the four-point calibration before each of runs 2 and 3. Export all three CSVs with distinct names.

### B. Two 60-second recording sessions

1. Fill in pen/pencil type, paper, lighting, desk surface, handedness, and notes.
2. Turn on **Record session**, choose a local folder, and confirm the red `REC` indicator stays visible.
3. For roughly 60 seconds, write several lines while holding Space only for real contact. Include deliberate hovering, taps, normal strokes, short lifts between letters, and a few longer lifts.
4. Stop recording cleanly. Repeat once, preferably changing at least one variable such as pen, pencil, lighting, or desk surface.
5. In **Review Recorded Session…**, spot-check crops and correct several obvious Contact/Hover frames to verify the sidecar workflow.
6. Send the two complete `.deskink-session` folders, including images, JSON/JSONL, and any correction sidecar. Do not send only `events.jsonl`.

### C. Video and debug evidence

1. Make a macOS screen recording covering both 60-second sessions, with the Desk View preview, PDF overlay, red recording indicator, and software-latency panel visible when practical.
2. Also record the pen tapping the paper next to the Mac display with a phone in slow motion—240 fps if available. Frame both the physical nib and the on-screen ink so contact-to-visible-ink frames can be counted.
3. After at least 300 committed samples, take a screenshot of the expanded software-latency panel.
4. Capture the DeskInk camera logs showing device name, model ID, unique ID, all advertised formats, selected format, and clock-relation label.

Return the three CSVs, two complete session folders, screen recording, slow-motion phone video, latency-panel screenshot, and camera/device logs. Those are the inputs for Phase 2; until then, the existing Vision tracker remains experimental and the pen-tip tracking problem is not claimed fixed.
