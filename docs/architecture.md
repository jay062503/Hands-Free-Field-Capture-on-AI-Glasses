# FieldCapture — Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Meta DAT 1.0 Glasses                         │
│         Camera (12MP fixed-focus) · Microphone · BLE radio          │
└───────────────────────────────┬─────────────────────────────────────┘
                                │  BLE (frames + audio)
                                │  [fallback: phone camera + mic]
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      MockDeviceKitService                           │
│  • startSession / pauseSession / resumeSession / stopSession        │
│  • Disconnect detection → reconnect timer (5s × 5 attempts)         │
│  • Automatic phone-camera fallback when mock unavailable             │
│  • Publishes: frameAvailable, voiceCommandReceived, disconnect       │
└────────────┬───────────────────────────┬────────────────────────────┘
             │ frames                    │ voice audio
             │                           ▼
             │               ┌─────────────────────────┐
             │               │   VoiceCommandService    │
             │               │  SFSpeechRecognizer      │
             │               │  VoiceCommandParser      │
             │               │  parse() → ParsedCommand │
             │               │  .captureNameplate        │
             │               │  .captureDamage(room,srf) │
             │               │  .note(text)              │
             │               └───────────┬─────────────┘
             │                           │ ParsedCommand
             ▼                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        SessionViewModel                             │
│  • Holds pendingCommand until a frame arrives                       │
│  • Orchestrates: quality check → extraction → record → upload       │
│  • @Published state consumed by SwiftUI views                       │
└──────┬──────────────┬──────────────────┬────────────────────────────┘
       │              │                  │
       ▼              ▼                  ▼
┌──────────┐  ┌───────────────┐  ┌──────────────────┐
│ Quality  │  │  Extraction   │  │   JobRecord       │
│ Check    │  │  Service      │  │   Builder         │
│ Service  │  │               │  │                   │
│          │  │  GPT-4o API   │  │  Accumulates      │
│ Blur     │  │  (HTTPS)      │  │  captures, notes  │
│ Bright   │  │               │  │  Generates line   │
│ Framing  │  │  Nameplate    │  │  items from       │
│          │  │  Damage       │  │  LineItemCatalog   │
│ → pass   │  │  Note (local) │  │                   │
│ → retake │  └───────┬───────┘  └──────────┬────────┘
└──────────┘          │                     │
                      │ ExtractionResult     │ JobRecord
                      ▼                     ▼
              ┌──────────────────────────────────────────┐
              │            UploadQueueService             │
              │  NWPathMonitor watches connectivity        │
              │  Captures written to disk immediately      │
              │  FIFO drain when signal restored           │
              │  Exponential back-off (3 attempts max)     │
              │  → POST to Cozmo backend (stubbed)         │
              └──────────────────────────────────────────┘
                                  │
                                  ▼
                        ┌──────────────────┐
                        │  Cozmo Backend   │
                        │  (stubbed; real  │
                        │  endpoint goes   │
                        │  here)           │
                        └──────────────────┘


SwiftUI View Layer
──────────────────
ContentView  ←──  SessionViewModel (single source of truth)
  ├── CameraPreviewView  (live feed, phone or mock)
  ├── StatusPill         (current pipeline stage)
  ├── RetakeBanner       (quality failure reasons)
  ├── ErrorBanner        (connectivity / API errors)
  ├── VoiceSimulator     (dev-only; hidden in prod build)
  └── JobRecordView      (captures · fields · confidence · line items · JSON export)
```

## Data Flow (single capture, happy path)

```
Tech says "capture damage kitchen north wall"
         │
         ▼
VoiceCommandService.handleTranscript()
         │
         ▼
VoiceCommandParser.parse() → .captureDamage(room: "kitchen", surface: "north wall")
         │
         ▼
SessionViewModel: pendingCommand = .captureDamage, captureStatus = .waitingForFrame
         │
         ▼  (next frame from device)
QualityCheckService.check(frame)
         │ passed? ──────────────────────► retakeBanner displayed; tech adjusts + retakes
         │
         ▼
ExtractionService.extract(frame, .damage, voiceHint: "room: kitchen, surface: north wall")
         │  POST to GPT-4o API
         │  Response: { room, surface, damageType, roughSizeM2, severityLevel, confidence }
         ▼
JobRecordBuilder.addCapture()
         │  → triggers regenerateLineItems() → matches DRY-RR-SF, PAINT-WALL-SF, EQUIP-DH-EA
         ▼
UploadQueueService.enqueue()
         │  writes image + extraction JSON to disk
         │  if connected → uploads immediately
         │  if disconnected → queues; drains when NWPathMonitor fires .satisfied
         ▼
SessionViewModel.captureStatus = .captured(.damage)   (shown 2 seconds, then .idle)
```
