// LineItemCatalogTests.swift
// FieldCaptureTests
//
// Tests that extraction text correctly maps to line-item codes.

import XCTest
@testable import FieldCapture

final class LineItemCatalogTests: XCTestCase {

    func test_drywall_matched() {
        let matches = LineItemCatalog.matches(for: "water stain on drywall")
        let codes = matches.map(\.code)
        XCTAssertTrue(codes.contains("DRY-RR-SF"))
    }

    func test_subfloor_matched() {
        let matches = LineItemCatalog.matches(for: "subfloor soft by the cabinet")
        let codes = matches.map(\.code)
        XCTAssertTrue(codes.contains("FLR-SUB-SF"))
    }

    func test_mold_matched() {
        let matches = LineItemCatalog.matches(for: "black mold on ceiling")
        let codes = matches.map(\.code)
        XCTAssertTrue(codes.contains("MOLD-TREAT-SF"))
    }

    func test_waterHeater_matched() {
        let matches = LineItemCatalog.matches(for: "water heater nameplate, GE model XJ-12")
        let codes = matches.map(\.code)
        XCTAssertTrue(codes.contains("EQUIP-WH-EA"))
    }

    func test_carpet_matched() {
        let matches = LineItemCatalog.matches(for: "carpet soaked, water damage in bedroom")
        let codes = matches.map(\.code)
        XCTAssertTrue(codes.contains("FLR-CAR-SF"))
    }

    func test_noMatch_unrelatedText() {
        let matches = LineItemCatalog.matches(for: "sunny day outside")
        XCTAssertTrue(matches.isEmpty)
    }

    func test_allCatalogEntriesHaveCodes() {
        for entry in LineItemCatalog.all {
            XCTAssertFalse(entry.code.isEmpty, "Entry has empty code: \(entry.description)")
            XCTAssertFalse(entry.triggerKeywords.isEmpty, "Entry has no keywords: \(entry.code)")
        }
    }

    func test_catalogHasAtLeastFifteenEntries() {
        XCTAssertGreaterThanOrEqual(LineItemCatalog.all.count, 15)
    }

    func test_findByCode() {
        let entry = LineItemCatalog.find(by: "DRY-RR-SF")
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.unit, "sq_ft")
    }
}
