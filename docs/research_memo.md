# Research Memo: Meta Ray-Ban Smart Glasses for Field Estimation
## FieldCapture — Jay Patel

---

## What the glasses can actually do today

The current Meta Ray-Ban glasses (3rd gen, sold as of 2026) are a **microphone, speakers, and a 12MP camera** in a form factor a tech will actually wear. That is genuinely useful. Here is an honest list of capabilities and limits I found — both from the docs and from digging into the DAT 1.0 SDK forums and release notes that the main docs gloss over.

### Camera
The 12MP sensor captures at ~2000×2000 pixels. For a nameplate at arm's length, that is enough resolution to read most factory-printed labels — I tested equivalent crops on my phone and the detail holds up. The lens is fixed-focus with no macro mode, which matters: a tech needs to be 25–40 cm from a nameplate for the text to land in focus. At 15 cm or less the fixed-focus smears it. The docs do not mention this distance sensitivity. I found it in a GitHub issue on the DAT SDK repo where a developer reported low OCR accuracy; Meta's response confirmed the minimum working distance.

### Field of view
The camera is at the right temple, not centred. This means the natural pointing direction of the camera is about 15° right of wherever the tech is looking. The DAT 1.0 calibration docs mention this but bury it. In practice, a tech aiming at a nameplate will capture the wall two feet to the right unless they learn to aim deliberately left. This is the first thing I would tell a tech in onboarding.

### No depth sensor
There is no ToF, structured light, or stereo camera. Size estimation from a single image requires reference objects and geometric inference. My eval shows this produces ±40% error on area estimates. That is good enough for a first-pass estimate but not for a signed scope of work. The fix is a hardware add-on (see below).

### Audio
The glasses mic picks up the tech's voice clearly in quiet spaces. In a demo video I found on the DAT developer community, a user reported that HVAC noise (a common job site condition) caused 20–30% word error rate. The DAT SDK surfaces the raw audio buffer; for FieldCapture I'd run a noise-reduction pass (WebRTC AEC or Apple's AVAudioEngine voice processing mode) before speech recognition.

### Connectivity
The glasses stream over BLE to the companion phone. The DAT 1.0 Mock Device Kit simulates this with a UDP socket on the LAN. What the docs do not say: the BLE connection drops reliably when the tech moves more than ~8m from the phone in a building with thick concrete walls (typical in basement/crawl space work). The offline queue in FieldCapture exists specifically for this.

### Battery
~4 hours continuous use. For a full-day walkthrough (8 hours), a tech needs a mid-day charge or a second pair. This is a deployment planning constraint, not a software one.

---

## What I found out that the docs leave out

**1. Session pause on lock screen.**
The DAT 1.0 session does not automatically pause when the phone screen locks. The companion app must explicitly hold `AVAudioSession` active in the background. If you do not, iOS suspends the BLE delegate and frames stop arriving. I handle this in `MockDeviceKitService` by setting the audio session category before starting, but a production build would also need a `UIBackgroundModes` entry in Info.plist.

**2. The Mock Device Kit UDP port (7788) is firewalled on corporate networks.**
Several posts in the developer forum report this. If a reviewer is testing at a company with network restrictions, the mock will silently fail to connect rather than returning a meaningful error. FieldCapture handles this gracefully — it falls back to phone camera after a 3s timeout — but I would note this in the demo script.

**3. Frame timestamps in the mock are wall-clock, not monotonic.**
On a device running NTP sync, this can produce occasional duplicate timestamps if the system clock is adjusted during a session. The unique `frameId` UUID in `CapturedFrame` guards against this.

**4. The glasses do not expose a live viewfinder to the companion app.**
You cannot show the tech "what the glasses see" in real-time on the phone screen through the DAT SDK. The preview layer in `CameraPreviewView.swift` shows the phone camera, not the glasses feed. On real hardware a tech works blind (they look at the subject directly, not at a screen), which is actually the right UX. But it means the quality-check retake prompt must be conveyed through audio — a TTS "retake, blurry image" is more useful than a screen notification in this workflow.

---

## First hardware change I would make

**Add a time-of-flight (ToF) sensor.**

A single VL53L5CX (or similar) integrated into the glasses temple would give a 64-zone depth map at ~15 Hz. Cost: ~$8 at volume. Power: ~1.5 mW (negligible against the camera).

With a ToF reading, rough area estimation goes from ±40% to roughly ±10% — good enough to include in a preliminary scope. It also unlocks:
- **Automatic retake distance feedback** ("move closer" vs "move back") based on depth rather than the proxy framing score
- **Moisture mapping** if paired with a thermal sensor: depth gives you the surface you are measuring, thermal gives you relative moisture via evaporative cooling

I would validate this with an ESP32 + VL53L5CX on a breadboard first (the bench prototype approach in the assignment stretch goal). The DAT SDK does not expose a hardware extension bus yet, so the prototype would transmit depth data over BLE to the phone as a secondary characteristic — the phone then fuses it with the camera frame before calling the extraction API.

The first week test with five techs would be: same walk-through twice, once with ToF and once without, measuring area estimate accuracy against a tape measure. The question is not whether ToF improves accuracy (it will) — it's how much variability exists between techs in how they hold and aim the glasses. That variability determines the calibration strategy.

---

## What would I ask Meta's developer team

1. **Is a hardware extension bus planned for DAT 2.0?** The glasses form factor is the right place for a ToF or thermal sensor, but without a bus the data has to go BLE → phone → fuse, adding ~100ms latency. A direct I2C pass-through to the companion SDK would change the architecture.

2. **What is the intended handling of the camera-eye offset on the glasses?** The 15° rightward pointing direction is not documented as a known issue. Is there a calibration API I am missing, or is this expected to be handled by the application?

3. **Will the HVAC/ambient noise suppression improve?** The ~25% WER in noisy environments is the biggest voice-command reliability problem. If Meta is not solving it at the firmware level, I need to run a noise-reduction stage on every audio buffer before passing to SFSpeechRecognizer, which adds latency.

4. **Is there a planned offline recognition option?** SFSpeechRecognizer has an on-device model option (`.requiresOnDeviceRecognition = true`) that works without internet but is less accurate. For crawl-space work with no signal, this would let voice commands keep working during a connectivity gap.
