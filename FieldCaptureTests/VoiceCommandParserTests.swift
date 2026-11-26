// VoiceCommandParserTests.swift
// FieldCaptureTests
//
// Unit tests for voice command parsing.
// These are the most important tests because if parsing breaks, the whole
// hands-free loop breaks. Each test mirrors a realistic speech-to-text output
// (imperfect casing, filler words, varied phrasing).

import XCTest
@testable import FieldCapture

final class VoiceCommandParserTests: XCTestCase {

    // MARK: - Nameplate

    func test_captureNameplate_exact() {
        XCTAssertEqual(VoiceCommandParser.parse("capture nameplate"), .captureNameplate)
    }

    func test_captureNameplate_withFillerWords() {
        XCTAssertEqual(VoiceCommandParser.parse("um capture nameplate"), .captureNameplate)
    }

    func test_captureNameplate_mixedCase() {
        XCTAssertEqual(VoiceCommandParser.parse("Capture Nameplate"), .captureNameplate)
    }

    func test_captureNameplate_bareWord() {
        // Speech often drops "capture" — just "nameplate" should still work
        XCTAssertEqual(VoiceCommandParser.parse("nameplate"), .captureNameplate)
    }

    // MARK: - Damage

    func test_captureDamage_full() {
        let result = VoiceCommandParser.parse("capture damage kitchen north wall")
        if case .captureDamage(let room, let surface) = result {
            XCTAssertTrue(room.contains("kitchen"))
            XCTAssertTrue(surface.contains("north wall") || surface.contains("wall"))
        } else {
            XCTFail("Expected captureDamage, got \(result)")
        }
    }

    func test_captureDamage_withComma() {
        let result = VoiceCommandParser.parse("capture damage, bathroom, ceiling")
        if case .captureDamage(let room, _) = result {
            XCTAssertTrue(room.contains("bathroom"))
        } else {
            XCTFail("Expected captureDamage")
        }
    }

    func test_captureDamage_noRoom() {
        // Should still produce a damage command with unknown room
        let result = VoiceCommandParser.parse("damage north wall")
        if case .captureDamage(_, let surface) = result {
            XCTAssertTrue(surface.contains("wall") || surface.contains("unknown"))
        } else {
            XCTFail("Expected captureDamage")
        }
    }

    func test_captureDamage_basementFloor() {
        let result = VoiceCommandParser.parse("capture damage basement floor")
        if case .captureDamage(let room, let surface) = result {
            XCTAssertTrue(room.contains("basement"))
            XCTAssertTrue(surface.contains("floor"))
        } else {
            XCTFail("Expected captureDamage")
        }
    }

    // MARK: - Note

    func test_note_withColon() {
        let result = VoiceCommandParser.parse("note: subfloor soft by the cabinet")
        if case .note(let text) = result {
            XCTAssertTrue(text.lowercased().contains("subfloor"))
        } else {
            XCTFail("Expected note, got \(result)")
        }
    }

    func test_note_withoutColon() {
        let result = VoiceCommandParser.parse("note subfloor feels soft near the sink")
        if case .note(let text) = result {
            XCTAssertTrue(text.lowercased().contains("subfloor"))
        } else {
            XCTFail("Expected note")
        }
    }

    func test_note_preservesMixedCase() {
        // Notes should keep original text for the job record
        let result = VoiceCommandParser.parse("note: Check the GFCI outlet near the sink")
        if case .note(let text) = result {
            XCTAssertTrue(text.contains("GFCI"))
        } else {
            XCTFail("Expected note")
        }
    }

    // MARK: - Unknown

    func test_unknown_randomSpeech() {
        let result = VoiceCommandParser.parse("hello is this working")
        if case .unknown(let raw) = result {
            XCTAssertFalse(raw.isEmpty)
        } else {
            XCTFail("Expected unknown")
        }
    }

    func test_unknown_empty() {
        let result = VoiceCommandParser.parse("")
        if case .unknown = result {
            // pass
        } else {
            XCTFail("Expected unknown for empty input")
        }
    }
}
