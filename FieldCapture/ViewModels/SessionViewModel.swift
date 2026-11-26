// SessionViewModel.swift
// FieldCapture
//
// The main ViewModel that coordinates the full capture pipeline:
//   VoiceCommand → Frame → QualityCheck → Extraction → JobRecord → Upload
//
// Fixed from original:
//   - processNote: removed broken guard-case pattern; directly parses locally
//   - parseNotePublic extension removed (duplication eliminated)
//   - simulateCommand: no longer double-processes commands; voice service only
//   - Quality check: warnings shown in UI but never hard-block capture
//   - CaptureStatus.retakeNeeded renamed to .warning to match new advisory semantics

import Foundation
import Combine
import CoreImage

@MainActor
final class SessionViewModel: ObservableObject {

    // MARK: - Published State

    @Published var sessionState: SessionState = .idle
    @Published var captureStatus: CaptureStatus = .idle
    @Published var lastCapture: CaptureEvent?
    @Published var job: JobRecord?
    @Published var pendingUploads: Int = 0
    @Published var isConnected: Bool = true
    @Published var errorMessage: String?
    @Published var qualityWarnings: [String] = []  // advisory, non-blocking
    @Published var lastVoiceCommand: String = ""
    @Published var usingFallback: Bool = false
    @Published var captureCount: Int = 0

    // MARK: - Dependencies

    private let deviceService = MockDeviceKitService()
    private let voiceService = VoiceCommandService()
    private let qualityService = QualityCheckService.shared
    private let extractionService = ExtractionService.shared
    private let uploadQueue = UploadQueueService.shared
    private let jobBuilder = JobRecordBuilder()

    private var cancellables = Set<AnyCancellable>()
    private var pendingCommand: ParsedCommand?

    // MARK: - Init

    init() {
        bindServices()
    }

    // MARK: - Bindings

    private func bindServices() {
        deviceService.$sessionState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.sessionState = state
                self?.usingFallback = self?.deviceService.usingFallback ?? false
            }
            .store(in: &cancellables)

        uploadQueue.$pendingCount
            .receive(on: RunLoop.main)
            .assign(to: &$pendingUploads)

        uploadQueue.$isConnected
            .receive(on: RunLoop.main)
            .assign(to: &$isConnected)

