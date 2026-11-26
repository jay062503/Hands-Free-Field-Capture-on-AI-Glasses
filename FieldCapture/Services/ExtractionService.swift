// ExtractionService.swift
// FieldCapture
//
// Sends a pre-processed frame to Google Gemini 1.5 Flash and returns
// structured extraction results with per-field confidence scores.
//
// Vision model: gemini-1.5-flash-latest (free tier: 15 req/min, 1500/day)
// Why Gemini Flash:
//   - Free tier — no billing required
//   - Native multimodal (image + text in one call)
//   - JSON mode via responseMimeType
//   - ~1–2 s per call
//
// API key: stored in Info.plist as GEMINI_API_KEY, loaded at runtime.
// Never hardcoded. See README for setup.
//
// Image is pre-processed (auto-levels, sharpen, upscale) before the API
// call via QualityCheckService.shared.preprocessedJPEG(from:).
// Prompts are written to infer aggressively from low-quality images.

import Foundation
import CoreImage

final class ExtractionService {

    static let shared = ExtractionService()

    private let geminiURL = "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash-latest:generateContent"

    private var apiKey: String {
        Bundle.main.object(forInfoDictionaryKey: "GEMINI_API_KEY") as? String ?? ""
    }

    // MARK: - Main extraction entry point

    func extract(frame: CapturedFrame,
                 captureType: CaptureEvent.CaptureType,
                 voiceHint: String? = nil) async throws -> ExtractionResult {

        switch captureType {
        case .note:
            return .note(parseNoteLocally(voiceHint ?? ""))

        case .nameplate:
            // Pre-process before sending to API
            let b64 = QualityCheckService.shared.preprocessedJPEG(from: frame.image)
                   ?? encodeImage(frame.image)
            return try await extractNameplate(base64Image: b64, voiceHint: voiceHint)

        case .damage:
            let b64 = QualityCheckService.shared.preprocessedJPEG(from: frame.image)
                   ?? encodeImage(frame.image)
            return try await extractDamage(base64Image: b64, voiceHint: voiceHint)
        }
    }

    // MARK: - Nameplate Extraction

    private func extractNameplate(base64Image: String, voiceHint: String?) async throws -> ExtractionResult {

        var prompt = """
        You are an expert OCR assistant for property insurance claims.
        You are reading an appliance nameplate photo. The photo may be dark, blurry,
        taken at an angle, low resolution, or partially obscured — this is normal in field conditions.

        YOUR JOB: Extract every field. Never return null without a genuine attempt.

        Strategies for hard images:
        - Partial text: reconstruct from visible characters (e.g. "GE" + partial -> "GEW_")
        - Faded/embossed text: mentally increase contrast and read the shape
        - Rotated or angled: mentally correct the perspective
        - Serial number cut off: return whatever is visible with low confidence
        - Manufacture date: often encoded in serial (first 4 digits = YYWW, or letter A=Jan)

        Confidence scale:
          0.9+  clear and unambiguous
          0.7-0.9 mostly clear, minor uncertainty
          0.5-0.7 partial read or inferred
          0.3-0.5 best guess from context
          <0.3  barely readable but still include it

        Return ONLY valid JSON (no markdown, no code fences):
        {
          "make":             {"value": string_or_null, "confidence": float, "source": "vision_api"},
          "model":            {"value": string_or_null, "confidence": float, "source": "vision_api"},
          "serialNumber":     {"value": string_or_null, "confidence": float, "source": "vision_api"},
          "manufactureDate":  {"value": string_or_null, "confidence": float, "source": "vision_api"},
          "rawText": "everything readable from the label verbatim",
          "overallConfidence": float
        }
        """

        if let hint = voiceHint {
            prompt += "\n\nAdditional context: \(hint)"
        }
        prompt += "\n\nExtract all nameplate fields from this image."

        let responseText = try await callGemini(prompt: prompt, base64Image: base64Image)
        guard let data = responseText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ExtractionError.parseFailure("Could not parse nameplate JSON response")
        }

