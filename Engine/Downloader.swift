import Foundation

/// Downloads files to temporary storage with progress, respecting the Wi-Fi-only setting.
final class Downloader {
    private let session: URLSession

    init(wifiOnly: Bool) {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = !wifiOnly
        config.allowsExpensiveNetworkAccess = !wifiOnly
        config.allowsConstrainedNetworkAccess = !wifiOnly
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 30
        config.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: config)
    }

    /// Downloads `url` and returns the local file. `progress` receives 0...1.
    func download(_ url: URL, fileExtension: String, progress: @escaping (Double) -> Void) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue(HTTP.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        let operation = Operation(session: session, request: request, fileExtension: fileExtension, progress: progress)
        return try await withTaskCancellationHandler {
            try await operation.run()
        } onCancel: {
            operation.cancel()
        }
    }

    private final class Operation {
        let session: URLSession
        let request: URLRequest
        let fileExtension: String
        let progress: (Double) -> Void
        private var task: URLSessionDownloadTask?
        private var observation: NSKeyValueObservation?
        private let lock = NSLock()

        init(session: URLSession, request: URLRequest, fileExtension: String, progress: @escaping (Double) -> Void) {
            self.session = session
            self.request = request
            self.fileExtension = fileExtension
            self.progress = progress
        }

        func run() async throws -> URL {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: request) { [weak self] tempURL, response, error in
                    self?.observation?.invalidate()
                    if let error {
                        continuation.resume(throwing: KeepsakeError.from(error))
                        return
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                    guard let tempURL, status < 400 else {
                        continuation.resume(throwing: status == 403 || status == 410
                            ? KeepsakeError.server("The download link expired. Fetch the post again and retry.")
                            : KeepsakeError.downloadFailed)
                        return
                    }
                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(self?.fileExtension ?? "bin")
                    do {
                        try FileManager.default.moveItem(at: tempURL, to: destination)
                        continuation.resume(returning: destination)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                let progress = self.progress
                self.observation = task.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
                    progress(p.fractionCompleted)
                }
                lock.lock()
                self.task = task
                lock.unlock()
                task.resume()
            }
        }

        func cancel() {
            lock.lock()
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }
}