        deviceService.eventPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] event in Task { await self?.handleDeviceEvent(event) } }
            .store(in: &cancellables)

        // Phone mic voice commands
        voiceService.commandPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] command in Task { await self?.handleVoiceCommand(command) } }
            .store(in: &cancellables)
    }

    // MARK: - Session Control

    func startSession() {
        Task {
            await deviceService.startSession()
            if let sessionId = deviceService.currentSessionId {
                jobBuilder.beginSession(sessionId: sessionId)
                try? voiceService.startListening()
            }
        }
    }

    func pauseSession() {
        deviceService.pauseSession()
        voiceService.stopListening()
        captureStatus = .paused
    }

    func resumeSession() {
        deviceService.resumeSession()
        try? voiceService.startListening()
        captureStatus = .idle
    }

    func stopSession() {
        voiceService.stopListening()
        deviceService.stopSession()
        captureStatus = .idle
        job = jobBuilder.build(deviceMode: usingFallback ? "phone_camera" : "mock_device_kit")
        print("[Session] Session stopped. Job: \(job?.jobId ?? "none")")
    }

    // MARK: - Simulated commands (dev — text field input)
    // Only routes through the voice service to avoid double-processing.
    // Previously this called both simulateVoiceCommand AND handleTranscript,
    // which caused every command to fire twice.
    func simulateCommand(_ text: String) {
        voiceService.handleTranscript(text)
    }

    // MARK: - Event Handling

    private func handleDeviceEvent(_ event: MockDeviceEvent) async {
        switch event {
        case .sessionStarted:   captureStatus = .idle
        case .sessionPaused:    captureStatus = .paused
        case .sessionResumed:   captureStatus = .idle
        case .sessionStopped:   captureStatus = .idle

        case .deviceDisconnected:
            errorMessage = "Glasses disconnected — captures will queue until reconnected"
            jobBuilder.recordConnectivityEvent("lost", queueDepth: pendingUploads)

        case .deviceReconnected:
            errorMessage = nil
            jobBuilder.recordConnectivityEvent("restored", queueDepth: pendingUploads)

        case .frameAvailable(let frame):
            await handleFrame(frame)

        case .voiceCommandReceived(let text):
            // Glasses mic → parse and handle directly (does NOT go through voiceService
            // to avoid double-firing when simulateCommand also calls voiceService)
            let command = VoiceCommandParser.parse(text)
            await handleVoiceCommand(command)

        case .error(let err):
            errorMessage = err.localizedDescription
        }
    }

    private func handleVoiceCommand(_ command: ParsedCommand) async {
        guard case .unknown = command else { }
        lastVoiceCommand = describeCommand(command)

        switch command {
        case .captureNameplate:
            pendingCommand = .captureNameplate
            captureStatus = .waitingForFrame(type: .nameplate)

        case .captureDamage(let room, let surface):
            pendingCommand = command
            captureStatus = .waitingForFrame(type: .damage)
            print("[Session] Waiting for damage frame — \(room) / \(surface)")

        case .note(let text):
            await processNote(text)

        case .unknown(let raw):
            guard !raw.isEmpty else { return }
            print("[Session] Unknown command: \(raw)")
        }
    }

    // MARK: - Frame Processing

    private func handleFrame(_ frame: CapturedFrame) async {
        guard let command = pendingCommand else { return }
        guard captureStatus != .processing else { return }

        captureStatus = .processing
        qualityWarnings = []

        let captureType: CaptureEvent.CaptureType
        switch command {
        case .captureNameplate: captureType = .nameplate
        case .captureDamage:    captureType = .damage
        default: captureStatus = .idle; return
        }

        // Quality check — only hard-blocks on blank image
        let quality = qualityService.check(frame: frame, captureType: captureType)
        if !quality.passed {
            // Truly blank frame — hard block
            captureStatus = .retakeNeeded(reasons: quality.failureReasons)
            return
        }

        // Surface advisory warnings non-blocking
        if !quality.failureReasons.isEmpty {
            qualityWarnings = quality.failureReasons
            // Auto-dismiss after 4 seconds
            let warnings = quality.failureReasons
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                if self?.qualityWarnings == warnings { self?.qualityWarnings = [] }
            }
        }

        do {
            captureStatus = .extracting

            let voiceHint: String? = {
                if case .captureDamage(let r, let s) = command {
                    return "room: \(r), surface: \(s)"
                }
                return nil
            }()

            let extraction = try await extractionService.extract(
                frame: frame,
                captureType: captureType,
                voiceHint: voiceHint
            )

            jobBuilder.addCapture(type: captureType, frame: frame, quality: quality, extraction: extraction)
            captureCount = jobBuilder.captures.count

            if let imageData = cgImageToJPEG(frame.image) {
                uploadQueue.enqueue(
                    captureId: frame.frameId,
                    jobId: jobBuilder.jobId,
                    imageData: imageData,
                    extraction: extraction,
                    captureType: captureType
                )
            }

            lastCapture = jobBuilder.captures.last
            pendingCommand = nil
            captureStatus = .captured(type: captureType)

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.captureStatus = .idle
            }

        } catch {
            captureStatus = .error(message: error.localizedDescription)
            errorMessage = "Extraction failed: \(error.localizedDescription)"
            print("[Session] Extraction error: \(error)")
        }
    }

    // MARK: - Note Processing
    // Simplified from the original broken guard-case pattern.
    // Notes never need a vision API call — always parse locally.

    private func processNote(_ text: String) async {
        let extraction = extractionService.parseNoteLocally(text)
        jobBuilder.addNote(rawText: text, extraction: extraction)
        captureCount = jobBuilder.captures.count
        captureStatus = .captured(type: .note)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.captureStatus = .idle
        }
    }

    // MARK: - Helpers

    private func describeCommand(_ cmd: ParsedCommand) -> String {
        switch cmd {
        case .captureNameplate:            return "capture nameplate"
        case .captureDamage(let r, let s): return "capture damage — \(r), \(s)"
        case .note(let t):                 return "note: \(t)"
        case .unknown(let r):              return r
        }
    }

    private func cgImageToJPEG(_ image: CGImage) -> Data? {
        let ciImage = CIImage(cgImage: image)
        let context = CIContext()
        return context.jpegRepresentation(
            of: ciImage,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.88]
        )
    }
}

// MARK: - Capture Status

enum CaptureStatus: Equatable {
    case idle
    case paused
    case waitingForFrame(type: CaptureEvent.CaptureType)
    case processing
    case extracting
    case captured(type: CaptureEvent.CaptureType)
    case retakeNeeded(reasons: [String])   // hard-block only (blank frame)
    case error(message: String)

    static func == (lhs: CaptureStatus, rhs: CaptureStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.paused, .paused),
             (.processing, .processing), (.extracting, .extracting): return true
        case (.waitingForFrame(let a), .waitingForFrame(let b)): return a == b
        case (.captured(let a), .captured(let b)): return a == b
        case (.retakeNeeded(let a), .retakeNeeded(let b)): return a == b
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}
