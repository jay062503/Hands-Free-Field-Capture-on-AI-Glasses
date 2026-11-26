// UploadQueueService.swift
// FieldCapture
//
// Handles offline-first capture upload.
// Captures are written to disk immediately on capture.
// A network monitor watches connectivity and drains the queue
// when signal returns.
//
// Design decisions:
//   - Persistence via simple JSON on disk (no CoreData dependency for a 72hr build)
//   - Upload order is FIFO — preserves walkthrough sequence
//   - Each item retried up to 3 times with exponential back-off before marking failed
//   - Failed items stay in queue for the session; job record flags them

import Foundation
import Network
import Combine

final class UploadQueueService: ObservableObject {

    static let shared = UploadQueueService()

    @Published private(set) var pendingCount: Int = 0
    @Published private(set) var isConnected: Bool = true

    private let queueDir: URL
    private var queue: [QueuedUpload] = []
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.fieldcapture.networkmonitor")
    private var cancellables = Set<AnyCancellable>()
    private var isUploading = false

    // MARK: - Init

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        queueDir = docs.appendingPathComponent("FieldCapture/UploadQueue", isDirectory: true)
        try? FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
        loadQueueFromDisk()
        startNetworkMonitor()
    }

    // MARK: - Enqueue

    func enqueue(captureId: String,
                 jobId: String,
                 imageData: Data,
                 extraction: ExtractionResult,
                 captureType: CaptureEvent.CaptureType) {

        let item = QueuedUpload(
            id: UUID().uuidString,
            captureId: captureId,
            jobId: jobId,
            imagePath: saveImage(imageData, captureId: captureId),
            extractionPayload: encodeExtraction(extraction),
            captureType: captureType.rawValue,
            enqueuedAt: Date(),
            attempts: 0,
            status: .pending
        )

        queue.append(item)
        saveQueueToDisk()
        pendingCount = queue.filter { $0.status == .pending || $0.status == .retrying }.count

        print("[UploadQueue] Enqueued \(captureId). Queue depth: \(pendingCount)")

        if isConnected {
            Task { await drainQueue() }
        }
    }

    // MARK: - Network Monitor

    private func startNetworkMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            DispatchQueue.main.async {
                self?.isConnected = connected
                if connected {
                    print("[UploadQueue] Connectivity restored — draining queue")
                    Task { await self?.drainQueue() }
                } else {
                    print("[UploadQueue] Connectivity lost — captures will queue")
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }

    // MARK: - Drain

    private func drainQueue() async {
        guard !isUploading else { return }
        isUploading = true
        defer { isUploading = false }

        while let index = queue.firstIndex(where: {
            ($0.status == .pending || $0.status == .retrying) && $0.attempts < 3
        }) {
            guard isConnected else { break }

            queue[index].status = .retrying
            queue[index].attempts += 1

            let item = queue[index]
            print("[UploadQueue] Uploading \(item.captureId), attempt \(item.attempts)")

            let success = await uploadItem(item)
            if success {
                queue[index].status = .uploaded
                print("[UploadQueue] Uploaded \(item.captureId)")
            } else {
                if item.attempts >= 3 {
                    queue[index].status = .failed
                    print("[UploadQueue] Failed \(item.captureId) after 3 attempts")
                } else {
                    queue[index].status = .pending
                    // Exponential back-off: 2s, 4s, 8s
                    let delay = pow(2.0, Double(item.attempts))
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }

            await MainActor.run {
                pendingCount = queue.filter { $0.status == .pending || $0.status == .retrying }.count
            }
            saveQueueToDisk()
        }
    }

    // MARK: - Upload (stubbed — replace with real endpoint)
    // In production this posts multipart/form-data to the Cozmo backend.
    // The endpoint, auth token, and retry policy would come from config.
    private func uploadItem(_ item: QueuedUpload) async -> Bool {
        // Simulate a network call. Replace with real URLSession call.
        // We simulate 80% success rate to exercise the retry path.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let success = Double.random(in: 0...1) > 0.2
        return success
    }

    // MARK: - Persistence

    private func saveImage(_ data: Data, captureId: String) -> String {
        let url = queueDir.appendingPathComponent("\(captureId).jpg")
        try? data.write(to: url)
        return url.path
    }

    private func saveQueueToDisk() {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        let url = queueDir.appendingPathComponent("queue.json")
        try? data.write(to: url)
    }

    private func loadQueueFromDisk() {
        let url = queueDir.appendingPathComponent("queue.json")
        guard let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode([QueuedUpload].self, from: data)
        else { return }
        // On reload, reset in-flight items to pending.
        queue = loaded.map { item in
            var i = item
            if i.status == .retrying { i.status = .pending }
            return i
        }
        pendingCount = queue.filter { $0.status == .pending || $0.status == .retrying }.count
        print("[UploadQueue] Loaded \(queue.count) items from disk, \(pendingCount) pending")
    }

    private func encodeExtraction(_ result: ExtractionResult) -> Data {
        return (try? JSONEncoder().encode(result)) ?? Data()
    }

    // MARK: - Job Record patch

    func connectivityEvents() -> [ConnectivityEvent] {
        // Returns events observed this session for embedding in JobRecord.
        return []  // populated properly in a full implementation
    }
}

// MARK: - Queue Item Model

struct QueuedUpload: Codable {
    var id: String
    var captureId: String
    var jobId: String
    var imagePath: String
    var extractionPayload: Data
    var captureType: String
    var enqueuedAt: Date
    var attempts: Int
    var status: UploadItemStatus

    enum UploadItemStatus: String, Codable {
        case pending
        case retrying
        case uploaded
        case failed
    }
}
