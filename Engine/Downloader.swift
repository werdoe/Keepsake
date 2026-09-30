import Foundation

/// Something that can fetch a file to local storage with progress.
/// The app uses a background session (keeps going when you leave the app);
/// the share extension uses the in-process `Downloader`.
protocol MediaDownloading: AnyObject {
    func download(_ source: MediaSource, url: URL, fileExtension: String, wifiOnly: Bool,
                  progress: @escaping (Double) -> Void) async throws -> URL
}

extension MediaDownloading {
    func request(for url: URL, headers: [String: String]?) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(HTTP.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers ?? [:] where !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}

/// Downloads files in-process with progress, respecting the Wi-Fi-only setting.
final class Downloader: MediaDownloading {
    private var sessions: [Bool: URLSession] = [:]
    private let lock = NSLock()

    private func session(wifiOnly: Bool) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[wifiOnly] { return existing }
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = !wifiOnly
        config.allowsExpensiveNetworkAccess = !wifiOnly
        config.allowsConstrainedNetworkAccess = !wifiOnly
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 30
        let session = URLSession(configuration: config)
        sessions[wifiOnly] = session
        return session
    }

    func download(_ source: MediaSource, url: URL, fileExtension: String, wifiOnly: Bool,
                  progress: @escaping (Double) -> Void) async throws -> URL {
        let operation = Operation(session: session(wifiOnly: wifiOnly), request: request(for: url, headers: source.headers),
                                  fileExtension: fileExtension, progress: progress)
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
            let fileExtension = self.fileExtension
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: request) { [weak self] tempURL, response, error in
                    self?.observation?.invalidate()
                    if let error {
                        continuation.resume(throwing: KeepsakeError.from(error))
                        return
                    }
                    do {
                        continuation.resume(returning: try Downloads.accept(tempURL, response: response, fileExtension: fileExtension))
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

enum Downloads {
    /// Checks the response and moves the finished download somewhere it won't be deleted.
    static func accept(_ tempURL: URL?, response: URLResponse?, fileExtension: String) throws -> URL {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard let tempURL, status < 400 else {
            throw status == 403 || status == 410
                ? KeepsakeError.server("The download link expired. Fetch the post again and retry.")
                : KeepsakeError.downloadFailed
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }
}
