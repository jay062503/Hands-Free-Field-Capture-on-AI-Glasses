// swift-tools-version: 5.9
// Package.swift — FieldCapture
//
// This file enables `swift build` and `swift test` from the command line
// and makes the project importable in SPM-aware editors.
// The actual Xcode project is FieldCapture.xcodeproj.
//
// Note: AVFoundation, Speech, CoreImage, Accelerate, Network, and Combine
// are all Apple system frameworks — no third-party dependencies.

import PackageDescription

let package = Package(
    name: "FieldCapture",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "FieldCapture", targets: ["FieldCapture"]),
    ],
    targets: [
        .target(
            name: "FieldCapture",
            path: "FieldCapture",
            sources: [
                "Models",
                "Services",
                "ViewModels",
                "Views",
                "FieldCaptureApp.swift"
            ],
            resources: [
                .process("Resources/Info.plist")
            ]
        ),
        .testTarget(
            name: "FieldCaptureTests",
            dependencies: ["FieldCapture"],
            path: "FieldCaptureTests"
        )
    ]
)
