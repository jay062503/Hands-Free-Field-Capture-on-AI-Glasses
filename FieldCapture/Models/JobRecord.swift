// JobRecord.swift
// FieldCapture
//
// Core data models for the job record schema.
// Every field in a job record comes from either a voice command,
// a nameplate capture, a damage capture, or a free-text note.

import Foundation

// MARK: - Top-level Job Record

struct JobRecord: Codable {
    var jobId: String
    var sessionId: String
    var technicianId: String?
    var startedAt: Date
    var completedAt: Date?
    var status: JobStatus
    var captures: [CaptureEvent]
    var notes: [StructuredNote]
    var lineItems: [LineItem]
    var metadata: JobMetadata

    enum JobStatus: String, Codable {
        case inProgress = "in_progress"
        case completed = "completed"
        case uploaded = "uploaded"
        case pendingUpload = "pending_upload"
    }
}

// MARK: - Capture Event

struct CaptureEvent: Codable, Identifiable {
    var id: String
    var captureType: CaptureType
    var timestamp: Date
    var imageLocalPath: String?
    var imageRemoteURL: String?
    var qualityCheck: QualityCheckResult
    var extraction: ExtractionResult
    var uploadStatus: UploadStatus

    enum CaptureType: String, Codable {
        case nameplate
        case damage
        case note
    }

    enum UploadStatus: String, Codable {
        case uploaded
        case queued
        case failed
    }
}

// MARK: - Quality Check

struct QualityCheckResult: Codable {
    var passed: Bool
    var blurScore: Double         // Laplacian variance; higher = sharper
    var brightnessScore: Double   // 0–255 mean pixel value
    var framingScore: Double      // subject coverage 0–1
    var failureReasons: [String]
    var thresholdsUsed: QualityThresholds
}

struct QualityThresholds: Codable {
    var minBlurScore: Double      // 80.0 — tuned on 40-frame test set
    var minBrightness: Double     // 40.0
    var minFraming: Double        // 0.15
}

// MARK: - Extraction Results (union-style with enum)

enum ExtractionResult: Codable {
    case nameplate(NameplateExtraction)
    case damage(DamageExtraction)
    case note(NoteExtraction)

    enum CodingKeys: String, CodingKey {
        case type, payload
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .nameplate(let n):
            try container.encode("nameplate", forKey: .type)
            try container.encode(n, forKey: .payload)
        case .damage(let d):
            try container.encode("damage", forKey: .type)
            try container.encode(d, forKey: .payload)
        case .note(let n):
            try container.encode("note", forKey: .type)
            try container.encode(n, forKey: .payload)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "nameplate":
            self = .nameplate(try container.decode(NameplateExtraction.self, forKey: .payload))
        case "damage":
            self = .damage(try container.decode(DamageExtraction.self, forKey: .payload))
        default:
            self = .note(try container.decode(NoteExtraction.self, forKey: .payload))
        }
    }
}

// MARK: - Nameplate Extraction

struct NameplateExtraction: Codable {
    var make: ConfidenceField
    var model: ConfidenceField
    var serialNumber: ConfidenceField
    var manufactureDate: ConfidenceField
    var rawText: String            // full OCR output for debugging
    var overallConfidence: Double
}

// MARK: - Damage Extraction

struct DamageExtraction: Codable {
    var room: ConfidenceField
    var surface: ConfidenceField
    var damageType: ConfidenceField
    var roughSizeM2: ConfidenceField   // square metres, estimated
    var severityLevel: ConfidenceField // low / medium / high
    var overallConfidence: Double
}

// MARK: - Note Extraction

struct NoteExtraction: Codable {
    var rawText: String
    var location: ConfidenceField?
    var subject: ConfidenceField?
    var urgency: ConfidenceField?      // normal / urgent
    var overallConfidence: Double
}

// MARK: - Shared Types

struct ConfidenceField: Codable {
    var value: String?
    var confidence: Double    // 0.0 – 1.0
    var source: String        // "vision_api" | "regex" | "voice_command" | "inferred"
}

struct StructuredNote: Codable, Identifiable {
    var id: String
    var timestamp: Date
    var rawVoiceText: String
    var extraction: NoteExtraction
}

// MARK: - Line Items

struct LineItem: Codable, Identifiable {
    var id: String
    var code: String           // e.g. "DRY-RR-SF"
    var description: String
    var unit: String           // "sq_ft" | "each" | "linear_ft"
    var estimatedQuantity: Double?
    var confidence: Double
    var sourceCaptures: [String]   // capture IDs that generated this item
}

// MARK: - Job Metadata

struct JobMetadata: Codable {
    var appVersion: String
    var sdkVersion: String
    var deviceMode: String     // "mock_device_kit" | "real_glasses" | "phone_camera"
    var connectivityEvents: [ConnectivityEvent]
    var totalCaptures: Int
    var failedQualityChecks: Int
    var retakeRequests: Int
}

struct ConnectivityEvent: Codable {
    var timestamp: Date
    var eventType: String      // "lost" | "restored"
    var queuedItemsAtEvent: Int
}
