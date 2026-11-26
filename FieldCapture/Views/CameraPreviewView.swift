// CameraPreviewView.swift
// FieldCapture
//
// UIViewRepresentable wrapper for AVCaptureVideoPreviewLayer.
// Shows the live camera feed behind the UI overlay.

import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {

    class PreviewView: UIView {
        override class var layerClass: AnyClass {
            return AVCaptureVideoPreviewLayer.self
        }
        var previewLayer: AVCaptureVideoPreviewLayer {
            return layer as! AVCaptureVideoPreviewLayer
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.connection?.videoOrientation = .portrait

        // Connect to a shared capture session managed by AppCaptureSession.
        view.previewLayer.session = AppCaptureSession.shared.session
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

// MARK: - Shared Capture Session

// A lightweight singleton so both the preview and the MockDeviceKitService
// can reference the same AVCaptureSession without creating two camera streams.
final class AppCaptureSession {
    static let shared = AppCaptureSession()
    let session = AVCaptureSession()
    private init() {}
}
