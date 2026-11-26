# FieldCapture

An iOS app that turns a technician's walk-through into a structured job record and draft estimate. No touching the phone. Voice commands trigger captures; a vision API extracts fields; the job record writes itself.

Built for the Cozmo AI take-home assignment (DAT 1.0 / Mock Device Kit).

**AI tools used:** GitHub Copilot for URLSession and vImage boilerplate. All prompt engineering, regex patterns, threshold logic, architecture decisions, and the eval report written manually. Noted inline in each file where Copilot was used.

---

## Setup (under 10 minutes on a clean Mac)

### Prerequisites

- Xcode 15 or later
- iOS 17+ device or simulator (simulator has no camera — use a real device for the full pipeline)
- OpenAI API key (GPT-4o access required)

### Steps

1. **Clone the repo**
   ```
   git clone https://github.com/<your-username>/FieldCapture.git
   cd FieldCapture
   ```

2. **Set your OpenAI API key**

   In Xcode: Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables
   Add: `OPENAI_API_KEY` = `sk-...`

   Or in Info.plist for local testing only (never commit a real key):
   ```xml
   <key>OPENAI_API_KEY</key>
   <string>sk-your-key-here</string>
   ```

3. **Open in Xcode**
   ```
   open FieldCapture.xcodeproj
   ```
   (If you are opening from this repo for the first time, Xcode will index the project. This takes ~30 seconds.)

4. **Select your target device** — a real iPhone is required for camera + speech. The simulator will launch but most features degrade gracefully.

5. **Build and run** — `Cmd+R`

6. **Grant permissions** — camera, microphone, and speech recognition. All three are required. The app explains why in each permission dialog.

---

## Running the Demo

1. Tap **Start Session**. The app attempts to connect to Mock Device Kit on the LAN. Since the companion desktop app is not running, it falls back to the phone camera after ~3 seconds and displays **PHONE CAM** in the top bar.

2. Tap the **mic icon** to open the voice command simulator. This is a dev convenience because the assignment is built without physical glasses.

3. Try these commands:
   ```
   capture nameplate
   capture damage kitchen north wall
   note: subfloor soft by the cabinet
   ```

4. After "capture nameplate", point the phone at an appliance label (water heater, microwave, fridge). The app will:
   - Run a quality check and prompt you to retake if the image is blurry, too dark, or the subject is cut off
   - Call GPT-4o to extract make, model, serial number, and manufacture date
   - Show confidence scores per field

5. After a few captures, tap **End Session** → the job record appears with all captures, extracted fields, notes, and draft line items. Tap **Copy JSON** to export.

---

## Architecture

See `docs/architecture.md` for the full diagram.

One-paragraph summary: `MockDeviceKitService` owns the DAT session lifecycle and the phone-camera fallback. `VoiceCommandService` runs `SFSpeechRecognizer` and routes to `VoiceCommandParser`. `SessionViewModel` acts as the pipeline coordinator: it holds a pending command, waits for a frame, runs `QualityCheckService`, calls `ExtractionService`, adds the result to `JobRecordBuilder`, and enqueues the upload in `UploadQueueService`. All UI state comes from `SessionViewModel` through Combine publishers.

---

## Voice Commands

| Command | Example | Behaviour |
|---|---|---|
| `capture nameplate` | "capture nameplate" | Waits for a frame, extracts make/model/serial/date |
| `capture damage [room] [surface]` | "capture damage kitchen north wall" | Extracts damage type, size, severity; room/surface from voice |
| `note: [text]` | "note: subfloor soft by the cabinet" | Structures the note, extracts location and urgency keywords |

The colon in `note:` is optional — "note subfloor feels soft" also works.

A fourth command for the live session (`capture moisture reading [value] [location]`) is stubbed in `VoiceCommandParser.swift` as a commented extension point. Uncommenting the two blocks and writing one test is the intended 30-minute live task.

---

## Mock Device Kit Notes

The DAT 1.0 Mock Device Kit requires the Meta companion desktop app running on the same LAN and UDP port 7788 open. For this submission, `MockDeviceKitService.checkMockDeviceAvailability()` returns `false` to exercise the phone-camera fallback path, since reviewers won't have the companion app. To test with real Mock Device Kit:
1. Run the Meta Developer Hub companion app on your Mac
2. Change `checkMockDeviceAvailability()` to return `true` (or implement the real UDP check)
3. The session lifecycle, quality checks, extraction, and upload queue all work identically on real hardware

**What the mock cannot simulate:**
- The 15° camera-eye offset of real glasses (documented in `docs/research_memo.md`)
- BLE range limits and concrete-wall signal loss
- The fixed-focus minimum working distance (~25cm)
- Audio in noisy environments (HVAC, compressors)

---

## Offline / Bad Connectivity

Captures are written to disk the moment they pass the quality check. `UploadQueueService` watches `NWPathMonitor`. When connectivity is restored, it drains the queue in FIFO order with exponential back-off (2s, 4s, 8s) on failure. The job record always shows how many items are queued vs uploaded. Nothing is lost on session end.

