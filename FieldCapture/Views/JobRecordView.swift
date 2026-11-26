// JobRecordView.swift
// FieldCapture
//
// Displays the completed job record with all captures, extracted fields,
// confidence scores, notes, and draft line items.
// Also provides a "Copy JSON" button for submitting the raw record.

import SwiftUI

struct JobRecordView: View {

    let record: JobRecord
    @State private var showRawJSON = false
    @State private var copied = false
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            List {
                // Header
                Section {
                    LabelRow(label: "Job ID", value: record.jobId)
                    LabelRow(label: "Session ID", value: record.sessionId)
                    LabelRow(label: "Status", value: record.status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                    LabelRow(label: "Device Mode", value: record.metadata.deviceMode)
                    LabelRow(label: "Total Captures", value: "\(record.metadata.totalCaptures)")
                    LabelRow(label: "Quality Failures", value: "\(record.metadata.failedQualityChecks)")
                    if let completed = record.completedAt {
                        LabelRow(label: "Duration", value: formatDuration(from: record.startedAt, to: completed))
                    }
                } header: { Text("Job Summary") }

                // Captures
                Section {
                    ForEach(record.captures) { capture in
                        CaptureRow(capture: capture)
                    }
                } header: { Text("Captures (\(record.captures.count))") }

                // Notes
                if !record.notes.isEmpty {
                    Section {
                        ForEach(record.notes) { note in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(note.rawVoiceText)
                                    .font(.subheadline)
                                Text("Urgency: \(note.extraction.urgency?.value ?? "normal") · Confidence: \(formatPct(note.extraction.overallConfidence))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    } header: { Text("Notes (\(record.notes.count))") }
                }

                // Line items
                Section {
                    ForEach(record.lineItems) { item in
                        LineItemRow(item: item)
                    }
                } header: { Text("Draft Line Items (\(record.lineItems.count))") }

                // Connectivity events
                if !record.metadata.connectivityEvents.isEmpty {
                    Section {
                        ForEach(record.metadata.connectivityEvents, id: \.timestamp) { ev in
                            HStack {
                                Image(systemName: ev.eventType == "lost" ? "wifi.slash" : "wifi")
                                    .foregroundColor(ev.eventType == "lost" ? .red : .green)
                                VStack(alignment: .leading) {
                                    Text(ev.eventType.capitalized)
                                        .font(.subheadline)
                                    Text("\(ev.queuedItemsAtEvent) items queued")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    } header: { Text("Connectivity Events") }
                }

                // Raw JSON
                Section {
                    Button(action: { showRawJSON.toggle() }) {
                        Label(showRawJSON ? "Hide JSON" : "Show Raw JSON", systemImage: "doc.text")
                    }
                    if showRawJSON {
                        ScrollView {
                            Text(prettyJSON)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 300)
                    }
                    Button(action: copyJSON) {
                        Label(copied ? "Copied!" : "Copy JSON", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                } header: { Text("Export") }
            }
            .navigationTitle("Job Record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    var prettyJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record),
              let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }

    func copyJSON() {
        UIPasteboard.general.string = prettyJSON
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copied = false }
        }
    }

    func formatDuration(from start: Date, to end: Date) -> String {
        let seconds = Int(end.timeIntervalSince(start))
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    func formatPct(_ val: Double) -> String {
        return String(format: "%.0f%%", val * 100)
    }
}

// MARK: - Sub-views

struct CaptureRow: View {
    let capture: CaptureEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: captureIcon)
                    .foregroundColor(captureColor)
                Text(capture.captureType.rawValue.capitalized)
                    .font(.headline)
                Spacer()
                ConfidenceBadge(confidence: overallConfidence)
            }

            switch capture.extraction {
            case .nameplate(let n):
                FieldRow(name: "Make", field: n.make)
                FieldRow(name: "Model", field: n.model)
                FieldRow(name: "Serial", field: n.serialNumber)
                FieldRow(name: "Manufacture Date", field: n.manufactureDate)
            case .damage(let d):
                FieldRow(name: "Room", field: d.room)
                FieldRow(name: "Surface", field: d.surface)
                FieldRow(name: "Damage Type", field: d.damageType)
                FieldRow(name: "Size (m²)", field: d.roughSizeM2)
                FieldRow(name: "Severity", field: d.severityLevel)
            case .note(let n):
                Text(n.rawText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                QualityDot(passed: capture.qualityCheck.passed, label: "Quality")
                UploadDot(status: capture.uploadStatus)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 6)
    }

    var captureIcon: String {
        switch capture.captureType {
        case .nameplate: return "tag.fill"
        case .damage: return "exclamationmark.triangle.fill"
        case .note: return "note.text"
        }
    }

    var captureColor: Color {
        switch capture.captureType {
        case .nameplate: return .blue
        case .damage: return .orange
        case .note: return .purple
        }
    }

    var overallConfidence: Double {
        switch capture.extraction {
        case .nameplate(let n): return n.overallConfidence
        case .damage(let d): return d.overallConfidence
        case .note(let n): return n.overallConfidence
        }
    }
}

struct FieldRow: View {
    let name: String
    let field: ConfidenceField

    var body: some View {
        HStack {
            Text(name)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(field.value ?? "—")
                .font(.caption)
            Spacer()
            ConfidenceBadge(confidence: field.confidence)
        }
    }
}

struct ConfidenceBadge: View {
    let confidence: Double

    var color: Color {
        if confidence >= 0.8 { return .green }
        if confidence >= 0.6 { return .yellow }
        return .red
    }

    var body: some View {
        Text(String(format: "%.0f%%", confidence * 100))
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(4)
    }
}

struct QualityDot: View {
    let passed: Bool
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(passed ? Color.green : Color.red)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

struct UploadDot: View {
    let status: CaptureEvent.UploadStatus

    var color: Color {
        switch status {
        case .uploaded: return .green
        case .queued: return .orange
        case .failed: return .red
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(status.rawValue.capitalized)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

struct LineItemRow: View {
    let item: LineItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.code)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.blue)
                Spacer()
                ConfidenceBadge(confidence: item.confidence)
            }
            Text(item.description)
                .font(.subheadline)
            HStack {
                if let qty = item.estimatedQuantity {
                    Text(String(format: "%.1f %@", qty, item.unit))
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Quantity TBD")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("\(item.sourceCaptures.count) source(s)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct LabelRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}
