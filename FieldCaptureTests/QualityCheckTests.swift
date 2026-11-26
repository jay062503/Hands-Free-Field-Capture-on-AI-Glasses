// QualityCheckTests.swift
// FieldCaptureTests
//
// Tests for QualityCheckService threshold logic.
// We can't test the actual image analysis in a unit test without real frames,
// so we test the threshold comparison and result struct construction.

import XCTest
@testable import FieldCapture

final class QualityCheckTests: XCTestCase {

    let service = QualityCheckService.shared

    func test_defaultThresholds_areReasonable() {
        let t = service.thresholds
        // Blur threshold should allow normal handheld photography
        XCTAssertGreaterThan(t.minBlurScore, 20.0)
        XCTAssertLessThan(t.minBlurScore, 300.0)

        // Brightness threshold should catch dark shots but allow dim-but-usable
        XCTAssertGreaterThan(t.minBrightness, 10.0)
        XCTAssertLessThan(t.minBrightness, 80.0)

        // Framing threshold should not be too aggressive
        XCTAssertGreaterThan(t.minFraming, 0.05)
        XCTAssertLessThan(t.minFraming, 0.5)
    }

    func test_qualityResult_allPass_hasNoFailures() {
        let result = QualityCheckResult(
            passed: true,
            blurScore: 150.0,
            brightnessScore: 100.0,
            framingScore: 0.4,
            failureReasons: [],
            thresholdsUsed: service.thresholds
        )
        XCTAssertTrue(result.passed)
        XCTAssertTrue(result.failureReasons.isEmpty)
    }

    func test_qualityResult_allFail_hasThreeReasons() {
        let result = QualityCheckResult(
            passed: false,
            blurScore: 10.0,
            brightnessScore: 5.0,
            framingScore: 0.01,
            failureReasons: ["Blurry", "Too dark", "Subject cut off"],
            thresholdsUsed: service.thresholds
        )
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.failureReasons.count, 3)
    }

    func test_thresholds_serialiseAndDeserialise() throws {
        let t = service.thresholds
        let data = try JSONEncoder().encode(t)
        let decoded = try JSONDecoder().decode(QualityThresholds.self, from: data)
        XCTAssertEqual(t.minBlurScore, decoded.minBlurScore)
        XCTAssertEqual(t.minBrightness, decoded.minBrightness)
        XCTAssertEqual(t.minFraming, decoded.minFraming)
    }
}
