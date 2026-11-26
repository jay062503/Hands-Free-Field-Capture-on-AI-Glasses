// LineItemCatalog.swift
// FieldCapture
//
// Defines the 15 line-item codes used in draft estimates.
// Codes are intentionally simple strings — a real integration
// would map these to Xactimate activity codes, but for this
// submission they serve as stand-ins that the reviewer can
// trace back to observations in the job record.

import Foundation

struct LineItemCatalog {

    // All 15 codes with descriptions, unit, and the trigger keywords
    // the mapping engine looks for in extraction results.
    static let all: [CatalogEntry] = [
        CatalogEntry(
            code: "DRY-RR-SF",
            description: "Remove and replace drywall",
            unit: "sq_ft",
            triggerKeywords: ["drywall", "wall", "ceiling", "plaster", "sheetrock"]
        ),
        CatalogEntry(
            code: "INS-RR-SF",
            description: "Remove and replace insulation (batt)",
            unit: "sq_ft",
            triggerKeywords: ["insulation", "batt", "fiberglass"]
        ),
        CatalogEntry(
            code: "FLR-SUB-SF",
            description: "Remove and replace subfloor (3/4\" OSB)",
            unit: "sq_ft",
            triggerKeywords: ["subfloor", "sub-floor", "floor sheathing", "soft floor"]
        ),
        CatalogEntry(
            code: "FLR-HAR-SF",
            description: "Remove and replace hardwood flooring",
            unit: "sq_ft",
            triggerKeywords: ["hardwood", "wood floor", "engineered wood"]
        ),
        CatalogEntry(
            code: "FLR-CAR-SF",
            description: "Remove and replace carpet and pad",
            unit: "sq_ft",
            triggerKeywords: ["carpet", "carpeting", "rug", "pad"]
        ),
        CatalogEntry(
            code: "FLR-TIL-SF",
            description: "Remove and replace ceramic/porcelain tile",
            unit: "sq_ft",
            triggerKeywords: ["tile", "ceramic", "porcelain", "grout"]
        ),
        CatalogEntry(
            code: "MOLD-TREAT-SF",
            description: "Mold remediation treatment",
            unit: "sq_ft",
            triggerKeywords: ["mold", "mildew", "black spot", "fungus", "microbial"]
        ),
        CatalogEntry(
            code: "PAINT-WALL-SF",
            description: "Paint walls (2 coats)",
            unit: "sq_ft",
            triggerKeywords: ["paint", "stain", "discoloration", "water stain"]
        ),
        CatalogEntry(
            code: "EQUIP-WH-EA",
            description: "Water heater replacement (40-gal electric)",
            unit: "each",
            triggerKeywords: ["water heater", "hot water heater", "water tank"]
        ),
        CatalogEntry(
            code: "EQUIP-DH-EA",
            description: "Dehumidifier placement (commercial)",
            unit: "each",
            triggerKeywords: ["humid", "moisture", "wet", "water damage", "flood"]
        ),
        CatalogEntry(
            code: "EQUIP-FAN-EA",
            description: "Air mover / drying fan placement",
            unit: "each",
            triggerKeywords: ["dry out", "air mover", "fan", "drying"]
        ),
        CatalogEntry(
            code: "DEMO-HAZ-HR",
            description: "Hazardous material handling (asbestos/lead presumed)",
            unit: "hours",
            triggerKeywords: ["asbestos", "lead", "popcorn ceiling", "textured ceiling", "pre-1980"]
        ),
        CatalogEntry(
            code: "TRIM-BASEBOARD-LF",
            description: "Remove and replace baseboard trim",
            unit: "linear_ft",
            triggerKeywords: ["baseboard", "trim", "molding"]
        ),
        CatalogEntry(
            code: "STRUC-BEAM-LF",
            description: "Structural beam assessment and repair",
            unit: "linear_ft",
            triggerKeywords: ["beam", "joist", "structural", "framing", "rot"]
        ),
        CatalogEntry(
            code: "CONTENT-PACK-HR",
            description: "Contents pack-out and inventory",
            unit: "hours",
            triggerKeywords: ["contents", "furniture", "belongings", "pack out", "move out"]
        )
    ]

    static func find(by code: String) -> CatalogEntry? {
        return all.first { $0.code == code }
    }

    // Returns all entries whose trigger keywords overlap with the given text.
    static func matches(for text: String) -> [CatalogEntry] {
        let lower = text.lowercased()
        return all.filter { entry in
            entry.triggerKeywords.contains { lower.contains($0) }
        }
    }
}

struct CatalogEntry {
    let code: String
    let description: String
    let unit: String
    let triggerKeywords: [String]
}
