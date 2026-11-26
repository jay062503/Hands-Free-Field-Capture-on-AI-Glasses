// ContentView.swift
// FieldCapture
//
// Root view — shows the camera feed and overlays session controls,
// voice command status, quality check prompts, and capture count.

import SwiftUI
import AVFoundation

struct ContentView: View {

    @StateObject private var vm = SessionViewModel()
    @State private var showJobRecord = false
    @State private var simulatedCommandText = ""
    @State private var showSimulator = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Camera preview
            if vm.sessionState == .active || vm.sessionState == .paused {
                CameraPreviewView()
                    .ignoresSafeArea()
                    .opacity(vm.sessionState == .paused ? 0.4 : 1.0)
            }

            // Main overlay
            VStack(spacing: 0) {
                topBar
                Spacer()
                captureStatusOverlay
                Spacer()
                bottomControls
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 44)

            // Quality retake banner (hard-block only)
            if case .retakeNeeded(let reasons) = vm.captureStatus {
                retakeBanner(reasons: reasons)
            }

            // Advisory quality warnings (non-blocking)
            if !vm.qualityWarnings.isEmpty {
                warningBanner(reasons: vm.qualityWarnings)
            }

            // Error banner
            if let err = vm.errorMessage {
                errorBanner(message: err)
            }
        }
        .sheet(isPresented: $showJobRecord) {
            if let job = vm.job {
                JobRecordView(record: job)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Top Bar

    var topBar: some View {
        HStack {
            // Session state indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(sessionStateColor)
                    .frame(width: 10, height: 10)
                Text(sessionStateLabel)
                    .font(.caption)
                    .foregroundColor(.white)
            }

            Spacer()

            // Connectivity
            HStack(spacing: 4) {
                Image(systemName: vm.isConnected ? "wifi" : "wifi.slash")
                    .foregroundColor(vm.isConnected ? .green : .orange)
                    .font(.caption)
                if vm.pendingUploads > 0 {
                    Text("\(vm.pendingUploads) queued")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

            // Fallback indicator
            if vm.usingFallback {
                Text("PHONE CAM")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.8))
                    .cornerRadius(4)
                    .foregroundColor(.white)
            }

            Spacer()

            // Capture count
            Text("\(vm.captureCount) captures")
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.5))
        .cornerRadius(10)
    }

    // MARK: - Capture Status Overlay

    var captureStatusOverlay: some View {
        Group {
            switch vm.captureStatus {

            case .idle:
                VStack(spacing: 8) {
                    Image(systemName: "ear")
                        .font(.system(size: 32))
                        .foregroundColor(.white.opacity(0.6))
                    Text("Listening for commands")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.6))
                    if !vm.lastVoiceCommand.isEmpty {
                        Text("Last: \"\(vm.lastVoiceCommand)\"")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.4))
                    }
                }

            case .waitingForFrame(let type):
                StatusPill(
                    icon: "camera.viewfinder",
                    text: "Point at \(type == .nameplate ? "nameplate" : "damage") and hold steady",
                    color: .blue
                )

            case .processing:
                StatusPill(icon: "cpu", text: "Checking frame quality...", color: .yellow)

            case .extracting:
                StatusPill(icon: "sparkles", text: "Extracting fields...", color: .purple)

            case .captured(let type):
                StatusPill(
                    icon: "checkmark.circle.fill",
                    text: "\(type == .nameplate ? "Nameplate" : "Damage") captured ✓",
                    color: .green
                )

            case .paused:
                StatusPill(icon: "pause.circle", text: "Session paused", color: .orange)

            case .retakeNeeded:
                EmptyView() // handled by retakeBanner

            case .error(let msg):
                StatusPill(icon: "exclamationmark.triangle", text: msg, color: .red)
            }
        }
    }

    // MARK: - Bottom Controls

    var bottomControls: some View {
        VStack(spacing: 16) {
            // Voice command simulator (dev convenience — hidden in prod)
            if showSimulator {
                HStack {
                    TextField("Simulate voice command", text: $simulatedCommandText)
                        .textFieldStyle(.roundedBorder)
                        .foregroundColor(.black)
                        .submitLabel(.go)
                        .onSubmit {
                            vm.simulateCommand(simulatedCommandText)
                            simulatedCommandText = ""
                        }

                    Button("Send") {
                        vm.simulateCommand(simulatedCommandText)
                        simulatedCommandText = ""
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            HStack(spacing: 20) {
                // Mic button
                Button(action: toggleMicSimulator) {
                    Image(systemName: showSimulator ? "mic.slash.fill" : "mic.fill")
                        .font(.title2)
                        .padding(14)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Circle())
                        .foregroundColor(.white)
                }

                // Main session button
                Button(action: mainButtonAction) {
                    Text(mainButtonLabel)
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(mainButtonColor)
                        .cornerRadius(14)
                }

                // Job record button
                if vm.job != nil || vm.captureCount > 0 {
                    Button(action: { showJobRecord = true }) {
                        Image(systemName: "doc.text.fill")
                            .font(.title2)
                            .padding(14)
                            .background(Color.white.opacity(0.15))
                            .clipShape(Circle())
                            .foregroundColor(.white)
                    }
                } else {
                    // Pause / resume
                    Button(action: pauseResumeAction) {
                        Image(systemName: vm.sessionState == .paused ? "play.fill" : "pause.fill")
                            .font(.title2)
                            .padding(14)
                            .background(Color.white.opacity(0.15))
                            .clipShape(Circle())
                            .foregroundColor(.white)
                    }
                    .disabled(vm.sessionState != .active && vm.sessionState != .paused)
                    .opacity(vm.sessionState == .active || vm.sessionState == .paused ? 1.0 : 0.3)
                }
            }
        }
    }

    // MARK: - Warning Banner (advisory, non-blocking)

    func warningBanner(reasons: [String]) -> some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.yellow)
                Text("Quality note")
                    .font(.headline)
                    .foregroundColor(.white)
            }
            ForEach(reasons, id: \.self) { reason in
                Text("⚠️ \(reason)")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(16)
        .background(Color.black.opacity(0.75))
        .cornerRadius(14)
        .padding(.horizontal, 24)
        .transition(.opacity)
    }

    // MARK: - Retake Banner

    func retakeBanner(reasons: [String]) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                Text("Retake needed")
                    .font(.headline)
                    .foregroundColor(.white)
            }
            ForEach(reasons, id: \.self) { reason in
                Text("• \(reason)")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .background(Color.black.opacity(0.85))
        .cornerRadius(16)
        .padding(.horizontal, 24)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Error Banner

    func errorBanner(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .foregroundColor(.orange)
            Text(message)
                .font(.caption)
                .foregroundColor(.white)
                .lineLimit(2)
        }
        .padding(12)
        .background(Color.black.opacity(0.8))
        .cornerRadius(10)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .bottom)
    }

    // MARK: - Helpers

    var sessionStateColor: Color {
        switch vm.sessionState {
        case .active: return .green
        case .paused: return .orange
        case .disconnected: return .red
        case .starting: return .yellow
        default: return .gray
        }
    }

    var sessionStateLabel: String {
        switch vm.sessionState {
        case .idle: return "IDLE"
        case .starting: return "STARTING..."
        case .active: return "LIVE"
        case .paused: return "PAUSED"
        case .stopping: return "STOPPING"
        case .disconnected: return "DISCONNECTED"
        case .error: return "ERROR"
        }
    }

    var mainButtonLabel: String {
        switch vm.sessionState {
        case .idle, .error: return "Start Session"
        case .starting: return "Starting..."
        case .active, .paused, .disconnected: return "End Session"
        case .stopping: return "Stopping..."
        }
    }

    var mainButtonColor: Color {
        switch vm.sessionState {
        case .idle, .error: return .blue
        case .active, .paused, .disconnected: return .red.opacity(0.8)
        default: return .gray
        }
    }

    func mainButtonAction() {
        switch vm.sessionState {
        case .idle, .error:
            vm.startSession()
        case .active, .paused, .disconnected:
            vm.stopSession()
            showJobRecord = true
        default:
            break
        }
    }

    func pauseResumeAction() {
        if vm.sessionState == .active {
            vm.pauseSession()
        } else if vm.sessionState == .paused {
            vm.resumeSession()
        }
    }

    func toggleMicSimulator() {
        showSimulator.toggle()
    }
}

// MARK: - Status Pill

struct StatusPill: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.7))
        .cornerRadius(20)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(color.opacity(0.5), lineWidth: 1))
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
