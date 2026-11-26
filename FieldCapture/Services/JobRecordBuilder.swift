// JobRecordBuilder.swift
// FieldCapture
//
// Accumulates captures, notes, and events during a session and
// assembles the final JobRecord + draft line items on session stop.
//
// Fixed from original:
//   - describeExtraction for nameplate no longer injects "water heater appliance"
//     unconditionally — it only uses actual extracted values, so line items
//     accurately reflect the real appliance rather than always triggering EQUIP-WH-EA.

import Foundation
import Combine

final class JobRecordBuilder: ObservableObject {

    private(set) var jobId: String = ""
    private(set) var sessionId: String = ""
    private(set) var startedAt: Date = Date()

    @Published private(set) var captures: [CaptureEvent] = []
    @Published private(set) var notes: [StructuredNote] = []
    @Published private(set) var lineItems: [LineItem] = []

    private var connectivityEvents: [ConnectivityEvent] = []

    // MARK: - Session lifecycle

    func beginSession(sessionId: String) {
        self.jobId = "JOB-\(UUID().uuidString.prefix(8).uppercased())"
        self.sessionId = sessionId
        self.startedAt = Date()
        captures = []
        notes = []
        lineItems = []
        connectivityEvents = []
        print("[JobRecord] Started job \(jobId)")
    }

    // MARK: - Add capture

    func addCapture(type: CaptureEvent.CaptureType,
                    frame: CapturedFrame,
                    quality: QualityCheckResult,
                    extraction: ExtractionResult) {
        let event = CaptureEvent(
            id: frame.frameId,
            captureType: type,
            timestamp: frame.timestamp,
            imageLocalPath: nil,
            imageRemoteURL: nil,
            qualityCheck: quality,
            extraction: extraction,
            uploadStatus: .queued
        )
        captures.append(event)
        print("[JobRecord] Added capture \(frame.frameId) type=\(type.rawValue)")
        regenerateLineItems()
    }

    // MARK: - Add note

    func addNote(rawText: String, extraction: NoteExtraction) {
        let note = StructuredNote(
            id: UUID().uuidString,
            timestamp: Date(),
            rawVoiceText: rawText,
            extraction: extraction
        )
        notes.append(note)
        regenerateLineItems()
    }

    // MARK: - Connectivity

    func recordConnectivityEvent(_ type: String, queueDepth: Int) {
        connectivityEvents.append(ConnectivityEvent(
            timestamp: Date(),
            eventType: type,
            queuedItemsAtEvent: queueDepth
        ))
    }

    // MARK: - Build final record

    func build(deviceMode: String) -> JobRecord {
        let failedQC = captures.filter { !$0.qualityCheck.passed }.count
        return JobRecord(
            jobId: jobId,
            sessionId: sessionId,
            technicianId: nil,
            startedAt: startedAt,
            completedAt: Date(),
            status: .completed,
            captures: captures,
            notes: notes,
            lineItems: lineItems,
            metadata: JobMetadata(
                appVersion: "1.0.0",
                sdkVersion: "DAT-1.0-Mock",
                deviceMode: deviceMode,
                connectivityEvents: connectivityEvents,
                totalCaptures: captures.count,
                failedQualityChecks: failedQC,
                retakeRequests: failedQC
            )
        )
    }

    // MARK: - Line item generation

    private func regenerateLineItems() {
        var seen: [String: LineItem] = [:]

        for capture in captures {
            let text    = describeExtraction(capture.extraction)
            let matches = LineItemCatalog.matches(for: text)
            let conf    = confidenceFromExtraction(capture.extraction)
            let size    = sizeFromExtraction(capture.extraction)

            for entry in matches {
                if var existing = seen[entry.code] {
                    existing.sourceCaptures.append(capture.id)
                    if let sizeStr = size,
                       let sizeVal = Double(sizeStr),
                       entry.unit == "sq_ft" || entry.unit == "sq_m" {
                        existing.estimatedQuantity = (existing.estimatedQuantity ?? 0) + sizeVal * 10.764
                    }
                    seen[entry.code] = existing
                } else {
                    let qty = size.flatMap(Double.init).map { $0 * 10.764 }
                    seen[entry.code] = LineItem(
                        id: UUID().uuidString,
                        code: entry.code,
                        description: entry.description,
                        unit: entry.unit,
                        estimatedQuantity: qty,
                        confidence: conf,
                        sourceCaptures: [capture.id]
                    )
                }
            }
        }

        for note in notes {
            for entry in LineItemCatalog.matches(for: note.extraction.rawText) {
                if seen[entry.code] == nil {
                    seen[entry.code] = LineItem(
                        id: UUID().uuidString,
                        code: entry.code,
                        description: entry.description,
                        unit: entry.unit,
                        estimatedQuantity: nil,
                        confidence: 0.6,
                        sourceCaptures: []
                    )
                }
            }
        }

        lineItems = Array(seen.values).sorted { $0.code < $1.code }
    }

    private func describeExtraction(_ result: ExtractionResult) -> String {
        switch result {
        case .nameplate(let n):
            // Only use actual extracted values — don't inject generic appliance keywords
            // that would always trigger EQUIP-WH-EA regardless of the real appliance.
            return [n.make.value, n.model.value, n.rawText]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        case .damage(let d):
            return [d.room.value, d.surface.value, d.damageType.value, d.severityLevel.value]
                .compactMap { $0 }.joined(separator: " ")
        case .note(let n):
            return n.rawText
        }
    }

    private func sizeFromExtraction(_ result: ExtractionResult) -> String? {
        if case .damage(let d) = result { return d.roughSizeM2.value }
        return nil
    }

    private func confidenceFromExtraction(_ result: ExtractionResult) -> Double {
        switch result {
        case .nameplate(let n): return n.overallConfidence
        case .damage(let d):    return d.overallConfidence
        case .note(let n):      return n.overallConfidence
        }
    }
}