        return .nameplate(NameplateExtraction(
            make:             parseField(json["make"]),
            model:            parseField(json["model"]),
            serialNumber:     parseField(json["serialNumber"]),
            manufactureDate:  parseField(json["manufactureDate"]),
            rawText:          json["rawText"] as? String ?? "",
            overallConfidence: json["overallConfidence"] as? Double ?? 0.5
        ))
    }

    // MARK: - Damage Extraction

    private func extractDamage(base64Image: String, voiceHint: String?) async throws -> ExtractionResult {

        var prompt = """
        You are an expert property damage assessor for insurance claims.
        You are looking at a photo of water or structural damage. The photo may be dark,
        blurry, low resolution, or taken at an angle — this is normal in field conditions.

        YOUR JOB: Extract every field. Never return null without a genuine attempt.

        Strategies for hard images:
        - Dark image: look for shape outlines, watermarks, discolouration patterns
        - Blurry image: identify damage category from shapes and colours
        - Partial view: estimate room from visible fixtures (toilet=bathroom, stove=kitchen)
        - Size estimation: use ANY visible reference — door frame ~2m tall, light switch ~1.1m
          from floor, outlet ~0.3m wide, baseboard ~0.1m tall, tile ~0.3m square.
          Always attempt a size estimate even if uncertain. Set confidence below 0.5.
        - Never return null for damageType or severityLevel — always make a best guess.

        Voice command context (if provided) is ground truth for room and surface.

        Return ONLY valid JSON (no markdown, no code fences):
        {
          "room":          {"value": string, "confidence": float, "source": string},
          "surface":       {"value": string, "confidence": float, "source": string},
          "damageType":    {"value": string, "confidence": float, "source": string},
          "roughSizeM2":   {"value": string, "confidence": float, "source": string},
          "severityLevel": {"value": "low or medium or high", "confidence": float, "source": string},
          "overallConfidence": float
        }
        """

        if let hint = voiceHint {
            prompt += "\n\nVoice command context: \(hint). Use this as ground truth for room and surface."
        }
        prompt += "\n\nAssess the damage in this image. Provide your best estimate for every field."

        let responseText = try await callGemini(prompt: prompt, base64Image: base64Image)
        guard let data = responseText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ExtractionError.parseFailure("Could not parse damage JSON response")
        }

        return .damage(DamageExtraction(
            room:             parseField(json["room"]),
            surface:          parseField(json["surface"]),
            damageType:       parseField(json["damageType"]),
            roughSizeM2:      parseField(json["roughSizeM2"]),
            severityLevel:    parseField(json["severityLevel"]),
            overallConfidence: json["overallConfidence"] as? Double ?? 0.5
        ))
    }

    // MARK: - Note parsing (local, no API call)

    func parseNoteLocally(_ text: String) -> NoteExtraction {
        let lower = text.lowercased()
        let locationKeywords = ["kitchen", "bathroom", "bedroom", "basement", "hallway",
                                "garage", "attic", "living room", "by the", "near the",
                                "under the", "crawl space"]
        let location = locationKeywords.first { lower.contains($0) }.map {
            ConfidenceField(value: $0, confidence: 0.75, source: "keyword_match")
        }
        let isUrgent = ["urgent", "immediate", "asap", "right away"].contains { lower.contains($0) }
        return NoteExtraction(
            rawText: text,
            location: location,
            subject: ConfidenceField(value: text, confidence: 0.9, source: "voice_command"),
            urgency: ConfidenceField(
                value: isUrgent ? "urgent" : "normal",
                confidence: isUrgent ? 0.88 : 0.9,
                source: "keyword_match"
            ),
            overallConfidence: 0.85
        )
    }

    // MARK: - Gemini API call

    private func callGemini(prompt: String, base64Image: String) async throws -> String {
        guard !apiKey.isEmpty else {
            throw ExtractionError.networkFailure(
                "GEMINI_API_KEY not set in Info.plist. " +
                "Get a free key at https://aistudio.google.com/app/apikey"
            )
        }

        guard let url = URL(string: "\(geminiURL)?key=\(apiKey)") else {
            throw ExtractionError.networkFailure("Invalid Gemini URL")
        }

        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["inlineData": ["mimeType": "image/jpeg", "data": base64Image]],
                    ["text": prompt]
                ]
            ]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "temperature": 0.1,
                "maxOutputTokens": 700
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ExtractionError.networkFailure("No HTTP response")
        }
        guard http.statusCode == 200 else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            // Extract the Gemini error message if present
            if let errJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw ExtractionError.apiError("HTTP \(http.statusCode): \(message)")
            }
            throw ExtractionError.apiError("HTTP \(http.statusCode): \(bodyStr)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String
        else {
            throw ExtractionError.parseFailure("Unexpected Gemini response shape")
        }

        // Strip markdown code fences Gemini sometimes adds even with responseMimeType set
        return stripCodeFences(text)
    }

    // MARK: - Helpers

    private func encodeImage(_ cgImage: CGImage) -> String {
        let ciImage = CIImage(cgImage: cgImage)
        let context = CIContext()
        guard let jpegData = context.jpegRepresentation(
            of: ciImage,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.88]
        ) else { return "" }
        return jpegData.base64EncodedString()
    }

    private func parseField(_ raw: Any?) -> ConfidenceField {
        guard let dict = raw as? [String: Any] else {
            return ConfidenceField(value: nil, confidence: 0.0, source: "parse_error")
        }
        return ConfidenceField(
            value:      dict["value"] as? String,
            confidence: dict["confidence"] as? Double ?? 0.0,
            source:     dict["source"] as? String ?? "vision_api"
        )
    }

    private func stripCodeFences(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            let lines = t.components(separatedBy: "\n")
            let inner = lines.dropFirst().dropLast(lines.last?.trimmingCharacters(in: .whitespaces) == "```" ? 1 : 0)
            t = inner.joined(separator: "\n")
        }
        return t
    }
}

// MARK: - Errors

enum ExtractionError: Error, LocalizedError {
    case networkFailure(String)
    case apiError(String)
    case parseFailure(String)
    case imageEncodingFailure

    var errorDescription: String? {
        switch self {
        case .networkFailure(let m): return "Network failure: \(m)"
        case .apiError(let m):       return "API error: \(m)"
        case .parseFailure(let m):   return "Parse failure: \(m)"
        case .imageEncodingFailure:  return "Could not encode image"
        }
    }
}
