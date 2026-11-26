// VoiceCommandService.swift
// FieldCapture
//
// Listens for voice input (either from the glasses mic via Mock Device Kit
// or from the phone mic as fallback) and parses the three required commands:
//
//   "capture nameplate"
//   "capture damage [room] [surface]"
//   "note: [free text]"
//
// Parsing is intentionally simple regex + pattern matching so it's easy to
// audit and extend. The fourth command ("capture moisture reading [value] [location]")
// is wired up in VoiceCommandParser as a commented-out extension point —
// uncommenting it is the intended live-session task.
//
// AI tools used: GitHub Copilot for boilerplate; regex patterns written manually.

import Foundation
import Speech
import Combine

// MARK: - Parsed Command

enum ParsedCommand: Equatable {
    case captureNameplate
    case captureDamage(room: String, surface: String)
    case note(text: String)
    // Stretch / live-session extension point:
    // case captureMoisture(value: String, location: String)
    case unknown(rawText: String)
}

// MARK: - Voice Command Service

final class VoiceCommandService: NSObject, ObservableObject {

    @Published private(set) var isListening = false
    @Published private(set) var lastTranscript: String = ""
    @Published private(set) var lastCommand: ParsedCommand?

    let commandPublisher = PassthroughSubject<ParsedCommand, Never>()

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Setup

    // Call this during app launch to request Speech permission.
    func requestPermissions() async -> Bool {
        let speechStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        return speechStatus == .authorized
    }

    // MARK: - Start / Stop

    func startListening() throws {
        guard !isListening else { return }

        // If a previous task is still running, cancel it.
        recognitionTask?.cancel()
        recognitionTask = nil

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = false  // only fire on final

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            if let result = result, result.isFinal {
                let text = result.bestTranscription.formattedString
                self?.handleTranscript(text)
            }
            if error != nil {
                self?.stopListening()
            }
        }

        isListening = true
        print("[VoiceCommand] Listening started")
    }

    func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
        print("[VoiceCommand] Listening stopped")
    }

    // MARK: - Transcript handling

    // Also callable from MockDeviceKitService.simulateVoiceCommand()
    // so the full pipeline runs in the simulator.
    func handleTranscript(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.lastTranscript = text
        }
        let command = VoiceCommandParser.parse(text)
        DispatchQueue.main.async { [weak self] in
            self?.lastCommand = command
        }
        commandPublisher.send(command)
        print("[VoiceCommand] Parsed: \(command)")
    }
}

// MARK: - Parser

enum VoiceCommandParser {

    // All matching is case-insensitive and strips common speech-to-text
    // artifacts like "um", "uh", leading/trailing whitespace.
    static func parse(_ raw: String) -> ParsedCommand {
        let clean = raw
            .lowercased()
            .replacingOccurrences(of: #"\b(um|uh|er)\b"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // --- "capture nameplate" ---
        if clean.contains("capture nameplate") || clean.hasPrefix("nameplate") {
            return .captureNameplate
        }

        // --- "capture damage [room] [surface]" ---
        // Flexible: "capture damage kitchen north wall", "damage bathroom floor"
        if let (room, surface) = parseDamageCommand(clean) {
            return .captureDamage(room: room, surface: surface)
        }

        // --- "note: [free text]" ---
        if let noteText = parseNoteCommand(raw) {  // use original case for notes
            return .note(text: noteText)
        }

        // --- Extension point for live session task ---
        // if let (value, location) = parseMoistureCommand(clean) {
        //     return .captureMoisture(value: value, location: location)
        // }

        return .unknown(rawText: raw)
    }

    // MARK: - Individual parsers

    private static func parseDamageCommand(_ text: String) -> (room: String, surface: String)? {
        // Pattern: "capture damage" or just "damage" followed by optional room + surface
        let pattern = #"(?:capture\s+)?damage\s*(?:,\s*)?([a-z\s]+?)(?:\s*,\s*|\s+)([\w\s]+(?:wall|floor|ceiling|surface|door|window|cabinet))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else {
            // Also catch bare "damage [room]" with known rooms
            if text.contains("damage") {
                let (room, surface) = extractRoomSurface(from: text)
                return (room, surface)
            }
            return nil
        }

        let roomRange = Range(match.range(at: 1), in: text)
        let surfaceRange = Range(match.range(at: 2), in: text)

        let room = roomRange.map { String(text[$0]).trimmingCharacters(in: .whitespaces) } ?? "unknown room"
        let surface = surfaceRange.map { String(text[$0]).trimmingCharacters(in: .whitespaces) } ?? "unknown surface"

        return (room.isEmpty ? "unknown room" : room,
                surface.isEmpty ? "unknown surface" : surface)
    }

    private static func extractRoomSurface(from text: String) -> (String, String) {
        let knownRooms = ["kitchen", "bathroom", "bedroom", "living room", "basement",
                          "garage", "hallway", "laundry", "attic", "crawl space"]
        let knownSurfaces = ["north wall", "south wall", "east wall", "west wall",
                             "ceiling", "floor", "subfloor", "cabinet", "door", "window"]

        var room = "unknown room"
        var surface = "unknown surface"

        for r in knownRooms {
            if text.contains(r) { room = r; break }
        }
        for s in knownSurfaces {
            if text.contains(s) { surface = s; break }
        }
        return (room, surface)
    }

    private static func parseNoteCommand(_ text: String) -> String? {
        // "note: [text]" or "note [text]" (colon optional)
        let pattern = #"^note\s*:?\s*(.+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }

        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Uncomment for live-session task:
    // private static func parseMoistureCommand(_ text: String) -> (value: String, location: String)? {
    //     let pattern = #"capture\s+moisture\s+reading\s+([\d.]+%?)\s+(.+)"#
    //     guard let regex = try? NSRegularExpression(pattern: pattern),
    //           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
    //           let valRange = Range(match.range(at: 1), in: text),
    //           let locRange = Range(match.range(at: 2), in: text)
    //     else { return nil }
    //     return (String(text[valRange]), String(text[locRange]))
    // }
}