---

## Quality Check Thresholds

| Check | Threshold | Basis |
|---|---|---|
| Blur (Laplacian variance) | ≥ 80.0 | Measured on 40-frame test set; gap between worst-good (71) and best-bad (61) |
| Brightness (mean intensity) | ≥ 40.0 | Splits usable low-light (min 44) from genuinely dark (max 38) |
| Framing (edge bbox coverage) | ≥ 0.15 | Conservative; a nameplate at the edge still passes |

Full derivation in `eval/eval_report.md`.

---

## Evaluation

See `eval/eval_report.md` for:
- Full 40-frame test set description
- Accuracy per field (nameplate and damage)
- Five worst failures with root causes
- Confidence score calibration analysis
- Cost per job (~$0.11) and latency (median 2.3s voice → record)

---

## What I'd Do With Two More Weeks

**Week 1:**
- Wire in the real DAT SDK (replace stubs in `MockDeviceKitService`)
- Add on-device SFSpeechRecognizer offline mode for crawl-space / no-signal work
- Pre-process images with CLAHE before API call (fixes failure #1 in the eval: faded dot-matrix nameplates)
- Add secondary brightness check: reject frames where std dev of pixel intensity < 15 even if mean > 40 (fixes failure #5)
- Build the ESP32 + VL53L5CX ToF bench prototype (stretch goal)

**Week 2:**
- Integrate ToF depth data into the size estimation prompt
- Add TTS retake prompts ("hold steady, blurry image") so the tech never has to look at the phone
- Write the Cozmo backend endpoint and replace the upload stub
- Run the glasses-vs-phone accuracy comparison (stretch goal)
- Increase the eval set to 100 frames with 5 different techs (lighting, hand steadiness, and distance vary a lot by person)

---

## Project Structure

```
FieldCapture/
├── FieldCapture/
│   ├── FieldCaptureApp.swift          App entry point
│   ├── Models/
│   │   ├── JobRecord.swift            All data models + schema
│   │   └── LineItemCatalog.swift      15 line-item codes + keyword matching
│   ├── Services/
│   │   ├── MockDeviceKitService.swift DAT session lifecycle + phone fallback
│   │   ├── VoiceCommandService.swift  Speech recognition + command parser
│   │   ├── QualityCheckService.swift  Blur / brightness / framing checks
│   │   ├── ExtractionService.swift    GPT-4o vision API calls
│   │   ├── UploadQueueService.swift   Offline queue with NWPathMonitor
│   │   └── JobRecordBuilder.swift     Accumulates captures → builds record
│   ├── ViewModels/
│   │   └── SessionViewModel.swift     Pipeline coordinator
│   ├── Views/
│   │   ├── ContentView.swift          Main camera + controls UI
│   │   ├── CameraPreviewView.swift    AVCaptureVideoPreviewLayer wrapper
│   │   └── JobRecordView.swift        Job record + JSON export
│   └── Resources/
│       └── Info.plist                 Permissions + API key config
├── FieldCaptureTests/
│   ├── VoiceCommandParserTests.swift  10 parser tests
│   ├── LineItemCatalogTests.swift     9 catalog tests
│   └── QualityCheckTests.swift       4 threshold tests
├── eval/
│   └── eval_report.md                 40-frame test set, accuracy, failures
├── sample_outputs/
│   ├── job_001.json                   Kitchen water heater + wall damage
│   ├── job_002.json                   Bathroom mold + floor damage
│   └── job_003.json                   Basement Rheem heater + wall infiltration
└── docs/
    ├── architecture.md                Full system diagram
    └── research_memo.md               Meta glasses capabilities + hardware recommendation
```

---

## Limitations (flagged upfront)

- **Size estimation is unreliable without depth hardware.** 50% accuracy at ±40% tolerance. Confidence scores are set below 0.6 for all size fields. See research memo for the fix.
- **Voice recognition degrades in noisy environments.** HVAC noise causes ~25% WER per DAT forum reports. The phone mic fallback has the same issue. TTS retake prompts help; a noise-reduction pre-pass would help more.
- **The upload endpoint is stubbed.** `UploadQueueService.uploadItem()` simulates an 80% success rate. A real Cozmo backend URL and auth token would replace this.
- **No real Mock Device Kit integration.** The companion app UDP connection is not implemented. The fallback path is production-quality; the mock path stubs out `checkMockDeviceAvailability()` returning `false`.
- **UIKit dependency in `SessionViewModel.makePlaceholderFrame()`** uses `UIGraphicsImageRenderer` — this is iOS-only, which is fine for this target but noted for portability.

---

## Receipts

Total API spend during development: ~$3.20 on GPT-4o test calls.  
No third-party libraries added. All dependencies are Apple frameworks (AVFoundation, Speech, CoreImage, Accelerate, Network, Combine).
